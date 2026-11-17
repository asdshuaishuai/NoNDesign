import Flutter
import UIKit

/// `.nonapp` 文件的 UIScene 打开入口。
///
/// Info.plist 的 `UIApplicationSceneManifest` 把 scene 委托给本类后，UIKit
/// **不再调用 AppDelegate 的 UI 回调**（`launchOptions[.url]` /
/// `application(_:open:options:)` 在 UIScene 生命周期下都是死路径）；
/// `FlutterSceneDelegate` 也只在 `scene:openURLContexts:` 里把 URL 转给
/// 插件代理，不会回调 AppDelegate。所以文件打开必须在这里接：
///
///   - `scene(_:willConnectTo:options:)`：冷启动的
///     `connectionOptions.urlContexts`（应用未运行时点「文件」里的 .nonapp）
///   - `scene(_:openURLContexts:)`：运行中的文件打开
///
/// 两条都复用 `AppDelegate.materialize`（file:// 直接用路径，content/
/// provider 拷到临时目录）后交给 `NonAppOpenInbox`：冷启动只入队，Dart
/// 就绪后 `takePending`/`drain` 拉取——与 AppDelegate 侧的 pending 设计同构。
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    deliver(connectionOptions.urlContexts)
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    deliver(URLContexts)
  }

  /// 统一入口：场景启动与运行中打开走同一落盘/入队路径，避免两处分叉。
  private func deliver(_ contexts: Set<UIOpenURLContext>) {
    for context in contexts {
      if let path = AppDelegate.materialize(context.url) {
        NonAppOpenInbox.shared.push(path)
      }
    }
  }
}
