import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var pillFrame = false
  private var pillMouseDown: NSEvent?

  override func sendEvent(_ event: NSEvent) {
    if pillFrame && event.type == .leftMouseDown {
      pillMouseDown = event
    } else if event.type == .leftMouseUp {
      pillMouseDown = nil
    }
    super.sendEvent(event)
  }

  private func dragPill(_ result: @escaping FlutterResult) {
    guard let event = pillMouseDown, NSEvent.pressedMouseButtons & 1 != 0 else {
      result(nil)
      return
    }
    pillMouseDown = nil
    performDrag(with: event)
    // AppKit returns before the drag ends and can consume the mouse-up event.
    let released = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
      guard let window = self else {
        timer.invalidate()
        return
      }
      if NSEvent.pressedMouseButtons & 1 != 0 && window.isVisible { return }
      timer.invalidate()
      result(nil)
    }
    RunLoop.main.add(released, forMode: .common)
  }

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
          let frame = screen.frame
          return [Double(area.minX), Double(origin - area.maxY),
            Double(area.width), Double(area.height), 1.0,
            Double(frame.minX), Double(origin - frame.maxY),
            Double(frame.width), Double(frame.height)]
        })
      case "setMiniFrame":
        self?.isOpaque = true
        result(nil)
      case "setPillFrame":
        guard let window = self, let pill = call.arguments as? Bool else {
          result(FlutterError(code: "bad-arguments", message: "Expected a pill state.", details: nil))
          return
        }
        window.pillFrame = pill
        if !pill { window.pillMouseDown = nil }
        window.isOpaque = !pill
        window.backgroundColor = pill ? .clear : .windowBackgroundColor
        if let content = window.contentView {
          if !pill { content.toolTip = nil }
          content.wantsLayer = true
          content.layer?.cornerRadius = pill ? 18 : 0
          content.layer?.masksToBounds = pill
        }
        window.invalidateShadow()
        result(nil)
      case "setPillTooltip":
        self?.contentView?.toolTip = call.arguments as? String
        result(nil)
      case "dragPill":
        if let window = self { window.dragPill(result) } else { result(nil) }
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
