#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  static LRESULT CALLBACK ChildWindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                          LPARAM lparam, UINT_PTR subclass,
                                          DWORD_PTR ref);
  bool UpdatePillRegion();
  bool SetPillTooltip(const std::string* text);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
  bool mini_frame_ = false;
  bool rounded_mini_frame_ = false;
  bool pill_frame_ = false;
  std::optional<std::pair<LONG, LONG>> pill_clip_;
  HWND pill_tooltip_ = nullptr;
  std::wstring pill_tooltip_text_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
