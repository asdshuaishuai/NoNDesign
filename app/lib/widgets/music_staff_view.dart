/// 音乐五线谱视图 + 确定性排版/命中测试纯函数（task-11 / task-14）。
///
/// 本文件三层：
/// * [musicStaffLayout]：把 [MusicScore] 换算成可断言的几何模型（行 rows →
///   小节 columns → 音符 notes）。纯函数——不写事实源、不读时钟、不用随机源；
///   同一输入两次调用结果 `==`，`toJsonString()` 字节相同。
/// * [staffHitTest]：把可视坐标（含缩放）换算回排版坐标，命中某行/小节/五线位置
///   → [MusicStaffHit]（位置 + 换算音高/鼓件）。纯函数，越界/空白安全返回 null。
/// * [MusicStaffView]：只消费上面布局的 `CustomPainter`（五线、谱号、符头/符干/
///   符尾、附点、小节线、拍号/调号文本、连音线占位），支持 50–150% 缩放与水平
///   滚动。默认只读：**不伪造播放头**，也不接收播放控制器；播放语义仍归
///   `MusicPianoRoll` + `MusicPlaybackSurface`。传入 [MusicStaffView.onNoteTap] 时
///   点击谱面只回调命中结果，视图本身仍不写事实源（落盘/校验由工作台经编辑出口做）。
///
/// 语义边界：布局/命中只做「记谱坐标 ↔ 画布几何」的确定性换算，不改音高/时值/关系。
/// 空轨道、空小节（整小节休止）、非法轨道索引、极端宽度都按空安全退化，不抛异常。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/music/music_score.dart';
import '../core/theme.dart';

// ---------------------------------------------------------------------------
// 排版常量（唯一来源；painter 与单测都从这里读，不在 widget 里散落魔法数）
// ---------------------------------------------------------------------------

/// 内容最小排版宽度：窄于此按 320 排，允许水平滚动，不把谱面压成一条线。
const double kMusicStaffMinWidth = 320.0;

/// 一个小节列的最小宽度（决定行内小节数上限）。
const double kMusicStaffMeasureMinWidth = 96.0;

/// 一个小节列的最大宽度（防止少小节谱被拉成巨型空白）。
const double kMusicStaffMeasureMaxWidth = 240.0;

/// 行内小节数上限（再多就换行，保证可读）。
const int kMusicStaffMaxMeasuresPerRow = 8;

/// 行左右留白 / 行首谱号+调号+拍号区宽度 / 小节内左右留白。
const double kMusicStaffRowPaddingX = 10.0;
const double kMusicStaffHeaderWidth = 58.0;
const double kMusicStaffMeasurePaddingX = 6.0;

/// 行高与五线几何：行首留 30px 给轨道名/小节号，五线 4 个间距共 32px。
const double kMusicStaffRowHeight = 112.0;
const double kMusicStaffStaffTopOffset = 30.0;
const double kMusicStaffLineSpacing = 8.0;
const double kMusicStaffTopPadding = 8.0;
const double kMusicStaffBottomPadding = 8.0;

/// 符头/符干几何。
const double kMusicStaffHeadWidth = 9.2;
const double kMusicStaffHeadHeight = 6.4;
const double kMusicStaffStemLength = 28.0;

/// 缩放区间与步长（50–150%，每步 10%）。
const int kMusicStaffZoomMinPercent = 50;
const int kMusicStaffZoomMaxPercent = 150;
const int kMusicStaffZoomStepPercent = 10;

/// 点击命中的五线垂直容差：底线/顶线外 ±2 个线间距（够到加线音符；再远算空白）。
const double kMusicStaffHitLineTolerance = kMusicStaffLineSpacing * 2;

// ---------------------------------------------------------------------------
// 纯函数：MusicScore → 可断言几何
// ---------------------------------------------------------------------------

