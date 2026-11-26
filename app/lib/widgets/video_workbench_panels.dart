/// 视频工作台的内容区专属面板：剧本/镜头树 + 镜头检查器 + 底部时间线。
///
/// 2026-11-24 工作台独立适配（UI-3 首批）：视频不再只是「预览 + 一条运输条」，
/// 而是导演台姿态——左侧剧本/镜头树、中间预览、底部镜头时间线、右侧镜头检查器。
/// 共享外壳（TitleBar/Rail/右 chat/StatusBar）仍由外层提供；本文件不承载 Agent。
library;

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import 'video_animation_surface.dart';

/// 一个镜头（timeline.scenes[i] 的只读视图）。
final class VideoShotItem {
  const VideoShotItem({
    required this.index,
    required this.label,
    required this.start,
    required this.duration,
    this.background = '',
    this.elementCount = 0,
    this.data = const <String, Object?>{},
  });

  final int index;
  final String label;

  /// 全局起始秒（由前面镜头时长累加；不依赖场景内部时间）。
  final double start;
  final double duration;
  final String background;
  final int elementCount;
  final Map<String, Object?> data;

  double get end => start + duration;
}

/// 从 timeline 投影镜头列表；坏场景跳过，不炸整条时间线。
List<VideoShotItem> videoShotsFromTimeline(Map<String, dynamic>? timeline) {
  if (timeline == null) return const <VideoShotItem>[];
  final Object? scenes = timeline['scenes'];
  if (scenes is! List) return const <VideoShotItem>[];
  final List<VideoShotItem> shots = <VideoShotItem>[];
  double cursor = 0;
  for (final Object? raw in scenes) {
    if (raw is! Map) continue;
    final double duration = switch (raw['duration']) {
      final num value when value.isFinite && value >= 0 => value.toDouble(),
      _ => 0,
    };
    final Map<String, Object?> data = Map<String, Object?>.from(raw);
    final String label = (raw['title'] ?? raw['name'] ?? raw['caption'] ?? '')
        .toString()
        .trim();
    final Object? elements = raw['elements'];
    shots.add(
      VideoShotItem(
        index: shots.length,
        label: label.isEmpty ? '镜头 ${shots.length + 1}' : label,
        start: cursor,
        duration: duration,
        background: (raw['background'] ?? '').toString(),
        elementCount: elements is List ? elements.length : 0,
        data: data,
      ),
    );
    cursor += duration;
  }
  return shots;
}

/// 面板头统一几何（视频导演台三栏；3D 视频项目列表/检查器沿用同一套规格）。
///
/// 2026-11-26 工作台内部整理：把「随机字号 + 随机内边距」的面板头收敛为一套
/// 固定层级——高度 34、水平内边距 NonSpace.md、标题 NonType.bodyStrong（w600）、
/// 右侧计数/状态 NonType.micro。避免同层面板头在不同工作台里高低/字号不一。
abstract final class VideoPanelMetrics {
  /// 小面板头高度（46px 内容工具条之下统一 34）。
  static const double headerHeight = 34;

  /// 面板列表行高（带 itemExtent 的列表不再逐帧测量子项）。
  static const double listRowExtent = 34;
}

/// 面板标题头（左图标 + 标题 + 可选计数/尾部动作）。
///
/// 静态标题可直接 `const VideoPanelHeader(...)` 构造，头部子树不进每帧重建。
class VideoPanelHeader extends StatelessWidget {
  const VideoPanelHeader({
    super.key,
    required this.icon,
    required this.title,
    this.meta,
    this.trailing,
  });

  final IconData icon;
  final String title;

  /// 右侧次要读数（计数/状态），统一 micro 字阶。
  final String? meta;

  /// 右侧动作（刷新/新建等），由调用方给出，不在此处内联业务逻辑。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    return SizedBox(
      height: VideoPanelMetrics.headerHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: NonSpace.md),
        child: Row(
          children: <Widget>[
            Icon(icon, size: NonType.body, color: p.ink4),
            const SizedBox(width: NonSpace.xs),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: NonType.bodyStrong,
                  fontWeight: FontWeight.w600,
                  color: p.ink,
                ),
              ),
            ),
            if (meta != null) ...<Widget>[
              const SizedBox(width: NonSpace.xs),
              Text(
                meta!,
                style: TextStyle(fontSize: NonType.micro, color: p.ink4),
              ),
            ],
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 左侧剧本/镜头树（视频专属；不复用设计左栏）。
class VideoScriptTree extends StatelessWidget {
  const VideoScriptTree({
    super.key,
    required this.shots,
    this.selectedIndex,
    required this.onSelect,
  });

