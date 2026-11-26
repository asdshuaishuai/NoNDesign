/// 3D 视频工作台（只读预览）：左侧项目列表、中部预览面、右侧只读检查器、
/// 底部只读镜头时间线 + 运输条。
///
/// 2026-11-24 工作台独立适配：内容区按视频导演台的交互姿态独立排布
/// （左项目 / 中预览 / 右检查 / 底时间线），共享外壳仍由外层 `WorkspaceChrome`
/// 提供。本批做**只读预览 + 新建最小项目**（不做场景/镜头编辑）：
///
///  * 项目事实源是 `<项目根>/portfolio/video3d/<name>/` 的 `scene3d.json` +
///    `screenplay3d.json`（[Video3dProjectStore]）；工作台可以**新建**一个最小
///    合法项目（地面 + 主光 + 相机 + 单镜头），创建后自动选中并加载预览。
///  * 已有项目的**场景/镜头编辑**仍未接线：预览面在
///    `video3d_preview_surface.dart`，播放/暂停/seek 只驱动页面播放头，不改项目。
///  * 只读检查器展示标题 / 节点 / 灯光 / 相机 / 镜头数 / 时长 / 校验状态与问题数。
///  * 底部镜头时间线按 [compileVideo3dTimeline] 的整数帧表比例绘制；运输条是
///    预览面唯一控制面。
///  * 没有可播放项目时播放按钮**禁用并说明原因**（项目不存在/坏文件/校验未通过/
///    预览准备中/画面数据为空），不做假播放按钮。
///  * 无项目、坏项目都是显性人话；原始诊断只进折叠的「技术详情」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/creative/creative_schema.dart';
import '../core/theme.dart';
import '../core/video3d/video3d_compile.dart';
import '../core/video3d/video3d_contract.dart';
import '../core/video3d/video3d_project.dart';
import '../core/workbench_layout.dart';
import 'aqua.dart';
import 'common.dart';
import 'video3d_preview_surface.dart';
import 'video_workbench_panels.dart';
import 'workbench_views.dart';

/// 跨实例打开通道（与 `threeLoadOnOpen` / `videoLoadOnOpen` 同模式）：
/// [openVideo3dWorkspace] 写入项目名，工作台在 initState 消费后清空。
///
/// 空 = 不指定项目：工作台保持「打开列表首项」逻辑。
String? video3dLoadOnOpen;

/// 一次性通道（与 [video3dLoadOnOpen] 同族）：顶栏「新建 3D 视频」置 true 后
/// 打开工作台，工作台消费后**不自动打开列表首项**，直接落空态——空态里的
/// 「新建 3D 视频」按钮就是新建入口。与 [video3dLoadOnOpen] 互斥：带项目的
/// 打开请求优先。
bool video3dNewOnOpen = false;

/// 预览面控制器工厂：工作台把已校验的项目与帧表交给它。
///
/// 生产为 [createDefaultVideo3dPreview]；测试注入 Fake，避免构造真 WebView。
typedef Video3dPreviewFactory = Video3dPreviewController Function(
  Video3dProjectSnapshot snapshot,
  Video3dTimeline timeline,
);

/// 时间文案（`m:ss`，与预览页/条目元数据同一口径：向零取整秒）。
String formatVideo3dClock(double seconds) {
  final double safe = seconds.isFinite && seconds > 0 ? seconds : 0;
  final int total = safe.floor();
  final int minutes = total ~/ 60;
  final int rest = total % 60;
  return '$minutes:${rest.toString().padLeft(2, '0')}';
}

/// 镜头条每段的相对宽度：整数帧数 / 总帧数（按帧表比例，不是时长近似）。
///
/// 总帧数非正或没有镜头时返回空表（界面给「没有可预览的镜头时间线」）。
List<double> video3dShotFractions(Video3dTimeline timeline) {
  if (timeline.totalFrames <= 0 || timeline.shots.isEmpty) {
    return const <double>[];
  }
  return <double>[
    for (final Video3dShotFrames shot in timeline.shots)
      shot.frameCount / timeline.totalFrames,
  ];
}

/// 项目列表行高（两行文本：名称 + 节点/镜头摘要；itemExtent 免逐帧测量）。
const double _video3dProjectRowExtent = 48;

// ---------------------------------------------------------------------------
// 新建项目的最小合法事实源
// ---------------------------------------------------------------------------

/// 新建项目的场景：一块地面 box + 一盏方向主光 + 一台相机。
///
/// 只放契约 v1 明确支持的图元与字段；[title] 是项目显示名（可选，作为场景
/// 文档的额外元数据字段，契约校验不消费它、也不因未知字段报错）。
Map<String, Object?> buildVideo3dStarterScene({String? title}) {
  final String trimmedTitle = (title ?? '').trim();
  return <String, Object?>{
    'v': video3dVersion,
    'units': 'm',
    if (trimmedTitle.isNotEmpty) 'title': trimmedTitle,
    'environment': <String, Object?>{'background': '#0b0d12'},
    'nodes': <Object?>[
      <String, Object?>{
        'id': 'floor',
        'type': 'box',
        'size': <double>[10, 0.1, 10],
        'position': <double>[0, -0.05, 0],
        'material': <String, Object?>{
          'color': '#9a8c7a',
          'roughness': 0.9,
          'metalness': 0.0,
        },
      },
    ],
    'lights': <Object?>[
      <String, Object?>{
        'id': 'key',
        'type': 'directional',
        'intensity': 1.0,
        'color': '#ffffff',
        'position': <double>[4, 6, 4],
        'target': <double>[0, 0, 0],
      },
    ],
    'cameras': <Object?>[
      <String, Object?>{
        'id': 'hero',
        'position': <double>[4, 2, 4],
        'target': <double>[0, 0.5, 0],
        'fov': 45,
      },
    ],
  };
}

/// 新建项目的镜头表：单镜头，时长 = 对话框输入，固定 30fps。
///
/// 顶层 `duration` 与镜头时长用**同一个** double，过 `verifyVideo3d` 的
/// 「镜头总时长 = 片长」检查（容差在契约层，不靠界面凑数）。
Map<String, Object?> buildVideo3dStarterScreenplay({
  required double durationSeconds,
}) {
  return <String, Object?>{
    'v': video3dVersion,
    'fps': video3dFps,
    'format': <String, Object?>{'width': 1280, 'height': 720},
    'duration': durationSeconds,
    'shots': <Object?>[
      <String, Object?>{
        'id': 's1',
        'duration': durationSeconds,
        'camera': <String, Object?>{'id': 'hero'},
      },
    ],
  };
}

/// 3D 视频工作台（只读预览）。
class Video3dWorkspace extends StatefulWidget {
  const Video3dWorkspace({super.key, this.projectStore, this.previewFactory});