/// 把乐谱排成只读五线谱几何。
///
/// [width] 是可用排版宽度（逻辑像素）；小于 [kMusicStaffMinWidth] 时按最小宽度
/// 排，`layout.width` 会如实反映实际内容宽度（调用方可据此横向滚动）。
/// [trackIndex] 为 null 时按轨道逐行排列全部轨道；给出时只排该轨道（越界返回
/// 空布局，不抛异常）。同一输入输出完全确定（两次调用 `==` 且 JSON 相同）。
MusicStaffLayout musicStaffLayout(
  MusicScore score, {
  required double width,
  int? trackIndex,
}) {
  final double contentWidth = _effectiveWidth(width);
  final List<int> trackIndexes;
  if (trackIndex == null) {
    trackIndexes = <int>[for (int i = 0; i < score.tracks.length; i++) i];
  } else if (trackIndex >= 0 && trackIndex < score.tracks.length) {
    trackIndexes = <int>[trackIndex];
  } else {
    trackIndexes = const <int>[];
  }
  final double availableInner =
      contentWidth - 2 * kMusicStaffRowPaddingX - kMusicStaffHeaderWidth;
  final int capacity = availableInner <= 0
      ? 1
      : math.max(
          1,
          math.min(
            kMusicStaffMaxMeasuresPerRow,
            (availableInner / kMusicStaffMeasureMinWidth).floor(),
          ),
        );
  final double timeSignatureCapacity = _measureCapacity(score.timeSig);
  final List<MusicStaffRow> rows = <MusicStaffRow>[];
  final Map<String, (int, MusicStaffNote)> noteLocations =
      <String, (int, MusicStaffNote)>{};

  for (final int ti in trackIndexes) {
    final MusicTrack track = score.tracks[ti];
    final int measureCount = track.measures.length;
    if (measureCount <= 0) continue; // 空轨道：没有小节就没有行（不画假谱面）
    final String clef = musicStaffClefForTrack(track);
    final int measuresPerRow = math.min(capacity, measureCount);
    final double slotWidth = availableInner / measuresPerRow;
    final double columnWidth = math.min(slotWidth, kMusicStaffMeasureMaxWidth);
    for (int start = 0; start < measureCount; start += measuresPerRow) {
      final int end = math.min(start + measuresPerRow, measureCount);
      final int rowIndex = rows.length;
      final double rowTop =
          kMusicStaffTopPadding + rowIndex * kMusicStaffRowHeight;
      final double staffTop = rowTop + kMusicStaffStaffTopOffset;
      final double staffBottom = staffTop + 4 * kMusicStaffLineSpacing;
      final double headerLeft = kMusicStaffRowPaddingX;
      final double contentLeft = headerLeft + kMusicStaffHeaderWidth;
      final List<MusicStaffColumn> columns = <MusicStaffColumn>[];
      for (int mi = start; mi < end; mi++) {
        final int columnIndex = mi - start;
        final double columnX = contentLeft + columnIndex * columnWidth;
        final double innerLeft = columnX + kMusicStaffMeasurePaddingX;
        final double innerWidth = columnWidth - 2 * kMusicStaffMeasurePaddingX;
        final MusicMeasure measure = track.measures[mi];
        final List<MusicStaffNote> notes = <MusicStaffNote>[];
        double cursor = 0;
        for (int ei = 0; ei < measure.events.length; ei++) {
          final MusicEvent event = measure.events[ei];
          final double duration = _safeDurationValue(event);
          // 时间轴 → x/宽度：正例按拍占比，坏数据（超容量/负时值）夹在列内。
          final double rawX =
              innerLeft + (cursor / timeSignatureCapacity) * innerWidth;
          final double maxX = math.max(innerLeft, innerLeft + innerWidth - 1.5);
          final double noteX = rawX.clamp(innerLeft, maxX).toDouble();
          final double rawWidth =
              (duration / timeSignatureCapacity) * innerWidth;
          final double maxWidth = math.max(1.5, innerLeft + innerWidth - noteX);
          final double noteWidth = math.min(math.max(1.5, rawWidth), maxWidth);
          final int staffStep = event.isRest
              ? 4 // 休止符锚在中间线；不参与音高映射
              : musicStaffStepForEvent(event, clef);
          final double rawHeadY =
              staffBottom - staffStep * (kMusicStaffLineSpacing / 2);
          final double headY = rawHeadY
              .clamp(rowTop + 8, rowTop + kMusicStaffRowHeight - 8)
              .toDouble();
          final MusicStaffNote note = MusicStaffNote(
            measureIndex: mi,
            eventIndex: ei,
            eventId: event.id,
            isRest: event.isRest,
            durationValue: duration,
            staffStep: staffStep,
            x: noteX,
            width: noteWidth,
            headX: noteX,
            headY: headY,
            filled: musicStaffIsFilled(event),
            stemUp: staffStep < 4,
            stemless: musicStaffIsStemless(event),
            flags: musicStaffFlagsForEvent(event),
            dots: _clampInt(event.dot, 0, 4),
            accidental: _accidentalOf(event),
            tupletN: event.isRest ? 0 : _clampInt(event.tupletN, 0, 9),
          );
          notes.add(note);
          if (event.id.isNotEmpty && !noteLocations.containsKey(event.id)) {
            noteLocations[event.id] = (rowIndex, note);
          }
          cursor += duration;
        }
        columns.add(
          MusicStaffColumn(
            measureIndex: mi,
            x: columnX,
            width: columnWidth,
            contentLeft: innerLeft,
            contentWidth: innerWidth,
            notes: List<MusicStaffNote>.unmodifiable(notes),
          ),
        );
      }
      rows.add(
        MusicStaffRow(
          index: rowIndex,
          trackIndex: ti,
          trackId: track.id,
          trackName: track.name,
          instrument: track.instrument,
          clef: clef,
          top: rowTop,
          height: kMusicStaffRowHeight,
          staffTop: staffTop,
          staffBottom: staffBottom,
          lineSpacing: kMusicStaffLineSpacing,
          headerLeft: headerLeft,
          contentLeft: contentLeft,
          columnWidth: columnWidth,
          systemWidth: columns.length * columnWidth,
          columns: List<MusicStaffColumn>.unmodifiable(columns),
        ),
      );
    }
  }

  // 连音线占位：布局只记录端点几何；不可见（跨行/跨轨/端点缺失）也保留占位。
  final List<MusicStaffTie> ties = <MusicStaffTie>[];
  for (final MusicRelation relation in score.relations) {
    if (relation.type != 'tie') continue;
    final Object? from = relation.data['from'];
    final Object? to = relation.data['to'];
    if (from is! String || to is! String) continue;
    if (from.isEmpty || to.isEmpty) continue;
    final (int, MusicStaffNote)? fromLocation = noteLocations[from];
    final (int, MusicStaffNote)? toLocation = noteLocations[to];
    if (fromLocation == null || toLocation == null) continue;
    final bool visible =
        fromLocation.$1 == toLocation.$1 &&
        !fromLocation.$2.isRest &&
        !toLocation.$2.isRest;
    ties.add(
      MusicStaffTie(
        rowIndex: fromLocation.$1,
        fromEventId: from,
        toEventId: to,
        fromX: fromLocation.$2.headX + kMusicStaffHeadWidth / 2,
        fromY: fromLocation.$2.headY,
        toX: toLocation.$2.headX + kMusicStaffHeadWidth / 2,
        toY: toLocation.$2.headY,
        visible: visible,
      ),
    );
  }

  return MusicStaffLayout(
    title: score.title,
    tempo: score.tempo,
    timeSig: List<int>.unmodifiable(score.timeSig),
    keySig: score.keySig,
    trackIndex: trackIndex,
    width: contentWidth,
    height:
        kMusicStaffTopPadding +
        rows.length * kMusicStaffRowHeight +
        kMusicStaffBottomPadding,
    maxMeasuresPerRow: capacity,
    rows: List<MusicStaffRow>.unmodifiable(rows),
    ties: List<MusicStaffTie>.unmodifiable(ties),
  );
}

/// 轨道的谱号语义：鼓轨固定打击谱号；其余只认 treble/bass，未知回退高音谱号。
String musicStaffClefForTrack(MusicTrack track) {
  if (track.instrument == 'drums') return 'percussion';
  final String clef = track.clef.trim().toLowerCase();
  if (clef == 'treble' || clef == 'bass' || clef == 'percussion') {
    return clef;
  }
  return 'treble';
}

/// 音高 → 相对五线底线的「半间距」偏移（0 = 底线；正数向上，负数向下）。
///
/// 高音谱号底线 E4、低音谱号底线 G2；打击谱号按鼓件名映射。
int musicStaffStepForEvent(MusicEvent event, String clef) {
  if (clef == 'percussion') {
    final String drum = (event.extra['drum'] ?? '').toString();
    return musicStaffDrumStep(drum);
  }
  const Map<String, int> stepIndex = <String, int>{
    'C': 0,
    'D': 1,
    'E': 2,
    'F': 3,
    'G': 4,
    'A': 5,
    'B': 6,
  };
  final int step = stepIndex[event.step.toUpperCase()] ?? 0;
  final int diatonic = event.octave * 7 + step;
  final int bottom =
      _clefBottomDiatonic[clef] ?? _clefBottomDiatonic['treble']!;
  return diatonic - bottom;
}

/// 五线底线对应的全音阶绝对位置：高音谱号 E4 = 4*7+2，低音谱号 G2 = 2*7+4。
const Map<String, int> _clefBottomDiatonic = <String, int>{
  'treble': 30,
  'bass': 18,
};

