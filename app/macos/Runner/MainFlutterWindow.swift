import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "Token Lens"
    self.minSize = NSSize(width: 700, height: 500)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let buildChannel = FlutterMethodChannel(
      name: "token_lens/build",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    buildChannel.setMethodCallHandler { call, result in
      guard call.method == "version" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    let windowChannel = FlutterMethodChannel(
      name: "token_lens/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "workAreas":
        let screens = NSScreen.screens
        let origin = screens.first?.frame.height ?? 0
        // Match window_manager's desktop coordinate system with y increasing downwards.
        result(screens.map { screen -> [Double] in
          let area = screen.visibleFrame
          return [Double(area.minX), Double(origin - area.maxY),
            Double(area.width), Double(area.height), 1.0]
        })
      case "setMiniFrame":
        self?.isOpaque = true
        result(nil)
      case "liveFrameSize":
        if let window = self, window.inLiveResize {
          result([Double(window.frame.width), Double(window.frame.height)])
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
