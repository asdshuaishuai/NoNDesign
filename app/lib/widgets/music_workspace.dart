/// 音乐工作台（编曲）：谱面优先的独立内容布局。
///
/// 2026-11-24 工作台独立适配（UI-4）：左侧项目/轨道、中部谱面 + 演奏页、
/// 右侧检查器、底部运输条；共享外壳（TitleBar/Rail/右 chat/StatusBar）由外层提供。
/// 当前批次：五线谱点击插入音符（默认四分音符）与检查器最小编辑都走同一编辑
/// 出口；**播放面已接线**——有播放计划且校验
/// 通过时把 [assembleMusicPlayer] 的页面接到 [MusicPlaybackSurface]，底部运输条
/// 播放/暂停/停止 + 播放头；播放只读，绝不改 `score.json` 事实源。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/music/music_compile.dart';
import '../core/music/music_edit.dart';
import '../core/music/music_player.dart';
import '../core/music/music_project.dart';
import '../core/music/music_score.dart';
import '../core/music/music_staff_edit.dart';
import '../core/theme.dart';
import '../core/workbench_layout.dart';
import 'music_playback_surface.dart';
import 'music_staff_view.dart';
import 'music_workbench_panels.dart';

/// 跨实例打开通道（与 `threeLoadOnOpen` / `videoLoadOnOpen` 同模式）：
/// [openMusicWorkspace] 写入项目名，音乐工作台在 initState 消费后清空。
///
/// 空 = 不指定项目：工作台保持原有「打开列表首项」逻辑。
String? musicLoadOnOpen;

/// 已挂载工作台的切换请求：工作台视图已存在时 initState 不会再跑，
/// 顶栏「音乐」分区里再点另一个项目走这里直接切。
///
/// 每次请求都是新对象：同一个项目名重复点击也能触发监听（ValueNotifier
/// 对相等值不 notify）。
final ValueNotifier<MusicProjectSwitch?> musicProjectSwitch =
    ValueNotifier<MusicProjectSwitch?>(null);

/// [musicProjectSwitch] 的一次「切到某个音乐项目」请求。
final class MusicProjectSwitch {
  const MusicProjectSwitch(this.name);

