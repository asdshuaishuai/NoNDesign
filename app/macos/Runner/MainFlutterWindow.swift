import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Always place the window on the main display. macOS can otherwise restore
    // a frame on a disconnected/offscreen display, which presents as "app runs
    // but no window".
    if let screen = NSScreen.main {
      let f = screen.visibleFrame
      let w = min(1440.0, f.width - 80)
      let h = min(920.0, f.height - 80)
      let rect = NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h)
      self.setFrame(rect, display: true)
    }
    self.minSize = NSSize(width: 1080, height: 700)
    self.title = "NoNDesign"

    // 标题栏透明并随主题：Flutter 侧经 nc/window setTheme 同步深浅。
    self.titlebarAppearsTransparent = true
    self.backgroundColor = NSColor(srgbRed: 0.031, green: 0.035, blue: 0.047, alpha: 1)
    let channel = FlutterMethodChannel(name: "nc/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setTheme",
            let args = call.arguments as? [String: Any],
            let dark = args["dark"] as? Bool else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        self?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // 与 NonPalette 对齐：dark bg #08090C / light bg #F3F4F7。
        self?.backgroundColor = dark
            ? NSColor(srgbRed: 0.031, green: 0.035, blue: 0.047, alpha: 1)
            : NSColor(srgbRed: 0.953, green: 0.957, blue: 0.969, alpha: 1)
      }
      result(nil)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    self.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
