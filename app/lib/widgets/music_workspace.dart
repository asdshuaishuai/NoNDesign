/// 音乐工作台（编曲）：谱面优先的独立内容布局。
///
/// 2026-11-24 工作台独立适配（UI-4）：左侧项目/轨道、中部谱面 + 演奏页、
/// 右侧检查器、底部运输条；共享外壳（TitleBar/Rail/右 chat/StatusBar）由外层提供。
/// 当前批次：谱面只读、检查器最小编辑；**播放面已接线**——有播放计划且校验
/// 通过时把 [assembleMusicPlayer] 的页面接到 [MusicPlaybackSurface]，底部运输条
/// 播放/暂停/停止 + 播放头；播放只读，绝不改 `score.json` 事实源。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/music/music_compile.dart';
import '../core/music/music_edit.dart';
import '../core/music/music_player.dart';
import '../core/music/music_project.dart';
import '../core/music/music_score.dart';
import '../core/theme.dart';
import '../core/workbench_layout.dart';
import 'music_playback_surface.dart';
import 'music_workbench_panels.dart';

class MusicWorkspace extends StatefulWidget {
  const MusicWorkspace({super.key, this.store, this.playbackFactory});

  /// 测试注入：指向临时目录的项目库；生产为 [MusicProjectStore.instance]。
  final MusicProjectStore? store;

  /// 测试注入：把播放面换成 Fake 控制器，避免构造真 WebView。
  ///
  /// 生产为 null，走 [createDefaultMusicPlayback]（`webview_all` + 播放页）。
  final MusicPlaybackController Function(MusicScore score, MusicPlayPlan plan)?
  playbackFactory;

  @override
  State<MusicWorkspace> createState() => _MusicWorkspaceState();
}

class _MusicWorkspaceState extends State<MusicWorkspace> {
  late final MusicProjectStore _store =
      widget.store ?? MusicProjectStore.instance;
  List<MusicProjectEntry> _entries = const <MusicProjectEntry>[];
  bool _loading = true;
  String _listError = '';
  String? _name;
  MusicProjectSnapshot? _snapshot;
  MusicProjectFailure? _failure;
  MusicInspectorStatus? _status;
  int _selectedTrack = 0;

