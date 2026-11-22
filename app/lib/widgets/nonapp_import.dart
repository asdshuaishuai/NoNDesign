// 应用包（`.nonapp`）的打开编排：应用内选择 / 系统关联 / 冷启动队列都汇到
// [openNonAppFromPath] 一条路径。
//
// 批次 07 起全部本地：
//   · 先等应用完成启动（冷启动时系统可能比应用先就绪，review nonapp-2）；
//   · 包解析 → 安装进本地应用库（目录 + 每个应用自己的数据库）；
//   · html 载荷 → 工作台（file:// + 本地数据桥）；a2ui 载荷 → 内嵌查看器；
//   · 安装失败（磁盘异常/平台限制）时 html 仍可**临时预览**，并明示不会保存。
//
// 先验后落：NonAppPackage.parse / 安装校验失败直接给一句人话，不写缓存、
// 不留半成品目录、不产生任何网络请求。
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/nonapp_cache.dart';
import '../core/nonapp_library.dart';
import '../core/nonapp_package.dart';
import '../core/platform_capabilities.dart';
import '../core/store.dart';
import 'hotapp_workspace.dart';
import 'nonapp_viewer.dart';

const XTypeGroup _nonAppTypeGroup =
    XTypeGroup(label: 'NaN 应用', extensions: ['nonapp']);

/// 冷启动打开文件时等应用就绪的上限。
///
/// 系统可能在应用完成初始化前就把文件交过来；此时应用库/本地数据面还没
/// 准备好，立刻判定会误走「临时预览」分支（review nonapp-2）。20s 后按当前
/// 状态继续——绝不让打开动作永久挂起。
const Duration nonAppBootWait = Duration(seconds: 20);

/// 应用包失败码 → 用户可见句子（术语表 §4；原始码只进日志/技术详情）。
String nonAppExceptionMessage(NonAppException error) {
  final code = error.code;
  if (code.startsWith('nonapp_unsupported_version')) {
    return '应用版本过新，请更新本应用';
  }
  if (code.startsWith('nonapp_requires_app')) {
    return '这个应用需要更新版本的 NaN 才能打开';
  }
  if (code.startsWith('nonapp_too_large')) {
    return '这个应用包太大了，无法打开';
  }
  if (code.startsWith('nonapp_invalid_zip') || code.startsWith('nonapp_empty_body')) {
    return '这个文件不是有效的应用包';
  }
  if (code.startsWith('nonapp_html_external_refs') ||
      code.startsWith('nonapp_a2ui_external_refs')) {
    return '这个应用引用了网络资源，无法在本机打开';
  }
  if (code.startsWith('nonapp_invalid_surface') ||
      code.startsWith('nonapp_unsupported_renderer') ||
      code.startsWith('nonapp_invalid_payload')) {
    return '这个应用的内容格式不受支持';
  }
  if (code.startsWith('nonapp_missing_')) {
    return '这个应用包不完整，无法打开';
  }
  if (code.startsWith('nonapp_install_failed') ||
      code.startsWith('nonapp_cache_failed') ||
      code.startsWith('nonapp_delete_failed')) {
    return '这个应用没能保存到本机，请检查磁盘空间';
  }
  if (code.startsWith('nonapp_invalid_name') || code.startsWith('nonapp_invalid_id')) {
    return '这个应用的名字不合法，无法打开';
  }
  return '这个应用包暂时打不开，请稍后重试';
}

/// 没有系统文件关联的平台明示「从应用内打开」（不得静默缺失）。
///
/// Linux/Windows 的文件关联不在本轮实现范围（运行时清单不在本批文件内），
/// 所以界面必须给出可行的替代路径，而不是让用户双击后什么都没有发生。
String? nonAppOpenHint(PlatformCapabilities host) {
  if (host.os == HostOs.linux || host.os == HostOs.windows) {
    return '在这台电脑上，请从应用内打开应用包（暂不支持双击文件打开）。';
  }
  return null;
}

/// 应用内打开：选一个应用包并走同一条分派。
Future<void> pickAndOpenNonApp(BuildContext context, {NonAppLibrary? library}) async {
  final XFile? file;
  try {
    file = await openFile(acceptedTypeGroups: const [_nonAppTypeGroup]);
  } catch (error) {
    if (context.mounted) {
      _notify(context, '打开失败', '这台设备暂时打不开文件选择器。', error);
    }
    return;
  }
  if (file == null) return; // 用户取消
  if (!context.mounted) return;
  await openNonAppFromPath(context, file.path, library: library);
}

