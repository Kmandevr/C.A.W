#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"

// The window that hosts the Flutter view. Over `caw/window` it takes its title
// from Dart (setTitle), hands Dart the files given on the command line
// (takeLaunchFiles) and the files dropped on it (openFiles). It keeps a minimum
// size and remembers its size and place between runs.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // The paths (UTF-8) given on the command line; kept until Dart asks for them.
  void SetLaunchFiles(std::vector<std::string> files);

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // `caw/window`: title, launch files and dropped files.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;

  // Files from the command line, until Dart takes them.
  std::vector<std::string> launch_files_;

  // The saved placement asked to be maximized: applied when the window shows.
  bool restore_maximized_ = false;

  // Puts the window where it was last closed (if that is still on a monitor).
  void RestorePlacement();

  // Saves the window's size, place and maximized state for the next run.
  void SavePlacement();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