/// [musicStaffStepForEvent] 的逆映射：半间距偏移 → 记谱音高（不应用调号）。
///
/// 打击谱号没有音高语义，返回占位 C4；鼓件名由 [musicStaffDrumForStep] 决定。
/// 越界偏移（八度 <0 或 >9）仍照实返回，由调用方决定是否算安全命中。
({String step, int octave}) musicStaffPitchForStep(int staffStep, String clef) {
  if (clef == 'percussion') return (step: 'C', octave: 4);
  const List<String> steps = <String>['C', 'D', 'E', 'F', 'G', 'A', 'B'];
  final int diatonic =
      staffStep + (_clefBottomDiatonic[clef] ?? _clefBottomDiatonic['treble']!);
  return (step: steps[diatonic % 7], octave: diatonic ~/ 7);
}

/// 鼓件名 → 打击谱号上的半间距偏移（底线上方：kick 最低，crash 最高）。
///
/// 顺序即音高顺序（[musicStaffDrumForStep] 的「等距取低」依赖这个稳定顺序）。
const Map<String, int> _drumSteps = <String, int>{
  'kick': 0,
  'tom': 2,
  'snare': 4,
  'openhat': 6,
  'hihat': 8,
  'ride': 10,
  'crash': 12,
};

int musicStaffDrumStep(String drum) => _drumSteps[drum] ?? 4;

/// [musicStaffDrumStep] 的逆映射：半间距偏移 → 最近的鼓件名。
///
/// 两个鼓件等距时取音高更低（更靠下）的那个，保证命中换算确定。
String musicStaffDrumForStep(int staffStep) {
  String nearest = 'snare';
  int bestDistance = 1 << 30;
  for (final MapEntry<String, int> entry in _drumSteps.entries) {
    final int distance = (entry.value - staffStep).abs();
    if (distance >= bestDistance) continue;
    bestDistance = distance;
    nearest = entry.key;
  }
  return nearest;
}

/// 符尾数量：四分及以上 0，八分 1，十六分 2，三十二分 3（上限 4）。
int musicStaffFlagsForEvent(MusicEvent event) {
  if (event.isRest) return 0;
  final double value = event.durNum / event.durDen;
  if (!value.isFinite || value <= 0) return 0;
  if (value >= 0.25 - 1e-9) return 0;
  final double raw = math.log(1 / value) / math.log(2);
  return _clampInt(raw.round() - 2, 0, 4);
}

/// 符头是否实心：二分及以上空心，四分及以下实心（附点按基础时值判定）。
bool musicStaffIsFilled(MusicEvent event) {
  if (event.isRest) return false;
  return event.durNum * 2 < event.durDen;
}

/// 是否无符干：全音符（含附点全音符）不画符干。
bool musicStaffIsStemless(MusicEvent event) {
  if (event.isRest) return true;
  return event.durNum >= event.durDen;
}

double _effectiveWidth(double width) {
  if (!width.isFinite || width < kMusicStaffMinWidth) {
    return kMusicStaffMinWidth;
  }
  return width;
}

double _measureCapacity(List<int> timeSig) {
  if (timeSig.length == 2 && timeSig[0] > 0 && timeSig[1] > 0) {
    return timeSig[0] / timeSig[1];
  }
  return 1.0;
}

double _safeDurationValue(MusicEvent event) {
  final double value = event.durationValue;
  if (!value.isFinite || value <= 0) return 0;
  return value;
}

String _accidentalOf(MusicEvent event) {
  if (event.isRest) return '';
  if (event.alter > 0) return '#';
  if (event.alter < 0) return 'b';
  return '';
}

int _clampInt(int value, int min, int max) =>
    value < min ? min : (value > max ? max : value);

// ---------------------------------------------------------------------------
// 几何模型（toJson / equality 便于单测断言确定性）
// ---------------------------------------------------------------------------

/// 一份乐谱的只读五线谱排版结果。
@immutable
final class MusicStaffLayout {
  const MusicStaffLayout({
    required this.title,
    required this.tempo,
    required this.timeSig,
    required this.keySig,
    required this.trackIndex,
    required this.width,
    required this.height,
    required this.maxMeasuresPerRow,
    required this.rows,
    required this.ties,
  });

  final String title;
  final int tempo;
  final List<int> timeSig;
  final String keySig;

  /// 请求的轨道过滤（null = 全部轨道逐行排列）；越界时 rows 为空。
  final int? trackIndex;

  /// 实际排版内容宽度（≥ [kMusicStaffMinWidth]）；横向滚动按它 × 缩放决定。
  final double width;

  /// 排版内容总高（无行时仍给上下留白，不让几何退化成 0）。
  final double height;

  /// 行内小节数上限（由宽度决定的容量；每行实际列数见 [MusicStaffRow.columns]）。
  final int maxMeasuresPerRow;

  final List<MusicStaffRow> rows;
  final List<MusicStaffTie> ties;

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'tempo': tempo,
    'timeSig': timeSig,
    'keySig': keySig,
    'trackIndex': trackIndex,
    'width': width,
    'height': height,
    'maxMeasuresPerRow': maxMeasuresPerRow,
    'rows': rows
        .map((MusicStaffRow row) => row.toJson())
        .toList(growable: false),
    'ties': ties
        .map((MusicStaffTie tie) => tie.toJson())
        .toList(growable: false),
  };

  /// 字节确定性入口：同一输入两次布局得到完全相同的 JSON 文本。
  String toJsonString() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MusicStaffLayout &&
        other.title == title &&
        other.tempo == tempo &&
        _listEquals(other.timeSig, timeSig) &&
        other.keySig == keySig &&
        other.trackIndex == trackIndex &&
        other.width == width &&
        other.height == height &&
        other.maxMeasuresPerRow == maxMeasuresPerRow &&
        _listEquals(other.rows, rows) &&
        _listEquals(other.ties, ties);
  }

  @override
  int get hashCode => Object.hash(
    title,
    tempo,
    Object.hashAll(timeSig),
    keySig,
    trackIndex,
    width,
    height,
    maxMeasuresPerRow,
    Object.hashAll(rows),
    Object.hashAll(ties),
  );

  @override
  String toString() =>
      'MusicStaffLayout(width: $width, rows: ${rows.length}, '
      'ties: ${ties.length})';
}

/// 一行 = 一条轨道的一行谱（`trackIndex` 指明所属轨道）。
@immutable
final class MusicStaffRow {
  const MusicStaffRow({
    required this.index,
    required this.trackIndex,
    required this.trackId,
    required this.trackName,
    required this.instrument,
    required this.clef,
    required this.top,
    required this.height,
    required this.staffTop,
    required this.staffBottom,
    required this.lineSpacing,
    required this.headerLeft,
    required this.contentLeft,
    required this.columnWidth,
    required this.systemWidth,
    required this.columns,
  });

  final int index;
  final int trackIndex;
  final String trackId;
  final String trackName;
  final String instrument;

  /// 'treble' / 'bass' / 'percussion'：谱号字形选择依据。
  final String clef;

  final double top;
  final double height;
  final double staffTop;
  final double staffBottom;
  final double lineSpacing;

