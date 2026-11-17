import Cocoa
import FlutterMacOS

/// `.nonapp` 文件的系统打开桥（双击 / 拖到 Dock 图标 / `open -a`）。
///
/// 事件到达时 Dart 侧可能还没就绪（冷启动没有 FlutterMethodChannel 的
/// handler）：先入队，等 `MainFlutterWindow` 建好通道并设置 `onPath` 后
/// 由 `drain()` 推出；Dart 侧另有 `takePending` 主动拉取（双保险，Dart 侧
/// 带 2s 去重，重复投递不会重复打开）。
///
/// 实现放在 AppDelegate.swift 同一文件里（不新增 Swift 文件——那要改
/// Runner.xcodeproj/project.pbxproj 的文件清单）。
final class NonAppOpenBridge {
  static let shared = NonAppOpenBridge()

  private let lock = NSLock()
  private var pending: [String] = []

  /// 通道就绪后由 MainFlutterWindow 设置；未设置时所有事件只入队。
  var onPath: ((String) -> Void)?

  func enqueue(_ path: String) {
    guard !path.isEmpty else { return }
    lock.lock()
    let ready = onPath != nil
    if !ready {
      pending.append(path)
      lock.unlock()
      return
    }
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.onPath?(path)
    }
  }

  /// 取出并清空队列（Dart 的 takePending 调用点）。
  func takeAll() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    let items = pending
    pending.removeAll()
    return items
  }

  /// 通道就绪后把积压路径推给 Dart。
  func drain() {
    let items = takeAll()
    guard !items.isEmpty, onPath != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      for path in items {
        self.onPath?(path)
      }
    }
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// 双击 `.nonapp` / 拖到 Dock 图标：Finder 走 openFiles。
  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    for path in filenames {
      NonAppOpenBridge.shared.enqueue(path)
    }
    sender.reply(toOpenOrPrint: .success)
  }

  /// `open -a` / URL 形式交付（file:// URL）。
  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.isFileURL {
      NonAppOpenBridge.shared.enqueue(url.path)
    }
    application.reply(toOpenOrPrint: .success)
  }
}
