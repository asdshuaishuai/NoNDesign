/// 音乐工作台的内容区专属面板：项目列表、轨道列表、只读谱面预览、可编辑检查器、运输条。
///
/// 2026-11-24 工作台独立适配（UI-4 首批）：音乐是**谱面优先**的工作台，左侧项目/
/// 轨道、中部谱面、右侧检查器、底部运输条；共享外壳仍由外层提供。
/// 本批：谱面只读；检查器提供最小编辑面（标题/速度、小节加删、四分音符/休止、
/// 轨道音量/静音），编辑动作交给工作台保存；**播放能力已接线**（演奏页 + 底部
/// 运输条播放/暂停/停止 + 播放头），但运输条只读播放控制器，不碰 `score.json`。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/music/music_compile.dart';
import '../core/music/music_edit.dart';
import '../core/music/music_project.dart';
import '../core/music/music_score.dart';
import '../core/theme.dart';
import 'music_playback_surface.dart';

/// 左侧项目列表（音乐项目库）。
class MusicProjectList extends StatelessWidget {
  const MusicProjectList({
    super.key,
    required this.entries,
    this.selectedName,
    required this.onOpen,
    this.loading = false,
    this.error = '',
  });

  final List<MusicProjectEntry> entries;
  final String? selectedName;
  final ValueChanged<String> onOpen;
  final bool loading;
  final String error;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('music-project-list'),
      color: p.bgElevated.withValues(alpha: 0.9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 10, 7),
            child: Row(
              children: <Widget>[
                Icon(Icons.library_music_outlined, size: 13, color: p.ink4),
                const SizedBox(width: 6),
                Text(
                  '音乐项目',
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
                '还没有音乐项目。\n让 NaN 在工作区里写一份乐谱，或在后续批次新建。',
                style: TextStyle(fontSize: 11, height: 1.5, color: p.ink4),
              ),
            )
          else
            for (final entry in entries)
              InkWell(
                key: ValueKey('music-project-${entry.name}'),
                onTap: () => onOpen(entry.name),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.audiotrack_outlined,
                        size: 12,
                        color: entry.name == selectedName ? p.accent : p.ink4,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          entry.title.isEmpty ? entry.name : entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: entry.name == selectedName ? p.ink : p.ink2,
                            fontWeight: entry.name == selectedName
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (entry.corrupt)
                        Icon(Icons.error_outline, size: 12, color: p.warn)
                      else if (!entry.verified)
                        Icon(Icons.rule, size: 12, color: p.ink4),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// 轨道列表（选中轨道联动检查器/谱面强调）。
class MusicTrackList extends StatelessWidget {
  const MusicTrackList({
    super.key,
    required this.tracks,
    this.selectedIndex = 0,
    required this.onSelect,
  });

  final List<MusicTrack> tracks;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('music-track-list'),
      color: p.bgElevated.withValues(alpha: 0.9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 10, 7),
            child: Row(
              children: <Widget>[
                Icon(Icons.queue_music, size: 13, color: p.ink4),
                const SizedBox(width: 6),
                Text(
                  '轨道',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
                const Spacer(),
                Text(
                  '${tracks.length}',
                  style: TextStyle(fontSize: 10, color: p.ink4),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: p.line),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: tracks.length,
              itemBuilder: (context, index) {
                final track = tracks[index];
                final active = index == selectedIndex;
                return InkWell(
                  key: ValueKey('music-track-${track.id}'),
                  onTap: () => onSelect(index),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.graphic_eq,
                          size: 12,
                          color: active ? p.accent : p.ink4,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            track.name.isEmpty ? track.id : track.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: active ? p.ink : p.ink2,
                              fontWeight: active
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        Text(
                          track.instrument,
                          style: TextStyle(fontSize: 9, color: p.ink4),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 只读谱面预览（钢琴卷帘式；五线谱排版在编辑器批次）。
class MusicPianoRoll extends StatelessWidget {
  const MusicPianoRoll({
    super.key,
    required this.score,
    this.playPlan,
    this.selectedTrack = 0,
  });

  final MusicScore score;
  final MusicPlayPlan? playPlan;
  final int selectedTrack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('music-piano-roll'),
      decoration: BoxDecoration(
        color: p.panel2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: <Widget>[
                Text(
                  score.title.isEmpty ? '未命名乐谱' : score.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: p.ink,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${score.tempo} BPM · ${score.timeSig.join('/')} · ${score.keySig}',
                  style: TextStyle(fontSize: 10, color: p.ink4),
                ),
                const Spacer(),
                Text(
                  '只读谱面预览（钢琴卷帘）',
                  style: TextStyle(fontSize: 10, color: p.ink4),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: p.line),
          Expanded(
            child: playPlan == null
                ? Center(
                    child: Text(
                      '乐谱还没有编译成播放计划，先通过校验器。',
                      style: TextStyle(fontSize: 11, color: p.ink4),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(10),
                    child: CustomPaint(
                      painter: _PianoRollPainter(
                        score: score,
                        playPlan: playPlan,
                        selectedTrack: selectedTrack,
                        palette: p,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PianoRollPainter extends CustomPainter {
  _PianoRollPainter({
    required this.score,
    required this.playPlan,
    required this.selectedTrack,
    required this.palette,
  });

  final MusicScore score;
  final MusicPlayPlan? playPlan;
  final int selectedTrack;
  final NonPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final int totalTicks = playPlan!.totalTicks;
    if (totalTicks <= 0 || size.width <= 0 || size.height <= 0) return;
    final double rowHeight = size.height / math.max(1, score.tracks.length);
    final Paint grid = Paint()..color = palette.line.withValues(alpha: 0.6);
    final Paint bar = Paint()..color = palette.accent;
    final Paint other = Paint()..color = palette.ink4.withValues(alpha: 0.35);
    for (int i = 0; i < score.tracks.length; i++) {
      final double top = i * rowHeight;
      canvas.drawLine(Offset(0, top), Offset(size.width, top), grid);
      final bool active = i == selectedTrack;
      final List<MusicPlayEvent> events = _eventsOf(
        score.tracks[i].id,
        playPlan!,
      );
      for (final event in events) {
        if (event.isRest) continue;
        final int start = event.startTick;
        final int dur = event.durationTicks;
        final double left = start / totalTicks * size.width;
        final double width = (dur / totalTicks * size.width).clamp(
          2.0,
          size.width - left,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              left + 1,
              top + rowHeight * 0.22,
              width - 2,
              rowHeight * 0.56,
            ),
            const Radius.circular(3),
          ),
          active ? bar : other,
        );
      }
    }
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      grid,
    );
  }

  static List<MusicPlayEvent> _eventsOf(String trackId, MusicPlayPlan plan) {
    return <MusicPlayEvent>[
      for (final event in plan.events)
        if (event.trackId == trackId) event,
    ];
  }

  @override
  bool shouldRepaint(covariant _PianoRollPainter old) =>
      old.selectedTrack != selectedTrack ||
      !identical(old.score, score) ||
      old.palette != palette;
}

/// 一次编辑动作：接收当前乐谱，返回修改后的乐谱；保存/刷新/报错由工作台负责。
typedef MusicEditAction = MusicScore Function(MusicScore score);

/// 工作台回传的保存/校验结果（检查器只如实显示，不伪造「已保存」）。
class MusicInspectorStatus {
  const MusicInspectorStatus({
    required this.message,
    this.isError = false,
    this.validation,
  });

  final String message;
  final bool isError;
  final MusicValidation? validation;
}

/// 右侧检查器：乐谱元数据 + 最小编辑面 + 校验结果 + 选中轨道。
///
/// 编辑动作通过 [onApply] 交给工作台执行（`MusicProjectStore.save`、刷新 snapshot
/// 与失败提示都在工作台）；[onApply] 为 null 时检查器保持只读。
class MusicInspector extends StatefulWidget {
  const MusicInspector({
    super.key,
    required this.snapshot,
    this.selectedTrack = 0,
    this.status,
    this.onApply,
  });

  final MusicProjectSnapshot? snapshot;
  final int selectedTrack;
  final MusicInspectorStatus? status;
  final Future<void> Function(MusicEditAction action, String successMessage)?
  onApply;

  @override
  State<MusicInspector> createState() => _MusicInspectorState();
}

class _MusicInspectorState extends State<MusicInspector> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _tempoCtrl;
  double? _volumeDraft;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _tempoCtrl = TextEditingController();
    _syncFrom(widget.snapshot);
  }

  @override
  void didUpdateWidget(covariant MusicInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.snapshot, widget.snapshot) ||
        oldWidget.selectedTrack != widget.selectedTrack) {
      _volumeDraft = null;
      _syncFrom(widget.snapshot, previous: oldWidget.snapshot);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _tempoCtrl.dispose();
    super.dispose();
  }

  /// 保存/刷新后用新 snapshot 回填输入框；不覆盖用户还没保存的手输内容。
  void _syncFrom(
    MusicProjectSnapshot? snapshot, {
    MusicProjectSnapshot? previous,
  }) {
    final MusicScore? score = snapshot?.score;
    if (score == null) return;
    final MusicScore? oldScore = previous?.score;
    final bool projectChanged =
        previous == null || previous.name != snapshot!.name;
    if (projectChanged || oldScore == null || oldScore.title != score.title) {
      _titleCtrl.text = score.title;
    }
    if (projectChanged || oldScore == null || oldScore.tempo != score.tempo) {
      _tempoCtrl.text = '${score.tempo}';
    }
  }

  void _saveMetadata() {
    final Future<void> Function(MusicEditAction, String)? onApply =
        widget.onApply;
    if (onApply == null) return;
    final String title = _titleCtrl.text;
    final String tempoText = _tempoCtrl.text.trim();
    onApply((MusicScore score) {
      final int? tempo = int.tryParse(tempoText);
      if (tempo == null) {
        throw const MusicEditFailure('invalid_tempo', '速度要填 20–300 的整数。');
      }
      return editScoreTempo(editScoreTitle(score, title), tempo);
    }, '标题与速度已保存');
  }

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    final MusicProjectSnapshot? snapshot = widget.snapshot;
    final MusicScore? score = snapshot?.score;
    final MusicTrack? track = score != null && score.tracks.isNotEmpty
        ? score.tracks[widget.selectedTrack.clamp(0, score.tracks.length - 1)]
        : null;
    final MusicValidation? validation =
        widget.status?.validation ?? snapshot?.validation;
    final bool editable = widget.onApply != null && score != null;
    return Container(
      key: const ValueKey('music-inspector'),
      color: p.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 8),
            child: Row(
              children: <Widget>[
                Icon(Icons.tune, size: 13, color: p.ink4),
                const SizedBox(width: 6),
                Text(
                  '乐谱检查器',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
                const Spacer(),
                Text(
                  editable ? '可编辑' : '只读',
                  style: TextStyle(fontSize: 9, color: p.ink4),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: p.line),
          Expanded(
            child: score == null
                ? Center(
                    child: Text(
                      '还没有打开的乐谱',
                      style: TextStyle(fontSize: 11, color: p.ink4),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (snapshot != null) _kv(p, '项目', snapshot.name),
                        _titleField(p, editable),
                        const SizedBox(height: 8),
                        _tempoRow(p, editable),
                        _kv(p, '拍号', score.timeSig.join('/')),
                        _kv(p, '调号', score.keySig),
                        _kv(p, '轨道', '${score.tracks.length}'),
                        _kv(p, '小节', '${score.measureCount}'),
                        if (track != null) ...<Widget>[
                          const SizedBox(height: 10),
                          _sectionLabel(p, '选中轨道'),
                          _kv(
                            p,
                            '名称',
                            track.name.isEmpty ? track.id : track.name,
                          ),
                          _kv(p, '乐器', track.instrument),
                          _kv(p, '谱号', track.clef),
                          _volumeRow(p, track, editable),
                          _muteRow(p, track, editable),
                          const SizedBox(height: 8),
                          _actionButtons(track, editable),
                        ],
                        const SizedBox(height: 10),
                        if (widget.status != null)
                          _statusBox(p, widget.status!),
                        _VerificationBadge(validation: validation),
                        if (validation != null &&
                            validation.blockingIssues.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 8),
                          for (final MusicIssue issue
                              in validation.blockingIssues)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '· ${issue.message}',
                                style: TextStyle(
                                  fontSize: 10,
                                  height: 1.4,
                                  color: p.warn,
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _titleField(NonPalette p, bool editable) => TextField(
    key: const ValueKey('music-title-field'),
    controller: _titleCtrl,
    enabled: editable,
    maxLength: musicMaxTitleLength,
    style: TextStyle(fontSize: 11, color: p.ink2),
    decoration: InputDecoration(
      labelText: '标题',
      isDense: true,
      counterText: '',
      labelStyle: TextStyle(fontSize: 10, color: p.ink4),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    ),
  );

  Widget _tempoRow(NonPalette p, bool editable) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Expanded(
        child: TextField(
          key: const ValueKey('music-tempo-field'),
          controller: _tempoCtrl,
          enabled: editable,
          keyboardType: TextInputType.number,
          style: TextStyle(fontSize: 11, color: p.ink2),
          decoration: InputDecoration(
            labelText: '速度 (BPM)',
            isDense: true,
            labelStyle: TextStyle(fontSize: 10, color: p.ink4),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 6,
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      FilledButton(
        key: const ValueKey('music-save'),
        onPressed: editable ? _saveMetadata : null,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          visualDensity: VisualDensity.compact,
        ),
        child: const Text('保存', style: TextStyle(fontSize: 11)),
      ),
    ],
  );

  Widget _volumeRow(NonPalette p, MusicTrack track, bool editable) {
    final double value = (_volumeDraft ?? track.volume)
        .clamp(0.0, 1.0)
        .toDouble();
    final Future<void> Function(MusicEditAction, String)? onApply =
        widget.onApply;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 58,
          child: Text('音量', style: TextStyle(fontSize: 10, color: p.ink4)),
        ),
        Expanded(
          child: Slider(
            key: const ValueKey('music-track-volume'),
            value: value,
            min: 0,
            max: 1,
            divisions: 20,
            onChanged: editable
                ? (double next) => setState(() => _volumeDraft = next)
                : null,
            onChangeEnd: editable && onApply != null
                ? (double next) async {
                    await onApply(
                      (MusicScore score) =>
                          editTrackVolume(score, track.id, next),
                      '轨道音量已保存',
                    );
                    if (mounted) setState(() => _volumeDraft = null);
                  }
                : null,
          ),
        ),
        SizedBox(
          width: 32,
          child: Text(
            value.toStringAsFixed(2),
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 10, color: p.ink3),
          ),
        ),
      ],
    );
  }

  Widget _muteRow(NonPalette p, MusicTrack track, bool editable) {
    final Future<void> Function(MusicEditAction, String)? onApply =
        widget.onApply;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 58,
          child: Text('静音', style: TextStyle(fontSize: 10, color: p.ink4)),
        ),
        Text(
          track.muted ? '已静音' : '未静音',
          style: TextStyle(fontSize: 11, color: track.muted ? p.warn : p.ink2),
        ),
        const Spacer(),
        IconButton(
          key: const ValueKey('music-track-mute'),
          tooltip: track.muted ? '取消这条轨道的静音' : '静音这条轨道',
          onPressed: editable && onApply != null
              ? () => onApply(
                  (MusicScore score) =>
                      editTrackMuted(score, track.id, !track.muted),
                  '轨道静音状态已保存',
                )
              : null,
          iconSize: 15,
          visualDensity: VisualDensity.compact,
          icon: Icon(
            track.muted ? Icons.volume_off : Icons.volume_up,
            color: track.muted ? p.warn : p.ink3,
          ),
        ),
      ],
    );
  }

  Widget _actionButtons(MusicTrack track, bool editable) {
    final Future<void> Function(MusicEditAction, String)? onApply =
        widget.onApply;
    if (!editable || onApply == null) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        _actionButton(
          key: 'music-append-measure',
          label: '追加空小节',
          action: (MusicScore score) => appendEmptyMeasure(score, track.id),
          successMessage: '已追加空小节',
        ),
        _actionButton(
          key: 'music-remove-measure',
          label: '删除空小节',
          action: (MusicScore score) => removeLastEmptyMeasure(score, track.id),
          successMessage: '已删除末尾空小节',
        ),
        _actionButton(
          key: 'music-append-quarter',
          label: '追加四分音符',
          action: (MusicScore score) => appendQuarterNote(score, track.id),
          successMessage: '已追加四分音符（C4）',
        ),
        _actionButton(
          key: 'music-append-rest',
          label: '追加四分休止',
          action: (MusicScore score) => appendQuarterRest(score, track.id),
          successMessage: '已追加四分休止',
        ),
      ],
    );
  }

  Widget _actionButton({
    required String key,
    required String label,
    required MusicEditAction action,
    required String successMessage,
  }) {
    final Future<void> Function(MusicEditAction, String)? onApply =
        widget.onApply;
    return OutlinedButton(
      key: ValueKey(key),
      onPressed: onApply == null ? null : () => onApply(action, successMessage),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(label, style: const TextStyle(fontSize: 11)),
    );
  }

  Widget _statusBox(NonPalette p, MusicInspectorStatus status) => Container(
    key: const ValueKey('music-edit-status'),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      color: status.isError ? p.warn.withValues(alpha: 0.12) : p.panel2,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(
        color: status.isError ? p.warn.withValues(alpha: 0.4) : p.line,
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(
          status.isError ? Icons.error_outline : Icons.check_circle_outline,
          size: 13,
          color: status.isError ? p.warn : p.success,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            status.message,
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              color: status.isError ? p.warn : p.ink2,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _sectionLabel(NonPalette p, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: p.ink2,
      ),
    ),
  );

  Widget _kv(NonPalette p, String key, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 58,
          child: Text(key, style: TextStyle(fontSize: 10, color: p.ink4)),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(fontSize: 11, color: p.ink2, height: 1.35),
          ),
        ),
      ],
    ),
  );
}

class _VerificationBadge extends StatelessWidget {
  const _VerificationBadge({required this.validation});

  final MusicValidation? validation;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final verified = validation?.verified ?? false;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: verified ? p.panel2 : p.warn.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: verified ? p.line : p.warn.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            verified ? Icons.check_circle_outline : Icons.error_outline,
            size: 13,
            color: verified ? p.success : p.warn,
          ),
          const SizedBox(width: 6),
          Text(
            verified ? '乐谱校验通过' : '乐谱校验未通过',
            style: TextStyle(fontSize: 11, color: verified ? p.ink2 : p.warn),
          ),
        ],
      ),
    );
  }
}

/// 底部运输条：播放/暂停/停止 + 播放头（进度、时间、拍位读数）。
///
/// 只读 [MusicPlaybackController]（生产是 WebView 演奏页，测试可注入 Fake），
/// 因此不构造真 WebView 也能测完播放控制；运输条**不碰** `score.json`，播放
/// 只是编译产物的执行面。
///
/// 不可播放时按钮禁用并给一句**如实**原因（没有播放计划 / 校验未通过 /
/// 演奏页还没就绪 / 乐谱没有可播放的音符），不假装可点。
class MusicTransportBar extends StatelessWidget {
  const MusicTransportBar({super.key, required this.snapshot, this.playback});

