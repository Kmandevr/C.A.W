#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
#include <shellapi.h>

#include <algorithm>
#include <optional>
#include <utility>
#include <variant>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

// Where the window's placement is kept between runs (per user).
constexpr wchar_t kPlacementKey[] = L"Software\\C.A.W\\Window";
constexpr wchar_t kPlacementValue[] = L"Placement";

// The smallest window, in logical pixels (scaled by the monitor's DPI).
constexpr int kMinWidth = 960;
constexpr int kMinHeight = 600;

// UTF-8 to UTF-16 for Win32 calls; empty on failure.
std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                                           static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring utf16(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), static_cast<int>(utf8.size()),
                        &utf16[0], length);
  return utf16;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

void FlutterWindow::SetLaunchFiles(std::vector<std::string> files) {
  launch_files_ = std::move(files);
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RestorePlacement();

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "caw/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setTitle") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            const auto it = args->find(flutter::EncodableValue("title"));
            if (it != args->end()) {
              if (const auto* title = std::get_if<std::string>(&it->second)) {
                ::SetWindowTextW(GetHandle(), Utf16FromUtf8(*title).c_str());
              }
            }
          }
          result->Success();
        } else if (call.method_name() == "takeLaunchFiles") {
          flutter::EncodableList files;
          for (const std::string& path : launch_files_) {
            files.emplace_back(path);
          }
          launch_files_.clear();
          result->Success(flutter::EncodableValue(files));
        } else {
          result->NotImplemented();
        }
      });

  // Files dropped from Explorer arrive as WM_DROPFILES.
  ::DragAcceptFiles(GetHandle(), TRUE);

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    if (restore_maximized_) {
      ::ShowWindow(GetHandle(), SW_MAXIMIZE);
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RestorePlacement() {
  WINDOWPLACEMENT placement{};
  DWORD size = static_cast<DWORD>(sizeof(placement));
  if (::RegGetValueW(HKEY_CURRENT_USER, kPlacementKey, kPlacementValue, RRF_RT_REG_BINARY, nullptr,
                     &placement, &size) != ERROR_SUCCESS ||
      size != sizeof(placement) || placement.length != sizeof(placement)) {
    return;
  }
  RECT rect = placement.rcNormalPosition;
  // Only onto a monitor that is still there, and kept inside its work area.
  HMONITOR monitor = ::MonitorFromRect(&rect, MONITOR_DEFAULTTONULL);
  if (monitor == nullptr) {
    return;
  }
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!::GetMonitorInfoW(monitor, &info)) {
    return;
  }
  const RECT work = info.rcWork;
  const LONG width = (std::min)(rect.right - rect.left, work.right - work.left);
  const LONG height = (std::min)(rect.bottom - rect.top, work.bottom - work.top);
  if (width <= 0 || height <= 0) {
    return;
  }
  const LONG left = (std::max)(work.left, (std::min)(rect.left, work.right - width));
  const LONG top = (std::max)(work.top, (std::min)(rect.top, work.bottom - height));
  placement.rcNormalPosition = RECT{left, top, left + width, top + height};
  restore_maximized_ = placement.showCmd == SW_SHOWMAXIMIZED;
  // Hidden until the first frame (Show); the maximized state is applied then.
  placement.showCmd = SW_HIDE;
  placement.flags = 0;
  ::SetWindowPlacement(GetHandle(), &placement);
}

void FlutterWindow::SavePlacement() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  WINDOWPLACEMENT placement{};
  placement.length = static_cast<UINT>(sizeof(placement));
  if (!::GetWindowPlacement(hwnd, &placement)) {
    return;
  }
  // A minimized window comes back at its normal size.
  if (placement.showCmd != SW_SHOWMAXIMIZED) {
    placement.showCmd = SW_SHOWNORMAL;
  }
  ::RegSetKeyValueW(HKEY_CURRENT_USER, kPlacementKey, kPlacementValue, REG_BINARY, &placement,
                    static_cast<DWORD>(sizeof(placement)));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  switch (message) {
    case WM_GETMINMAXINFO: {
      const UINT dpi = FlutterDesktopGetDpiForMonitor(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = ::MulDiv(kMinWidth, static_cast<int>(dpi), 96);
      info->ptMinTrackSize.y = ::MulDiv(kMinHeight, static_cast<int>(dpi), 96);
      return 0;
    }
    case WM_DROPFILES: {
      HDROP drop = reinterpret_cast<HDROP>(wparam);
      const UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      flutter::EncodableList paths;
      for (UINT i = 0; i < count; ++i) {
        const UINT length = ::DragQueryFileW(drop, i, nullptr, 0);
        if (length == 0) {
          continue;
        }
        std::wstring path(static_cast<size_t>(length) + 1, L'\0');
        ::DragQueryFileW(drop, i, &path[0], length + 1);
        path.resize(length);
        const std::string utf8 = Utf8FromUtf16(path.c_str());
        if (!utf8.empty()) {
          paths.emplace_back(utf8);
        }
      }
      ::DragFinish(drop);
      if (window_channel_ && !paths.empty()) {
        window_channel_->InvokeMethod("openFiles", std::make_unique<flutter::EncodableValue>(paths));
      }
      return 0;
    }
    case WM_CLOSE:
    case WM_DESTROY:
      // Before Flutter's lifecycle handling may take WM_CLOSE; WM_DESTROY saves
      // too in case it did.
      SavePlacement();
      break;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
