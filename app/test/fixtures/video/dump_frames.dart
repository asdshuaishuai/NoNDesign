// 黄金对照的 Dart 侧导出器（批次 08）。
//
// 用 `dart run` 直接跑（不依赖 Flutter 绑定）：`video_service.dart` 是纯 Dart，
// 因此 Python 侧的参考实现（仓库里还存在时）与 Dart 侧可以对同一份示例、
// 同一组时间点逐帧比对 SVG。
//
// 用法（在 `app/` 下）：
//   dart run test/fixtures/video/dump_frames.dart --out /tmp/dart-video.json
//   dart run test/fixtures/video/dump_frames.dart --out /tmp/dart-video.json \
//       --points 0,0.5,1.25,3.5,7.9
//
// 输出形状见 `scripts/wf/video_golden_check.py` 的 `load_dart_dump`。
import 'dart:convert';
import 'dart:io';

import 'package:nondesign/core/video_service.dart';
import 'package:nondesign/core/video_samples.dart';

void main(List<String> args) {
  var outPath = '';
  var points = <double>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--out' && i + 1 < args.length) {
      outPath = args[i + 1];
      i++;
    } else if (args[i] == '--points' && i + 1 < args.length) {
      points = args[i + 1]
          .split(',')
          .map((value) => double.tryParse(value.trim()) ?? 0)
          .toList();
      i++;
    }
  }
  if (outPath.isEmpty) {
    stderr.writeln('用法：dart run test/fixtures/video/dump_frames.dart --out <path> [--points a,b,c]');
    exitCode = 2;
    return;
  }

  final service = VideoService(host: VideoHost.macos);
  final samples = <Map<String, dynamic>>[];
  for (var index = 0; index < videoSamples.length; index++) {
    final sample = videoSamples[index];
    final document = service.loadSample(index);
    final review = service.review(
      timeline: document.timeline,
      spec: document.spec.raw,
    );
    final times = points.isEmpty
        ? <double>[
            0,
            document.totalSeconds * 0.25,
            document.totalSeconds * 0.5,
            document.totalSeconds * 0.75,
            document.totalSeconds,
          ]
        : points.where((time) => time <= document.totalSeconds).toList();
    samples.add(<String, dynamic>{
      'id': sample.id,
      'fps': document.fps,
      'width': document.width,
      'height': document.height,
      'total_seconds': document.totalSeconds,
      'frames': document.frameCount(),
      'review_ok': review.ok,
      'review_problems': review.problems,
      'frame_svgs': <Map<String, dynamic>>[
        for (final time in times) <String, dynamic>{'t': time, 'svg': document.frameSvg(time)},
      ],
    });
  }

  File(outPath).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'generator': 'app/test/fixtures/video/dump_frames.dart',
      'samples': samples,
    }),
  );
  stdout.writeln('wrote $outPath (${samples.length} samples)');
}