  final List<VideoShotItem> shots;
  final int? selectedIndex;
  final ValueChanged<VideoShotItem> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('video-workbench-script-tree'),
      color: p.bgElevated.withValues(alpha: 0.9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          VideoPanelHeader(
            icon: Icons.reorder_outlined,
            title: '剧本 / 镜头',
            meta: '${shots.length}',
          ),
          Divider(height: 1, color: p.line),
          Expanded(
            child: shots.isEmpty
                ? Center(
                    child: Text(
                      '还没有镜头',
                      style: TextStyle(
                        fontSize: NonType.caption,
                        color: p.ink4,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: NonSpace.xs),
                    itemExtent: VideoPanelMetrics.listRowExtent,
                    itemCount: shots.length,
                    itemBuilder: (context, index) {
                      final shot = shots[index];
                      final active = shot.index == selectedIndex;
                      return InkWell(
                        key: ValueKey('video-shot-${shot.index}'),
                        borderRadius: BorderRadius.circular(NonRadius.md),
                        onTap: () => onSelect(shot),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: NonSpace.sm,
                            vertical: NonSpace.xs,
                          ),
                          child: Row(
                            children: <Widget>[
                              Text(
                                '${shot.index + 1}',
                                style: TextStyle(
                                  fontSize: NonType.micro,
                                  fontFamily: 'Menlo',
                                  color: active ? p.accent : p.ink4,
                                ),
                              ),
                              const SizedBox(width: NonSpace.sm),
                              Expanded(
                                child: Text(
                                  shot.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: NonType.body,
                                    color: active ? p.ink : p.ink2,
                                    fontWeight: active
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                              Text(
                                '${shot.duration.toStringAsFixed(shot.duration >= 10 ? 0 : 1)}s',
                                style: TextStyle(
                                  fontSize: NonType.micro,
                                  color: p.ink4,
                                ),
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

/// 右侧镜头检查器（视频专属）。
class VideoShotInspector extends StatelessWidget {
  const VideoShotInspector({
    super.key,
    this.shot,
    this.title = '',
    this.fps = 0,
    this.totalSeconds = 0,
    this.shotCount = 0,
    this.readOnly = false,
  });

  final VideoShotItem? shot;
  final String title;
  final int fps;
  final double totalSeconds;
  final int shotCount;

  /// 只读形态：宽屏（右栏常驻）时右侧共享窄栏的「检查」tab 是唯一编辑入口，
  /// 内容区这块检查器降级为只读摘要，避免同一属性两处可编辑却不同步；
  /// 窄屏/独立面板保持原样（本检查器本身仍只做展示）。
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final shot = this.shot;
    return Container(
      key: const ValueKey('video-workbench-inspector'),
      color: p.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const VideoPanelHeader(
            icon: Icons.movie_filter_outlined,
            title: '镜头检查器',
          ),
          Divider(height: 1, color: p.line),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(NonSpace.md),
              child: shot == null
                  ? _overview(p)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          shot.label,
                          style: TextStyle(
                            fontSize: NonType.bodyStrong,
                            fontWeight: FontWeight.w700,
                            color: p.ink,
                          ),
                        ),
                        const SizedBox(height: NonSpace.xs),
                        Text(
                          '镜头 ${shot.index + 1} · ${_timeRange(shot)}',
                          style: TextStyle(
                            fontSize: NonType.micro,
                            color: p.ink4,
                          ),
                        ),
                        const SizedBox(height: NonSpace.md),
                        _kv(p, '时长', '${shot.duration.toStringAsFixed(2)} 秒'),
                        if (shot.background.isNotEmpty)
                          _kv(p, '背景', shot.background),
                        _kv(p, '元素', '${shot.elementCount}'),
                        if (shot.data['transition'] != null)
                          _kv(p, '转场', '${shot.data['transition']}'),
                        if (shot.data['camera'] != null)
                          _kv(p, '镜头', '${shot.data['camera']}'),
                        const SizedBox(height: NonSpace.sm),
                        Text(
                          readOnly
                              ? '宽屏下请到右侧「检查」面板改镜头属性；这里只读。'
                              : '镜头属性编辑在剧本编译器批次接入；本检查器当前只读。',
                          key: readOnly
                              ? const ValueKey(
                                  'video-workbench-inspector-readonly-hint',
                                )
                              : null,
                          style: TextStyle(
                            fontSize: NonType.micro,
                            height: NonType.lineBody,
                            color: p.ink4,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _overview(NonPalette p) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        '项目概览',
        style: TextStyle(
          fontSize: NonType.bodyStrong,
          fontWeight: FontWeight.w700,
          color: p.ink,
        ),
      ),
      const SizedBox(height: NonSpace.md),
      _kv(p, '标题', title.isEmpty ? '—' : title),
      _kv(p, '镜头', '$shotCount'),
      _kv(p, '片长', '${totalSeconds.toStringAsFixed(2)} 秒'),
      _kv(p, '帧率', fps <= 0 ? '—' : '$fps'),
      const SizedBox(height: NonSpace.sm),
      Text(
        '在左侧选择镜头查看时长/背景/元素。',
        style: TextStyle(fontSize: NonType.micro, color: p.ink4),
      ),
    ],
  );

  static String _timeRange(VideoShotItem shot) =>
      '${shot.start.toStringAsFixed(2)}–${shot.end.toStringAsFixed(2)}s';

  Widget _kv(NonPalette p, String key, String value) => Padding(
    padding: const EdgeInsets.only(bottom: NonSpace.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 60,
          child: Text(
            key,
            style: TextStyle(fontSize: NonType.micro, color: p.ink4),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: NonType.caption,
              color: p.ink2,
              height: NonType.lineCaption,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 底部镜头时间线（视频专属；按场景时长比例排布）。
///
/// 共享播放头只读呈现：播放/暂停控制在预览播放器里；本栏显示时间、播放状态
/// 与当前播放头在镜头条上的位置，供导演台对齐。
///
/// 高度由外层 `WorkbenchLayout.bottomBarHeight` 驱动（[height] 缺省 92 仅给
/// 独立面板测试用）；不在 widget 里再写死第二份魔法数。
class VideoTimelineStrip extends StatelessWidget {
  const VideoTimelineStrip({
    super.key,
    required this.shots,
    this.selectedIndex,
    required this.onSelect,
    this.fps = 0,
    this.playheadSeconds = 0,
    this.playing = false,
    this.controller,
    this.height = 92.0,
  });

  final List<VideoShotItem> shots;
  final int? selectedIndex;
  final ValueChanged<VideoShotItem> onSelect;
  final int fps;
  final double playheadSeconds;
  final bool playing;

  /// 导演台外部运输条控制器（null = 只读指示，不假装可点）。
  final VideoAnimationController? controller;

  /// 底部时间线高度（导演台由 WorkbenchLayout 规格传入）。
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final total = shots.fold<double>(0, (sum, shot) => sum + shot.duration);
    final playhead = total <= 0
        ? 0.0
        : playheadSeconds.clamp(0.0, total) / total;
    return Container(
      key: const ValueKey('video-workbench-timeline'),
      height: height,
      padding: const EdgeInsets.fromLTRB(
        NonSpace.md,
        NonSpace.sm,
        NonSpace.md,
        NonSpace.sm,
      ),
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (controller == null)
                Icon(
                  playing
                      ? Icons.pause_circle_outline
                      : Icons.play_circle_outline,
                  size: 13,
                  color: p.ink4,
                )
              else
                IconButton(
                  key: const ValueKey('video-transport-play'),
                  onPressed: controller!.togglePlay,
                  tooltip: playing ? '暂停' : '播放',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    playing
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                    color: p.ink3,
                  ),
                ),
              const SizedBox(width: NonSpace.sm),
              Text(
                '时间线',
                style: TextStyle(fontSize: NonType.caption, color: p.ink3),
              ),
              const SizedBox(width: NonSpace.sm),
              Text(
                _formatSeconds(playheadSeconds),
                key: const ValueKey('video-timeline-playhead'),
                style: TextStyle(
                  fontSize: NonType.micro,
                  fontFamily: 'Menlo',
                  color: p.ink4,
                ),
              ),
              const Spacer(),
              Text(
                '${total.toStringAsFixed(1)}s · ${fps <= 0 ? '—' : '$fps fps'}',
                style: TextStyle(fontSize: NonType.micro, color: p.ink4),
              ),
            ],
          ),
          const SizedBox(height: NonSpace.sm),
          Expanded(
            child: total <= 0
                ? Center(
                    child: Text(
                      '没有可排布的镜头',
                      style: TextStyle(fontSize: NonType.micro, color: p.ink4),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) => Stack(
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            for (final shot in shots)
                              Expanded(
                                flex: (shot.duration * 1000).round().clamp(
                                  1,
                                  1 << 30,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: NonSpace.xxs,
                                  ),
                                  child: InkWell(
                                    key: ValueKey(
                                      'video-timeline-shot-${shot.index}',
                                    ),
                                    borderRadius: BorderRadius.circular(
                                      NonRadius.sm,
                                    ),
                                    onTap: () => onSelect(shot),
                                    child: Container(
                                      alignment: Alignment.centerLeft,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: NonSpace.sm,
                                      ),
                                      decoration: BoxDecoration(
                                        color: shot.index == selectedIndex
                                            ? p.accent.withValues(alpha: 0.24)
                                            : p.panel2,
                                        borderRadius: BorderRadius.circular(
                                          NonRadius.sm,
                                        ),
                                        border: Border.all(
                                          color: shot.index == selectedIndex
                                              ? p.accent
                                              : p.line,
                                        ),
                                      ),
                                      child: Text(
                                        '${shot.index + 1}',
                                        maxLines: 1,
                                        style: TextStyle(
                                          fontSize: NonType.micro,
                                          color: shot.index == selectedIndex
                                              ? p.ink
                                              : p.ink3,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        Positioned(
                          left: (constraints.maxWidth * playhead).clamp(
                            0.0,
                            constraints.maxWidth - 2,
                          ),
                          top: 0,
                          bottom: 0,
                          child: Container(width: 2, color: p.accent),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

String _formatSeconds(double seconds) {
  final total = seconds < 0 ? 0.0 : seconds;
  final minutes = total ~/ 60;
  final rest = total - minutes * 60;
  final restText = rest.toStringAsFixed(3).padLeft(6, '0'); // 00.000
  return '${minutes.toString().padLeft(2, '0')}:$restText';
}
