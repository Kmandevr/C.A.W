// The `caw/video` method channel on Windows (see video_channel.h). Calls run on
// the platform thread one at a time; Dart waits for each frame before the next.
#include "video_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>
#include <vector>

#include "video_encoder.h"

namespace {

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
std::unique_ptr<Mp4Encoder> g_encoder;

std::wstring Utf16(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int n = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                                      static_cast<int>(utf8.size()), nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(n), L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), static_cast<int>(utf8.size()), &out[0], n);
  return out;
}

const flutter::EncodableValue* Arg(const flutter::EncodableMap* args, const char* name) {
  if (args == nullptr) return nullptr;
  const auto it = args->find(flutter::EncodableValue(name));
  return it == args->end() ? nullptr : &it->second;
}

int IntArg(const flutter::EncodableMap* args, const char* name, int fallback) {
  const auto* v = Arg(args, name);
  if (v == nullptr) return fallback;
  if (const auto* i = std::get_if<int32_t>(v)) return *i;
  if (const auto* l = std::get_if<int64_t>(v)) return static_cast<int>(*l);
  return fallback;
}

std::string StringArg(const flutter::EncodableMap* args, const char* name) {
  const auto* v = Arg(args, name);
  const auto* s = v == nullptr ? nullptr : std::get_if<std::string>(v);
  return s == nullptr ? std::string() : *s;
}

void Reply(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result, const std::string& error) {
  if (error.empty()) {
    result->Success();
  } else {
    result->Error("video", error);
  }
}

}  // namespace

void RegisterVideoChannel(flutter::BinaryMessenger* messenger) {
  g_encoder = std::make_unique<Mp4Encoder>();
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "caw/video", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        const std::string& method = call.method_name();
        if (method == "caps") {
          int max_long = 0, max_short = 0;
          Mp4Encoder::Caps(&max_long, &max_short);
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("maxLong"), flutter::EncodableValue(max_long)},
              {flutter::EncodableValue("maxShort"), flutter::EncodableValue(max_short)},
          }));
        } else if (method == "start") {
          Reply(result, g_encoder->Start(IntArg(args, "width", 0), IntArg(args, "height", 0), IntArg(args, "fps", 30),
                                         IntArg(args, "bitrate", 8000000), Utf16(StringArg(args, "audio")),
                                         Utf16(StringArg(args, "output"))));
        } else if (method == "frame") {
          const auto* v = Arg(args, "rgba");
          const auto* bytes = v == nullptr ? nullptr : std::get_if<std::vector<uint8_t>>(v);
          if (bytes == nullptr) {
            result->Error("video", "no frame");
            return;
          }
          Reply(result, g_encoder->AddFrame(bytes->data(), bytes->size()));
        } else if (method == "finish") {
          Reply(result, g_encoder->Finish());
        } else if (method == "cancel") {
          g_encoder->Cancel();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

void UnregisterVideoChannel() {
  g_channel = nullptr;
  g_encoder = nullptr;
}