  /// 行首（谱号/调号/拍号区左边界）；五线从 [headerLeft] 画到 [contentLeft]+[systemWidth]。
  final double headerLeft;
  final double contentLeft;
  final double columnWidth;
  final double systemWidth;
  final List<MusicStaffColumn> columns;

  Map<String, Object?> toJson() => <String, Object?>{
    'index': index,
    'trackIndex': trackIndex,
    'trackId': trackId,
    'trackName': trackName,
    'instrument': instrument,
    'clef': clef,
    'top': top,
    'height': height,
    'staffTop': staffTop,
    'staffBottom': staffBottom,
    'lineSpacing': lineSpacing,
    'headerLeft': headerLeft,
    'contentLeft': contentLeft,
    'columnWidth': columnWidth,
    'systemWidth': systemWidth,
    'columns': columns
        .map((MusicStaffColumn column) => column.toJson())
        .toList(growable: false),
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MusicStaffRow &&
        other.index == index &&
        other.trackIndex == trackIndex &&
        other.trackId == trackId &&
        other.trackName == trackName &&
        other.instrument == instrument &&
        other.clef == clef &&
        other.top == top &&
        other.height == height &&
        other.staffTop == staffTop &&
        other.staffBottom == staffBottom &&
        other.lineSpacing == lineSpacing &&
        other.headerLeft == headerLeft &&
        other.contentLeft == contentLeft &&
        other.columnWidth == columnWidth &&
        other.systemWidth == systemWidth &&
        _listEquals(other.columns, columns);
  }

  @override
  int get hashCode => Object.hash(
    index,
    trackIndex,
    trackId,
    trackName,
    instrument,
    clef,
    top,
    height,
    staffTop,
    staffBottom,
    lineSpacing,
    headerLeft,
    contentLeft,
    columnWidth,
    systemWidth,
    Object.hashAll(columns),
  );
}

/// 一行里的一个小节列。
@immutable
final class MusicStaffColumn {
  const MusicStaffColumn({
    required this.measureIndex,
    required this.x,
    required this.width,
    required this.contentLeft,
    required this.contentWidth,
    required this.notes,
  });

  /// 小节在轨道内的下标（0 起；测试据此断言覆盖顺序）。
  final int measureIndex;
  final double x;
  final double width;
  final double contentLeft;
  final double contentWidth;
  final List<MusicStaffNote> notes;

  Map<String, Object?> toJson() => <String, Object?>{
    'measureIndex': measureIndex,
    'x': x,
    'width': width,
    'contentLeft': contentLeft,
    'contentWidth': contentWidth,
    'notes': notes
        .map((MusicStaffNote note) => note.toJson())
        .toList(growable: false),
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MusicStaffColumn &&
        other.measureIndex == measureIndex &&
        other.x == x &&
        other.width == width &&
        other.contentLeft == contentLeft &&
        other.contentWidth == contentWidth &&
        _listEquals(other.notes, notes);
  }

  @override
  int get hashCode => Object.hash(
    measureIndex,
    x,
    width,
    contentLeft,
    contentWidth,
    Object.hashAll(notes),
  );
}

/// 一个音符/休止的几何：时值宽度、符头位置、符干/符尾/附点/升降号提示。
@immutable
final class MusicStaffNote {
  const MusicStaffNote({
    required this.measureIndex,
    required this.eventIndex,
    required this.eventId,
    required this.isRest,
    required this.durationValue,
    required this.staffStep,
    required this.x,
    required this.width,
    required this.headX,
    required this.headY,
    required this.filled,
    required this.stemUp,
    required this.stemless,
    required this.flags,
    required this.dots,
    required this.accidental,
    required this.tupletN,
  });

  final int measureIndex;
  final int eventIndex;
  final String eventId;
  final bool isRest;

  /// 实际时值（相对全音符，含附点/连音）。
  final double durationValue;

  /// 相对五线底线的半间距偏移（0 = 底线；正向上）。
  final int staffStep;

  /// 时间槽左边界与宽度（按小节容量比例映射）。
  final double x;
  final double width;

  /// 符头锚点：左边界 + 垂直中心。
  final double headX;
  final double headY;

  final bool filled;
  final bool stemUp;
  final bool stemless;
  final int flags;
  final int dots;

  /// '' / '#' / 'b'：绘制层用文本画简单升降号。
  final String accidental;
  final int tupletN;

  Map<String, Object?> toJson() => <String, Object?>{
    'measureIndex': measureIndex,
    'eventIndex': eventIndex,
    'eventId': eventId,
    'isRest': isRest,
    'durationValue': durationValue,
    'staffStep': staffStep,
    'x': x,
    'width': width,
    'headX': headX,
    'headY': headY,
    'filled': filled,
    'stemUp': stemUp,
    'stemless': stemless,
    'flags': flags,
    'dots': dots,
    'accidental': accidental,
    'tupletN': tupletN,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MusicStaffNote &&
        other.measureIndex == measureIndex &&
        other.eventIndex == eventIndex &&
        other.eventId == eventId &&
        other.isRest == isRest &&
        other.durationValue == durationValue &&
        other.staffStep == staffStep &&
        other.x == x &&
        other.width == width &&
        other.headX == headX &&
        other.headY == headY &&
        other.filled == filled &&
        other.stemUp == stemUp &&
        other.stemless == stemless &&
        other.flags == flags &&
        other.dots == dots &&
        other.accidental == accidental &&
        other.tupletN == tupletN;
  }

  @override
  int get hashCode => Object.hash(
    measureIndex,
    eventIndex,
    eventId,
    isRest,
    durationValue,
    staffStep,
    x,
    width,
    headX,
    headY,
    filled,
    stemUp,
    stemless,
    flags,
    dots,
    accidental,
    tupletN,
  );
}

/// 连音线占位：端点几何 + 是否可在同一行画出（跨行实现留后续批次）。
@immutable
final class MusicStaffTie {
  const MusicStaffTie({
    required this.rowIndex,
    required this.fromEventId,
    required this.toEventId,
    required this.fromX,
    required this.fromY,
    required this.toX,
    required this.toY,
    required this.visible,
  });

  final int rowIndex;
  final String fromEventId;
  final String toEventId;
  final double fromX;
  final double fromY;
  final double toX;
  final double toY;

  /// 两端都在同一行且都不是休止 → 绘制层画弧；否则只留占位，不伪造。
  final bool visible;

  Map<String, Object?> toJson() => <String, Object?>{
    'rowIndex': rowIndex,
    'fromEventId': fromEventId,
    'toEventId': toEventId,
    'fromX': fromX,
    'fromY': fromY,
    'toX': toX,
    'toY': toY,
    'visible': visible,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MusicStaffTie &&
        other.rowIndex == rowIndex &&
        other.fromEventId == fromEventId &&
        other.toEventId == toEventId &&
        other.fromX == fromX &&
        other.fromY == fromY &&
        other.toX == toX &&
        other.toY == toY &&
        other.visible == visible;
  }

