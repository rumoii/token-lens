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

    super.awakeFromNib()
  }
}
