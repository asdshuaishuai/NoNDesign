/// 3D 视频工作台（只读预览）：左侧项目列表、中部预览面、右侧只读检查器、
/// 底部只读镜头时间线 + 运输条。
///
/// 2026-11-24 工作台独立适配：内容区按视频导演台的交互姿态独立排布
/// （左项目 / 中预览 / 右检查 / 底时间线），共享外壳仍由外层 `WorkspaceChrome`
/// 提供。本批只做**只读预览**：
///
///  * 项目事实源是 `<项目根>/portfolio/video3d/<name>/` 的 `scene3d.json` +
///    `screenplay3d.json`（[Video3dProjectStore]）；本工作台只读，不写盘。
///  * 预览面在 `video3d_preview_surface.dart`：经 `assembleVideo3dPreview` 组装的
///    自包含页面接进 `webview_all`；播放/暂停/seek 只驱动页面播放头，不改项目。
///  * 只读检查器展示节点 / 灯光 / 相机 / 镜头数 / 时长 / 校验状态与问题数。
///  * 底部镜头时间线按 [compileVideo3dTimeline] 的整数帧表比例绘制；运输条是
///    预览面唯一控制面。
///  * 没有可播放项目时播放按钮**禁用并说明原因**（项目不存在/坏文件/校验未通过/
///    预览准备中/画面数据为空），不做假播放按钮。
///  * 无项目、坏项目都是显性人话；原始诊断只进折叠的「技术详情」。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import '../core/video3d/video3d_compile.dart';
import '../core/video3d/video3d_contract.dart';
import '../core/video3d/video3d_project.dart';
import '../core/workbench_layout.dart';
import 'video3d_preview_surface.dart';