  final MusicProjectSnapshot? snapshot;

  /// 播放控制器；null = 当前没有可用的播放面（按钮全部禁用）。
  final MusicPlaybackController? playback;

  @override
  Widget build(BuildContext context) {
    final playback = this.playback;
    if (playback == null) return _bar(context, null);
    return ListenableBuilder(
      listenable: playback,
      builder: (BuildContext context, Widget? _) => _bar(context, playback),
    );
  }

  /// 为什么现在不能播；null = 可以播。
  String? _disabledReason(MusicPlaybackController? playback) {
    final snapshot = this.snapshot;
    if (snapshot == null) return '还没有打开的乐谱';
    if (snapshot.playPlan == null) {
      return '乐谱还没有编译出播放计划，先通过校验';
    }
    if (!snapshot.validation.verified) return '乐谱校验未通过，先修好再播放';
    if (playback == null) return '演奏页还没有准备好';
    final String error = playback.loadError;
    if (!playback.ready) {
      return error.isEmpty ? '演奏页准备中…' : error;
    }
    if (playback.duration <= 0) return '乐谱里还没有可播放的音符';
    return null;
  }

  Widget _bar(BuildContext context, MusicPlaybackController? playback) {
    final NonPalette p = context.palette;
    final MusicScore? score = snapshot?.score;
    final MusicPlayPlan? plan = snapshot?.playPlan;
    final String? reason = _disabledReason(playback);
    final bool enabled = reason == null;
    final double duration =
        playback?.duration ??
        (plan == null ? 0 : musicPlaybackDurationSeconds(plan));
    final double position = playback?.position ?? 0;
    final bool playing = playback?.playing ?? false;
    final double sliderMax = duration > 0 ? duration : 1;
    final double sliderValue = position
        .clamp(0.0, duration > 0 ? duration : 0.0)
        .toDouble();
    final int bar = playback?.bar ?? 0;
    final String meta = score == null
        ? '没有乐谱'
        : '${score.tempo} BPM · ${score.timeSig.join('/')} · ${score.keySig}'
              '${bar > 0 ? ' · 第 $bar 小节' : ''}';
    return Container(
      key: const ValueKey('music-transport'),
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const ValueKey('music-transport-play'),
            tooltip: '播放',
            onPressed: enabled && playback != null && !playing
                ? playback.play
                : null,
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: Icon(Icons.play_arrow, color: p.ink3),
          ),
          IconButton(
            key: const ValueKey('music-transport-pause'),
            tooltip: '暂停',
            onPressed: enabled && playback != null && playing
                ? playback.pause
                : null,
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: Icon(Icons.pause, color: p.ink3),
          ),
          IconButton(
            key: const ValueKey('music-transport-stop'),
            tooltip: '停止',
            onPressed: enabled && playback != null ? playback.stop : null,
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: Icon(Icons.stop, color: p.ink3),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: enabled
                ? SizedBox(
                    height: 30,
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
                        key: const ValueKey('music-transport-seek'),
                        value: sliderValue,
                        max: sliderMax,
                        activeColor: p.accent,
                        inactiveColor: p.line,
                        onChanged: playback == null
                            ? null
                            : (double value) => playback.seek(value),
                      ),
                    ),
                  )
                : _reasonText(p, reason),
          ),
          const SizedBox(width: 8),
          Text(
            enabled
                ? '${formatMusicPlaybackTime(position)} / '
                      '${formatMusicPlaybackTime(duration)}'
                : '—',
            key: const ValueKey('music-transport-time'),
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
              meta,
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
      key: const ValueKey('music-transport-reason'),
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
