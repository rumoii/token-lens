#include "flutter_window.h"

#include <optional>
#include <commctrl.h>
#include <dwmapi.h>
#include <windowsx.h>

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

using flutter::EncodableList;
// DWMWA_WINDOW_CORNER_PREFERENCE and its values in the Windows 11 SDK.
constexpr DWORD kWindowCornerPreference = 33;
constexpr int kDefaultCorner = 0;
constexpr int kRoundCorner = 2;

BOOL CALLBACK CollectWorkArea(HMONITOR monitor, HDC, LPRECT, LPARAM context) {
  MONITORINFO info = {sizeof(info)};
  if (!GetMonitorInfo(monitor, &info)) return TRUE;
  const RECT& rect = info.rcWork;
  EncodableList area = {
      static_cast<int32_t>(rect.left), static_cast<int32_t>(rect.top),
      static_cast<int32_t>(rect.right - rect.left),
      static_cast<int32_t>(rect.bottom - rect.top),
      FlutterDesktopGetDpiForMonitor(monitor) / 96.0};
  auto& areas = *reinterpret_cast<EncodableList*>(context);
  if (info.dwFlags & MONITORINFOF_PRIMARY) {
    areas.insert(areas.begin(), flutter::EncodableValue(area));
  } else {
    areas.emplace_back(area);
  }
  return TRUE;
}

LRESULT ResizeEdge(HWND window, LPARAM position) {
  RECT frame;
  if (!GetWindowRect(window, &frame)) return HTCLIENT;
  const int x = GET_X_LPARAM(position), y = GET_Y_LPARAM(position);
  const int edge = MulDiv(6, GetDpiForWindow(window), 96);
  const bool left = x < frame.left + edge, right = x >= frame.right - edge;
  if (y < frame.top + edge) return left ? HTTOPLEFT : right ? HTTOPRIGHT : HTTOP;
  if (y >= frame.bottom - edge) return left ? HTBOTTOMLEFT : right ? HTBOTTOMRIGHT : HTBOTTOM;
  return left ? HTLEFT : right ? HTRIGHT : HTCLIENT;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  OnDestroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

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
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "token_lens/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "workAreas") {
          EncodableList areas;
          EnumDisplayMonitors(nullptr, nullptr, CollectWorkArea,
                              reinterpret_cast<LPARAM>(&areas));
          result->Success(flutter::EncodableValue(areas));
          return;
        }
        if (call.method_name() == "getFrame") {
          RECT rect;
          if (!GetWindowRect(GetHandle(), &rect)) {
            result->Error("window-frame", "Unable to read the window frame.");
            return;
          }
          const double scale = GetDpiForWindow(GetHandle()) / 96.0;
          result->Success(flutter::EncodableValue(EncodableList{
              static_cast<int32_t>(rect.left), static_cast<int32_t>(rect.top),
              (rect.right - rect.left) / scale,
              (rect.bottom - rect.top) / scale}));
          return;
        }
        if (call.method_name() == "setFrame") {
          const auto* args = call.arguments()
                                 ? std::get_if<EncodableList>(call.arguments())
                                 : nullptr;
          if (!args || args->size() != 4) {
            result->Error("bad-arguments", "setFrame requires four coordinates.");
            return;
          }
          // Positions are screen pixels. Size is in DIPs on the destination
          // display, so a move across monitors keeps the panel's logical size.
          POINT origin = {static_cast<LONG>(std::get<double>((*args)[0])),
                          static_cast<LONG>(std::get<double>((*args)[1]))};
          HMONITOR monitor = MonitorFromPoint(origin, MONITOR_DEFAULTTONEAREST);
          const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
          if (!SetWindowPos(GetHandle(), nullptr, origin.x, origin.y,
                            static_cast<int>(std::get<double>((*args)[2]) * scale + 0.5),
                            static_cast<int>(std::get<double>((*args)[3]) * scale + 0.5),
                            SWP_NOACTIVATE | SWP_NOZORDER)) {
            result->Error("window-frame", "Unable to set the window frame.");
            return;
          }
          result->Success();
          return;
        }
        if (call.method_name() == "setMiniFrame") {
          const auto* args = call.arguments()
                                 ? std::get_if<EncodableList>(call.arguments())
                                 : nullptr;
          if (!args || args->size() != 2 ||
              !std::holds_alternative<bool>((*args)[0]) ||
              !std::holds_alternative<bool>((*args)[1])) {
            result->Error("bad-arguments", "setMiniFrame requires two booleans.");
            return;
          }
          mini_frame_ = std::get<bool>((*args)[0]);
          const int corner = mini_frame_ && std::get<bool>((*args)[1])
                                 ? kRoundCorner : kDefaultCorner;
          const HRESULT status = DwmSetWindowAttribute(
              GetHandle(), kWindowCornerPreference, &corner, sizeof(corner));
          // Windows 10 rejects the corner preference and keeps square corners.
          rounded_mini_frame_ = corner == kRoundCorner && SUCCEEDED(status);
          if (!SetWindowPos(GetHandle(), nullptr, 0, 0, 0, 0,
                            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE |
                                SWP_NOACTIVATE | SWP_NOZORDER)) {
            result->Error("window-frame", "Unable to update the window frame.");
            return;
          }
          result->Success();
          return;
        }
        if (call.method_name() != "setDarkTitleBar") {
          result->NotImplemented();
          return;
        }
        const auto* dark = call.arguments()
                               ? std::get_if<bool>(call.arguments())
                               : nullptr;
        if (!dark) {
          result->Error("bad-arguments", "setDarkTitleBar requires a bool.");
          return;
        }
        if (FAILED(SetDarkTitleBar(*dark))) {
          result->Error("dwm-failed", "Unable to update the window title bar.");
          return;
        }
        result->Success();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  SetWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                    ChildWindowProc, 1, reinterpret_cast<DWORD_PTR>(this));

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (window_channel_) {
    window_channel_->SetMethodCallHandler(nullptr);
    window_channel_.reset();
  }
  if (flutter_controller_) {
    RemoveWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                         ChildWindowProc, 1);
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT CALLBACK FlutterWindow::ChildWindowProc(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR /*subclass*/, DWORD_PTR ref) {
  auto* window = reinterpret_cast<FlutterWindow*>(ref);
  if (message == WM_NCHITTEST && window->mini_frame_ &&
      ResizeEdge(window->GetHandle(), lparam) != HTCLIENT) {
    // Let the top-level window handle the resize grip inside the Flutter view.
    return HTTRANSPARENT;
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_NCCALCSIZE && mini_frame_) {
    auto* area = wparam
        ? &reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam)->rgrc[0]
        : reinterpret_cast<RECT*>(lparam);
    // Keep a physical pixel of native frame for DWM to draw the border and
    // shadow. The runner omits the caption while retaining the resize styles.
    if (rounded_mini_frame_) InflateRect(area, -1, -1);
    return 0;
  }
  if (message == WM_GETMINMAXINFO && !mini_frame_) {
    const UINT dpi = ::GetDpiForWindow(hwnd);
    auto* bounds = reinterpret_cast<MINMAXINFO*>(lparam);
    bounds->ptMinTrackSize.x = ::MulDiv(700, dpi, 96);
    bounds->ptMinTrackSize.y = ::MulDiv(500, dpi, 96);
    return 0;
  }
  if (message == WM_NCHITTEST && mini_frame_) {
    const LRESULT edge = ResizeEdge(hwnd, lparam);
    if (edge != HTCLIENT) return edge;
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
