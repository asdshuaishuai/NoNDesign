// 离线 html 载荷的本地缓存（file:// WebView 的执行面）。
//
// 无服务器时 `.nonapp` 的 HTML 载荷只能落到本机磁盘再经 `loadFile` 打开
// （WebView 没有「内存 html」路径：loadHtmlString 在 webview_flutter 的
// 平台实现里并不暴露）。缓存根：
//   - 桌面：`~/.nondesign/nonapp_cache`（HOME 缺失时回落系统临时目录）
//   - iOS / Android：`Directory.systemTemp`——Android 进程通常没有 HOME，
//     environ 取到空串会把路径拼成 `/.nondesign/...`（不可写）
//
// **这不是持久库**（离线导入不持久化，重开需重导入）：系统可随时清理
// 临时目录，prune 也只保最近 8 个。写入前跑一次 [assertHtmlOfflineSafe]
// ——缓存是 file:// 打开前的最后一道闸。
import 'dart:convert';
import 'dart:io';

import 'nonapp_package.dart';

class NonAppCache {
  NonAppCache._();

  /// 测试注入点（默认 null = 按平台推导）；生产代码不要设置。
  static Directory? rootOverride;

  /// 缓存根目录（不存在时创建）。
  static Directory root() {
    final override = rootOverride;
    if (override != null) {
      if (!override.existsSync()) override.createSync(recursive: true);
      return override;
    }
    final dir = _platformRoot();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Directory _platformRoot() {
    if (Platform.isIOS || Platform.isAndroid) {
      return Directory('${Directory.systemTemp.path}/nonapp_cache');
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
  static Future<String> writeHtml({
    required String name,
    required List<int> htmlBytes,
  }) async {
    if (!isValidNonAppName(name)) {
      throw NonAppException('nonapp_invalid_name:$name', '应用名非法，拒绝写缓存');
    }
    // 保守预筛必须跑在落盘之前：缓存文件会被 file:// 直接执行。
    assertHtmlOfflineSafe(utf8.decode(htmlBytes));

    final dir = root();
    final target = File('${dir.path}/$name.html');
    final tmp = File('${dir.path}/.$name.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await tmp.writeAsBytes(htmlBytes, flush: true);
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
    final dir = root();
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
    final dir = root();
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File) continue;
      try {
        await e.delete();
      } catch (_) {}
    }
  }
}