  /// 测试注入：指向临时目录的项目库；生产为 [Video3dProjectStore.instance]。
  final Video3dProjectStore? projectStore;

  /// 测试注入：把预览面换成 Fake 控制器，避免构造真 WebView。
  final Video3dPreviewFactory? previewFactory;

  @override
  State<Video3dWorkspace> createState() => _Video3dWorkspaceState();
}

class _Video3dWorkspaceState extends State<Video3dWorkspace> {
  late final Video3dProjectStore _projectStore =
      widget.projectStore ?? Video3dProjectStore.instance;

  List<Video3dProjectEntry> _entries = const <Video3dProjectEntry>[];
  bool _loading = true;
  String _listError = '';
  String? _name;
  bool _opening = false;
  Video3dProjectSnapshot? _snapshot;
  Video3dProjectFailure? _failure;
  Video3dPreviewController? _preview;
  Video3dTimeline? _timeline;

  /// 镜头条比例缓存：随项目快照重算一次，运输条每帧刷新时不再重算帧表。
  List<double> _shotFractions = const <double>[];
  String _previewError = '';

  // ---- 四栏目（呈现效果 / 文档 / 规范 / 源码） --------------------------

  /// 当前栏目。用户裁决 2026-11-27：所有工作台内容区固定四栏目；框架在
  /// `widgets/workbench_views.dart`，本工作台只做数据装配，「呈现效果」=
  /// 原有预览 + 检查器 + 镜头时间线（行为不变）。
  WorkbenchColumn _column = WorkbenchColumn.present;

  /// 文档栏数据（`docs.md` 优先，其次 `brief.md`；null = 没有文档）。
  String? _docsMarkdown;

  /// 源码栏数据（`scene3d.json` + `screenplay3d.json` 的只读文本树）。
  List<WorkbenchSourceFile> _sourceFiles = const <WorkbenchSourceFile>[];

  /// initState 从 [video3dLoadOnOpen] 取到的开局项目名（只消费一次）。
  String? _pendingOpen;

  /// initState 从 [video3dNewOnOpen] 取到的「落新建空态」请求（只消费一次）。
  bool _pendingNew = false;

