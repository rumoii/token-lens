#include "flutter_window.h"

#include <algorithm>
#include <cmath>
#include <optional>
#include <commctrl.h>
#include <dwmapi.h>
#include <windowsx.h>

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

using flutter::EncodableList;
// DWM attributes introduced in the Windows 11 SDK.
constexpr DWORD kWindowCornerPreference = 33;
constexpr DWORD kBorderColor = 34;
constexpr COLORREF kDefaultBorder = 0xffffffff;
constexpr int kDefaultCorner = 0;
constexpr int kRoundCorner = 2;
constexpr double kPillSnapDistance = 24.0;

BOOL CALLBACK CollectWorkArea(HMONITOR monitor, HDC, LPRECT, LPARAM context) {
  MONITORINFO info = {sizeof(info)};
  if (!GetMonitorInfo(monitor, &info)) return TRUE;
  const RECT& rect = info.rcWork;
  EncodableList area = {
      static_cast<int32_t>(rect.left), static_cast<int32_t>(rect.top),
      static_cast<int32_t>(rect.right - rect.left),
      static_cast<int32_t>(rect.bottom - rect.top),
      FlutterDesktopGetDpiForMonitor(monitor) / 96.0,
      static_cast<int32_t>(info.rcMonitor.left),
      static_cast<int32_t>(info.rcMonitor.top),
      static_cast<int32_t>(info.rcMonitor.right - info.rcMonitor.left),
      static_cast<int32_t>(info.rcMonitor.bottom - info.rcMonitor.top)};
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

bool NearHorizontalEdge(const RECT& frame) {
  const POINT center = {(frame.left + frame.right) / 2,
                        (frame.top + frame.bottom) / 2};
  const HMONITOR monitor = MonitorFromPoint(center, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info = {sizeof(info)};
  if (!GetMonitorInfo(monitor, &info)) return false;
  const double distance =
      kPillSnapDistance * FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  return std::abs(frame.left - info.rcWork.left) < distance ||
         std::abs(frame.right - info.rcWork.right) < distance;
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
              (rect.bottom - rect.top) / scale, scale}));
          return;
        }
        if (call.method_name() == "setFrame") {
          const auto* args = call.arguments()
                                 ? std::get_if<EncodableList>(call.arguments())
                                 : nullptr;
          if (!args || (args->size() != 4 && args->size() != 5) ||
              !std::all_of(args->begin(), args->end(), [](const auto& n) {
                return std::holds_alternative<double>(n);
              })) {
            result->Error("bad-arguments", "Invalid setFrame coordinates.");
            return;
          }
          // Positions are screen pixels. Size is in DIPs on the destination
          // display, so a move across monitors keeps the panel's logical size.
          const double x = std::get<double>((*args)[0]);
          const double y = std::get<double>((*args)[1]);
          const POINT origin = {std::lround(x), std::lround(y)};
          HMONITOR monitor = MonitorFromPoint(origin, MONITOR_DEFAULTTONEAREST);
          const double scale = args->size() == 5
                                   ? std::get<double>((*args)[4])
                                   : FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
          // Round the two edges on each axis so an aligned far edge stays put.
          const int width = std::lround(x + std::get<double>((*args)[2]) * scale) - origin.x;
          const int height = std::lround(y + std::get<double>((*args)[3]) * scale) - origin.y;
          const UINT flags = SWP_NOACTIVATE | SWP_NOZORDER |
                             (pill_frame_ ? SWP_NOSENDCHANGING : 0);
          if (!SetWindowPos(GetHandle(), nullptr, origin.x, origin.y,
                            width, height, flags)) {
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
        if (call.method_name() == "setPillFrame") {
          const auto* pill = call.arguments()
                                 ? std::get_if<bool>(call.arguments())
                                 : nullptr;
          if (!pill) {
            result->Error("bad-arguments", "setPillFrame requires a bool.");
            return;
          }
          pill_frame_ = *pill;
          if (!pill_frame_) {
            SetPillTooltip(nullptr);
            SetPillDragHighlight(false);
            pill_drag_accent_.reset();
          }
          // Keep the caption style out of the pill. WM_NCCALCSIZE shares
          // the one-pixel DWM frame with the compact window.
          const LONG_PTR style = GetWindowLongPtr(GetHandle(), GWL_STYLE);
          SetWindowLongPtr(GetHandle(), GWL_STYLE,
                           pill_frame_ ? style & ~WS_CAPTION : style | WS_CAPTION);
          if (!SetWindowPos(GetHandle(), nullptr, 0, 0, 0, 0,
                            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE |
                                SWP_NOACTIVATE | SWP_NOZORDER)) {
            result->Error("window-frame", "Unable to change the pill frame.");
            return;
          }
          result->Success();
          return;
        }
        if (call.method_name() == "setPillDragAccent") {
          SetPillDragHighlight(false);
          pill_drag_accent_.reset();
          const auto* color = call.arguments()
                                  ? std::get_if<int32_t>(call.arguments())
                                  : nullptr;
          if (pill_frame_ && color) {
            pill_drag_accent_ = RGB(*color >> 16, *color >> 8, *color);
          }
          result->Success();
          return;
        }
        if (call.method_name() == "setPillTooltip") {
          const auto* text = call.arguments()
                                 ? std::get_if<std::string>(call.arguments())
                                 : nullptr;
          if (!SetPillTooltip(pill_frame_ ? text : nullptr)) {
            result->Error("window-tooltip", "Unable to create the pill tooltip.");
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
  SetPillTooltip(nullptr);
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
  if (message == WM_NCHITTEST && window->mini_frame_ && !window->pill_frame_ &&
      ResizeEdge(window->GetHandle(), lparam) != HTCLIENT) {
    // Let the top-level window handle the resize grip inside the Flutter view.
    return HTTRANSPARENT;
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

void FlutterWindow::SetPillDragHighlight(bool near_edge) {
  if (pill_drag_highlighted_ == near_edge) return;
  const COLORREF color = near_edge ? pill_drag_accent_.value() : kDefaultBorder;
  if (SUCCEEDED(DwmSetWindowAttribute(GetHandle(), kBorderColor, &color,
                                       sizeof(color)))) {
    pill_drag_highlighted_ = near_edge;
  }
}

bool FlutterWindow::SetPillTooltip(const std::string* text) {
  if (pill_tooltip_) {
    DestroyWindow(pill_tooltip_);
    pill_tooltip_ = nullptr;
  }
  if (!text || text->empty()) return true;
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       text->c_str(), -1, nullptr, 0);
  if (size == 0) return false;
  pill_tooltip_text_.resize(size);
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text->c_str(), -1,
                           pill_tooltip_text_.data(), size)) return false;
  INITCOMMONCONTROLSEX controls = {sizeof(controls), ICC_WIN95_CLASSES};
  InitCommonControlsEx(&controls);
  const HWND owner = GetHandle();
  pill_tooltip_ = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_NOACTIVATE, TOOLTIPS_CLASSW, nullptr,
      WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX, CW_USEDEFAULT, CW_USEDEFAULT,
      CW_USEDEFAULT, CW_USEDEFAULT, owner, nullptr, GetModuleHandle(nullptr),
      nullptr);
  if (!pill_tooltip_) return false;
  TOOLINFOW tool = {};
  tool.cbSize = sizeof(tool);
  tool.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
  tool.hwnd = owner;
  tool.uId = reinterpret_cast<UINT_PTR>(flutter_controller_->view()->GetNativeWindow());
  tool.lpszText = pill_tooltip_text_.data();
  SendMessage(pill_tooltip_, TTM_SETMAXTIPWIDTH, 0,
              MulDiv(320, GetDpiForWindow(owner), 96));
  return SendMessageW(pill_tooltip_, TTM_ADDTOOLW, 0,
                      reinterpret_cast<LPARAM>(&tool)) != FALSE;
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
    // shadow. The runner omits the caption in both compact presentations.
    if (rounded_mini_frame_) InflateRect(area, -1, -1);
    return 0;
  }
  if (message == WM_GETMINMAXINFO && (pill_frame_ || !mini_frame_)) {
    const UINT dpi = ::GetDpiForWindow(hwnd);
    auto* bounds = reinterpret_cast<MINMAXINFO*>(lparam);
    bounds->ptMinTrackSize.x = pill_frame_ ? 0 : ::MulDiv(700, dpi, 96);
    bounds->ptMinTrackSize.y = pill_frame_ ? 0 : ::MulDiv(500, dpi, 96);
    return 0;
  }
  if (message == WM_NCHITTEST && mini_frame_ && !pill_frame_) {
    const LRESULT edge = ResizeEdge(hwnd, lparam);
    if (edge != HTCLIENT) return edge;
  }
  if (message == WM_MOVING && pill_drag_accent_ && rounded_mini_frame_) {
    SetPillDragHighlight(NearHorizontalEdge(*reinterpret_cast<RECT*>(lparam)));
  } else if (message == WM_EXITSIZEMOVE) {
    SetPillDragHighlight(false);
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