/// 打开一个应用包文件（系统关联 / 冷启动队列 / 应用内选择共用）。
Future<void> openNonAppFromPath(
  BuildContext context,
  String rawPath, {
  NonAppLibrary? library,
}) async {
  final path = _localPath(rawPath);
  if (path == null) {
    _notify(context, '打开失败', '这个位置的应用包无法读取。');
    return;
  }

  final List<int> bytes;
  try {
    bytes = await File(path).readAsBytes();
  } catch (error) {
    if (!context.mounted) return;
    _notify(context, '打开失败', '这个文件读不出来，可能已经被移走。', error);
    return;
  }
  if (!context.mounted) return;

  final NonAppPackage pkg;
  try {
    pkg = NonAppPackage.parse(bytes);
  } on NonAppException catch (error) {
    _notify(context, '应用包被拒', nonAppExceptionMessage(error), error);
    return;
  } catch (error) {
    _notify(context, '应用包被拒', '这个文件不是有效的应用包。', error);
    return;
  }
  if (!context.mounted) return;

  final store = _storeOf(context);
  if (store == null) {
    _notify(context, '打开失败', '应用还没有准备好，请稍后再试。');
    return;
  }

  // 冷启动竞态：系统先交付、应用后完成初始化。等就绪后再决定安装/预览。
  await _awaitBoot(store);
  if (!context.mounted) return;

  NonAppLibrary lib;
  try {
    lib = library ?? await NonAppLibrary.open();
  } catch (error) {
    debugPrint('[nonapp] library open failed: $error');
    if (!context.mounted) return;
    _notify(context, '应用包被拒', '应用库暂时打不开，请稍后重试。', error);
    return;
  }

  LibraryApp entry;
  try {
    entry = await lib.install(pkg);
  } on NonAppException catch (error) {
    debugPrint('[nonapp] install rejected: $error');
    // html 仍可临时打开（不保存）；a2ui 走内存渲染——两条都不依赖磁盘。
    if (pkg.renderer == 'html' && pkg.htmlBytes != null && context.mounted) {
      await _openTemporary(context, store, pkg, error);
    } else if (pkg.renderer == 'a2ui' && pkg.messages != null && context.mounted) {
      await _openTemporaryA2ui(context, pkg, error);
    } else if (context.mounted) {
      _notify(context, '应用包被拒', nonAppExceptionMessage(error), error);
    }
    return;
  } catch (error) {
    debugPrint('[nonapp] install failed: $error');
    if (pkg.renderer == 'html' && pkg.htmlBytes != null && context.mounted) {
      await _openTemporary(context, store, pkg, error);
    } else if (pkg.renderer == 'a2ui' && pkg.messages != null && context.mounted) {
      await _openTemporaryA2ui(context, pkg, error);
    } else if (context.mounted) {
      _notify(context, '应用包被拒', '这个应用没能保存到本机，请检查磁盘空间。', error);
    }
    return;
  }
  if (!context.mounted) return;

  if (pkg.renderer == 'a2ui') {
    final messages = pkg.messages;
    if (messages == null) {
      _notify(context, '打开失败', '这个应用的内容读不出来。');
      return;
    }
    _notify(context, '已打开', pkg.manifest.title);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NonAppA2uiViewer(title: pkg.manifest.title, messages: messages),
    ));
    return;
  }

  hotAppOfflinePath = null;
  hotAppLoadOnOpen = entry.name;
  store.setView('plugin:hotapp');
  _notify(context, '已导入热应用', entry.title);
}

/// 库不可用时的临时预览：写缓存文件（CSP + 数据桥），明示不会保存。
Future<void> _openTemporary(
  BuildContext context,
  AppStore store,
  NonAppPackage pkg,
  Object error,
) async {
  final html = pkg.htmlBytes;
  if (html == null) return;
  String cachePath;
  try {
    cachePath = await NonAppCache.writeHtml(
      name: pkg.manifest.name,
      htmlBytes: html,
      withDbBridge: true,
    );
  } catch (cacheError) {
    if (!context.mounted) return;
    _notify(context, '打开失败', '这个应用暂时无法打开，请稍后重试。', cacheError);
    return;
  }
  if (!context.mounted) return;
  hotAppLoadOnOpen = null;
  hotAppOfflinePath = cachePath;
  store.setView('plugin:hotapp');
  debugPrint('[nonapp] temporary preview: $error');
  _notify(context, '已临时打开', '这个应用没有保存到本机，重新打开需要再导入一次。');
}

/// a2ui 载荷的临时预览：内存渲染（零磁盘/零网络），明示不会保存。
Future<void> _openTemporaryA2ui(
  BuildContext context,
  NonAppPackage pkg,
  Object error,
) async {
  final messages = pkg.messages;
  if (messages == null) return;
  debugPrint('[nonapp] temporary a2ui preview: $error');
  _notify(context, '已临时打开', '这个应用没有保存到本机，重新打开需要再导入一次。');
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => NonAppA2uiViewer(title: pkg.manifest.title, messages: messages),
  ));
}

/// 等应用完成启动（`ready == true`），上限 [timeout]。
///
/// 启动失败（bootError）时 ready 同样会变 true；此时本地库通常是好的
/// （启动失败可能只是「连接桌面」不可达），照常安装。
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

/// `file://` URL → 本地路径；普通路径原样返回（系统两侧都可能给）。
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

/// 通知统一走 ToastService（宿主渲染；调试详情只进日志）。
void _notify(BuildContext context, String title, String detail, [Object? error]) {
  if (!context.mounted) return;
  if (error != null) debugPrint('[nonapp] $title: $error');
  final store = _storeOf(context);
  final toasts = store?.toasts;
  if (toasts != null) {
    toasts.show(title, detail: detail);
    return;
  }
  // 没有 store 的独立宿主（测试/嵌入页）：不退回 SnackBar——通知的呈现只
  // 有一个出口，缺失时宁可只留日志也不制造第二套弹条。
  debugPrint('[nonapp] $title — $detail');
}