  @override
  void initState() {
    super.initState();
    // 跨视图打开：项目名由 [openVideo3dWorkspace] 一次性写入，空 = 列表首项。
    _pendingOpen = video3dLoadOnOpen;
    video3dLoadOnOpen = null;
    // 顶栏「新建 3D 视频」：落空态而不是替用户打开首个项目。
    _pendingNew = video3dNewOnOpen;
    video3dNewOnOpen = false;
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _preview?.dispose();
    _preview = null;
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _listError = '';
    });
    List<Video3dProjectEntry> entries;
    String error = '';
    try {
      entries = await _projectStore.list();
    } catch (_) {
      entries = const <Video3dProjectEntry>[];
      error = '3D 视频项目暂时读不出来，请稍后重试。';
    }
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
      _listError = error;
    });
    final bool pendingNew = _pendingNew;
    _pendingNew = false;
    if (error.isNotEmpty) return;
    // 顶栏「新建 3D 视频」：列表照常列，但不替用户选中首个项目——空态里的
    // 新建按钮才是这次请求的落点。
    if (pendingNew) return;
    final String? pending = _pendingOpen;
    _pendingOpen = null;
    if (pending != null && pending.isNotEmpty) {
      // 指定了开局项目：打开它（读不到时由 _open 如实报错）。
      await _open(pending);
    } else if (_name == null && entries.isNotEmpty) {
      await _open(entries.first.name);
    }
  }

  Future<void> _open(String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _pendingOpen = null; // 已经落到具体项目，开局通道到此消费完
    video3dLoadOnOpen = null;
    // 切项目先卸预览面：旧页不能继续对着新项目响。
    final Video3dPreviewController? previous = _preview;
    _preview = null;
    previous?.dispose();
    setState(() {
      _name = trimmed;
      _opening = true;
      _snapshot = null;
      _failure = null;
      _timeline = null;
      _previewError = '';
      // 切项目 = 切内容：旧项目的文档/源码不能带进新项目的栏目。
      _docsMarkdown = null;
      _sourceFiles = const <WorkbenchSourceFile>[];
    });
    Video3dProjectSnapshot snapshot;
    try {
      snapshot = await _projectStore.read(trimmed);
    } on Video3dProjectFailure catch (failure) {
      if (!mounted || _name != trimmed) return;
      setState(() {
        _opening = false;
        _failure = failure;
        // 坏项目：栏目条常显，但呈现效果的既有错误面要在眼前；其余栏目如实空。
        _column = WorkbenchColumn.present;
        _docsMarkdown = null;
        _sourceFiles = const <WorkbenchSourceFile>[];
      });
      return;
    } catch (error) {
      if (!mounted || _name != trimmed) return;
      setState(() {
        _opening = false;
        _failure = Video3dProjectFailure('io_error', '$error');
        _column = WorkbenchColumn.present;
        _docsMarkdown = null;
        _sourceFiles = const <WorkbenchSourceFile>[];
      });
      return;
    }
    if (!mounted || _name != trimmed) return;
    _bindSnapshot(snapshot);
  }

  /// 打「新建 3D 视频」小对话框；创建成功返回项目名，随后刷新列表并自动选中
  /// 新项目（打开预览）。
  ///
  /// 写盘交给对话框里的 [Video3dProjectStore.save]（先校验后落盘）；失败留显性
  /// 人话 + 折叠技术详情，不静默关窗。
  Future<void> _createProject() async {
    final String? created = await showNonDialog<String>(
      context: context,
      builder: (routeContext) =>
          _Video3dCreateDialog(projectStore: _projectStore),
    );
    if (!mounted || created == null) return;
    // 刷新列表时把新项目作为开局目标一次性通道消费：列表出现 + 自动选中 + 预览。
    _pendingOpen = created;
    await _refresh();
  }

  /// 写入新快照、按校验状态重建预览面。
  ///
  /// 只有校验通过且帧表可编译时才创建控制器；否则底部运输条禁用播放并如实
  /// 说明原因（不做假播放按钮）。
  void _bindSnapshot(Video3dProjectSnapshot snapshot) {
    Video3dTimeline? timeline;
    String previewError = '';
    if (snapshot.verified &&
        snapshot.scene != null &&
        snapshot.screenplay != null) {
      try {
        timeline = compileVideo3dTimeline(snapshot.screenplay!);
      } catch (_) {
        previewError = '项目时间线没能编译出来，先修好镜头时长';
      }
    }
    Video3dPreviewController? next;
    if (timeline != null) {
      try {
        final Video3dPreviewFactory factory =
            widget.previewFactory ??
            (Video3dProjectSnapshot snapshot, Video3dTimeline timeline) =>
                createDefaultVideo3dPreview(snapshot, timeline);
        next = factory(snapshot, timeline);
      } catch (_) {
        previewError = '预览面没有准备好，可以重试';
      }
    }
    final Video3dPreviewController? previous = _preview;
    // 帧表比例在绑定快照时算一次（运输条帧刷新只改播放头，不重算比例）。
    final List<double> shotFractions = timeline == null
        ? const <double>[]
        : video3dShotFractions(timeline);
    // 四栏目数据与快照同一拍装配：文档/源码都在项目目录里，读一次缓存；
    // 切栏目不再读盘，也不伪造内容。
    final String? docs = _readDocs(snapshot.dir);
    final List<WorkbenchSourceFile> sources = _readSourceFiles(snapshot);
    setState(() {
      _snapshot = snapshot;
      _timeline = timeline;
      _shotFractions = shotFractions;
      _preview = next;
      _previewError = previewError;
      _opening = false;
      _failure = null;
      _docsMarkdown = docs;
      _sourceFiles = sources;
    });
    previous?.dispose();
    if (next != null) unawaited(next.start());
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final WorkbenchLayout layout = resolveWorkbenchLayout(
          kind: WorkbenchKind.video3d,
          width: constraints.maxWidth,
          height: constraints.maxHeight,
        );
        final bool hasLeft = layout.left == PanelPolicy.docked;
        final bool hasRight = layout.right == PanelPolicy.docked;
        // 四栏目（用户裁决 2026-11-27）：顶部固定栏目条 + 内容区。呈现效果 =
        // 原有「项目列表 | 预览 | 检查器 + 底部镜头时间线」（行为不变）；
        // 切到文档/规范/源码时不构建呈现面子树，也不触碰预览控制器
        // （WebView 页面不会因此重新准备/重新加载）。
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(p, layout),
            Expanded(
              child: WorkbenchColumns(
                column: _column,
                onColumnChanged: _onColumnChanged,
                data: _columnData(),
                present: Builder(
                  builder: (BuildContext context) => _presentPane(
                    p,
                    layout,
                    hasLeft: hasLeft,
                    hasRight: hasRight,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 栏目切换：栏目条只改当前栏目，预览控制器/项目快照都不动。
  void _onColumnChanged(WorkbenchColumn column) {
    if (_column == column) return;
    setState(() => _column = column);
  }

  /// 呈现效果栏目：原有预览主体（左项目 | 中预览 | 右检查器）+ 底部镜头时间线。
  Widget _presentPane(
    NonPalette p,
    WorkbenchLayout layout, {
    required bool hasLeft,
    required bool hasRight,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (hasLeft)
                SizedBox(
                  width: layout.leftWidth,
                  child: _Video3dProjectList(
                    entries: _entries,
                    selectedName: _name,
                    loading: _loading,
                    error: _listError,
                    onOpen: (String name) => unawaited(_open(name)),
                    onCreate: () => unawaited(_createProject()),
                  ),
                ),
              if (hasLeft) Container(width: 1, color: p.line),
              Expanded(child: _centerPane(p)),
              if (hasRight) Container(width: 1, color: p.line),
              if (hasRight)
                SizedBox(
                  width: layout.rightWidth,
                  child: _Video3dInspector(
                    snapshot: _snapshot,
                    timeline: _timeline,
                    failure: _failure,
                  ),
                ),
            ],
          ),
        ),
        if (layout.bottomBar)
          _Video3dBottomBar(
            height: layout.bottomBarHeight,
            snapshot: _snapshot,
            timeline: _timeline,
            shotFractions: _shotFractions,
            preview: _preview,
            failure: _failure,
          ),
      ],
    );
  }

  // -- 四栏目数据装配 -------------------------------------------------------
  //
  // 只读装配：文档/规范/源码全部来自项目目录与磁盘快照；没有就返回 null /
  // 空列表（栏目显示框架的可行动空态），绝不编造内容。

  /// 四栏目数据袋：项目不在场/还没读到快照时全部为空（可行动空态）。
  WorkbenchColumnData _columnData() {
    final Video3dProjectSnapshot? snapshot = _snapshot;
    if (snapshot == null) return const WorkbenchColumnData();
    return WorkbenchColumnData(
      docsMarkdown: _docsMarkdown,
      // 规范栏：两份机器可读事实源按文件名并排展示（scene3d = 场景，
      // screenplay3d = 镜头/时间），未知字段也原样保留。
      specJson: <String, Object?>{
        Video3dProjectStore.sceneFile: snapshot.sceneRaw,
        Video3dProjectStore.screenplayFile: snapshot.screenplayRaw,
      },
      specSummary: _specSummaryOf(snapshot),
      sourceFiles: _sourceFiles,
    );
  }

  /// 规范栏顶部的一句人话：校验状态 + 节点/镜头/总帧。
  String _specSummaryOf(Video3dProjectSnapshot snapshot) {
    final int nodes =
        snapshot.scene?.nodes.length ?? _listLength(snapshot.sceneRaw['nodes']);
    final int shots =
        snapshot.screenplay?.shots.length ??
        _listLength(snapshot.screenplayRaw['shots']);
    final int frames = _timeline?.totalFrames ?? 0;
    final String verify = snapshot.verified
        ? '校验通过'
        : '校验未通过（${snapshot.verification.checks.length} 个问题）';
    return '$verify · $nodes 节点 / $shots 镜头 / $frames 帧';
  }

  static int _listLength(Object? value) => value is List ? value.length : 0;

  /// 项目内人读文档：`docs.md` 优先，其次 `brief.md`；空文件按没有文档。
  String? _readDocs(String dir) {
    for (final String name in const <String>['docs.md', 'brief.md']) {
      final String? text = _readTextFile('$dir/$name');
      if (text != null) return text;
    }
    return null;
  }

  /// 只读源码树：`scene3d.json` + `screenplay3d.json`（两份事实源，不含
  /// artifacts/缓存等派生内容）。磁盘文本优先；读不出来退回已解码快照。
  List<WorkbenchSourceFile> _readSourceFiles(Video3dProjectSnapshot snapshot) {
    final List<WorkbenchSourceFile> files = <WorkbenchSourceFile>[];
    for (final String name in const <String>[
      Video3dProjectStore.sceneFile,
      Video3dProjectStore.screenplayFile,
    ]) {
      final String? text = _readTextFile('${snapshot.dir}/$name');
      if (text != null) {
        files.add(WorkbenchSourceFile(path: name, content: text));
        continue;
      }
      final Map<String, Object?> raw = name == Video3dProjectStore.sceneFile
          ? snapshot.sceneRaw
          : snapshot.screenplayRaw;
      files.add(
        WorkbenchSourceFile(
          path: name,
          content: const JsonEncoder.withIndent('  ').convert(raw),
        ),
      );
    }
    return files;
  }

  /// 读项目目录内一个文本文件；缺失/读失败/空白一律 null。
  String? _readTextFile(String path) {
    final File file = File(path);
    if (!file.existsSync()) return null;
    try {
      final String text = file.readAsStringSync();
      return text.trim().isEmpty ? null : text;
    } on FileSystemException {
      return null;
    }
  }

  /// 浅色（Aqua）头部的工具圆钮：40×40 槽位（与既有 IconButton 实测同尺寸），
  /// 内部 28px 白面圆钮。Key 挂在 [AquaToolIcon] 上以保留既有 Key。
  Widget _aquaHeaderTool({
    required Key key,
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
  }) => SizedBox(
    width: 40,
    height: 40,
    child: Center(
      child: AquaToolIcon(
        key: key,
        icon: icon,
        tooltip: tooltip,
        size: 28,
        onTap: onTap,
      ),
    ),
  );

  Widget _header(NonPalette p, WorkbenchLayout layout) {
    final String title = _snapshot?.name ?? _name ?? '';
    final bool? verified = _snapshot?.verified;
    // 浅色（Aqua）：工具条白面 + 发丝线 + 深色软阴影（静态，不参与布局测量）；
    // 深色保持原底。
    final bool aqua = isAquaTheme(context);
    return Container(
      key: const ValueKey('video3d-header'),
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: NonSpace.md),
      decoration: BoxDecoration(
        color: aqua ? p.panel : p.bgElevated,
        border: Border(bottom: BorderSide(color: p.line)),
        boxShadow: aqua
            ? <BoxShadow>[
                BoxShadow(
                  color: p.line,
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.movie_creation_outlined, size: 16, color: p.ink3),
          const SizedBox(width: NonSpace.sm),
          Text(
            '3D 视频工作台',
            style: TextStyle(
              fontSize: NonType.bodyStrong,
              fontWeight: FontWeight.w600,
              color: p.ink,
            ),
          ),
          const SizedBox(width: NonSpace.md),
          Flexible(
            child: Text(
              title.isEmpty ? '还没有打开的 3D 视频项目' : '只读预览 · $title',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: NonType.caption, color: p.ink4),
            ),
          ),
          const Spacer(),
          if (verified != null)
            Text(
              verified ? '校验通过' : '校验未通过',
              key: const ValueKey('video3d-header-verify'),
              style: TextStyle(
                fontSize: NonType.micro,
                color: verified ? p.success : p.warn,
              ),
            ),
          // 窄屏没有左侧项目栏：给一个项目下拉，项目仍可切换。
          if (layout.left != PanelPolicy.docked && _entries.isNotEmpty)
            PopupMenuButton<String>(
              key: const ValueKey('video3d-project-menu'),
              tooltip: '切换 3D 视频项目',
              offset: const Offset(0, 34),
              color: p.panel,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(NonRadius.md),
                side: BorderSide(color: p.lineStrong),
              ),
              onSelected: (String name) => unawaited(_open(name)),
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                for (final Video3dProjectEntry entry in _entries)
                  PopupMenuItem<String>(
                    value: entry.name,
                    height: 34,
                    child: Text(
                      entry.corrupt ? '${entry.name}（文件不完整）' : entry.name,
                      style: TextStyle(
                        fontSize: NonType.body,
                        color: entry.corrupt ? p.warn : p.ink2,
                      ),
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: NonSpace.sm,
                  vertical: NonSpace.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.list_alt_outlined, size: 14, color: p.ink3),
                    const SizedBox(width: NonSpace.xs),
                    Text(
                      '项目',
                      style: TextStyle(
                        fontSize: NonType.caption,
                        color: p.ink3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (isAquaTheme(context)) ...[
            _aquaHeaderTool(
              key: const ValueKey('video3d-new-project-header'),
              icon: Icons.add,
              tooltip: '新建 3D 视频',
              onTap: () => unawaited(_createProject()),
            ),
            _aquaHeaderTool(
              key: const ValueKey('video3d-refresh'),
              icon: Icons.refresh,
              tooltip: '刷新 3D 视频项目',
              onTap: _loading ? null : _refresh,
            ),
          ] else ...[
            IconButton(
              key: const ValueKey('video3d-new-project-header'),
              tooltip: '新建 3D 视频',
              onPressed: () => unawaited(_createProject()),
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.add, color: p.ink3),
            ),
            IconButton(
              key: const ValueKey('video3d-refresh'),
              tooltip: '刷新 3D 视频项目',
              onPressed: _loading ? null : _refresh,
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.refresh, color: p.ink3),
            ),
          ],
        ],
      ),
    );
  }

  Widget _centerPane(NonPalette p) {
    if (_opening) {
      return Center(
        child: Text(
          '正在打开 3D 视频项目…',
          style: TextStyle(fontSize: NonType.body, color: p.ink3),
        ),
      );
    }
    if (_failure != null) return _failurePane(p, _failure!);
    final Video3dProjectSnapshot? snapshot = _snapshot;
    if (snapshot == null) {
      if (_loading) {
        return Center(
          child: Text(
            '正在读取 3D 视频项目…',
            style: TextStyle(fontSize: NonType.body, color: p.ink3),
          ),
        );
      }
      return _emptyPane(p);
    }
    if (!snapshot.verified) return _verificationPane(p, snapshot);
    if (_previewError.isNotEmpty) {
      return _messagePane(p, Icons.movie_filter_outlined, _previewError);
    }
    final Video3dPreviewController? preview = _preview;
    final Video3dTimeline? timeline = _timeline;
    if (preview == null || timeline == null) {
      return _messagePane(p, Icons.movie_filter_outlined, '预览面还没有准备好，可以重试');
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NonSpace.md,
        NonSpace.md,
        NonSpace.md,
        NonSpace.md,
      ),
      child: Video3dPreviewSurface(preview: preview),
    );
  }

  Widget _emptyPane(NonPalette p) {
    return Center(
      key: const ValueKey('video3d-empty'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(NonSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.movie_creation_outlined, size: 30, color: p.ink4),
            const SizedBox(height: NonSpace.md),
            Text(
              '还没有 3D 视频项目',
              style: TextStyle(
                fontSize: NonType.bodyStrong,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
            const SizedBox(height: NonSpace.sm),
            Text(
              '新建一个最小项目，或者把已有的项目文件放进项目目录后刷新；'
              '选中项目就能只读预览画面、镜头和检查器。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: NonType.caption,
                height: NonType.lineBody,
                color: p.ink4,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const ValueKey('video3d-new-project-empty'),
              onPressed: () => unawaited(_createProject()),
              icon: const Icon(Icons.add, size: 16),
              label: const Text(
                '新建 3D 视频',
                style: TextStyle(fontSize: NonType.body),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _failurePane(NonPalette p, Video3dProjectFailure failure) {
    return Center(
      key: const ValueKey('video3d-project-failure'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(NonSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.movie_filter_outlined, size: 28, color: p.warn),
            const SizedBox(height: NonSpace.sm),
            Text(
              video3dProjectFailureMessage(failure),
              key: const ValueKey('video3d-project-failure-message'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: NonType.bodyStrong,
                height: NonType.lineBody,
                color: p.ink2,
              ),
            ),
            const SizedBox(height: NonSpace.sm),
            Text(
              '这个项目暂时打不开；左侧列表里还留着它。修好文件后可以重新读取。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: NonType.caption,
                height: NonType.lineBody,
                color: p.ink4,
              ),
            ),
            const SizedBox(height: NonSpace.md),
            _reloadButton(p),
            if (failure.technical.isNotEmpty)
              _technicalPane('技术详情', failure.technical),
          ],
        ),
      ),
    );
  }

  Widget _verificationPane(NonPalette p, Video3dProjectSnapshot snapshot) {
    final List<Video3dIssue> issues = snapshot.verification.checks;
    final String detail = <String>[
      for (final Video3dIssue issue in issues)
        '${issue.code} @ ${issue.pointer.isEmpty ? '/' : issue.pointer}: '
            '${issue.message}',
    ].join('\n');
    return Center(
      key: const ValueKey('video3d-verification-failed'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(NonSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.rule_folder_outlined, size: 28, color: p.warn),
            const SizedBox(height: NonSpace.sm),
            Text(
              '这个项目没有通过校验，暂时不能预览',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: NonType.bodyStrong,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
            const SizedBox(height: NonSpace.sm),
            Text(
              '场景或镜头文件还有 ${issues.length} 个问题；修好后重新读取就能预览。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: NonType.caption,
                height: NonType.lineBody,
                color: p.ink4,
              ),
            ),
            const SizedBox(height: NonSpace.md),
            for (final Video3dIssue issue in issues.take(4))
              Padding(
                padding: const EdgeInsets.only(bottom: NonSpace.xs),
                child: Text(
                  '· ${issue.message}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: NonType.caption,
                    height: NonType.lineCaption,
                    color: p.ink3,
                  ),
                ),
              ),
            if (issues.length > 4)
              Text(
                '还有 ${issues.length - 4} 个问题',
                style: TextStyle(fontSize: NonType.micro, color: p.ink4),
              ),
            const SizedBox(height: NonSpace.md),
            _reloadButton(p),
            _technicalPane('技术详情（问题位置）', detail),
          ],
        ),
      ),
    );
  }

  Widget _messagePane(NonPalette p, IconData icon, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NonSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 28, color: p.ink4),
            const SizedBox(height: NonSpace.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: NonType.body,
                height: NonType.lineBody,
                color: p.ink2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reloadButton(NonPalette p) {
    final String? name = _name;
    return TextButton.icon(
      key: const ValueKey('video3d-reload'),
      onPressed: name == null ? null : () => unawaited(_open(name)),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: NonSpace.md),
      ),
      icon: const Icon(Icons.refresh, size: 15),
      label: const Text('重新读取', style: TextStyle(fontSize: NonType.caption)),
    );
  }

  Widget _technicalPane(String title, String detail) {
    if (detail.isEmpty) return const SizedBox.shrink();
    return _Video3dTechnicalDetails(title: title, detail: detail);
  }
}

