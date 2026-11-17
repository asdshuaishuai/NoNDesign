// `.nonapp` 的打开编排：应用内打开（file_selector）/ OS 关联 / 冷启动队列
// 都汇到 [openNonAppFromPath] 一条路径。
//
// 分派（docs/plan-chat-stream-shell.md §1.1「打开路径」）：
//   有服务器（api != null）→ POST /hotapp/import 落 hotapps + 作品集登记
//       · html → hotAppLoadOnOpen = name; setView('plugin:hotapp')
//       · a2ui → 拉 /hotapp/a2ui/{name} 后 push NonAppA2uiViewer
//   无服务器（api == null）→ **零服务依赖**
//       · a2ui → 直接 push 查看器（内存渲染，零 HTTP）
//       · html → 写本地缓存后 hotAppOfflinePath = 缓存路径（file:// WebView）
//
// 先验后落：NonAppPackage.parse 失败（NonAppException）直接 SnackBar 显示
// 稳定 code，不写缓存、不打服务端、不产生半成品。
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/api_nonapp.dart';
import '../core/nonapp_cache.dart';
import '../core/nonapp_package.dart';
import '../core/store.dart';
import 'hotapp_workspace.dart';
import 'nonapp_viewer.dart';

const XTypeGroup _nonAppTypeGroup =
    XTypeGroup(label: 'NoNDesign 应用', extensions: ['nonapp']);

/// 冷启动打开文件时等 boot 完成的上限：桌面端 spawn Python + /health 的
/// 正常耗时在数秒内（ServerLauncher 自身 30s 启动超时），20s 后按当前
/// 状态继续——绝不让打开动作永久挂起。
const Duration nonAppBootWait = Duration(seconds: 20);

/// 应用内打开：`file_selector` 选一个 `.nonapp` 并走同一条分派。
Future<void> pickAndOpenNonApp(BuildContext context) async {
  final XFile? file;
  try {
    file = await openFile(acceptedTypeGroups: const [_nonAppTypeGroup]);
  } catch (e) {
    if (context.mounted) _snack(context, '打开失败', '文件选择器不可用：$e');
    return;
  }
  if (file == null) return; // 用户取消
  if (!context.mounted) return;
  await openNonAppFromPath(context, file.path);
}

/// 打开一个 `.nonapp` 文件（OS 关联 / 冷启动队列 / 应用内选择共用）。
Future<void> openNonAppFromPath(BuildContext context, String rawPath) async {
  final path = _localPath(rawPath);
  if (path == null) {
    _snack(context, '打开失败', '不支持的路径：$rawPath');
    return;
  }

  final List<int> bytes;
  try {
    bytes = await File(path).readAsBytes();
  } catch (e) {
    if (context.mounted) _snack(context, '打开失败', '$path：$e');
    return;
  }
  if (!context.mounted) return;

  final NonAppPackage pkg;
  try {
    pkg = NonAppPackage.parse(bytes);
  } on NonAppException catch (e) {
    _snack(context, '应用包被拒', e.code);
    return;
  } catch (e) {
    _snack(context, '应用包被拒', '$e');
    return;
  }
  if (!context.mounted) return;

  final store = _storeOf(context);
  if (store == null) {
    _snack(context, '打开失败', '应用状态未就绪');
    return;
  }

  // 冷启动竞态：intake 在首帧就 drain 平台队列，而 api 要等
  // ServerLauncher.launch()（spawn Python + /health）完成后才赋值——不等就
  // 判成「离线」，桌面冷启动双击文件会误走离线分支（不导入、不进作品集）。
  await _awaitBoot(store);
  if (!context.mounted) return;

  final api = store.api;
  if (api != null) {
    await _installAndOpen(context, store, pkg, bytes);
  } else {
    await _openOffline(context, store, pkg);
  }
}

