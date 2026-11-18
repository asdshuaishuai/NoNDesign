// 视频本地面（批次 08）的契约测试。
//
// 三组不可回退的语义：
//  1. 规范先行：规范缺失/不完整/参数不是数字都在第一帧之前拒绝；
//  2. 符号声明闭包：算式里的自定义名字必须来自 params ∪ formulas（外加
//     t/T/pi/e 与数学函数白名单），语法错误/禁用结构/未知函数/定义域错误
//     全部 fail-closed；
//  3. 确定性渲染与对照：同一份脚本同时间点出同一帧；帧数/时长与旧管线
//     逐字一致；机械对照的节拍覆盖与符号闭包逐条移植。
//
// 外加：示例内嵌常量与 `assets/video/sample/` 文件双向对账；桌面渲染任务
// （假进程注入）的进度/失败路径；手机主机的显式拒绝。
//
// 真实 resvg/ffmpeg 出片是 opt-in：
//   cd app && flutter test --dart-define=VIDEO_RENDER_GATE=true test/video_service_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/video_samples.dart';
import 'package:nondesign/core/video_service.dart';

const bool _renderGate = bool.fromEnvironment('VIDEO_RENDER_GATE');

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

Map<String, dynamic> _science({
  Map<String, dynamic>? params,
  List<dynamic>? formulas,
}) =>
    <String, dynamic>{
      'kind': 'science',
      'subject': '测试主题',
      'laws': <String>['定律一'],
      'assumptions': <String>['假设一'],
      'facts': <String>['事实一'],
      if (params != null) 'params': params,
      if (formulas != null) 'formulas': formulas,
    };

Map<String, dynamic> _screenplay({List<dynamic>? beats}) => <String, dynamic>{
      'kind': 'screenplay',
      'style': '简笔',
      'beats': beats ??
          <dynamic>[
            <String, dynamic>{'at': 0.0, 'what': '开场'},
          ],
    };

Map<String, dynamic> _timeline({
  List<dynamic>? scenes,
  String spec = 'spec.json',
  int fps = 30,
  int width = 640,
  int height = 360,
}) =>
    <String, dynamic>{
      'fps': fps,
      'width': width,
      'height': height,
      'spec': spec,
      'scenes': scenes ??
          <dynamic>[
            <String, dynamic>{
              'duration': 1.0,
              'elements': <dynamic>[
                <String, dynamic>{'type': 'text', 'text': 'hello', 'x': '50%', 'y': 100},
              ],
            },
          ],
    };

VideoDocument _doc({
  Map<String, dynamic>? timeline,
  Map<String, dynamic>? spec,
}) =>
    VideoDocument.build(
      timeline: timeline ?? _timeline(),
      spec: spec ?? _science(),
    );

Matcher _rejects(String code) => throwsA(
      isA<VideoRejected>().having((error) => error.code, 'code', code),
    );

double _eval(String source, {Set<String>? allowed, Map<String, Object>? env}) =>
    VideoExpr.compile(source, allowed ?? <String>{'t', 'T', 'a', 'b', 'v', 'pi', 'e'})
        .evaluate(env ?? const <String, Object>{});

// 1×1 PNG（假光栅化器写盘用）。
final List<int> _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// 假进程：resvg/rsvg-convert 写一张 PNG，ffmpeg 写一个 mp4。
VideoProcessRunner _fakeRunner({
  bool failEncode = false,
  bool failRaster = false,
}) =>
    (executable, arguments) async {
      final name = executable.split('/').last;
      if (name == 'ffmpeg') {
        if (failEncode) {
          return ProcessResult(0, 1, '', 'boom: encoder failed');
        }
        final target = File(arguments.last)..writeAsBytesSync(<int>[0, 0, 0, 24]);
        return ProcessResult(0, 0, 'ok ${target.path}', '');
      }
      if (failRaster) {
        return ProcessResult(0, 1, '', 'boom: raster failed');
      }
      // resvg: <svg> <png> --width … ；rsvg-convert: -o <png> <svg>
      final pngPath = name == 'resvg'
          ? arguments[1]
          : arguments[arguments.indexOf('-o') + 1];
      File(pngPath).writeAsBytesSync(_png);
      return ProcessResult(0, 0, '', '');
    };