// ---------------------------------------------------------------------------
// 左侧项目列表
// ---------------------------------------------------------------------------

class _Video3dProjectList extends StatelessWidget {
  const _Video3dProjectList({
    required this.entries,
    required this.selectedName,
    required this.loading,
    required this.error,
    required this.onOpen,
    required this.onCreate,
  });

  final List<Video3dProjectEntry> entries;
  final String? selectedName;
  final bool loading;
  final String error;
  final ValueChanged<String> onOpen;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    return Container(
      key: const ValueKey('video3d-project-list'),
      color: p.bgElevated.withValues(alpha: 0.9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          VideoPanelHeader(
            icon: Icons.movie_creation_outlined,
            title: '3D 视频项目',
            meta: loading ? null : '${entries.length}',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (loading)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.4),
                  ),
                IconButton(
                  key: const ValueKey('video3d-new-project'),
                  tooltip: '新建 3D 视频',
                  onPressed: onCreate,
                  iconSize: 13,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 22,
                    minHeight: 22,
                  ),
                  icon: Icon(Icons.add, color: p.ink4),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: p.line),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(NonSpace.md),
              child: Text(
                error,
                style: TextStyle(
                  fontSize: NonType.caption,
                  color: p.warn,
                  height: NonType.lineCaption,
                ),
              ),
            )
          else if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(NonSpace.md),
              child: Text(
                '还没有 3D 视频项目。\n点右上角「+」新建，或把项目文件放进项目目录后刷新。',
                style: TextStyle(
                  fontSize: NonType.caption,
                  height: NonType.lineBody,
                  color: p.ink4,
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: NonSpace.xs),
                itemExtent: _video3dProjectRowExtent,
                itemCount: entries.length,
                itemBuilder: (BuildContext context, int index) {
                  final Video3dProjectEntry entry = entries[index];
                  return _ProjectRow(
                    entry: entry,
                    selected: entry.name == selectedName,
                    onOpen: () => onOpen(entry.name),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.entry,
    required this.selected,
    required this.onOpen,
  });

  final Video3dProjectEntry entry;
  final bool selected;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    final String meta = entry.corrupt
        ? '文件不完整，打不开'
        : '${entry.nodes} 节点 · ${entry.shots} 镜头 · '
              '${formatVideo3dClock(entry.durationSeconds)}';
    return InkWell(
      key: ValueKey<String>('video3d-project-${entry.name}'),
      onTap: onOpen,
      child: Container(
        color: selected ? p.accentSoft.withValues(alpha: 0.35) : null,
        padding: const EdgeInsets.fromLTRB(
          NonSpace.md,
          NonSpace.xs,
          NonSpace.md,
          NonSpace.xs,
        ),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.movie_creation_outlined,
              size: 12,
              color: selected ? p.accent : p.ink4,
            ),
            const SizedBox(width: NonSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: NonType.body,
                      color: selected ? p.ink : p.ink2,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: NonSpace.xxs),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: NonType.micro,
                      color: entry.corrupt ? p.warn : p.ink4,
                    ),
                  ),
                ],
              ),
            ),
            if (entry.corrupt)
              Icon(Icons.error_outline, size: 12, color: p.warn)
            else if (!entry.verified)
              Icon(Icons.rule, size: 12, color: p.ink4),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 右侧只读检查器
