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

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    self.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
