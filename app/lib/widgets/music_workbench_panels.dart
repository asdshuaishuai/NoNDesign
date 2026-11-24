/// 音乐工作台的内容区专属面板：项目列表、轨道列表、只读谱面预览、检查器、运输条。
///
/// 2026-11-24 工作台独立适配（UI-4 首批）：音乐是**谱面优先**的工作台，左侧项目/
/// 轨道、中部谱面、右侧检查器、底部运输条；共享外壳仍由外层提供。
/// 本批只读：不伪造播放按钮（Web Audio 播放页与编辑器在后续批次）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/music/music_compile.dart';
import '../core/music/music_project.dart';
import '../core/music/music_score.dart';
import '../core/theme.dart';

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

/// 右侧检查器：乐谱元数据 + 校验结果 + 选中轨道。
class MusicInspector extends StatelessWidget {
  const MusicInspector({
    super.key,
    required this.snapshot,
    this.selectedTrack = 0,
  });

  final MusicProjectSnapshot? snapshot;
  final int selectedTrack;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final snapshot = this.snapshot;
    final MusicScore? score = snapshot?.score;
    final MusicTrack? track = score != null && score.tracks.isNotEmpty
        ? score.tracks[selectedTrack.clamp(0, score.tracks.length - 1)]
        : null;
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
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _kv(p, '标题', score.title.isEmpty ? '未命名' : score.title),
                        _kv(p, '速度', '${score.tempo} BPM'),
                        _kv(p, '拍号', score.timeSig.join('/')),
                        _kv(p, '调号', score.keySig),
                        _kv(p, '轨道', '${score.tracks.length}'),
                        _kv(p, '小节', '${score.measureCount}'),
                        if (track != null) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            '选中轨道',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: p.ink2,
                            ),
                          ),
                          const SizedBox(height: 6),
                          _kv(
                            p,
                            '名称',
                            track.name.isEmpty ? track.id : track.name,
                          ),
                          _kv(p, '乐器', track.instrument),
                          _kv(p, '谱号', track.clef),
                          _kv(p, '音量', track.volume.toStringAsFixed(2)),
                        ],
                        const SizedBox(height: 10),
                        _VerificationBadge(validation: snapshot?.validation),
                        if (snapshot?.validation.blockingIssues.isNotEmpty ==
                            true) ...<Widget>[
                          const SizedBox(height: 8),
                          for (final issue
                              in snapshot!.validation.blockingIssues)
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

/// 底部运输条（只读：BPM/拍号/总拍数；播放引擎待批次，不放假按钮）。
class MusicTransportBar extends StatelessWidget {
  const MusicTransportBar({super.key, required this.snapshot});

  final MusicProjectSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final MusicScore? score = snapshot?.score;
    final MusicPlayPlan? plan = snapshot?.playPlan;
    final int totalTicks = plan?.totalTicks ?? 0;
    final int ppq = plan?.ppq ?? 3840;
    final int bpm = score?.tempo ?? 0;
    final double seconds = bpm > 0 && ppq > 0
        ? totalTicks * 60 / (bpm * ppq)
        : 0;
    return Container(
      key: const ValueKey('music-transport'),
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.queue_music, size: 14, color: p.ink4),
          const SizedBox(width: 8),
          Text(
            score == null
                ? '没有乐谱'
                : '${score.tempo} BPM · ${score.timeSig.join('/')} · ${score.keySig}',
            style: TextStyle(fontSize: 11, color: p.ink3),
          ),
          const Spacer(),
          Text(
            plan == null
                ? '—'
                : '${seconds.toStringAsFixed(2)}s · $totalTicks tick · ppq $ppq',
            key: const ValueKey('music-transport-time'),
            style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4),
          ),
          const SizedBox(width: 12),
          Text('播放引擎待批次', style: TextStyle(fontSize: 10, color: p.ink4)),
        ],
      ),
    );
  }
}
