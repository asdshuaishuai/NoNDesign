/// 代码动画播放面。
///
/// 视频模块不是「先渲染成 mp4 再播放」：时间线脚本 + 规范在 [VideoDocument]
/// 里编译成算式，任意时刻 t 的整帧画面由 [VideoDocument.frameSvg] 现算。这里
/// 直接把这份逐帧画面接到屏幕上——用户点播放，看到的就是代码动画本身，不落
/// 任何成片文件，也不需要外部程序（桌面/手机同一套行为）。
///
/// 约定：
///  * 推进节拍 = 文档帧率（钳在 1–30），用 [Timer.periodic] 而不是重绘回调，
///    低帧率时也能稳定按「帧」走；
///  * 暂停即停表，拖动时间条立即换帧（暂停态也能逐帧看）；
///  * 单帧生成失败（脚本里这一段算式写坏、或画面本身画不出来）只在面板里
///    给一句人话，工作面不崩、播放器不卡死。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme.dart';
import '../core/video_service.dart';

/// 逐帧播放一份 [VideoDocument]。
class VideoAnimationSurface extends StatefulWidget {
  const VideoAnimationSurface({
    super.key,
    required this.document,
    this.fps,
    this.autoplay = false,
    this.loop = true,
    this.onFrame,
  });

  /// 已通过校验、预编译好的脚本。
  final VideoDocument document;

  /// 播放帧率；缺省取文档自己的帧率，两端都钳在 1–30。
  final int? fps;

  /// 打开即播（默认不播：让用户自己点）。
  final bool autoplay;

  /// 循环播放的初始状态。
  final bool loop;

  /// 每换一帧回调一次（时间、0 基帧号），供外部做读数/联动。
  final void Function(double seconds, int frameIndex)? onFrame;

  @override
  State<VideoAnimationSurface> createState() => _VideoAnimationSurfaceState();
}

class _VideoAnimationSurfaceState extends State<VideoAnimationSurface> {
  static const int _minFps = 1;
  static const int _maxFps = 30;

  /// 画面画不出来时的唯一一句人话（不出现实现名/文件格式/错误码）。
  static const String frameProblemMessage = '这一帧没能画出来，检查脚本里这一段的算式';

  Timer? _timer;
  double _t = 0;
  bool _playing = false;
  bool _loop = true;
  bool _resumeAfterScrub = false;
  String _svg = '';
  String _problem = '';

  int get _fps => (widget.fps ?? widget.document.fps).clamp(_minFps, _maxFps);

  double get _duration {
    final total = widget.document.totalSeconds;
    return total.isFinite && total > 0 ? total : 0.001;
  }

  Duration get _period {
    final micros = (1000000 / _fps).round();
    return Duration(microseconds: micros < 1 ? 1 : micros);
  }

  /// 文档按当前帧率一共多少帧（至少 1，片长不足一帧也要能看）。
  int get _totalFrames => math.max(1, widget.document.frameCount(_fps));

  /// 当前时间所在的帧号（0 基）。
  int get _frameIndex {
    final raw = (_t * _fps).floor();
    return raw.clamp(0, _totalFrames - 1);
  }

  /// 界面上显示的帧号（1 基：`frame 1/N` 是片头）。
  int get _frameNumber => _frameIndex + 1;

