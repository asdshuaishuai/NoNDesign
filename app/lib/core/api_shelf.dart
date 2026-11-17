import 'dart:io';

import 'api.dart';

/// 艺术架（Art Shelf）专用 API 面：作品集视图/视频播放面消费的少量端点与
/// 本机文件动作。核心 [NoNDesignApi] 保持不动——这里是 extension，端点仍是
/// 既有服务端（/three/delete 早在 server/main.py 落地，客户端此前从未接线）。
extension ShelfApi on NoNDesignApi {
  /// 真删 3D 项目目录（服务端 /three/delete，白名单 + 越界断言在服务端）。
  /// 与作品集的「从艺术架移除」不同：这是删产物本身，不可恢复。
  Future<Map<String, dynamic>> threeDelete(String name) =>
      postJson('/three/delete', {'name': name});

  /// mp4 产物的播放 URL（服务端 `/video/mp4?path=…`，Range/seek 由
  /// Starlette FileResponse 承担）。path 是产物绝对路径
  /// （`videos/<job>/frames.mp4`，或持久化失败时回退的
  /// `video/<job>/frames.mp4`）。
  String videoMp4Url(String path) => videoMp4UrlFor(baseUrl, path);
}

/// 与 [ShelfApi.videoMp4Url] 同一拼装：播放面只拿到 baseUrl（没有 api 实例），
/// 两处必须同形——改一处等于两处。
String videoMp4UrlFor(String baseUrl, String path) {
  final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
  return '$base/video/mp4?path=${Uri.encodeQueryComponent(path)}';
}

/// 在系统文件管理器中定位产物。
///
/// 只支持桌面三平台：iOS/Android 没有 `open`/`xdg-open`/`explorer`，
/// `Process.run` 在移动端必抛 ProcessException——先按平台短路返回 false，
/// 调用方据此隐藏该菜单项（移动端只留『复制路径』）。
Future<bool> revealInFolder(String path) async {
  if (!revealSupported) return false;
  try {
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      // explorer 命中成功也常返回非 0（其退出码语义不可靠），不读 exitCode。
      await Process.run('explorer', ['/select,$path']);
    } else {
      await Process.run('xdg-open', [File(path).parent.path]);
    }
    return true;
  } catch (_) {
    // 找不到可执行文件 / 被沙箱拦 / 路径已消失：一律降级为「做不到」。
    return false;
  }
}

/// 「在文件夹中显示」是否可能可用（桌面三平台）。菜单按它隐藏入口——
/// 移动端点一下只会静默失败，不如不显示。
bool get revealSupported =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;