/// 等 store 完成 boot（`ready == true`），上限 [nonAppBootWait]。
///
/// boot 已失败（bootError）时 ready 同样会变 true，api 仍是 null → 走离线，
/// 这是正确降级。超时则按当前状态继续（不把用户挂在启动屏外）。
Future<void> _awaitBoot(AppStore store, {Duration timeout = nonAppBootWait}) async {
  if (store.ready) return;
  final completer = Completer<void>();
  void listener() {
    if (store.ready && !completer.isCompleted) completer.complete();
  }

  store.addListener(listener);
  try {
    await completer.future.timeout(timeout, onTimeout: () {});
  } finally {
    store.removeListener(listener);
  }
}

/// 有服务器：安装进本机热应用库 + 作品集，再进工作台/查看器。
Future<void> _installAndOpen(
  BuildContext context,
  AppStore store,
  NonAppPackage pkg,
  List<int> bytes,
) async {
  final api = store.api;
  if (api == null) return;
  Map<String, dynamic> res;
  try {
    res = await api.hotAppImport(bytes, name: pkg.manifest.name);
  } catch (e) {
    if (context.mounted) _snack(context, '导入失败', '$e');
    return;
  }
  if (res['ok'] != true) {
    if (context.mounted) _snack(context, '导入被拒', '${res['detail'] ?? res['error'] ?? '未知错误'}');
    return;
  }
  if (!context.mounted) return;

  if (pkg.renderer != 'a2ui') {
    // 只写应用名：html 载荷由服务端托管（/hotapp/page/{name}）。
    hotAppOfflinePath = null;
    hotAppLoadOnOpen = pkg.manifest.name;
    store.setView('plugin:hotapp');
    _snack(context, '已导入热应用', '${pkg.manifest.title}（${pkg.manifest.name}）');
    return;
  }

  Map<String, dynamic> a2;
  try {
    a2 = await api.hotAppA2ui(pkg.manifest.name);
  } catch (e) {
    if (context.mounted) _snack(context, '读取 a2ui 失败', '$e');
    return;
  }
  final raw = a2['messages'];
  if (!context.mounted) return;
  if (a2['ok'] != true || raw is! List) {
    _snack(context, '读取 a2ui 失败', '${a2['detail'] ?? a2['error'] ?? '无消息序列'}');
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => NonAppA2uiViewer(
      title: (a2['title'] ?? pkg.manifest.title).toString(),
      messages: raw,
    ),
  ));
}

/// 无服务器：a2ui 内存渲染（零 HTTP）；html 落缓存走 file:// 离线工作台。
Future<void> _openOffline(
  BuildContext context,
  AppStore store,
  NonAppPackage pkg,
) async {
  if (pkg.renderer == 'a2ui') {
    final messages = pkg.messages;
    if (messages == null) {
      _snack(context, '打开失败', '包内缺少 surface 消息');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NonAppA2uiViewer(title: pkg.manifest.title, messages: messages),
    ));
    return;
  }

  final html = pkg.htmlBytes;
  if (html == null) {
    _snack(context, '打开失败', '包内缺少 index.html');
    return;
  }
  String cachePath;
  try {
    cachePath = await NonAppCache.writeHtml(name: pkg.manifest.name, htmlBytes: html);
  } on NonAppException catch (e) {
    if (context.mounted) _snack(context, '离线打开失败', e.code);
    return;
  }
  if (!context.mounted) return;
  // 应用名通道留空：离线态没有服务端应用，只有本机缓存文件。
  hotAppLoadOnOpen = null;
  hotAppOfflinePath = cachePath;
  store.setView('plugin:hotapp');
}

/// `file://` URL → 本地路径；普通路径原样返回（OS 两侧都可能给）。
String? _localPath(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  if (!value.startsWith('file://')) return value;
  try {
    return Uri.parse(value).toFilePath();
  } catch (_) {
    return null;
  }
}

AppStore? _storeOf(BuildContext context) {
  try {
    return context.read<AppStore>();
  } catch (_) {
    return null; // 无 Provider 的宿主（测试/独立页）：调用方报错
  }
}

void _snack(BuildContext context, String title, String detail) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        if (detail.trim().isNotEmpty)
          Text(detail.trim(),
              style: const TextStyle(fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
      ],
    ),
  ));
}