/// 跨实例打开通道（与 `threeLoadOnOpen` / `videoLoadOnOpen` 同模式）：
/// [openVideo3dWorkspace] 写入项目名，工作台在 initState 消费后清空。
///
/// 空 = 不指定项目：工作台保持「打开列表首项」逻辑。
String? video3dLoadOnOpen;

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
  String _previewError = '';

  /// initState 从 [video3dLoadOnOpen] 取到的开局项目名（只消费一次）。
  String? _pendingOpen;

  @override
  void initState() {
    super.initState();
    // 跨视图打开：项目名由 [openVideo3dWorkspace] 一次性写入，空 = 列表首项。
    _pendingOpen = video3dLoadOnOpen;
    video3dLoadOnOpen = null;
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
    if (error.isNotEmpty) return;
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
    });
    Video3dProjectSnapshot snapshot;
    try {
      snapshot = await _projectStore.read(trimmed);
    } on Video3dProjectFailure catch (failure) {
      if (!mounted || _name != trimmed) return;
      setState(() {
        _opening = false;
        _failure = failure;
      });
      return;
    } catch (error) {
      if (!mounted || _name != trimmed) return;
      setState(() {
        _opening = false;
        _failure = Video3dProjectFailure('io_error', '$error');
      });
      return;
    }
    if (!mounted || _name != trimmed) return;
    _bindSnapshot(snapshot);
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
    setState(() {
      _snapshot = snapshot;
      _timeline = timeline;
      _preview = next;
      _previewError = previewError;
      _opening = false;
      _failure = null;
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
          kind: WorkbenchKind.video,
          width: constraints.maxWidth,
          height: constraints.maxHeight,
        );
        final bool hasLeft = layout.left == PanelPolicy.docked;
        final bool hasRight = layout.right == PanelPolicy.docked;
        final Widget body = Row(
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
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(p, layout),
            Expanded(child: body),
            if (layout.bottomBar)
              _Video3dBottomBar(
                height: layout.bottomBarHeight,
                snapshot: _snapshot,
                timeline: _timeline,
                preview: _preview,
                failure: _failure,
              ),
          ],
        );
      },
    );
  }

  Widget _header(NonPalette p, WorkbenchLayout layout) {
    final String title = _snapshot?.name ?? _name ?? '';
    final bool? verified = _snapshot?.verified;
    return Container(
      key: const ValueKey('video3d-header'),
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.movie_creation_outlined, size: 16, color: p.ink3),
          const SizedBox(width: 8),
          Text(
            '3D 视频工作台',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: p.ink,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              title.isEmpty ? '还没有打开的 3D 视频项目' : '只读预览 · $title',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: p.ink4),
            ),
          ),
          const Spacer(),
          if (verified != null)
            Text(
              verified ? '校验通过' : '校验未通过',
              key: const ValueKey('video3d-header-verify'),
              style: TextStyle(
                fontSize: 10,
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
                borderRadius: BorderRadius.circular(10),
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
                        fontSize: 12,
                        color: entry.corrupt ? p.warn : p.ink2,
                      ),
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.list_alt_outlined, size: 14, color: p.ink3),
                    const SizedBox(width: 4),
                    Text('项目', style: TextStyle(fontSize: 11, color: p.ink3)),
                  ],
                ),
              ),
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
      ),
    );
  }

  Widget _centerPane(NonPalette p) {
    if (_opening) {
      return Center(
        child: Text(
          '正在打开 3D 视频项目…',
          style: TextStyle(fontSize: 12, color: p.ink3),
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
            style: TextStyle(fontSize: 12, color: p.ink3),
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
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Video3dPreviewSurface(preview: preview),
    );
  }

  Widget _emptyPane(NonPalette p) {
    return Center(
      key: const ValueKey('video3d-empty'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.movie_creation_outlined, size: 30, color: p.ink4),
            const SizedBox(height: 10),
            Text(
              '还没有 3D 视频项目',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '左侧会列出本机的 3D 视频项目；选中后可以只读预览画面、镜头和检查器。'
              '这一批先做只读预览，新建入口在后续批次提供。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, height: 1.5, color: p.ink4),
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
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.movie_filter_outlined, size: 28, color: p.warn),
            const SizedBox(height: 8),
            Text(
              video3dProjectFailureMessage(failure),
              key: const ValueKey('video3d-project-failure-message'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.45, color: p.ink2),
            ),
            const SizedBox(height: 6),
            Text(
              '这个项目暂时打不开；左侧列表里还留着它。修好文件后可以重新读取。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, height: 1.5, color: p.ink4),
            ),
            const SizedBox(height: 10),
            _reloadButton(p),
            if (failure.technical.isNotEmpty)
              _technicalPane(p, '技术详情', failure.technical),
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
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.rule_folder_outlined, size: 28, color: p.warn),
            const SizedBox(height: 8),
            Text(
              '这个项目没有通过校验，暂时不能预览',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '场景或镜头文件还有 ${issues.length} 个问题；修好后重新读取就能预览。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, height: 1.5, color: p.ink4),
            ),
            const SizedBox(height: 10),
            for (final Video3dIssue issue in issues.take(4))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '· ${issue.message}',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, height: 1.4, color: p.ink3),
                ),
              ),
            if (issues.length > 4)
              Text(
                '还有 ${issues.length - 4} 个问题',
                style: TextStyle(fontSize: 10, color: p.ink4),
              ),
            const SizedBox(height: 10),
            _reloadButton(p),
            _technicalPane(p, '技术详情（问题位置）', detail),
          ],
        ),
      ),
    );
  }

  Widget _messagePane(NonPalette p, IconData icon, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 28, color: p.ink4),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: p.ink2),
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
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      icon: const Icon(Icons.refresh, size: 15),
      label: const Text('重新读取', style: TextStyle(fontSize: 11)),
    );
  }

  Widget _technicalPane(NonPalette p, String title, String detail) {
    if (detail.isEmpty) return const SizedBox.shrink();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          key: const ValueKey('video3d-technical-details'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          dense: true,
          title: Text(title, style: TextStyle(fontSize: 11, color: p.ink4)),
          iconColor: p.ink4,
          collapsedIconColor: p.ink4,
          children: <Widget>[
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                detail,
                style: TextStyle(fontSize: 10.5, color: p.ink4, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
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
  });

  final List<Video3dProjectEntry> entries;
  final String? selectedName;
  final bool loading;
  final String error;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    return Container(
      key: const ValueKey('video3d-project-list'),
      color: p.bgElevated.withValues(alpha: 0.9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 10, 7),
            child: Row(
              children: <Widget>[
                Icon(Icons.movie_creation_outlined, size: 13, color: p.ink4),
                const SizedBox(width: 6),
                Text(
                  '3D 视频项目',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
                const Spacer(),
                if (loading)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.4),
                  )
                else
                  Text(
                    '${entries.length}',
                    style: TextStyle(
                      fontSize: 10,
                      fontFamily: 'Menlo',
                      color: p.ink4,
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: p.line),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                error,
                style: TextStyle(fontSize: 11, color: p.warn, height: 1.4),
              ),
            )
          else if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '还没有 3D 视频项目。\n项目文件出现在这里后，选中即可只读预览。',
                style: TextStyle(fontSize: 11, height: 1.5, color: p.ink4),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
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
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.movie_creation_outlined,
              size: 12,
              color: selected ? p.accent : p.ink4,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: selected ? p.ink : p.ink2,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.5,
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
    final int issueCount = snapshot?.verification.checks.length ?? 0;
    return Container(
      key: const ValueKey('video3d-inspector'),
      color: p.bgElevated.withValues(alpha: 0.9),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.fact_check_outlined, size: 13, color: p.ink4),
                const SizedBox(width: 6),
                Text(
                  '只读检查器',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              snapshot == null ? '选中项目后显示场景与镜头摘要' : snapshot.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: p.ink4),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: p.line),
            const SizedBox(height: 6),
            if (failure != null)
              Text(
                video3dProjectFailureMessage(failure),
                style: TextStyle(fontSize: 11, height: 1.4, color: p.warn),
              )
            else if (snapshot == null)
              Text('还没有打开的项目', style: TextStyle(fontSize: 11, color: p.ink4))
            else ...<Widget>[
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
              const SizedBox(height: 8),
              Divider(height: 1, color: p.line),
              const SizedBox(height: 8),
              Text(
                snapshot.verified
                    ? '本批只读：预览、检查器和镜头时间线都不改项目文件。'
                    : '修好场景或镜头文件后点顶栏刷新，就能重新预览。',
                style: TextStyle(fontSize: 10, height: 1.5, color: p.ink4),
              ),
              if (!snapshot.verified && issueCount > 0) ...<Widget>[
                const SizedBox(height: 8),
                for (final Video3dIssue issue
                    in snapshot.verification.checks.take(6))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '· ${issue.message}',
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.35,
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
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          Text(label, style: TextStyle(fontSize: 11, color: p.ink4)),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 11,
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
    required this.preview,
    required this.failure,
  });

  final double height;
  final Video3dProjectSnapshot? snapshot;
  final Video3dTimeline? timeline;
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
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
            child: Row(
              children: <Widget>[
                Icon(Icons.linear_scale, size: 12, color: p.ink4),
                const SizedBox(width: 6),
                Text(
                  '镜头时间线',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: p.ink3,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  shotCount > 0 ? '$shotCount 个镜头 · 只读' : '只读',
                  style: TextStyle(fontSize: 9.5, color: p.ink4),
                ),
                const Spacer(),
                if (timeline != null && timeline.totalFrames > 0)
                  Text(
                    '${timeline.totalFrames} 帧 · ${timeline.durationSeconds.toStringAsFixed(1)} 秒',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontFamily: 'Menlo',
                      color: p.ink4,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: SizedBox(height: 30, child: _timeline(p, timeline, preview)),
          ),
          const SizedBox(height: 3),
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

  /// 镜头条：按 [video3dShotFractions] 的帧表比例分段，播放头只读显示。
  Widget _timeline(
    NonPalette p,
    Video3dTimeline? timeline,
    Video3dPreviewController? preview,
  ) {
    if (timeline == null ||
        timeline.totalFrames <= 0 ||
        timeline.shots.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '没有可预览的镜头时间线',
          style: TextStyle(fontSize: 10, color: p.ink4),
        ),
      );
    }
    final List<double> fractions = video3dShotFractions(timeline);
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
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          timeline.shots[i].id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 9, color: p.ink3),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
          const SizedBox(width: 4),
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
          const SizedBox(width: 8),
          Text(
            enabled
                ? '${formatVideo3dClock(frameSeconds)} / '
                      '${formatVideo3dClock(duration)}'
                : '—',
            key: const ValueKey('video3d-transport-time'),
            maxLines: 1,
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'Menlo',
              color: p.ink4,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              fps > 0 && totalFrames > 0
                  ? '$fps fps · $totalFrames 帧'
                  : '没有可播放的画面',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 10, color: p.ink4),
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
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            reason ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: p.ink3),
          ),
        ),
      ],
    );
  }
}