  @override
  int get hashCode => Object.hash(
    rowIndex,
    fromEventId,
    toEventId,
    fromX,
    fromY,
    toX,
    toY,
    visible,
  );
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// 命中测试纯函数：可视坐标（含缩放）→ 行/小节/五线位置 → 音高
// ---------------------------------------------------------------------------

/// 五线谱点击命中结果（task-14）。
///
/// 只描述几何命中：轨道/小节 + 五线半间距偏移 + 换算出的记谱音高。命中已有音符
/// 时额外给 [eventIndex]/[eventId]（供后续「点音符」交互；本次插入不依赖它）。
@immutable
final class MusicStaffHit {
  const MusicStaffHit({
    required this.rowIndex,
    required this.trackIndex,
    required this.measureIndex,
    required this.clef,
    required this.staffStep,
    required this.step,
    required this.alter,
    required this.octave,
    this.drum = '',
    this.eventIndex,
    this.eventId,
  });

  /// 排版行下标（[MusicStaffLayout.rows] 中的位置）。
  final int rowIndex;

  final int trackIndex;
  final int measureIndex;

  /// 'treble' / 'bass' / 'percussion'。
  final String clef;

  /// 相对五线底线的半间距偏移（0 = 底线；正数向上）。
  final int staffStep;

  /// 换算出的记谱音高（打击谱号是占位 C4，真实音色看 [drum]）。
  final String step;
  final int alter;
  final int octave;

  /// 打击谱号命中的鼓件名（'' = 非鼓轨）。
  final String drum;

  /// 命中已有音符时的事件位置；空白（或未命中符头）为 null。
  final int? eventIndex;
  final String? eventId;

  bool get isPercussion => clef == 'percussion';

  Map<String, Object?> toJson() => <String, Object?>{
    'rowIndex': rowIndex,
    'trackIndex': trackIndex,
    'measureIndex': measureIndex,
    'clef': clef,
    'staffStep': staffStep,
    'step': step,
    'alter': alter,
    'octave': octave,
    'drum': drum,
    'eventIndex': eventIndex,
    'eventId': eventId,
  };

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MusicStaffHit &&
        other.rowIndex == rowIndex &&
        other.trackIndex == trackIndex &&
        other.measureIndex == measureIndex &&
        other.clef == clef &&
        other.staffStep == staffStep &&
        other.step == step &&
        other.alter == alter &&
        other.octave == octave &&
        other.drum == drum &&
        other.eventIndex == eventIndex &&
        other.eventId == eventId;
  }

  @override
  int get hashCode => Object.hash(
    rowIndex,
    trackIndex,
    measureIndex,
    clef,
    staffStep,
    step,
    alter,
    octave,
    drum,
    eventIndex,
    eventId,
  );

  @override
  String toString() =>
      'MusicStaffHit(track: $trackIndex, measure: $measureIndex, '
      'staffStep: $staffStep, ${isPercussion ? drum : '$step$octave'})';
}

/// 把可视坐标 [local]（已含 [zoom]，即 GestureDetector 的 `localPosition`）换算回
/// [layout] 的排版坐标，命中一行/一小节/一个五线位置。
///
/// 安全返回 null 的情形：布局没有行、坐标/缩放非有限、落在行外、落在行首
/// 谱号+调号+拍号区或小节区外、距五线超过 [kMusicStaffHitLineTolerance]、以及
/// 换算出的八度超出 0–9。命中空白/越界绝不抛异常。
MusicStaffHit? staffHitTest(
  MusicStaffLayout layout,
  Offset local, {
  double zoom = 1.0,
}) {
  if (layout.rows.isEmpty) return null;
  if (!local.dx.isFinite || !local.dy.isFinite) return null;
  if (!zoom.isFinite || zoom <= 0) return null;
  final Offset point = local / zoom;
  MusicStaffRow? row;
  for (final MusicStaffRow candidate in layout.rows) {
    if (point.dy >= candidate.top &&
        point.dy <= candidate.top + candidate.height) {
      row = candidate;
      break;
    }
  }
  if (row == null) return null;
  // 行首谱号/调号/拍号区不是小节，点它按空白处理（不猜小节）。
  final double contentLeft = row.contentLeft;
  final double contentRight = row.contentLeft + row.systemWidth;
  if (point.dx < contentLeft || point.dx > contentRight) return null;
  MusicStaffColumn? column;
  for (final MusicStaffColumn candidate in row.columns) {
    if (point.dx >= candidate.x && point.dx < candidate.x + candidate.width) {
      column = candidate;
      break;
    }
  }
  if (column == null) {
    // 最右边界（最后一个列右沿）落到最后一个小节；再往右是空白。
    if (point.dx != contentRight || row.columns.isEmpty) return null;
    column = row.columns.last;
  }
  final double topLimit = row.staffTop - kMusicStaffHitLineTolerance;
  final double bottomLimit = row.staffBottom + kMusicStaffHitLineTolerance;
  if (point.dy < topLimit || point.dy > bottomLimit) return null;
  // 五线半间距 → 最近的线/间（round 把点击吸附到最近的半间距）。
  final int staffStep = ((row.staffBottom - point.dy) / (row.lineSpacing / 2))
      .round();
  final String clef = row.clef;
  final bool percussion = clef == 'percussion';
  final ({String step, int octave}) pitch = musicStaffPitchForStep(
    staffStep,
    clef,
  );
  if (!percussion && (pitch.octave < 0 || pitch.octave > 9)) return null;
  int? eventIndex;
  String? eventId;
  for (final MusicStaffNote note in column.notes) {
    if (note.isRest) continue;
    final Rect head = Rect.fromCenter(
      center: Offset(note.headX + kMusicStaffHeadWidth / 2, note.headY),
      width: kMusicStaffHeadWidth * 1.6,
      height: row.lineSpacing * 1.2,
    );
    if (!head.contains(point)) continue;
    eventIndex = note.eventIndex;
    eventId = note.eventId;
    break;
  }
  return MusicStaffHit(
    rowIndex: row.index,
    trackIndex: row.trackIndex,
    measureIndex: column.measureIndex,
    clef: clef,
    staffStep: staffStep,
    step: pitch.step,
    alter: 0,
    octave: pitch.octave,
    drum: percussion ? musicStaffDrumForStep(staffStep) : '',
    eventIndex: eventIndex,
    eventId: eventId,
  );
}

// ---------------------------------------------------------------------------
// 绘制层：只消费 MusicStaffLayout（不重算几何）
// ---------------------------------------------------------------------------

class _MusicStaffPainter extends CustomPainter {
  _MusicStaffPainter({
    required this.layout,
    required this.palette,
    required this.zoom,
    this.highlightTrackIndex,
  });

  final MusicStaffLayout layout;
  final NonPalette palette;

  /// 1.0 = 100%；50–150% 由外层 [MusicStaffView] 夹紧。
  final double zoom;

