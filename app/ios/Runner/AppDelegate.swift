import Flutter
import UIKit

/// `.nonapp` 文件的系统打开收件箱（iOS）。
///
/// iOS 的打开路径有三条，全部汇到同一队列：
///   ① 冷启动 `launchOptions[.url]`（「文件」App 点击 → 应用未运行）
///   ② 运行中 `application(_:open:options:)`（文件 App 分享/打开到本应用）
///   ③ 其它应用经 `UIActivityViewController` 交付的 file URL
///
/// 冷启动时 Dart 侧还没有通道 handler，所以**只入队**；Dart 就绪后调
/// `nc/open` 的 `takePending` 拉取并清空（**冷启动 URL 不丢**——这是
/// macOS 侧 pending 队列的同款设计）。运行中则直接经 `onPath` 推给 Dart。
final class NonAppOpenInbox {
  static let shared = NonAppOpenInbox()

  private let lock = NSLock()
  private var pending: [String] = []

  /// 通道就绪后由 AppDelegate 设置。
  var onPath: ((String) -> Void)?

  func push(_ path: String) {
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

  func takeAll() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    let items = pending
    pending.removeAll()
    return items
  }

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
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 冷启动：系统用 file:// URL 把文件交给我们（应用还没起来，先入队）。
    if let url = launchOptions?[.url] as? URL {
      self.accept(url)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 运行中打开文档（iOS 9+ 的文档交互入口）。
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    self.accept(url)
    return true
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // iOS 的 FlutterAppDelegate 声明含 FlutterPluginRegistry
    // （Flutter.framework/Headers/FlutterAppDelegate.h:27-28），所以这里可以
    // 用 registrar(forPlugin:) 取 binaryMessenger（macOS 不行——那边
    // FlutterAppDelegate 不是 registry，通道只能建在 FlutterViewController）。
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NonAppOpen") else {
      return
    }
    let channel = FlutterMethodChannel(name: "nc/open", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "takePending":
        result(NonAppOpenInbox.shared.takeAll())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    NonAppOpenInbox.shared.onPath = { path in
      channel.invokeMethod("openPath", arguments: ["path": path])
    }
    NonAppOpenInbox.shared.drain()
  }

  /// file:// 直接用路径；其它 scheme（content/provider）先拷到临时目录。
  private func accept(_ url: URL) {
    guard let path = Self.materialize(url) else { return }
    NonAppOpenInbox.shared.push(path)
  }

  private static func materialize(_ url: URL) -> String? {
    if url.isFileURL {
      return url.path
    }
    // 文档提供者给的 URL 需要安全作用域访问：拷贝到 tmp 后立刻释放。
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped { url.stopAccessingSecurityScopedResource() }
    }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("nonapp_inbox", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let dest = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).nonapp")
      let data = try Data(contentsOf: url)
      try data.write(to: dest, options: .atomic)
      return dest.path
    } catch {
      return nil
    }
  }
}
