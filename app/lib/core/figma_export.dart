/// Figma 导出包（本地生成，不经任何服务进程）。
///
/// 输入是引擎自渲染的 [RenderEnvelope]（每板 `svg` + 节点树），输出是
/// 一个目录：
///
/// ```
/// board-<id>.svg      每板一份，可直接拖进 Figma 成为可编辑矢量图层
/// nondesign.json      节点树清单，figma-plugin/ 的双向插件消费它建真实图层
/// README.txt          两条导入路径的说明
/// ```
///
/// 纪律：
///  * **只在本地写文件**——没有 HTTP、没有外部进程、没有固定端口；
///  * 板 id / 节点 id 是不可信字符串：文件名做 ASCII 清洗，JSON 里原样保留
///    （JSON 不是标记语言，不存在属性注入面）；
///  * 不可见节点不进清单（与插件 `style.visible === false` 跳过同语义）；
///  * 每板节点数封顶 [FigmaExporter.nodeCapPerBoard]（清单是导入素材，不是
///    完整文档镜像——超大画板只带前 N 个节点，`truncated` 显式标注）；
///  * 手机/平板没有保存/分享通道：导出**明示不可用**，绝不写进沙盒假装
///    成功（用户拿不到文件）。
library;

import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// 导出发生的宿主类别。
///
/// 桌面 = 有用户可见的文件夹与分享通道；移动端目前没有 share-sheet 插件，
/// 导出包只能落在应用沙盒里（用户不可见）——按不可用处理。
enum FigmaExportPlatform { desktop, mobile }

/// 一次导出的结果。失败时 [error] 是机器码（只进技术详情），[message] 是
/// 用户可见的一句话。
class FigmaExportResult {
  const FigmaExportResult({
    required this.ok,
    this.dir = '',
    this.boards = 0,
    this.files = const <String>[],
    this.error,
    this.message,
    this.technical,
  });

  final bool ok;

  /// 产物目录（成功时非空）。
  final String dir;

  /// 导出的板数。
  final int boards;

  /// 产物文件名（排序）。
  final List<String> files;

  /// 失败码（`figma_mobile_unavailable` / `render_failed` / …）。
  final String? error;

  /// 用户可见的失败句（术语表：不出现实现名与裸错误码）。
  final String? message;

  /// 原始诊断（文件系统异常等），只进折叠的「技术详情」。
  final String? technical;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        if (dir.isNotEmpty) 'dir': dir,
        'boards': boards,
        'files': files,
        if (error != null) 'error': error,
        if (message != null) 'message': message,
        if (technical != null) 'detail': technical,
      };
}

/// 失败码 → 用户可见句子。
String figmaFailureMessage(String? code) {
  switch (code) {
    case 'figma_mobile_unavailable':
      return '这台设备暂不支持导出 Figma 包，请在电脑上导出';
    case 'figma_nothing_to_export':
      return '还没有可以导出的画板';
    case 'figma_write_failed':
      return '导出没有完成，请换一个位置再试';
    case 'render_failed':
      return '预览生成失败';
    default:
      return '这次导出没有完成，请重试';
  }
}

/// 本地 Figma 导出器。
class FigmaExporter {
  FigmaExporter({
    FigmaExportPlatform? platform,
    DateTime Function()? clock,
  })  : platform = platform ?? defaultPlatform(),
        _clock = clock ?? DateTime.now;

  /// 宿主类别（测试注入）。
  final FigmaExportPlatform platform;

  final DateTime Function() _clock;

  /// 每板清单的节点上限。超出时清单标 `truncated`，不静默假装完整。
  static const int nodeCapPerBoard = 300;