  /// 当前左侧轨道列表选中的轨道（只做行底色/标签强调，不改几何）。
  final int? highlightTrackIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (layout.rows.isEmpty || size.width <= 0 || size.height <= 0) return;
    canvas.save();
    canvas.scale(zoom);
    final Paint staffLinePaint = Paint()
      ..color = palette.ink4.withValues(alpha: 0.45)
      ..strokeWidth = 0.9;
    final Paint barlinePaint = Paint()
      ..color = palette.ink3.withValues(alpha: 0.7)
      ..strokeWidth = 1.0;
    final Paint finalBarlinePaint = Paint()
      ..color = palette.ink3
      ..strokeWidth = 1.7;
    for (final MusicStaffRow row in layout.rows) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, row.top, layout.width, row.height));
      final bool highlighted =
          highlightTrackIndex != null && highlightTrackIndex == row.trackIndex;
      if (highlighted) {
        canvas.drawRect(
          Rect.fromLTWH(0, row.top, layout.width, row.height),
          Paint()..color = palette.accent.withValues(alpha: 0.055),
        );
      }
      _paintRowHeader(canvas, row, highlighted);
      _paintStaffLines(canvas, row, staffLinePaint);
      _paintBarlines(canvas, row, barlinePaint, finalBarlinePaint);
      _paintNotes(canvas, row, staffLinePaint);
      _paintTies(canvas, row);
      canvas.restore();
    }
    canvas.restore();
  }

  void _paintRowHeader(Canvas canvas, MusicStaffRow row, bool highlighted) {
    final Color labelColor = highlighted ? palette.accent : palette.ink3;
    final String label = row.trackName.isEmpty ? row.trackId : row.trackName;
    _paintText(
      canvas,
      label,
      Offset(row.headerLeft, row.top + 7),
      fontSize: 10,
      color: labelColor,
      fontWeight: FontWeight.w600,
    );
    // 拍号/调号文本：调号画在谱号右侧，拍号画成上下两行数字。
    final List<int> timeSig = layout.timeSig;
    _paintClef(canvas, row);
    if (layout.keySig.trim().isNotEmpty) {
      _paintText(
        canvas,
        layout.keySig.trim(),
        Offset(row.headerLeft + 27, row.staffTop + 10),
        fontSize: 9,
        color: palette.ink3,
      );
    }
    if (timeSig.length == 2 && timeSig[0] > 0 && timeSig[1] > 0) {
      final double timeX = row.headerLeft + 47;
      _paintText(
        canvas,
        '${timeSig[0]}',
        Offset(timeX, row.staffTop + 1),
        fontSize: 10,
        color: palette.ink2,
        center: true,
        fontWeight: FontWeight.w600,
      );
      _paintText(
        canvas,
        '${timeSig[1]}',
        Offset(timeX, row.staffTop + 17),
        fontSize: 10,
        color: palette.ink2,
        center: true,
        fontWeight: FontWeight.w600,
      );
    }
    // 小节号：画在列左上方，只做定位提示，不参与语义。
    for (final MusicStaffColumn column in row.columns) {
      _paintText(
        canvas,
        '${column.measureIndex + 1}',
        Offset(column.x + 1, row.staffTop - 9),
        fontSize: 8,
        color: palette.ink4,
      );
    }
  }

  void _paintStaffLines(Canvas canvas, MusicStaffRow row, Paint paint) {
    final double left = row.headerLeft;
    final double right = row.contentLeft + row.systemWidth;
    for (int i = 0; i < 5; i++) {
      final double y = row.staffTop + i * row.lineSpacing;
      canvas.drawLine(Offset(left, y), Offset(right, y), paint);
    }
  }

  void _paintBarlines(
    Canvas canvas,
    MusicStaffRow row,
    Paint barlinePaint,
    Paint finalBarlinePaint,
  ) {
    if (row.columns.isEmpty) return;
    for (int i = 1; i < row.columns.length; i++) {
      final MusicStaffColumn column = row.columns[i];
      canvas.drawLine(
        Offset(column.x, row.staffTop),
        Offset(column.x, row.staffBottom),
        barlinePaint,
      );
    }
    final double endX = row.contentLeft + row.systemWidth;
    canvas.drawLine(
      Offset(endX, row.staffTop),
      Offset(endX, row.staffBottom),
      finalBarlinePaint,
    );
  }

  void _paintClef(Canvas canvas, MusicStaffRow row) {
    final double cx = row.headerLeft + 12;
    final Paint stroke = Paint()
      ..color = palette.ink2
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final Paint fill = Paint()..color = palette.ink2;
    switch (row.clef) {
      case 'bass':
        // 低音谱号简单字形：F 线上的点 + 右侧弧线。
        canvas.drawCircle(
          Offset(cx + 1, row.staffTop + row.lineSpacing),
          2.2,
          fill,
        );
        final Path path = Path()
          ..moveTo(cx + 4, row.staffTop + row.lineSpacing - 3)
          ..cubicTo(
            cx + 11,
            row.staffTop + row.lineSpacing + 2,
            cx + 9,
            row.staffTop + row.lineSpacing + 11,
            cx + 2,
            row.staffTop + row.lineSpacing + 14,
          );
        canvas.drawPath(path, stroke);
        break;
      case 'percussion':
        // 打击谱号简单字形：两条竖向粗线。
        for (final double offset in <double>[-4.2, 1.8]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(cx + offset, row.staffTop + 8, 2.4, 16),
              const Radius.circular(1),
            ),
            fill,
          );
        }
        break;
      default:
        // 高音谱号简单字形：绕 G 线的螺旋 + 下方尾巴。
        final Path path = Path()
          ..moveTo(cx + 1, row.staffBottom + 8)
          ..cubicTo(
            cx + 1,
            row.staffBottom - 2,
            cx - 6,
            row.staffTop + 16,
            cx - 5,
            row.staffTop + 9,
          )
          ..cubicTo(
            cx - 4,
            row.staffTop + 1,
            cx + 5,
            row.staffTop - 2,
            cx + 5,
            row.staffTop + 6,
          )
          ..cubicTo(
            cx + 5,
            row.staffTop + 13,
            cx - 2,
            row.staffTop + 15,
            cx - 2,
            row.staffTop + 21,
          )
          ..cubicTo(
            cx - 2,
            row.staffTop + 27,
            cx + 4,
            row.staffTop + 25,
            cx + 2,
            row.staffBottom + 8,
          );
        canvas.drawPath(path, stroke);
        canvas.drawCircle(Offset(cx + 1, row.staffBottom + 9.5), 1.5, fill);
        break;
    }
  }

  void _paintNotes(Canvas canvas, MusicStaffRow row, Paint staffLinePaint) {
    for (final MusicStaffColumn column in row.columns) {
      if (column.notes.isEmpty) {
        // 空小节 = 整小节休止：画一个居中的全休止符，不画假音符。
        final double cx = column.contentLeft + column.contentWidth / 2;
        canvas.drawRect(
          Rect.fromLTWH(cx - 6, row.staffTop + row.lineSpacing, 12, 3.2),
          Paint()..color = palette.ink2.withValues(alpha: 0.85),
        );
        continue;
      }
      for (final MusicStaffNote note in column.notes) {
        if (note.isRest) {
          _paintRest(canvas, row, note);
        } else {
          _paintNote(canvas, row, note, staffLinePaint);
        }
      }
    }
  }

  void _paintNote(
    Canvas canvas,
    MusicStaffRow row,
    MusicStaffNote note,
    Paint staffLinePaint,
  ) {
    final double cx = note.headX + kMusicStaffHeadWidth / 2;
    _paintLedgerLines(canvas, row, note, cx, staffLinePaint);
    final Paint headFill = Paint()..color = palette.ink;
    final Paint headStroke = Paint()
      ..color = palette.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25;
    canvas.save();
    canvas.translate(cx, note.headY);
    canvas.rotate(-0.3);
    final Rect headRect = Rect.fromCenter(
      center: Offset.zero,
      width: kMusicStaffHeadWidth,
      height: kMusicStaffHeadHeight,
    );
    if (note.filled) {
      canvas.drawOval(headRect, headFill);
    } else {
      canvas.drawOval(headRect, headStroke);
    }
    canvas.restore();
    if (!note.stemless) {
      final double stemX = note.stemUp
          ? cx + kMusicStaffHeadWidth / 2 - 0.8
          : cx - kMusicStaffHeadWidth / 2 + 0.8;
      final double tipY = note.stemUp
          ? note.headY - kMusicStaffStemLength
          : note.headY + kMusicStaffStemLength;
      final Paint stemPaint = Paint()
        ..color = palette.ink
        ..strokeWidth = 1.1;
      canvas.drawLine(
        Offset(stemX, note.headY),
        Offset(stemX, tipY),
        stemPaint,
      );
      final Paint flagPaint = Paint()
        ..color = palette.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      for (int flag = 0; flag < note.flags; flag++) {
        final double flagY = note.stemUp
            ? tipY + flag * 5.5
            : tipY - flag * 5.5;
        final Path path = Path()..moveTo(stemX, flagY);
        if (note.stemUp) {
          path
            ..quadraticBezierTo(stemX + 9, flagY + 1, stemX + 11, flagY + 7)
            ..quadraticBezierTo(stemX + 6, flagY + 5, stemX + 1, flagY + 4);
        } else {
          path
            ..quadraticBezierTo(stemX - 9, flagY - 1, stemX - 11, flagY - 7)
            ..quadraticBezierTo(stemX - 6, flagY - 5, stemX - 1, flagY - 4);
        }
        canvas.drawPath(path, flagPaint);
      }
    }
    if (note.accidental.isNotEmpty) {
      _paintText(
        canvas,
        note.accidental,
        Offset(cx - kMusicStaffHeadWidth / 2 - 8, note.headY - 5),
        fontSize: 9,
        color: palette.ink2,
      );
    }
    if (note.dots > 0) {
      final double dotY = note.headY;
      for (int dot = 0; dot < note.dots; dot++) {
        canvas.drawCircle(
          Offset(cx + kMusicStaffHeadWidth / 2 + 4 + dot * 3.5, dotY),
          1.5,
          headFill,
        );
      }
    }
    if (note.tupletN > 0) {
      _paintText(
        canvas,
        '${note.tupletN}',
        Offset(cx, note.headY - 16),
        fontSize: 7,
        color: palette.ink4,
        center: true,
      );
    }
  }

  void _paintLedgerLines(
    Canvas canvas,
    MusicStaffRow row,
    MusicStaffNote note,
    double cx,
    Paint paint,
  ) {
    final double half = row.lineSpacing / 2;
    final double halfHeadWidth = kMusicStaffHeadWidth * 1.2;
    if (note.staffStep < 0) {
      for (int step = -2; step >= note.staffStep; step -= 2) {
        final double y = row.staffBottom - step * half;
        if (y <= row.top + 6 || y >= row.top + row.height - 6) continue;
        canvas.drawLine(
          Offset(cx - halfHeadWidth, y),
          Offset(cx + halfHeadWidth, y),
          paint,
        );
      }
    } else if (note.staffStep > 8) {
      for (int step = 10; step <= note.staffStep; step += 2) {
        final double y = row.staffBottom - step * half;
        if (y <= row.top + 6 || y >= row.top + row.height - 6) continue;
        canvas.drawLine(
          Offset(cx - halfHeadWidth, y),
          Offset(cx + halfHeadWidth, y),
          paint,
        );
      }
    }
  }

  void _paintRest(Canvas canvas, MusicStaffRow row, MusicStaffNote note) {
    final double cx = note.headX + kMusicStaffHeadWidth / 2;
    final double midY = row.staffTop + row.lineSpacing * 2;
    final double value = note.durationValue;
    final Paint fill = Paint()..color = palette.ink2;
    final Paint stroke = Paint()
      ..color = palette.ink2
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    if (value >= 0.75) {
      // 全休止 / 全音符休止：挂在第四线（自上而下第二条线）下方。
      canvas.drawRect(
        Rect.fromLTWH(cx - 6, row.staffTop + row.lineSpacing, 12, 3.2),
        fill,
      );
    } else if (value >= 0.375) {
      // 二分休止：坐在中间线上。
      canvas.drawRect(Rect.fromLTWH(cx - 6, midY - 3.4, 12, 3.2), fill);
    } else if (value >= 0.1875) {
      // 四分休止：简单折线钩。
      final Path path = Path()
        ..moveTo(cx + 3, midY - 7)
        ..quadraticBezierTo(cx - 5, midY - 1, cx + 2, midY + 3)
        ..lineTo(cx + 5, midY + 1)
        ..moveTo(cx + 2, midY + 3)
        ..lineTo(cx + 4, midY + 7);
      canvas.drawPath(path, stroke);
    } else {
      // 八分及更短休止：短线 + 点。
      final Path path = Path()
        ..moveTo(cx + 3, midY - 8)
        ..cubicTo(cx - 4, midY - 2, cx + 4, midY + 2, cx - 2, midY + 7);
      canvas.drawPath(path, stroke);
      canvas.drawCircle(Offset(cx - 2, midY + 8), 1.6, fill);
    }
  }

  void _paintTies(Canvas canvas, MusicStaffRow row) {
    for (final MusicStaffTie tie in layout.ties) {
      if (tie.rowIndex != row.index) continue;
      final double startY = tie.fromY + kMusicStaffHeadHeight / 2 + 1.5;
      final double endY = tie.toY + kMusicStaffHeadHeight / 2 + 1.5;
      if (!tie.visible) {
        // 跨行占位：只画半截虚线，表示连音线在本行继续；不伪造完整弧。
        final Paint stub = Paint()
          ..color = palette.accent.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2;
        canvas.drawLine(
          Offset(tie.fromX + 1, startY + 2),
          Offset(tie.fromX + 7, startY + 2),
          stub,
        );
        continue;
      }
      final Path path = Path()
        ..moveTo(tie.fromX, startY)
        ..quadraticBezierTo(
          (tie.fromX + tie.toX) / 2,
          math.max(tie.fromY, tie.toY) + 9,
          tie.toX,
          endY,
        );
      canvas.drawPath(
        path,
        Paint()
          ..color = palette.accent.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset topLeft, {
    required double fontSize,
    required Color color,
    FontWeight fontWeight = FontWeight.w400,
    bool center = false,
  }) {
    if (text.isEmpty) return;
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: fontWeight,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center ? Offset(topLeft.dx - painter.width / 2, topLeft.dy) : topLeft,
    );
  }

  @override
  bool shouldRepaint(covariant _MusicStaffPainter oldDelegate) =>
      oldDelegate.zoom != zoom ||
      oldDelegate.palette != palette ||
      oldDelegate.highlightTrackIndex != highlightTrackIndex ||
      oldDelegate.layout != layout;
}