VideoService _service(
  Directory root, {
  VideoProcessRunner? runner,
  VideoBinaryResolver? resolver,
  VideoHost host = VideoHost.macos,
}) =>
    VideoService(
      host: host,
      videosRoot: () async => root,
      runner: runner ?? _fakeRunner(),
      binaryResolver: resolver ?? ((name) async => '/usr/local/bin/$name'),
    );

Future<VideoRenderJob> _waitFor(VideoService service, VideoRenderJob job) async {
  var current = job;
  for (var i = 0; i < 300 && current.isRunning; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    current = service.job(job.id) ?? current;
  }
  return current;
}

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('video_service_test');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

Directory _appDir() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('cannot locate app/ from ${Directory.current.path}');
}

// ---------------------------------------------------------------------------
// 规范硬门
// ---------------------------------------------------------------------------

void main() {
  group('规范硬门', () {
    test('时间线没有 spec 字段 → spec_missing', () {
      final timeline = _timeline()..remove('spec');
      expect(() => VideoDocument.build(timeline: timeline, spec: _science()),
          _rejects('spec_missing'));
    });

    test('规范缺失（null 或空文本）→ spec_missing', () {
      expect(() => VideoDocument.build(timeline: _timeline(), spec: null),
          _rejects('spec_missing'));
      expect(
        () => VideoDocument.fromScripts(
          timelineJson: jsonEncode(_timeline()),
          specJson: '   ',
        ),
        _rejects('spec_missing'),
      );
    });

    test('科学规范缺字段 / 空数组 / 类型不对 → spec_invalid', () {
      for (final spec in <Map<String, dynamic>>[
        _science()..remove('subject'),
        _science()..['laws'] = <String>[],
        _science()..['facts'] = '不是数组',
        _science()..['assumptions'] = null,
      ]) {
        expect(() => VideoDocument.build(timeline: _timeline(), spec: spec),
            _rejects('spec_invalid'));
      }
    });

    test('参数不是数字（含布尔）→ spec_invalid；公式缺 name/expr → spec_invalid', () {
      expect(
        () => VideoDocument.build(
          timeline: _timeline(),
          spec: _science(params: <String, dynamic>{'g': '9.8'}),
        ),
        _rejects('spec_invalid'),
      );
      expect(
        () => VideoDocument.build(
          timeline: _timeline(),
          spec: _science(params: <String, dynamic>{'g': true}),
        ),
        _rejects('spec_invalid'),
      );
      expect(
        () => VideoDocument.build(
          timeline: _timeline(),
          spec: _science(formulas: <dynamic>[
            <String, dynamic>{'name': 'a'},
          ]),
        ),
        _rejects('spec_invalid'),
      );
    });

    test('剧本规范缺 style/beats → spec_invalid；未知 kind → spec_invalid', () {
      expect(
        () => VideoDocument.build(
          timeline: _timeline(),
          spec: <String, dynamic>{'kind': 'screenplay', 'beats': <dynamic>[<String, dynamic>{'at': 0}]},
        ),
        _rejects('spec_invalid'),
      );
      expect(
        () => VideoDocument.build(
          timeline: _timeline(),
          spec: _screenplay(beats: <dynamic>[]),
        ),
        _rejects('spec_invalid'),
      );
      expect(
        () => VideoDocument.build(
          timeline: _timeline(),
          spec: <String, dynamic>{'kind': 'unknown'},
        ),
        _rejects('spec_invalid'),
      );
    });

    test('两条规范线都能通过并保留参数与公式', () {
      final science = _doc(
        spec: _science(
          params: <String, dynamic>{'g': 9.8},
          formulas: <dynamic>[
            <String, dynamic>{'name': 'a', 'expr': 'g * 2'},
          ],
        ),
      );
      expect(science.spec.kind, VideoSpecKind.science);
      expect(science.spec.params['g'], 9.8);
      expect(science.spec.formulaSources['a'], 'g * 2');

      final screenplay = _doc(spec: _screenplay());
      expect(screenplay.spec.kind, VideoSpecKind.screenplay);
    });

    test('时间线文件路径解析：规范缺文件 → spec_missing，坏 JSON → spec_invalid', () {
      final dir = _tempDir();
      final timelineFile = File('${dir.path}/timeline.json')
        ..writeAsStringSync(jsonEncode(_timeline(spec: 'spec.json')));
      expect(() => VideoDocument.fromFile(timelineFile), _rejects('spec_missing'));

      File('${dir.path}/spec.json').writeAsStringSync('{not json');
      expect(() => VideoDocument.fromFile(timelineFile), _rejects('spec_invalid'));

      File('${dir.path}/spec.json').writeAsStringSync(jsonEncode(_science()));
      final doc = VideoDocument.fromFile(timelineFile);
      expect(doc.spec.kind, VideoSpecKind.science);
      expect(doc.baseDir?.path, dir.path);
    });

    test('时间线 JSON 本身不合法 → timeline_invalid', () {
      expect(
        () => VideoDocument.fromScripts(timelineJson: '{oops', specJson: jsonEncode(_science())),
        _rejects('timeline_invalid'),
      );
    });
  });

  // -------------------------------------------------------------------------
  // 算式：语法、白名单、定义域
  // -------------------------------------------------------------------------

  group('算式白名单与定义域', () {
    test('基本运算与优先级（Python 语义）', () {
      expect(_eval('1 + 2 * 3'), 7);
      expect(_eval('-2 ** 2'), -4);
      expect(_eval('2 ** 3 ** 2'), 512);
      expect(_eval('7 // 2'), 3);
      expect(_eval('-5 // 2'), -3);
      expect(_eval('5 % 3'), 2);
      expect(_eval('-5 % 3'), 1);
      expect(_eval('2 * -3'), -6);
      expect(_eval('.5 + 1'), 1.5);
    });

    test('数学函数与常量', () {
      expect(_eval('sin(pi / 2)'), closeTo(1, 1e-12));
      expect(_eval('radians(180)'), closeTo(math.pi, 1e-12));
      expect(_eval('sqrt(9)'), 3);
      expect(_eval('min(3, 1, 2)'), 1);
      expect(_eval('max(3, 1, 2)'), 3);
      expect(_eval('pow(2, 10)'), 1024);
      expect(_eval('floor(2.9)'), 2);
      expect(_eval('ceil(2.1)'), 3);
      expect(_eval('atan2(1, 1) * 180 / pi'), closeTo(45, 1e-9));
    });

    test('未声明符号拒绝，声明后放行', () {
      expect(() => _eval('u1 + 1', allowed: <String>{'t'}), _rejects('undeclared_symbol'));
      expect(_eval('u1 + 1', allowed: <String>{'u1'}, env: <String, Object>{'u1': 1.0}), 2);
      // 常量 pi/e 也必须在允许集合里（与旧管线一致：caller 负责加入）。
      expect(() => _eval('pi', allowed: <String>{'t'}), _rejects('undeclared_symbol'));
      expect(_eval('pi', allowed: <String>{'pi'}), closeTo(math.pi, 1e-12));
    });

    test('未知函数 / 禁用结构 / 语法错误', () {
      expect(() => _eval('foo(1)'), _rejects('expr_unknown_function'));
      expect(() => _eval('a < b'), _rejects('expr_forbidden_construct'));
      expect(() => _eval('a[0]'), _rejects('expr_forbidden_construct'));
      expect(() => _eval('a.b'), _rejects('expr_forbidden_construct'));
      expect(() => _eval('{1: 2}'), _rejects('expr_forbidden_construct'));
      expect(() => _eval('1 +'), _rejects('expr_syntax_error'));
      expect(() => _eval('(1 + 2'), _rejects('expr_syntax_error'));
      expect(() => _eval('1x'), _rejects('expr_syntax_error'));
    });

    test('定义域错误 fail-closed（除零/开方/对数/负底数）', () {
      expect(() => _eval('1 / 0'), _rejects('expr_domain_error'));
      expect(() => _eval('1 // 0'), _rejects('expr_domain_error'));
      expect(() => _eval('1 % 0'), _rejects('expr_domain_error'));
      expect(() => _eval('sqrt(-1)'), _rejects('expr_domain_error'));
      expect(() => _eval('log(0)'), _rejects('expr_domain_error'));
      expect(() => _eval('log(-1)'), _rejects('expr_domain_error'));
      expect(() => _eval('(-2) ** 0.5'), _rejects('expr_domain_error'));
      expect(() => _eval('pow(-2, 0.5)'), _rejects('expr_domain_error'));
    });

    test('时间相关公式在求值期展开，不冻结在 T=0', () {
      final doc = VideoDocument.build(
        timeline: _timeline(
          scenes: <dynamic>[
            <String, dynamic>{
              'duration': 2.0,
              'elements': <dynamic>[
                <String, dynamic>{
                  'type': 'text',
                  'textValue': <String, dynamic>{'expr': 'v', 'format': 'v = {:.2f}'},
                  'x': 10,
                  'y': 50,
                },
              ],
            },
          ],
        ),
        spec: _science(
          params: <String, dynamic>{'a': 2.0},
          formulas: <dynamic>[
            <String, dynamic>{'name': 'v', 'expr': 'a * T'},
          ],
        ),
      );
      final atZero = doc.frameSvg(0.0);
      final atOne = doc.frameSvg(1.0);
      expect(atZero, contains('v = 0.00'));
      expect(atOne, contains('v = 2.00'));
    });
  });

  // -------------------------------------------------------------------------
  // 帧与确定性
  // -------------------------------------------------------------------------

  group('帧与确定性', () {
    test('空场景 / 全零时长 → no_scenes / no_frames', () {
      expect(
        () => VideoDocument.build(
          timeline: _timeline(scenes: <dynamic>[]),
          spec: _science(),
        ),
        _rejects('no_scenes'),
      );
      expect(
        () => VideoDocument.build(
          timeline: _timeline(scenes: <dynamic>[
            <String, dynamic>{'duration': 0.0, 'elements': <dynamic>[]},
          ]),
          spec: _science(),
        ),
        _rejects('no_frames'),
      );
    });

    test('同一 (脚本, 规范) 同一时间点出同一帧', () {
      final doc = _doc(
        timeline: _timeline(
          scenes: <dynamic>[
            <String, dynamic>{
              'duration': 1.0,
              'elements': <dynamic>[
                <String, dynamic>{
                  'type': 'rect',
                  'x': <String, dynamic>{'expr': 't * 100'},
                  'y': 10,
                  'w': 10,
                  'h': 10,
                },
              ],
            },
          ],
        ),
      );
      expect(doc.frameSvg(0.37), doc.frameSvg(0.37));
      expect(doc.frameSvg(0.0), isNot(doc.frameSvg(0.5)));
    });

    test('时间线帧数 = 时长 × 帧率（截断），与旧管线一致', () {
      final doc = _doc(
        timeline: _timeline(
          fps: 24,
          scenes: <dynamic>[
            <String, dynamic>{'duration': 1.5, 'elements': <dynamic>[]},
            <String, dynamic>{'duration': 2.0, 'elements': <dynamic>[]},
          ],
        ),
      );
      expect(doc.totalSeconds, closeTo(3.5, 1e-12));
      expect(doc.frameCount(), 84);
      expect(doc.frameCount(10), 35);
    });

    test('入场动画：delay 未到不出元素，百分比/中心解析正确', () {
      final doc = _doc(
        timeline: _timeline(
          width: 640,
          height: 360,
          scenes: <dynamic>[
            <String, dynamic>{
              'duration': 2.0,
              'elements': <dynamic>[
                <String, dynamic>{
                  'type': 'text',
                  'text': 'later',
                  'x': '50%',
                  'y': 'center',
                  'anim': <String, dynamic>{'in': 'fade', 'dur': 0.5, 'delay': 1.0},
                },
              ],
            },
          ],
        ),
      );
      expect(doc.frameSvg(0.2), isNot(contains('later')));
      final shown = doc.frameSvg(1.5);
      expect(shown, contains('later'));
      expect(shown, contains('x="320.0"'));
      expect(shown, contains('y="180.0"'));
    });

    test('文本读数按模板格式化（默认两位小数）', () {
      final doc = _doc(
        timeline: _timeline(
          scenes: <dynamic>[
            <String, dynamic>{
              'duration': 1.0,
              'elements': <dynamic>[
                <String, dynamic>{
                  'type': 'text',
                  'textValue': <String, dynamic>{'expr': 'n'},
                  'x': 10,
                  'y': 20,
                },
                <String, dynamic>{
                  'type': 'text',
                  'textValue': <String, dynamic>{'expr': 'n', 'format': 'n = {:.0f}'},
                  'x': 10,
                  'y': 40,
                },
              ],
            },
          ],
        ),
        spec: _science(params: <String, dynamic>{'n': 7}),
      );
      final svg = doc.frameSvg(0.0);
      expect(svg, contains('>7.00<'));
      expect(svg, contains('>n = 7<'));
    });

    test('orbit / path 运动是绝对位置；linear 是加性偏移', () {
      final orbit = _doc(
        timeline: _timeline(
          scenes: <dynamic>[
            <String, dynamic>{
              'duration': 1.0,
              'elements': <dynamic>[
                <String, dynamic>{
                  'type': 'text',
                  'text': 'o',
                  'x': 0,
                  'y': 0,
                  'motion': <String, dynamic>{
                    'type': 'orbit',
                    'cx': 100,
                    'cy': 50,
                    'r': 10,
                    'omega': 0,
                  },
                },
              ],
            },
          ],
        ),
      );
      // omega=0 → 停在 (cx + r, cy)。
      expect(orbit.frameSvg(0.5), contains('x="110.0"'));
      expect(orbit.frameSvg(0.5), contains('y="50.0"'));

      final linear = _doc(
        timeline: _timeline(
          scenes: <dynamic>[
            <String, dynamic>{
              'duration': 1.0,
              'elements': <dynamic>[
                <String, dynamic>{
                  'type': 'text',
                  'text': 'l',
                  'x': 10,
                  'y': 10,
                  'motion': <String, dynamic>{'type': 'linear', 'vx': 20, 'vy': 0},
                },
              ],
            },
          ],
        ),
      );
      expect(linear.frameSvg(0.5), contains('x="20.0"'));
    });
  });

  // -------------------------------------------------------------------------
  // 机械对照
  // -------------------------------------------------------------------------

  group('机械对照', () {
    test('三个内置示例全部通过对照，片长与帧数与旧管线一致', () {
      final service = VideoService(host: VideoHost.macos);
      const expected = <String, (double, int)>{
        'physics-friction': (8.0, 240),
        'bio-mitosis': (10.0, 300),
        'art-sketch': (5.0, 150),
      };
      for (var i = 0; i < service.samples.length; i++) {
        final sample = service.samples[i];
        final doc = service.loadSample(i);
        final review = service.review(timeline: doc.timeline, spec: doc.spec.raw);
        expect(review.ok, isTrue, reason: '${sample.id}: ${review.problems}');
        expect(doc.totalSeconds, expected[sample.id]!.$1, reason: sample.id);
        expect(doc.frameCount(), expected[sample.id]!.$2, reason: sample.id);
        // 对照材料：6 个均匀时间点，含 0 与片长内最后一段。
        expect(review.sampleTimes.length, 6);
        expect(review.sampleTimes.first, 0);
        expect(review.sampleTimes.last, closeTo(doc.totalSeconds * 5 / 6, 1e-3));
      }
    });

    test('未声明符号聚合上报（不抛异常）', () {
      final timeline = _timeline(
        scenes: <dynamic>[
          <String, dynamic>{
            'duration': 1.0,
            'elements': <dynamic>[
              <String, dynamic>{'type': 'text', 'text': 'x', 'x': <String, dynamic>{'expr': 'ghost + 1'}, 'y': 10},
            ],
          },
        ],
      );
      final review = reviewVideoScript(timeline: timeline, spec: _science());
      expect(review.ok, isFalse);
      expect(review.problems.join('\n'), contains('ghost'));
      expect(review.technical.join('\n'), contains('undeclared_symbol'));
    });

    test('剧本节拍超出片长 → FAIL；科学故事板幕数只作提示', () {
      final screenplay = reviewVideoScript(
        timeline: _timeline(scenes: <dynamic>[
          <String, dynamic>{'duration': 1.0, 'elements': <dynamic>[]},
        ]),
        spec: _screenplay(beats: <dynamic>[
          <String, dynamic>{'at': 0.5, 'what': '开场'},
          <String, dynamic>{'at': 9.0, 'what': '结尾'},
        ]),
      );
      expect(screenplay.ok, isFalse);
      expect(screenplay.problems.join(), contains('第 2 个节拍落在片长之外'));

      final science = reviewVideoScript(
        timeline: _timeline(scenes: <dynamic>[
          <String, dynamic>{'duration': 1.0, 'elements': <dynamic>[]},
        ]),
        spec: <String, dynamic>{
          ..._science(),
          'storyboard': <dynamic>[
            <String, dynamic>{'note': 'a', 'duration': 1},
            <String, dynamic>{'note': 'b', 'duration': 1},
          ],
        },
      );
      expect(science.ok, isTrue);
      expect(science.notes.join(), contains('规范里写了 2 幕'));
    });

    test('规范缺失的对照不抛异常，给一句人话', () {
      final review = reviewVideoScript(timeline: _timeline(), spec: null);
      expect(review.ok, isFalse);
      expect(review.problems.single, '这份脚本还缺一份说明规范，先补齐规范再渲染');
      expect(review.output, isNot(contains('spec_missing')));
    });
  });

  // -------------------------------------------------------------------------
  // 示例资产对账
  // -------------------------------------------------------------------------

  group('示例与资产', () {
    test('内嵌示例与 assets/video/sample 文件逐字一致（结构相等）', () {
      final assets = Directory('${_appDir().path}/assets/video/sample');
      expect(assets.existsSync(), isTrue);
      expect(videoSamples, isNotEmpty);
      for (final sample in videoSamples) {
        final timelineFile = File('${assets.path}/${sample.id}/timeline.json');
        final specFile = File('${assets.path}/${sample.id}/${sample.specName}');
        expect(timelineFile.existsSync(), isTrue, reason: sample.id);
        expect(specFile.existsSync(), isTrue, reason: sample.id);
        final embeddedTimeline = jsonDecode(sample.timelineJson);
        final fileTimeline = jsonDecode(timelineFile.readAsStringSync());
        expect(embeddedTimeline, equals(fileTimeline), reason: '${sample.id}/timeline.json');
        expect(
          jsonDecode(sample.specJson),
          equals(jsonDecode(specFile.readAsStringSync())),
          reason: '${sample.id}/${sample.specName}',
        );
        expect((embeddedTimeline as Map)['spec'], sample.specName);
      }
    });

    test('失败提示全部是人话：不出现裸代号', () {
      const codes = <String>[
        'spec_missing',
        'spec_invalid',
        'no_scenes',
        'no_frames',
        'undeclared_symbol',
        'expr_syntax_error',
        'expr_unknown_function',
        'expr_domain_error',
        'render_desktop_only',
        'rasterizer_missing',
        'encoder_missing',
        'render_failed',
        'job_missing',
        'timeline_invalid',
        'unknown_code',
      ];
      final bareCode = RegExp(r'^[a-z0-9]+(_[a-z0-9]+)+$');
      for (final code in codes) {
        final message = videoFailureMessage(VideoRejected(code));
        expect(message.trim(), isNotEmpty, reason: code);
        expect(bareCode.hasMatch(message), isFalse, reason: code);
        expect(message, isNot(contains(code)), reason: code);
      }
    });
  });

  // -------------------------------------------------------------------------
  // 渲染任务
  // -------------------------------------------------------------------------

  group('渲染任务', () {
    test('手机/平板：显式拒绝（不 spawn、不落盘）', () async {
      final service = _service(_tempDir(), host: VideoHost.ios);
      await expectLater(service.startRender(_doc()), _rejects('render_desktop_only'));
    });

    test('缺少光栅化/编码组件：渲染前干净拒绝', () async {
      final rasterMissing = _service(
        _tempDir(),
        resolver: (name) async => name == 'ffmpeg' ? '/usr/local/bin/ffmpeg' : null,
      );
      await expectLater(rasterMissing.startRender(_doc()), _rejects('rasterizer_missing'));

      final encoderMissing = _service(
        _tempDir(),
        resolver: (name) async => name == 'ffmpeg' ? null : '/usr/local/bin/resvg',
      );
      await expectLater(encoderMissing.startRender(_doc()), _rejects('encoder_missing'));
    });

    test('渲染成功：逐帧进度推进到完成，产物落 <root>/<job>/frames.mp4', () async {
      final root = _tempDir();
      final service = _service(root);
      final doc = _doc(
        timeline: _timeline(
          fps: 10,
          scenes: <dynamic>[
            <String, dynamic>{'duration': 1.0, 'elements': <dynamic>[]},
          ],
        ),
      );
      final started = await service.startRender(doc);
      expect(started.totalFrames, 10);
      expect(started.status, VideoJobStatus.running);

      final done = await _waitFor(service, started);
      expect(done.status, VideoJobStatus.done);
      expect(done.frames, 10);
      expect(done.mp4Path, endsWith('/frames.mp4'));
      expect(File(done.mp4Path!).existsSync(), isTrue);
      expect(done.mp4Path, startsWith(root.path));
      // 帧文件保留（预览条带直接读本机文件）；SVG 已被清掉。
      expect(File('${done.directory}/frame_00000.png').existsSync(), isTrue);
      expect(File('${done.directory}/frame_00000.svg').existsSync(), isFalse);
      expect(service.job(done.id), isNotNull);
      expect(service.job('nope'), isNull);
    });

    test('编码失败：任务标记失败并保留诊断日志', () async {
      final service = _service(_tempDir(), runner: _fakeRunner(failEncode: true));
      final started = await service.startRender(_doc());
      final failed = await _waitFor(service, started);
      expect(failed.status, VideoJobStatus.failed);
      expect(failed.failureCode, 'render_failed');
      expect(failed.log, contains('boom'));
      expect(videoFailureMessage(failed.failureCode), '视频没有渲染完成，请重试');
    });

    test('光栅化失败：同样落 failed，不产出成片', () async {
      final root = _tempDir();
      final service = _service(root, runner: _fakeRunner(failRaster: true));
      final started = await service.startRender(_doc());
      final failed = await _waitFor(service, started);
      expect(failed.status, VideoJobStatus.failed);
      expect(failed.mp4Path, isNull);
    });

    test('取消：帧间停下，状态为 cancelled', () async {
      final service = _service(_tempDir());
      final doc = _doc(
        timeline: _timeline(
          fps: 10,
          scenes: <dynamic>[
            <String, dynamic>{'duration': 2.0, 'elements': <dynamic>[]},
          ],
        ),
      );
      final started = await service.startRender(doc);
      service.cancel(started.id);
      final settled = await _waitFor(service, started);
      expect(
        settled.status,
        anyOf(VideoJobStatus.cancelled, VideoJobStatus.done),
        reason: '取消是帧间检查：已经跑完则允许 done',
      );
      if (settled.status == VideoJobStatus.cancelled) {
        expect(settled.mp4Path, isNull);
      }
    });

    test('渲染门与帧数：零帧直接拒绝', () async {
      final doc = _doc(
        timeline: _timeline(
          fps: 10,
          scenes: <dynamic>[
            <String, dynamic>{'duration': 1.0, 'elements': <dynamic>[]},
          ],
        ),
      );
      final service = _service(_tempDir());
      await expectLater(service.startRender(doc, fps: 0), _rejects('no_frames'));
    });
  });

  // -------------------------------------------------------------------------
  // 真实出片（opt-in：本机 resvg + ffmpeg）
  // -------------------------------------------------------------------------

  group('真实出片', () {
    test('本机渲染组件存在并可出片（VIDEO_RENDER_GATE=true 时执行）', () async {
      if (!_renderGate) {
        // ignore: avoid_print
        print('[video] VIDEO_RENDER_GATE 未开启：跳过真实出片（用 --dart-define=VIDEO_RENDER_GATE=true 执行）');
        return;
      }
      final root = _tempDir();
      final service = VideoService(host: VideoHost.macos, videosRoot: () async => root);
      final binaries = await service.resolveBinaries();
      expect(binaries.canRender, isTrue,
          reason: '需要本机安装 resvg（或 rsvg-convert）与 ffmpeg');
      final doc = _doc(
        timeline: _timeline(
          fps: 6,
          width: 320,
          height: 180,
          scenes: <dynamic>[
            <String, dynamic>{
              'duration': 0.5,
              'elements': <dynamic>[
                <String, dynamic>{'type': 'rect', 'x': 20, 'y': 40, 'w': 120, 'h': 80, 'color': '#FFB65C'},
              ],
            },
          ],
        ),
      );
      final started = await service.startRender(doc);
      final done = await _waitFor(service, started);
      expect(done.status, VideoJobStatus.done, reason: done.log);
      expect(done.frames, 3);
      expect(File(done.mp4Path!).existsSync(), isTrue);
      expect(File(done.mp4Path!).lengthSync(), greaterThan(0));
    });
  });
}

