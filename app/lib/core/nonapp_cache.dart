// 本地预览载荷的缓存（file:// WebView 的执行面）。
//
// WebView 没有「内存 html」路径（loadHtmlString 在 webview_flutter 的平台
// 实现里并不暴露），所以预览必须落成文件再 `loadFile`。缓存根：
//   - 桌面：`~/.nondesign/nonapp_cache`（HOME 缺失时回落系统临时目录）
//   - iOS / Android：**应用支持目录**（path_provider）——不再用
//     `Directory.systemTemp`：系统可随时清理临时目录，重开应用时预览会一起
//     消失（批次 07 迁移；S2 残留项）
//
// 缓存本身仍是**可丢的**（应用真正的数据在 `nonapp_library` 的目录与
// app.db 里），prune 只保最近 8 个预览文件；清了也只是重开时重建一次。
// 写入前跑一次 [assertHtmlOfflineSafe]——缓存是 file:// 打开前的最后一道闸。
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'hotapp_db.dart';
import 'nonapp_package.dart';

class NonAppCache {
  NonAppCache._();

  /// 测试注入点（默认 null = 按平台推导）；生产代码不要设置。
  static Directory? rootOverride;

  /// 测试注入点：强制按移动端路径解析（真实主机跑测试时造不出 iOS/Android）。
  static bool? debugMobileOverride;

  /// 测试注入点：替代 path_provider 的「应用支持目录」。
  static Future<Directory> Function()? debugSupportDirectory;

  /// 缓存根目录（不存在时创建）。
  ///
  /// 移动端需要 path_provider，因此这个入口是异步的；调用方都在异步上下文。
  static Future<Directory> root() async {
    final override = rootOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    final dir = await _platformRoot();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<Directory> _platformRoot() async {
    final mobile = debugMobileOverride ?? (Platform.isIOS || Platform.isAndroid);
    if (mobile) {
      try {
        final provider = debugSupportDirectory ?? getApplicationSupportDirectory;
        final support = await provider();
        return Directory('${support.path}/nonapp_cache');
      } catch (_) {
        // 平台通道不可用（异常宿主/测试）：退回临时目录，但**只在缓存**上
        // 退——应用库与数据库仍走 AppPaths 的持久目录。
        return Directory('${Directory.systemTemp.path}/nonapp_cache');
      }
    }
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      // 桌面 HOME 缺失（异常环境/受限沙箱）：临时目录是唯一可靠的可写位置。
      return Directory('${Directory.systemTemp.path}/nonapp_cache');
    }
    return Directory('$home/.nondesign/nonapp_cache');
  }

  /// 写入 html 载荷（原子：临时文件 + rename），返回缓存文件绝对路径。
  ///
  /// [name] 只做文件名（manifest.name 已过白名单）；同应用覆盖同一文件。
  /// [withDbBridge] 为 true 时注入「CSP + 本地数据桥」运行时（工作台预览）；
  /// 为 false 时只注入 CSP（纯预览/无库兜底）。
  static Future<String> writeHtml({
    required String name,
    required List<int> htmlBytes,
    bool withDbBridge = false,
  }) async {
    if (!isValidNonAppName(name)) {
      throw NonAppException('nonapp_invalid_name:$name', '应用名非法，拒绝写缓存');
    }
    // 保守预筛必须跑在落盘之前：缓存文件会被 file:// 直接执行。
    final html = utf8.decode(htmlBytes);
    assertHtmlOfflineSafe(html);
    // file:// 没有响应头，meta 是唯一可用的第二道防线——JS 拼接/编码的地址
    // 过不了 CSP（review nonapp-5）；数据桥也必须在页面脚本之前就位。
    final safeHtml = withDbBridge ? injectHotAppRuntime(html) : injectNonAppCsp(html);
    final safeBytes = utf8.encode(safeHtml);

    final dir = await root();
    final target = File('${dir.path}/$name.html');
    final tmp = File('${dir.path}/.$name.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await tmp.writeAsBytes(safeBytes, flush: true);
      await tmp.rename(target.path);
    } catch (e) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      throw NonAppException('nonapp_cache_failed', '写本地缓存失败：$e');
    }
    await prune();
    return target.path;
  }

  /// 只保留最近 [keep] 个缓存文件（按 mtime 倒序），其余删除。
  static Future<void> prune({int keep = 8}) async {
    final dir = await root();
    final entries = <MapEntry<File, DateTime>>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (name.startsWith('.') || name.endsWith('.tmp')) continue;
      try {
        entries.add(MapEntry(e, (await e.stat()).modified));
      } catch (_) {}
    }
    entries.sort((a, b) => b.value.compareTo(a.value));
    for (final stale in entries.skip(keep)) {
      try {
        await stale.key.delete();
      } catch (_) {}
    }
  }

  /// 清空缓存（不动根目录）。
  static Future<void> clear() async {
    final dir = await root();
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      try {
        await e.delete();
      } catch (_) {}
    }
  }
}