// ---------------------------------------------------------------------------
// 只读视图（缩放 50–150% + 水平滚动）
// ---------------------------------------------------------------------------

/// 五线谱视图：默认显示乐谱全部轨道，由 [trackIndex] 可只看一条轨道。
///
/// 默认只读：不写 `score.json`、不改播放面、不画播放头；左侧轨道列表的选中状态
/// 只通过 [selectedTrackIndex] 做行底色强调。给出 [onNoteTap] 后点击谱面只回调
/// [MusicStaffHit]，落盘/校验仍由调用方经编辑出口完成（视图自身不写事实源）。
class MusicStaffView extends StatefulWidget {
  const MusicStaffView({
    super.key,
    required this.score,
    this.trackIndex,
    this.selectedTrackIndex,
    this.onNoteTap,
  });

  final MusicScore score;

  /// 只看某条轨道（null = 全部轨道逐行排列）。
  final int? trackIndex;

  /// 只用于选中行的视觉强调（不改变排版几何）。
  final int? selectedTrackIndex;

  /// 点击谱面命中的回调；null = 保持只读（不装手势、无点击行为）。
  final ValueChanged<MusicStaffHit>? onNoteTap;

  @override
  State<MusicStaffView> createState() => _MusicStaffViewState();
}

class _MusicStaffViewState extends State<MusicStaffView> {
  int _zoomPercent = 100;