  @override
  void initState() {
    super.initState();
    _loop = widget.loop;
    _applyFrame(0);
    if (widget.autoplay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _play();
      });
    }
  }

  @override
  void didUpdateWidget(VideoAnimationSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.document, widget.document)) {
      // 换了脚本：停表回到片头，画面立刻换成新文档的第一帧。
      _timer?.cancel();
      _timer = null;
      _playing = false;
      _loop = widget.loop;
      _applyFrame(0);
      return;
    }
    _loop = widget.loop;
    if (oldWidget.fps != widget.fps) {
      _applyFrame(_t);
      if (_playing) _startTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  // ------------------------------------------------------------------ 帧

  /// 生成 [t] 时刻的画面；失败只留一句人话，不抛给上层。
  void _applyFrame(double t) {
    final clamped = t < 0 ? 0.0 : (t > _duration ? _duration : t);
    String svg;
    try {
      svg = widget.document.frameSvg(clamped);
    } catch (_) {
      _t = clamped;
      _svg = '';
      _problem = frameProblemMessage;
      return;
    }
    _t = clamped;
    if (svg.trim().isEmpty || !svg.contains('<svg')) {
      _svg = '';
      _problem = frameProblemMessage;
      return;
    }
    _svg = svg;
    _problem = '';
  }

  void _setTime(double t) {
    setState(() => _applyFrame(t));
    widget.onFrame?.call(_t, _frameIndex);
  }

  // ------------------------------------------------------------------ 播放

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_period, _onTick);
  }

  void _onTick(Timer timer) {
    if (!_playing) {
      timer.cancel();
      return;
    }
    final next = _t + 1 / _fps;
    if (next >= _duration - 1e-9) {
      if (_loop) {
        _setTime(next % _duration);
        return;
      }
      _setTime(_duration);
      _pause();
      return;
    }
    _setTime(next);
  }

  void _play() {
    if (_playing) return;
    setState(() {
      // 停在片尾再点播放：从片头重来，而不是原地不动。
      if (_t >= _duration - 1e-9) _applyFrame(0);
      _playing = true;
    });
    _startTimer();
    widget.onFrame?.call(_t, _frameIndex);
  }

  void _pause() {
    if (!_playing) return;
    _timer?.cancel();
    _timer = null;
    setState(() => _playing = false);
  }

  void _togglePlay() => _playing ? _pause() : _play();

  void _restart() {
    _setTime(0);
    if (_playing) _startTimer();
  }

  void _toggleLoop() => setState(() => _loop = !_loop);

  void _onScrubStart(double _) {
    _resumeAfterScrub = _playing;
    if (_playing) _pause();
  }

  void _onScrubEnd(double _) {
    if (!_resumeAfterScrub) return;
    _resumeAfterScrub = false;
    _play();
  }

  // ------------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('video-animation-surface'),
      decoration: BoxDecoration(
        color: p.panel2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: _framePane(context),
            ),
          ),
          _controls(context),
        ],
      ),
    );
  }

  /// 画面区：按文档宽高比内嵌，任何帧尺寸都不溢出面板。
  Widget _framePane(BuildContext context) {
    if (_problem.isNotEmpty || _svg.isEmpty) return _problemPane(context);
    final document = widget.document;
    final aspect = document.height <= 0 ? 16 / 9 : document.width / document.height;
    return LayoutBuilder(builder: (context, constraints) {
      final maxWidth = constraints.maxWidth.isFinite ? constraints.maxWidth : 640.0;
      final maxHeight = constraints.maxHeight.isFinite ? constraints.maxHeight : 360.0;
      if (maxWidth <= 0 || maxHeight <= 0) return const SizedBox.shrink();
      var width = maxWidth;
      var height = aspect <= 0 ? maxHeight : width / aspect;
      if (height > maxHeight) {
        height = maxHeight;
        width = height * aspect;
      }
      if (width <= 0 || height <= 0) return const SizedBox.shrink();
      return Center(
        child: SizedBox(
          width: width,
          height: height,
          child: ColoredBox(
            color: Colors.black,
            child: SvgPicture.string(
              _svg,
              fit: BoxFit.contain,
              alignment: Alignment.center,
              semanticsLabel: '动画画面',
              // 解析/绘制失败不是崩，是一个可以说清楚的空画面。
              errorBuilder: (context, error, stackTrace) => _problemPane(context),
            ),
          ),
        ),
      );
    });
  }

  Widget _problemPane(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.image_not_supported_outlined, size: 22, color: p.ink4),
          const SizedBox(height: 8),
          Text(
            frameProblemMessage,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: p.ink3, height: 1.5),
          ),
        ]),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 10, 4),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          _iconButton(
            buttonKey: const ValueKey('video-animation-play'),
            icon: _playing ? Icons.pause : Icons.play_arrow,
            tooltip: _playing ? '暂停' : '播放',
            onPressed: _togglePlay,
            active: _playing,
          ),
          _iconButton(
            buttonKey: const ValueKey('video-animation-restart'),
            icon: Icons.replay,
            tooltip: '回到片头',
            onPressed: _restart,
          ),
          _iconButton(
            buttonKey: const ValueKey('video-animation-loop'),
            icon: _loop ? Icons.repeat_on_outlined : Icons.repeat_outlined,
            tooltip: _loop ? '循环播放已开' : '循环播放已关',
            onPressed: _toggleLoop,
            active: _loop,
          ),
          const Spacer(),
          Text(
            'frame $_frameNumber/$_totalFrames',
            key: const ValueKey('video-animation-frame'),
            style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: p.ink4),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                '${formatVideoTime(_t)} / ${formatVideoTime(_duration)}',
                key: const ValueKey('video-animation-time'),
                style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: p.ink3),
              ),
            ),
          ),
        ]),
        SizedBox(
          height: 26,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              key: const ValueKey('video-animation-slider'),
              value: _t.clamp(0.0, _duration),
              min: 0,
              max: _duration,
              activeColor: p.accent,
              inactiveColor: p.line,
              onChangeStart: _onScrubStart,
              onChanged: _setTime,
              onChangeEnd: _onScrubEnd,
            ),
          ),
        ),
      ]),
    );
  }

  Widget _iconButton({
    required Key buttonKey,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    bool active = false,
  }) {
    final p = context.palette;
    return IconButton(
      key: buttonKey,
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      onPressed: onPressed,
      color: active ? p.accent : p.ink3,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }
}