  final String name;
}

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

  /// 中部谱面预览的本地视图选择：默认五线谱（只读），可切回钢琴卷帘。
  ///
  /// 只影响本实例的显示，不写设置/项目、不改变编辑与播放语义；切项目保留选择。
  bool _staffView = true;

  /// 当前播放面控制器；null = 没有可播放的编译产物（按钮禁用并说明原因）。
  MusicPlaybackController? _playback;

  /// 五线谱点击插入的串行闸：避免快速连点都用同一份旧 snapshot 覆盖彼此。
  ///
  /// 插入与删除共用同一把闸（同一时刻只允许一个谱面编辑在保存/重读链路上）。
  bool _staffTapBusy = false;

  /// 谱面当前选中的已有音符（点击符头选中；Delete/Backspace 删除后清空）。
  ///
  /// 选中只用于键盘删除与光圈提示，不写乐谱、不改播放面。
  ({int trackIndex, int measureIndex, String eventId})? _selectedEvent;

  /// 谱面键盘焦点（点谱面时主动索取，Delete/Backspace 才能落到谱面）。
  final FocusNode _staffFocus = FocusNode(debugLabel: 'music-staff-hit');

  /// initState 从 [musicLoadOnOpen] 取到的开局项目名（只消费一次）。
  String? _pendingOpen;

  @override
  void initState() {
    super.initState();
    // 跨视图打开：项目名由 [openMusicWorkspace] 一次性写入，空 = 走原有首项逻辑。
    _pendingOpen = musicLoadOnOpen;
    musicLoadOnOpen = null;
    musicProjectSwitch.addListener(_onSwitchRequest);
    _refresh();
  }

  /// 已挂载工作台的切项目请求（顶栏「音乐」分区 → 另一个项目）。
  void _onSwitchRequest() {
    final MusicProjectSwitch? request = musicProjectSwitch.value;
    if (!mounted || request == null || request.name.isEmpty) return;
    unawaited(_open(request.name));
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
    _pendingOpen = null; // 已经落到具体项目，开局通道到此消费完
    // 已挂载实例里切项目时，别把开局名留给下一次挂载（跨视图续接走
    // store.musicProjectName，不靠这个一次性通道）。
    musicLoadOnOpen = null;
    // 切项目先卸播放面：旧页不能继续对着新项目响。
    final MusicPlaybackController? previous = _playback;
    _playback = null;
    previous?.dispose();
    setState(() {
      _name = name;
      _failure = null;
      _status = null;
      _selectedTrack = 0;
      _selectedEvent = null;
      _staffTapBusy = false;
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
    musicProjectSwitch.removeListener(_onSwitchRequest);
    _staffFocus.dispose();
    _playback?.dispose();
    _playback = null;
    super.dispose();
  }

  /// 执行一次编辑：先改模型，再经 [MusicProjectStore.save] 落盘，读完新 snapshot
  /// 刷新工作台，并把 `save` 返回的校验结果如实回传给检查器。
  ///
  /// [onSaved] 只在「保存成功且已刷新 snapshot」后调用（失败分支绝不调用），
  /// 供调用方清理只属于本次编辑的临时状态（例如删除后的谱面选中项）。
  Future<void> _applyEdit(
    MusicEditAction action,
    String successMessage, {
    VoidCallback? onSaved,
  }) async {
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
    onSaved?.call();
  }

  void _setStatus(MusicInspectorStatus status) {
    if (!mounted) return;
    setState(() => _status = status);
  }

  /// 五线谱点击（task-16）：点已有音符 = 选中它（随后可用 Delete/Backspace 删除）；
  /// 点空白 = 在命中的**小节内拍位**插入音符（默认四分音符），再走 [_applyEdit]
  /// 的「改模型 → save → 重读 → 刷新」链路。
  ///
  /// 点哪一行就把选中轨道切到那一条（当前选中轨道 = 点击轨道）；视图只回调命中，
  /// 不改事实源。失败（如拍位已被音符占用）由 [_applyEdit] 显性显示，不伪造成功。
  void _onStaffNoteTap(MusicStaffHit hit) {
    final MusicProjectSnapshot? snapshot = _snapshot;
    if (snapshot == null) return;
    if (hit.trackIndex < 0 || hit.trackIndex >= snapshot.score.tracks.length) {
      return;
    }
    if (_staffTapBusy) return;
    // 点谱面即索取键盘焦点：选中后 Delete/Backspace 才能落到谱面。
    _staffFocus.requestFocus();
    if (_selectedTrack != hit.trackIndex) {
      setState(() => _selectedTrack = hit.trackIndex);
    }
    // 已有音符：只选中，不插入；删除走键盘出口（见 [_onStaffKey]）。
    final String? eventId = hit.eventId;
    if (eventId != null &&
        eventId.isNotEmpty &&
        hit.eventIndex != null &&
        hit.eventIndex! >= 0) {
      setState(() {
        _selectedEvent = (
          trackIndex: hit.trackIndex,
          measureIndex: hit.measureIndex,
          eventId: eventId,
        );
        _status = const MusicInspectorStatus(
          message: '已选中音符，按键盘 Delete 或 Backspace 删除。',
        );
      });
      return;
    }
    // 点空白 = 按拍位插入；拍面选中的旧音符先取消选中。
    if (_selectedEvent != null) setState(() => _selectedEvent = null);
    final MusicTrack track = snapshot.score.tracks[hit.trackIndex];
    final String? drum = track.instrument == 'drums' ? hit.drum : null;
    final String successMessage = musicStaffInsertAtMessage(
      beatIndex: hit.beatIndex,
      step: hit.step,
      alter: hit.alter,
      octave: hit.octave,
      drum: drum,
    );
    _staffTapBusy = true;
    unawaited(
      _applyEdit(
        (MusicScore score) => insertNoteAt(
          score,
          trackIndex: hit.trackIndex,
          measureIndex: hit.measureIndex,
          beatIndex: hit.beatIndex,
          step: hit.step,
          alter: hit.alter,
          octave: hit.octave,
          drum: drum,
        ),
        successMessage,
      ).whenComplete(() => _staffTapBusy = false),
    );
  }

  /// 谱面键盘出口：选中音符后 Delete/Backspace 删除。
  ///
  /// 忙（保存/重读链路未走完）时吞掉按键，避免同一次按键叠加多次删除；
  /// 没有选中音符时按键继续冒泡（返回 ignored），不抢其它快捷键。
  KeyEventResult _onStaffKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key != LogicalKeyboardKey.delete &&
        key != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    if (_selectedEvent == null) return KeyEventResult.ignored;
    if (_staffTapBusy) return KeyEventResult.handled;
    _deleteSelectedEvent();
    return KeyEventResult.handled;
  }

  /// 删除当前选中的音符：走同一编辑出口，成功后清空选中并显示「已删除音符」。
  ///
  /// 失败（如事件连着连线、事件已不存在）保留选中并显性提示，绝不静默改坏乐谱。
  void _deleteSelectedEvent() {
    final selected = _selectedEvent;
    if (selected == null || _staffTapBusy) return;
    _staffTapBusy = true;
    unawaited(
      _applyEdit(
        (MusicScore score) => deleteNoteAt(
          score,
          trackIndex: selected.trackIndex,
          measureIndex: selected.measureIndex,
          eventId: selected.eventId,
        ),
        musicStaffDeleteMessage(),
        onSaved: () {
          if (!mounted) return;
          setState(() => _selectedEvent = null);
        },
      ).whenComplete(() => _staffTapBusy = false),
    );
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
                    MusicTransportBar(
                      snapshot: _snapshot,
                      playback: _playback,
                      // 运输条高度来自音乐工作台规格（WorkbenchLayout）。
                      height: layout.bottomBarHeight,
                    ),
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
      padding: const EdgeInsets.symmetric(horizontal: NonSpace.md),
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.library_music_outlined, size: 16, color: p.ink3),
          const SizedBox(width: NonSpace.sm),
          Text(
            '音乐工作台',
            style: TextStyle(
              fontSize: NonType.bodyStrong,
              fontWeight: FontWeight.w600,
              color: p.ink,
            ),
          ),
          const SizedBox(width: NonSpace.md),
          Flexible(
            child: Text(
              title.isEmpty ? (_name ?? '还没有打开的乐谱') : '$title · $_name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: NonType.caption, color: p.ink4),
            ),
          ),
          const Spacer(),
          if (_snapshot?.validation.verified != true && _snapshot != null)
            Text(
              '校验未通过',
              style: TextStyle(fontSize: NonType.micro, color: p.warn),
            ),
          const SizedBox(width: NonSpace.sm),
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
        child: Text(
          '正在读取音乐项目…',
          style: TextStyle(fontSize: NonType.body, color: p.ink3),
        ),
      );
    }
    final failure = _failure;
    if (failure != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(NonSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.music_off_outlined, size: 28, color: p.warn),
              const SizedBox(height: NonSpace.sm),
              Text(
                musicProjectFailureMessage(failure),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: NonType.bodyStrong,
                  height: NonType.lineBody,
                  color: p.ink2,
                ),
              ),
              const SizedBox(height: NonSpace.sm),
              Text(
                failure.detail.isEmpty
                    ? failure.code
                    : '${failure.code}: ${failure.detail}',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: NonType.micro, color: p.ink4),
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
          padding: const EdgeInsets.all(NonSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.piano_outlined, size: 30, color: p.ink4),
              const SizedBox(height: NonSpace.md),
              Text(
                '还没有音乐项目',
                style: TextStyle(
                  fontSize: NonType.bodyStrong,
                  fontWeight: FontWeight.w600,
                  color: p.ink2,
                ),
              ),
              const SizedBox(height: NonSpace.sm),
              Text(
                '左侧会列出本机音乐项目；打开项目后可在右侧检查器做最小编辑。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: NonType.caption,
                  height: NonType.lineBody,
                  color: p.ink4,
                ),
              ),
            ],
          ),
        ),
      );
    }
    final MusicPlaybackController? playback = _playback;
    final Widget preview = _scorePreview(snapshot);
    if (playback == null) {
      return Padding(
        padding: const EdgeInsets.all(NonSpace.md),
        child: preview,
      );
    }
    // 谱面优先：谱面占大头，演奏页在下方给一块能看能点的画位；运输条在底部
    // 驱动同一份播放控制器（播放头 / 错误都经它回调刷新）。
    return Column(
      children: <Widget>[
        Expanded(
          flex: 3,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              NonSpace.md,
              NonSpace.md,
              NonSpace.md,
              NonSpace.sm,
            ),
            child: preview,
          ),
        ),
        Expanded(
          flex: 2,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              NonSpace.md,
              0,
              NonSpace.md,
              NonSpace.md,
            ),
            child: MusicPlaybackSurface(playback: playback),
          ),
        ),
      ],
    );
  }

  /// 中部谱面预览：本地切换「五线谱（默认，只读）/ 钢琴卷帘」。
  ///
  /// 切换只换显示，不改 snapshot、不重建播放面；两种视图都只读 `score.json`。
  Widget _scorePreview(MusicProjectSnapshot snapshot) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 视图切换条不再写死 34 高：按内容（图标+文字）取自然高度，
        // 窄屏/手机字号放大也不会把切换条挤爆。
        Padding(
          padding: const EdgeInsets.only(bottom: NonSpace.xs),
          child: Row(
            key: const ValueKey('music-view-toggle'),
            children: <Widget>[
              _MusicViewTab(
                key: const ValueKey('music-view-staff'),
                label: '五线谱',
                icon: Icons.music_note_outlined,
                selected: _staffView,
                onTap: () {
                  if (_staffView) return;
                  setState(() => _staffView = true);
                },
              ),
              const SizedBox(width: NonSpace.sm),
              _MusicViewTab(
                key: const ValueKey('music-view-roll'),
                label: '钢琴卷帘',
                icon: Icons.piano_outlined,
                selected: !_staffView,
                onTap: () {
                  if (!_staffView) return;
                  setState(() => _staffView = false);
                },
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  !_staffView
                      ? '只读卷帘 · 不写乐谱'
                      : _selectedEvent == null
                      ? '点击谱面按拍插入音符 · 默认四分音符'
                      : '已选中音符 · 按 Delete / Backspace 删除',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: NonType.micro, color: p.ink4),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _staffView
              ? Focus(
                  key: const ValueKey('music-staff-focus'),
                  focusNode: _staffFocus,
                  onKeyEvent: _onStaffKey,
                  child: MusicStaffView(
                    score: snapshot.score,
                    selectedTrackIndex: _selectedTrack,
                    selectedEventId: _selectedEvent?.eventId,
                    onNoteTap: _onStaffNoteTap,
                  ),
                )
              : MusicPianoRoll(
                  score: snapshot.score,
                  playPlan: snapshot.playPlan,
                  selectedTrack: _selectedTrack,
                ),
        ),
      ],
    );
  }
}

/// 中部谱面预览的本地切换按钮（五线谱 / 钢琴卷帘）。
class _MusicViewTab extends StatelessWidget {
  const _MusicViewTab({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(NonRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: NonSpace.sm,
          vertical: NonSpace.xs,
        ),
        decoration: BoxDecoration(
          color: selected ? p.accentSoft : null,
          borderRadius: BorderRadius.circular(NonRadius.sm),
          border: Border.all(
            color: selected ? p.accent.withValues(alpha: 0.5) : p.line,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 12, color: selected ? p.accent : p.ink4),
            const SizedBox(width: NonSpace.xs),
            Text(
              label,
              style: TextStyle(
                fontSize: NonType.caption,
                color: selected ? p.accent : p.ink3,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