  /// 当前播放面控制器；null = 没有可播放的编译产物（按钮禁用并说明原因）。
  MusicPlaybackController? _playback;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    List<MusicProjectEntry> entries;
    String error = '';
    try {
      entries = await _store.list();
    } catch (failure) {
      entries = const <MusicProjectEntry>[];
      error = '音乐项目暂时读不出来，请稍后重试。';
    }
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
      _listError = error;
    });
    if (error.isNotEmpty) return;
    if (_name == null && entries.isNotEmpty) {
      await _open(entries.first.name);
    }
  }

  Future<void> _open(String name) async {
    // 切项目先卸播放面：旧页不能继续对着新项目响。
    final MusicPlaybackController? previous = _playback;
    _playback = null;
    previous?.dispose();
    setState(() {
      _name = name;
      _failure = null;
      _status = null;
      _selectedTrack = 0;
    });
    try {
      final snapshot = await _store.read(name);
      if (!mounted || _name != name) return;
      _bindSnapshot(snapshot);
    } on MusicProjectFailure catch (failure) {
      if (!mounted || _name != name) return;
      setState(() {
        _snapshot = null;
        _failure = failure;
      });
    } catch (error) {
      if (!mounted || _name != name) return;
      setState(() {
        _snapshot = null;
        _failure = MusicProjectFailure('io_error', '$error');
      });
    }
  }

  /// 写入新 snapshot 并按它重建播放面。
  ///
  /// 有播放计划且校验通过才创建控制器；否则运输条禁用播放并如实说明原因。
  /// 播放只读编译产物，不改 `score.json`。
  void _bindSnapshot(MusicProjectSnapshot snapshot) {
    final MusicPlaybackController? next = _createPlayback(snapshot);
    final MusicPlaybackController? previous = _playback;
    setState(() {
      _snapshot = snapshot;
      _playback = next;
    });
    previous?.dispose();
    if (next != null) unawaited(next.start());
  }

  MusicPlaybackController? _createPlayback(MusicProjectSnapshot snapshot) {
    final MusicPlayPlan? plan = snapshot.playPlan;
    if (plan == null || !snapshot.validation.verified) return null;
    final factory = widget.playbackFactory ?? createDefaultMusicPlayback;
    return factory(snapshot.score, plan);
  }

  @override
  void dispose() {
    _playback?.dispose();
    _playback = null;
    super.dispose();
  }

  /// 执行一次编辑：先改模型，再经 [MusicProjectStore.save] 落盘，读完新 snapshot
  /// 刷新工作台，并把 `save` 返回的校验结果如实回传给检查器。
  Future<void> _applyEdit(MusicEditAction action, String successMessage) async {
    final String? name = _name;
    final MusicProjectSnapshot? snapshot = _snapshot;
    if (name == null || snapshot == null) return;
    MusicScore next;
    try {
      next = action(snapshot.score);
    } on MusicEditFailure catch (failure) {
      _setStatus(MusicInspectorStatus(message: failure.message, isError: true));
      return;
    } catch (_) {
      _setStatus(
        const MusicInspectorStatus(message: '这次修改没有生效，请再试一次。', isError: true),
      );
      return;
    }
    MusicValidation validation;
    try {
      validation = await _store.save(name, next);
    } on MusicProjectFailure catch (failure) {
      _setStatus(
        MusicInspectorStatus(
          message: musicProjectFailureMessage(failure),
          isError: true,
        ),
      );
      return;
    } catch (_) {
      _setStatus(
        const MusicInspectorStatus(message: '乐谱没能保存，请稍后再试。', isError: true),
      );
      return;
    }
    MusicProjectSnapshot fresh;
    try {
      fresh = await _store.read(name);
    } on MusicProjectFailure catch (failure) {
      _setStatus(
        MusicInspectorStatus(
          message: musicProjectFailureMessage(failure),
          isError: true,
        ),
      );
      return;
    } catch (_) {
      _setStatus(
        const MusicInspectorStatus(message: '保存后没能刷新乐谱，请点刷新重试。', isError: true),
      );
      return;
    }
    List<MusicProjectEntry> entries = _entries;
    try {
      entries = await _store.list();
    } catch (_) {
      entries = _entries;
    }
    if (!mounted || _name != name) return;
    // 保存后按新编译产物重建播放面（旧页对应旧乐谱，必须换掉）。
    final MusicPlaybackController? nextPlayback = _createPlayback(fresh);
    final MusicPlaybackController? previousPlayback = _playback;
    setState(() {
      _entries = entries;
      _snapshot = fresh;
      _failure = null;
      _playback = nextPlayback;
      _status = MusicInspectorStatus(
        message: validation.verified
            ? '$successMessage · 乐谱校验通过'
            : '$successMessage，但乐谱校验未通过',
        isError: !validation.verified,
        validation: validation,
      );
    });
    previousPlayback?.dispose();
    if (nextPlayback != null) unawaited(nextPlayback.start());
  }

  void _setStatus(MusicInspectorStatus status) {
    if (!mounted) return;
    setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      children: <Widget>[
        _header(context, p),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final layout = resolveWorkbenchLayout(
                kind: WorkbenchKind.music,
                width: constraints.maxWidth,
                height: constraints.maxHeight,
              );
              final MusicScore? score = _snapshot?.score;
              final bool hasLeft = layout.left == PanelPolicy.docked;
              final bool hasRight = layout.right == PanelPolicy.docked;
              final Widget center = _centerPane(context, p);
              final Widget body = Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (hasLeft)
                    SizedBox(
                      width: layout.leftWidth,
                      child: Column(
                        children: <Widget>[
                          MusicProjectList(
                            entries: _entries,
                            selectedName: _name,
                            onOpen: _open,
                            loading: _loading,
                            error: _listError,
                          ),
                          if (score != null) ...<Widget>[
                            Container(height: 1, color: p.line),
                            Expanded(
                              child: MusicTrackList(
                                tracks: score.tracks,
                                selectedIndex: _selectedTrack,
                                onSelect: (index) =>
                                    setState(() => _selectedTrack = index),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (hasLeft) Container(width: 1, color: p.line),
                  Expanded(child: center),
                  if (hasRight) Container(width: 1, color: p.line),
                  if (hasRight)
                    SizedBox(
                      width: layout.rightWidth,
                      child: MusicInspector(
                        snapshot: _snapshot,
                        selectedTrack: _selectedTrack,
                        status: _status,
                        onApply: _applyEdit,
                      ),
                    ),
                ],
              );
              return Column(
                children: <Widget>[
                  Expanded(child: body),
                  if (layout.bottomBar)
                    MusicTransportBar(snapshot: _snapshot, playback: _playback),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, NonPalette p) {
    final title = _snapshot?.score.title.trim() ?? '';
    return Container(
      key: const ValueKey('music-header'),
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.library_music_outlined, size: 16, color: p.ink3),
          const SizedBox(width: 8),
          Text(
            '音乐工作台',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: p.ink,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              title.isEmpty ? (_name ?? '还没有打开的乐谱') : '$title · $_name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: p.ink4),
            ),
          ),
          const Spacer(),
          if (_snapshot?.validation.verified != true && _snapshot != null)
            Text('校验未通过', style: TextStyle(fontSize: 10, color: p.warn)),
          const SizedBox(width: 8),
          IconButton(
            key: const ValueKey('music-refresh'),
            tooltip: '刷新音乐项目',
            onPressed: _loading ? null : _refresh,
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.refresh, color: p.ink3),
          ),
        ],
      ),
    );
  }

  Widget _centerPane(BuildContext context, NonPalette p) {
    if (_loading && _snapshot == null) {
      return Center(
        child: Text('正在读取音乐项目…', style: TextStyle(fontSize: 12, color: p.ink3)),
      );
    }
    final failure = _failure;
    if (failure != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.music_off_outlined, size: 28, color: p.warn),
              const SizedBox(height: 8),
              Text(
                musicProjectFailureMessage(failure),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.45, color: p.ink2),
              ),
              const SizedBox(height: 6),
              Text(
                failure.detail.isEmpty
                    ? failure.code
                    : '${failure.code}: ${failure.detail}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: p.ink4),
              ),
            ],
          ),
        ),
      );
    }
    final snapshot = _snapshot;
    if (snapshot == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.piano_outlined, size: 30, color: p.ink4),
              const SizedBox(height: 10),
              Text(
                '还没有音乐项目',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '左侧会列出本机音乐项目；打开项目后可在右侧检查器做最小编辑。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, height: 1.5, color: p.ink4),
              ),
            ],
          ),
        ),
      );
    }
    final MusicPlaybackController? playback = _playback;
    if (playback == null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: MusicPianoRoll(
          score: snapshot.score,
          playPlan: snapshot.playPlan,
          selectedTrack: _selectedTrack,
        ),
      );
    }
    // 谱面优先：谱面占大头，演奏页在下方给一块能看能点的画位；运输条在底部
    // 驱动同一份播放控制器（播放头 / 错误都经它回调刷新）。
    return Column(
      children: <Widget>[
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: MusicPianoRoll(
              score: snapshot.score,
              playPlan: snapshot.playPlan,
              selectedTrack: _selectedTrack,
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: MusicPlaybackSurface(playback: playback),
          ),
        ),
      ],
    );
  }
}