// ---------------------------------------------------------------------------

class _Video3dInspector extends StatelessWidget {
  const _Video3dInspector({
    required this.snapshot,
    required this.timeline,
    required this.failure,
  });

  final Video3dProjectSnapshot? snapshot;
  final Video3dTimeline? timeline;
  final Video3dProjectFailure? failure;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    final Video3dProjectSnapshot? snapshot = this.snapshot;
    final Video3dScene? scene = snapshot?.scene;
    final Video3dScreenplay? screenplay = snapshot?.screenplay;
    // 新建项目时写进场景文档的显示名（可选；未知字段不影响契约校验）。
    final String? projectTitle = creativeNonEmptyString(
      snapshot?.sceneRaw['title'],
    );
    final int issueCount = snapshot?.verification.checks.length ?? 0;
    return Container(
      key: const ValueKey('video3d-inspector'),
      color: p.bgElevated.withValues(alpha: 0.9),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          NonSpace.md,
          NonSpace.md,
          NonSpace.md,
          NonSpace.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const VideoPanelHeader(
              icon: Icons.fact_check_outlined,
              title: '只读检查器',
            ),
            const SizedBox(height: NonSpace.xxs),
            Text(
              snapshot == null ? '选中项目后显示场景与镜头摘要' : snapshot.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: NonType.micro, color: p.ink4),
            ),
            const SizedBox(height: NonSpace.sm),
            Divider(height: 1, color: p.line),
            const SizedBox(height: NonSpace.sm),
            if (failure != null)
              Text(
                video3dProjectFailureMessage(failure),
                style: TextStyle(
                  fontSize: NonType.caption,
                  height: NonType.lineCaption,
                  color: p.warn,
                ),
              )
            else if (snapshot == null)
              Text(
                '还没有打开的项目',
                style: TextStyle(fontSize: NonType.caption, color: p.ink4),
              )
            else ...<Widget>[
              if (projectTitle != null)
                _row(p, '标题', projectTitle, key: 'video3d-inspector-title'),
              _row(p, '场景节点', '${scene?.nodes.length ?? 0}'),
              _row(p, '灯光', '${scene?.lights.length ?? 0}'),
              _row(p, '相机', '${scene?.cameras.length ?? 0}'),
              _row(p, '镜头', '${screenplay?.shots.length ?? 0}'),
              _row(
                p,
                '时长',
                formatVideo3dClock(screenplay?.durationSeconds ?? 0),
                key: 'video3d-inspector-duration',
              ),
              _row(
                p,
                '总帧',
                '${timeline?.totalFrames ?? 0}',
                key: 'video3d-inspector-frames',
              ),
              _row(p, '帧率', '${timeline?.fps ?? screenplay?.fps ?? 0} fps'),
              _row(
                p,
                '校验',
                snapshot.verified ? '通过' : '未通过（$issueCount 个问题）',
                key: 'video3d-inspector-verify',
                color: snapshot.verified ? p.success : p.warn,
              ),
              const SizedBox(height: NonSpace.sm),
              Divider(height: 1, color: p.line),
              const SizedBox(height: NonSpace.sm),
              Text(
                snapshot.verified
                    ? '本批只读：预览、检查器和镜头时间线都不改项目文件。'
                    : '修好场景或镜头文件后点顶栏刷新，就能重新预览。',
                style: TextStyle(
                  fontSize: NonType.micro,
                  height: NonType.lineBody,
                  color: p.ink4,
                ),
              ),
              if (!snapshot.verified && issueCount > 0) ...<Widget>[
                const SizedBox(height: NonSpace.sm),
                for (final Video3dIssue issue
                    in snapshot.verification.checks.take(6))
                  Padding(
                    padding: const EdgeInsets.only(bottom: NonSpace.xs),
                    child: Text(
                      '· ${issue.message}',
                      style: TextStyle(
                        fontSize: NonType.micro,
                        height: NonType.lineCaption,
                        color: p.ink3,
                      ),
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(
    NonPalette p,
    String label,
    String value, {
    String? key,
    Color? color,
  }) {
    return Padding(
      key: key == null ? null : ValueKey<String>(key),
      padding: const EdgeInsets.symmetric(vertical: NonSpace.xs),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: TextStyle(fontSize: NonType.caption, color: p.ink4),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: NonType.caption,
              color: color ?? p.ink2,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 底部只读镜头时间线 + 运输条
// ---------------------------------------------------------------------------

class _Video3dBottomBar extends StatelessWidget {
  const _Video3dBottomBar({
    required this.height,
    required this.snapshot,
    required this.timeline,
    required this.shotFractions,
    required this.preview,
    required this.failure,
  });

  final double height;
  final Video3dProjectSnapshot? snapshot;
  final Video3dTimeline? timeline;

  /// 帧表比例（工作台在绑定快照时算一次，这里只读）。
  final List<double> shotFractions;
  final Video3dPreviewController? preview;
  final Video3dProjectFailure? failure;

  @override
  Widget build(BuildContext context) {
    final Video3dPreviewController? preview = this.preview;
    if (preview == null) return _bar(context, null);
    return ListenableBuilder(
      listenable: preview,
      builder: (BuildContext context, Widget? _) => _bar(context, preview),
    );
  }

  /// 为什么现在不能播；null = 可以播放。
  String? _disabledReason(Video3dPreviewController? preview) {
    if (failure != null) return '这个项目打不开，修好文件后再播放';
    if (snapshot == null) return '还没有选中 3D 视频项目';
    if (!snapshot!.verified) return '项目没有通过校验，先修好场景或镜头';
    if (timeline == null) return '项目时间线没能编译出来，先修好镜头时长';
    if (preview == null) return '预览面还没有准备好，可以重试';
    if (preview.loadError.isNotEmpty) return preview.loadError;
    if (!preview.ready) return '预览准备中…';
    if (preview.totalFrames <= 0) return '画面数据是空的，没有可播放的帧';
    return null;
  }

  Widget _bar(BuildContext context, Video3dPreviewController? preview) {
    final NonPalette p = context.palette;
    final Video3dTimeline? timeline = this.timeline;
    final String? reason = _disabledReason(preview);
    final bool enabled = reason == null;
    final int totalFrames = preview?.totalFrames ?? timeline?.totalFrames ?? 0;
    final int fps = preview?.fps ?? timeline?.fps ?? 0;
    final int frame = preview?.frame ?? 0;
    final int shotCount =
        snapshot?.screenplay?.shots.length ?? timeline?.shots.length ?? 0;
    final double duration =
        snapshot?.screenplay?.durationSeconds ?? timeline?.durationSeconds ?? 0;
    final double frameSeconds = fps > 0 ? frame / fps : 0;
    return Container(
      key: const ValueKey('video3d-bottom-bar'),
      height: height,
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NonSpace.md,
              NonSpace.sm,
              NonSpace.md,
              NonSpace.xxs,
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.linear_scale, size: 12, color: p.ink4),
                const SizedBox(width: NonSpace.sm),
                Text(
                  '镜头时间线',
                  style: TextStyle(
                    fontSize: NonType.caption,
                    fontWeight: FontWeight.w600,
                    color: p.ink3,
                  ),
                ),
                const SizedBox(width: NonSpace.sm),
                Text(
                  shotCount > 0 ? '$shotCount 个镜头 · 只读' : '只读',
                  style: TextStyle(fontSize: NonType.micro, color: p.ink4),
                ),
                const Spacer(),
                if (timeline != null && timeline.totalFrames > 0)
                  Text(
                    '${timeline.totalFrames} 帧 · ${timeline.durationSeconds.toStringAsFixed(1)} 秒',
                    style: TextStyle(
                      fontSize: NonType.micro,
                      fontFamily: 'Menlo',
                      color: p.ink4,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: NonSpace.md),
            child: SizedBox(
              height: 30,
              child: _timeline(p, timeline, preview, shotFractions),
            ),
          ),
          const SizedBox(height: NonSpace.xs),
          Divider(height: 1, color: p.line),
          Expanded(
            child: Center(
              child: _transport(
                context,
                p,
                preview,
                reason,
                enabled,
                totalFrames,
                fps,
                frame,
                frameSeconds,
                duration,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 镜头条：按预计算的帧表比例分段，播放头只读显示。
  Widget _timeline(
    NonPalette p,
    Video3dTimeline? timeline,
    Video3dPreviewController? preview,
    List<double> fractions,
  ) {
    if (timeline == null ||
        timeline.totalFrames <= 0 ||
        timeline.shots.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '没有可预览的镜头时间线',
          style: TextStyle(fontSize: NonType.micro, color: p.ink4),
        ),
      );
    }
    final double playhead = (((preview?.frame ?? 0) / timeline.totalFrames)
        .clamp(0.0, 1.0));
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Row(
              children: <Widget>[
                for (int i = 0; i < fractions.length; i++)
                  SizedBox(
                    width: width * fractions[i],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Container(
                        key: ValueKey<String>(
                          'video3d-shot-${timeline.shots[i].id}',
                        ),
                        height: 26,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: i.isEven
                              ? p.panel3
                              : p.accentSoft.withValues(alpha: 0.28),
                          borderRadius: BorderRadius.circular(NonRadius.sm),
                        ),
                        child: Text(
                          timeline.shots[i].id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: NonType.micro,
                            color: p.ink3,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (playhead > 0)
              Positioned(
                left: width * playhead - 1,
                top: 0,
                bottom: 0,
                child: Container(
                  key: const ValueKey('video3d-playhead'),
                  width: 2,
                  color: p.accent,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _transport(
    BuildContext context,
    NonPalette p,
    Video3dPreviewController? preview,
    String? reason,
    bool enabled,
    int totalFrames,
    int fps,
    int frame,
    double frameSeconds,
    double duration,
  ) {
    final double maxFrame = totalFrames > 1 ? totalFrames - 1 : 1;
    final double sliderValue = frame.toDouble().clamp(0.0, maxFrame);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NonSpace.sm,
        vertical: NonSpace.xs,
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const ValueKey('video3d-transport-play'),
            tooltip: '播放',
            onPressed: enabled && preview != null && !preview.playing
                ? preview.play
                : null,
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
            icon: Icon(Icons.play_arrow, color: p.ink3),
          ),
          IconButton(
            key: const ValueKey('video3d-transport-pause'),
            tooltip: '暂停',
            onPressed: enabled && preview != null && preview.playing
                ? preview.pause
                : null,
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
            icon: Icon(Icons.pause, color: p.ink3),
          ),
          IconButton(
            key: const ValueKey('video3d-transport-stop'),
            tooltip: '停止',
            onPressed: enabled && preview != null ? preview.stop : null,
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
            icon: Icon(Icons.stop, color: p.ink3),
          ),
          const SizedBox(width: NonSpace.xs),
          Expanded(
            child: enabled && preview != null
                ? SizedBox(
                    height: 28,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 5,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 10,
                        ),
                      ),
                      child: Slider(
                        key: const ValueKey('video3d-transport-seek'),
                        value: sliderValue,
                        max: maxFrame,
                        activeColor: p.accent,
                        inactiveColor: p.line,
                        onChanged: (double value) =>
                            unawaited(preview.seekFrame(value.round())),
                      ),
                    ),
                  )
                : _reasonText(p, reason),
          ),
          const SizedBox(width: NonSpace.sm),
          Text(
            enabled
                ? '${formatVideo3dClock(frameSeconds)} / '
                      '${formatVideo3dClock(duration)}'
                : '—',
            key: const ValueKey('video3d-transport-time'),
            maxLines: 1,
            style: TextStyle(
              fontSize: NonType.micro,
              fontFamily: 'Menlo',
              color: p.ink4,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: NonSpace.md),
          Flexible(
            child: Text(
              fps > 0 && totalFrames > 0
                  ? '$fps fps · $totalFrames 帧'
                  : '没有可播放的画面',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: NonType.micro, color: p.ink4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _reasonText(NonPalette p, String? reason) {
    return Row(
      key: const ValueKey('video3d-transport-reason'),
      children: <Widget>[
        Icon(Icons.info_outline, size: 13, color: p.warn),
        const SizedBox(width: NonSpace.sm),
        Expanded(
          child: Text(
            reason ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: NonType.caption, color: p.ink3),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 折叠的原始诊断（「技术详情」）
// ---------------------------------------------------------------------------

/// 用户可见文案在上一层；原始错误/问题定位只进这个折叠面板。
class _Video3dTechnicalDetails extends StatelessWidget {
  const _Video3dTechnicalDetails({
    required this.title,
    required this.detail,
    this.paneKey = const ValueKey('video3d-technical-details'),
  });

  final String title;
  final String detail;
  final Key paneKey;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          key: paneKey,
          tilePadding: const EdgeInsets.symmetric(horizontal: NonSpace.md),
          childrenPadding: const EdgeInsets.fromLTRB(
            NonSpace.md,
            0,
            NonSpace.md,
            NonSpace.sm,
          ),
          dense: true,
          title: Text(
            title,
            style: TextStyle(fontSize: NonType.caption, color: p.ink4),
          ),
          iconColor: p.ink4,
          collapsedIconColor: p.ink4,
          children: <Widget>[
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                detail,
                style: TextStyle(
                  fontSize: NonType.micro,
                  color: p.ink4,
                  height: NonType.lineCaption,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 新建项目小对话框
// ---------------------------------------------------------------------------

/// 新建项目允许的最长片长（秒）：再长就该走镜头表/脚本，不在小对话框里拼。
const double kVideo3dCreateMaxDuration = 3600;

/// 新建 3D 视频：名称白名单 + 可选标题 + 时长（秒）。
///
/// 写盘在对话框内完成（[Video3dProjectStore.save] 先校验后落盘）：成功返回
/// 项目名并关窗，调用方刷新列表、自动选中并加载预览；失败**不关窗**，给显性
/// 人话 + 折叠技术详情，用户能改名字/时长重试。
class _Video3dCreateDialog extends StatefulWidget {
  const _Video3dCreateDialog({required this.projectStore});

  final Video3dProjectStore projectStore;

  @override
  State<_Video3dCreateDialog> createState() => _Video3dCreateDialogState();
}

class _Video3dCreateDialogState extends State<_Video3dCreateDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _title = TextEditingController();
  final TextEditingController _duration = TextEditingController(text: '5');
  bool _saving = false;
  String _error = '';
  String _technical = '';

  @override
  void dispose() {
    _name.dispose();
    _title.dispose();
    _duration.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final String name = _name.text.trim();
    if (!creativeIsSafeProjectName(name)) {
      // 与项目库同一句人话（避免这里和存储层各写一份措辞）。
      setState(() {
        _error = video3dProjectFailureMessage('invalid_name');
        _technical = '';
      });
      return;
    }
    final double? duration = double.tryParse(_duration.text.trim());
    if (duration == null || !duration.isFinite || duration <= 0) {
      setState(() {
        _error = '时长要填一个大于 0 的秒数';
        _technical = '';
      });
      return;
    }
    if (duration < video3dMinShotDuration) {
      setState(() {
        _error = '时长至少一帧（30 帧/秒下约 0.033 秒）';
        _technical = '';
      });
      return;
    }
    if (duration > kVideo3dCreateMaxDuration) {
      setState(() {
        _error = '时长最多 $kVideo3dCreateMaxDuration 秒';
        _technical = '';
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = '';
      _technical = '';
    });
    Video3dVerification verification;
    try {
      verification = await widget.projectStore.save(
        name,
        scene: buildVideo3dStarterScene(title: _title.text),
        screenplay: buildVideo3dStarterScreenplay(durationSeconds: duration),
      );
    } on Video3dProjectFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = failure.message;
        _technical = failure.technical;
      });
      return;
    } catch (error) {
      if (!mounted) return;
      // 没归到项目库错误码的异常同样落人话；原始异常只进折叠详情。
      final Video3dProjectFailure failure = Video3dProjectFailure(
        'io_error',
        '$error',
      );
      setState(() {
        _saving = false;
        _error = failure.message;
        _technical = failure.technical;
      });
      return;
    }
    if (!mounted) return;
    if (!verification.verified) {
      // 模板本身应当永远合法；走到这里说明契约变了或输入踩了边界——如实说明。
      setState(() {
        _saving = false;
        _error = '生成的场景或镜头没有通过校验，项目没有保存';
        _technical = <String>[
          for (final Video3dIssue issue in verification.checks)
            '${issue.code} @ ${issue.pointer.isEmpty ? '/' : issue.pointer}: '
                '${issue.message}',
        ].join('\n');
      });
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    return AlertDialog(
      key: const ValueKey('video3d-create-dialog'),
      backgroundColor: p.panel,
      title: Text(
        '新建 3D 视频',
        style: TextStyle(fontSize: NonType.subtitle, color: p.ink),
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '会生成一个最小项目：一块地面、一盏主光、一台相机和一个单镜头；'
                '创建后自动打开预览。',
                style: TextStyle(
                  fontSize: NonType.caption,
                  height: NonType.lineBody,
                  color: p.ink3,
                ),
              ),
              const SizedBox(height: NonSpace.md),
              _field(
                p,
                label: '项目名',
                helper: '字母、数字、下划线或短横线',
                field: TextField(
                  key: const ValueKey('video3d-create-name'),
                  controller: _name,
                  autofocus: true,
                  enabled: !_saving,
                  style: TextStyle(fontSize: NonType.body, color: p.ink2),
                  decoration: _decoration(p, hint: '例如 night-market'),
                ),
              ),
              const SizedBox(height: NonSpace.md),
              _field(
                p,
                label: '标题（可选）',
                helper: '默认用项目名',
                field: TextField(
                  key: const ValueKey('video3d-create-title'),
                  controller: _title,
                  enabled: !_saving,
                  style: TextStyle(fontSize: NonType.body, color: p.ink2),
                  decoration: _decoration(p, hint: '显示在检查器里'),
                ),
              ),
              const SizedBox(height: NonSpace.md),
              _field(
                p,
                label: '时长（秒）',
                helper: '按 30 帧/秒计时，最多 $kVideo3dCreateMaxDuration 秒',
                field: TextField(
                  key: const ValueKey('video3d-create-duration'),
                  controller: _duration,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: TextStyle(fontSize: NonType.body, color: p.ink2),
                  decoration: _decoration(p, hint: '5'),
                  onSubmitted: (_) => unawaited(_submit()),
                ),
              ),
              if (_error.isNotEmpty) ...<Widget>[
                const SizedBox(height: NonSpace.md),
                Container(
                  key: const ValueKey('video3d-create-error'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: NonSpace.md,
                    vertical: NonSpace.sm,
                  ),
                  decoration: BoxDecoration(
                    color: p.warn.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(NonRadius.md),
                    border: Border.all(color: p.warn.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    _error,
                    style: TextStyle(
                      fontSize: NonType.caption,
                      height: NonType.lineCaption,
                      color: p.warn,
                    ),
                  ),
                ),
              ],
              if (_technical.isNotEmpty)
                _Video3dTechnicalDetails(
                  title: '技术详情',
                  detail: _technical,
                  paneKey: const ValueKey('video3d-create-technical'),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey('video3d-create-cancel'),
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('video3d-create-submit'),
          onPressed: _saving ? null : () => unawaited(_submit()),
          child: _saving
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              : const Text('创建'),
        ),
      ],
    );
  }

  Widget _field(
    NonPalette p, {
    required String label,
    required String helper,
    required Widget field,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: NonType.caption,
            fontWeight: FontWeight.w600,
            color: p.ink3,
          ),
        ),
        const SizedBox(height: NonSpace.xs),
        field,
        const SizedBox(height: NonSpace.xs),
        Text(
          helper,
          style: TextStyle(fontSize: NonType.micro, color: p.ink4),
        ),
      ],
    );
  }

  InputDecoration _decoration(NonPalette p, {required String hint}) {
    return InputDecoration(
      isDense: true,
      filled: true,
      fillColor: p.panel2,
      hintText: hint,
      hintStyle: TextStyle(fontSize: NonType.caption, color: p.ink4),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: NonSpace.md,
        vertical: NonSpace.sm,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(NonRadius.md),
      ),
    );
  }
}
