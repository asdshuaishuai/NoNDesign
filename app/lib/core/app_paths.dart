// 应用可写数据根目录（模型缓存 / 检索索引等本机持久物）。
//
// 与 [NonAppCache] 同一套平台规则，别另造一份：
//   - 桌面：`$HOME/.nondesign`（模型与索引都在这里，随用户目录持久）
//   - iOS / Android：`Directory.systemTemp`——Android 进程通常没有 HOME，
//     environ 取到空串会把路径拼成 `/.nondesign/...`（不可写）；系统可清理
//     临时目录，移动端模型缓存因此**不保证长期存活**（重下即可，登记于
//     docs/plan-flutter-3.50-adoption.md 的 N6 风险面）。
//
// 这里只负责「根目录在哪、要不要建」，具体子目录由消费方决定
// （`models/mediapipe/<task>/<file>`、`embedding_index/<file>.json`）。
import 'dart:io';

/// 应用数据根目录（可注入 [override]，测试用临时目录）。
///
/// 目录不存在时创建；创建失败由调用方按各自语义处理（模型下载会再报
/// 明确错误，索引写入会降级为「不落盘」）。
class AppPaths {
  AppPaths._();

  /// 桌面根目录名（与 nonapp_cache 的 `~/.nondesign` 同源）。
  static const String desktopDirName = '.nondesign';

  /// 测试注入点（默认 null = 按平台推导）；生产代码不要设置。
  static Directory? rootOverride;

  /// 根目录（不存在时创建）。
  static Directory dataRoot() {
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
      return Directory('${Directory.systemTemp.path}/nondesign');
    }
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      // 桌面 HOME 缺失（异常环境/受限沙箱）：临时目录是唯一可靠的可写位置。
      return Directory('${Directory.systemTemp.path}/nondesign');
    }
    return Directory('$home/$desktopDirName');
  }

  /// 子目录（按需创建），如 `dataSubdir('models/mediapipe/retrieval')`。
  static Directory dataSubdir(String relative) {
    final dir = Directory('${dataRoot().path}/$relative');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }
}