  /// 生产判定：桌面三平台可用；iOS/Android 走不可用分支。
  static FigmaExportPlatform defaultPlatform() {
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      return FigmaExportPlatform.desktop;
    }
    return FigmaExportPlatform.mobile;
  }

  bool get isAvailable => platform == FigmaExportPlatform.desktop;

  /// 构建 `nondesign.json` 的内容（纯函数，测试与工具共用）。
  ///
  /// 板与节点的字段形状对齐 `figma-plugin/code.js`：`rect {x,y,w,h}` 是几何
  /// 真源（插件 `geomOf` 优先读 `rect`），`style` 携带 fill / text_color /
  /// font_size / radius / opacity / visible。
  Map<String, dynamic> buildManifest(RenderEnvelope render, {int? exportedAt}) {
    final boards = <Map<String, dynamic>>[];
    for (final board in render.artboards) {
      if (board.id.isEmpty) continue;
      final nodes = <Map<String, dynamic>>[];
      var truncated = false;
      for (final node in board.nodes) {
        if (!node.style.visible) continue;
        if (nodes.length >= nodeCapPerBoard) {
          truncated = true;
          break;
        }
        nodes.add(_nodeJson(node));
      }
      boards.add(<String, dynamic>{
        'id': board.id,
        'name': board.name.isEmpty ? board.id : board.name,
        'width': board.width,
        'height': board.height,
        'background': board.background.isEmpty ? '#FFFFFF' : board.background,
        'nodes': nodes,
        if (truncated) 'truncated': true,
      });
    }
    return <String, dynamic>{
      'exportedAt': exportedAt ?? _clock().millisecondsSinceEpoch ~/ 1000,
      'boards': boards,
    };
  }

  /// 导出到 [directory]。目录不存在会创建；同名旧文件被覆盖。
  Future<FigmaExportResult> export({
    required RenderEnvelope render,
    required String directory,
  }) async {
    if (!isAvailable) {
      return FigmaExportResult(
        ok: false,
        error: 'figma_mobile_unavailable',
        message: figmaFailureMessage('figma_mobile_unavailable'),
      );
    }
    if (!render.ok) {
      return FigmaExportResult(
        ok: false,
        error: 'render_failed',
        message: figmaFailureMessage('render_failed'),
        technical: render.error,
      );
    }
    if (render.artboards.isEmpty) {
      return FigmaExportResult(
        ok: false,
        error: 'figma_nothing_to_export',
        message: figmaFailureMessage('figma_nothing_to_export'),
      );
    }
    final manifest = buildManifest(render);
    final written = <String>[];
    try {
      final target = Directory(directory);
      target.createSync(recursive: true);
      final used = <String>{};
      for (final board in manifest['boards'] as List) {
        final entry = board as Map<String, dynamic>;
        final rawId = entry['id'] as String;
        final fileId = _uniqueFileId(rawId, used);
        final file = File('${target.path}/board-$fileId.svg');
        final boardModel = render.artboards.firstWhere(
          (b) => b.id == rawId,
          orElse: () => render.artboards.first,
        );
        file.writeAsStringSync(boardModel.svg, flush: true);
        written.add(file.uri.pathSegments.last);
      }
      final manifestFile = File('${target.path}/nondesign.json');
      manifestFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(manifest),
        flush: true,
      );
      written.add('nondesign.json');
      final readme = File('${target.path}/README.txt');
      readme.writeAsStringSync(readmeText(), flush: true);
      written.add('README.txt');
      written.sort();
      return FigmaExportResult(
        ok: true,
        dir: target.path,
        boards: (manifest['boards'] as List).length,
        files: written,
      );
    } on FileSystemException catch (error) {
      return FigmaExportResult(
        ok: false,
        error: 'figma_write_failed',
        message: figmaFailureMessage('figma_write_failed'),
        technical: '$error',
      );
    }
  }

  /// README 正文（三条路径：插件 / SVG 拖入 / 说明）。
  String readmeText() => 'NaN → Figma 导出包\n'
      '==================\n'
      '方式一（插件，可编辑图层）：Figma → Plugins → Development → Import plugin from manifest\n'
      '  选择本仓库 figma-plugin/manifest.json，运行插件导入本目录 nondesign.json。\n'
      '方式二（矢量）：把 board-*.svg 拖进 Figma 画布，自动成为可编辑矢量图层。\n';

  static Map<String, dynamic> _nodeJson(CanvasNode node) => <String, dynamic>{
        'id': node.id,
        'kind': node.kind,
        'component': node.component,
        if (node.name.isNotEmpty) 'name': node.name,
        'text': node.text,
        'rect': <String, dynamic>{
          'x': node.x,
          'y': node.y,
          'w': node.w,
          'h': node.h,
        },
        'style': <String, dynamic>{
          'fill': node.style.fill,
          'text_color': node.style.textColor,
          'font_size': node.style.fontSize,
          'radius': node.style.radius,
          'opacity': node.style.opacity,
          'visible': node.style.visible,
        },
      };

  /// 文件名清洗：只留 `[A-Za-z0-9_-]`，其余换成 `_`；空回退 `board`；
  /// 同名（清洗后碰撞）追加序号，绝不互相覆盖。
  static String _uniqueFileId(String rawId, Set<String> used) {
    var safe = rawId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (safe.isEmpty) safe = 'board';
    if (safe.length > 64) safe = safe.substring(0, 64);
    var candidate = safe;
    var index = 2;
    while (!used.add(candidate)) {
      candidate = '${safe}_$index';
      index += 1;
    }
    return candidate;
  }
}