  void _changeZoom(int delta) {
    final int next = (_zoomPercent + delta)
        .clamp(kMusicStaffZoomMinPercent, kMusicStaffZoomMaxPercent)
        .toInt();
    if (next == _zoomPercent) return;
    setState(() => _zoomPercent = next);
  }

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    return Container(
      key: const ValueKey('music-staff-view'),
      decoration: BoxDecoration(
        color: p.panel2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(p),
          Divider(height: 1, color: p.line),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double layoutWidth = constraints.hasBoundedWidth
                    ? math.max(0.0, constraints.maxWidth)
                    : kMusicStaffMinWidth;
                final MusicStaffLayout layout = musicStaffLayout(
                  widget.score,
                  width: layoutWidth,
                  trackIndex: widget.trackIndex,
                );
                if (layout.rows.isEmpty) {
                  return _emptyState(p);
                }
                final double zoom = _zoomPercent / 100;
                final double paintWidth = layout.width * zoom;
                final double paintHeight = layout.height * zoom;
                final Widget canvasPaint = CustomPaint(
                  size: Size(paintWidth, paintHeight),
                  painter: _MusicStaffPainter(
                    layout: layout,
                    palette: p,
                    zoom: zoom,
                    highlightTrackIndex: widget.selectedTrackIndex,
                  ),
                );
                final ValueChanged<MusicStaffHit>? onNoteTap = widget.onNoteTap;
                // 只在给了回调时装手势：只读路径（onNoteTap == null）行为不变。
                final Widget painted = onNoteTap == null
                    ? canvasPaint
                    : GestureDetector(
                        key: const ValueKey('music-staff-hit'),
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (TapUpDetails details) {
                          final MusicStaffHit? hit = staffHitTest(
                            layout,
                            details.localPosition,
                            zoom: zoom,
                          );
                          if (hit != null) onNoteTap(hit);
                        },
                        child: canvasPaint,
                      );
                if (!constraints.hasBoundedHeight) {
                  return SingleChildScrollView(
                    key: const ValueKey('music-staff-scroll'),
                    scrollDirection: Axis.horizontal,
                    child: painted,
                  );
                }
                final double viewportWidth = math.max(0.0, layoutWidth);
                final double viewportHeight = math.max(
                  0.0,
                  constraints.maxHeight,
                );
                return SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: SingleChildScrollView(
                    key: const ValueKey('music-staff-scroll'),
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: math.max(paintWidth, viewportWidth),
                      height: math.max(paintHeight, viewportHeight),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: painted,
                      ),
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

  Widget _header(NonPalette p) {
    final String title = widget.score.title.trim();
    final String suffix = widget.onNoteTap == null ? '五线谱只读' : '五线谱 · 点击插入音符';
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
        child: Row(
          children: <Widget>[
            Icon(Icons.music_note_outlined, size: 14, color: p.ink3),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title.isEmpty ? '未命名乐谱 · $suffix' : '$title · $suffix',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: p.ink2),
              ),
            ),
            IconButton(
              key: const ValueKey('music-staff-zoom-out'),
              tooltip: '缩小五线谱',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              onPressed: _zoomPercent > kMusicStaffZoomMinPercent
                  ? () => _changeZoom(-kMusicStaffZoomStepPercent)
                  : null,
              icon: Icon(Icons.remove, color: p.ink3),
            ),
            SizedBox(
              width: 38,
              child: Text(
                '$_zoomPercent%',
                key: const ValueKey('music-staff-zoom'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: p.ink3),
              ),
            ),
            IconButton(
              key: const ValueKey('music-staff-zoom-in'),
              tooltip: '放大五线谱',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              onPressed: _zoomPercent < kMusicStaffZoomMaxPercent
                  ? () => _changeZoom(kMusicStaffZoomStepPercent)
                  : null,
              icon: Icon(Icons.add, color: p.ink3),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(NonPalette p) {
    final String message;
    if (widget.score.tracks.isEmpty) {
      message = '乐谱还没有轨道，五线谱暂时没有可排版的内容。';
    } else if (widget.trackIndex != null) {
      message = '这条轨道还没有小节，五线谱暂时没有可排版的内容。';
    } else {
      message = '乐谱还没有可排版的小节。';
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, height: 1.5, color: p.ink4),
        ),
      ),
    );
  }
}
