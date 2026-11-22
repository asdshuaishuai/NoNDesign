// 视频「生成项目」落地面（VideoProjectStore）的行为测试。
//
// 覆盖本任务不可回退的语义：
//  1. 一个项目 = `<视频根>/<name>/` 下 timeline.json / spec.json / video.json，
//     create/list/read/delete 全程可用，read 返回可直接逐帧播放的文档；
//  2. 硬门在**碰磁盘之前**：缺规范、规范非法、脚本没场景/没帧、时间线非法
//     都返回可读机器码，且磁盘上不留 `<root>/<name>`、不留暂存目录；
//  3. 重名拒绝、名字白名单（非法名字一个目录都不建）；
//  4. list 只读元数据：坏项目标 corrupt，不拖垮整张表，隐藏/非法目录不算项目；
//  5. read 重新校验：手改坏规范/时间线如实报 spec_invalid / timeline_invalid；
//  6. VideoProjectEntry 的 JSON 字段稳定（智能体工具信封用）。
//
// 测试一律注入临时目录（`VideoProjectStore(root:)`），不碰真实用户目录。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/video_project.dart';
import 'package:nondesign/core/video_service.dart';

/// 一份最小合规规范（科学线，硬门 1 的四个必填项都在）。
Map<String, dynamic> _scienceSpec({String subject = '测试主题'}) => <String, dynamic>{
      'kind': 'science',
      'subject': subject,
      'laws': <String>['质量守恒'],
      'assumptions': <String>['无空气阻力'],
      'facts': <String>['斜面摩擦因数 0.12'],
    };

/// 一份最小合规时间线（单场景 1 秒、一个文字元素）。
Map<String, dynamic> _timeline({
  double duration = 1.0,
  bool withScenes = true,
  bool withSpecField = false,
}) =>
    <String, dynamic>{
      'fps': 30,
      'width': 1280,
      'height': 720,
      if (withSpecField) 'spec': 'spec.json',
      if (withScenes)
        'scenes': <Map<String, dynamic>>[
          <String, dynamic>{
            'duration': duration,
            'elements': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'text',
                'text': '你好',
                'x': '50%',
                'y': 100,
              },
            ],
          },
        ],
    };

/// 内置示例的文档（给往返用例一份真素材：8 秒、30 帧/秒、science 规范）。
VideoDocument _sampleDoc() => VideoService.instance.loadSample(0);

Future<VideoProjectFailure> _failureOf(Future<Object?> Function() action) async {
  try {
    await action();
  } on VideoProjectFailure catch (error) {
    return error;
  }
  fail('期望抛出 VideoProjectFailure，但调用成功返回了');
}

void main() {
  late Directory tmp;
  late Directory videoRoot;
  late VideoProjectStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('nan-video-project-test-');
    videoRoot = Directory('${tmp.path}/video');
    store = VideoProjectStore(root: videoRoot);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  List<Directory> channelDirs() =>
      videoRoot.existsSync()
          ? videoRoot
              .listSync()
              .whereType<Directory>()
              .toList(growable: false)
          : const <Directory>[];

  test('create/list/read/delete：完整往返，文件布局与规范化正确', () async {
    final sample = _sampleDoc();
    final created = await store.create(
      name: 'friction-demo',
      timeline: sample.timeline,
      spec: sample.spec.raw,
      title: '斜面摩擦力',
    );

    // 落盘后三份文件都在。
    expect(Directory('${videoRoot.path}/friction-demo').existsSync(), isTrue);
    expect(File('${videoRoot.path}/friction-demo/timeline.json').existsSync(), isTrue);
    expect(File('${videoRoot.path}/friction-demo/spec.json').existsSync(), isTrue);
    expect(File('${videoRoot.path}/friction-demo/video.json').existsSync(), isTrue);

    // 稳定 JSON：两空格缩进 + 末尾换行；spec 字段被归一为 spec.json。
    final timelineRaw = File('${videoRoot.path}/friction-demo/timeline.json').readAsStringSync();
    expect(timelineRaw.endsWith('\n'), isTrue);
    final timelineJson = jsonDecode(timelineRaw) as Map<String, dynamic>;
    expect(timelineJson['spec'], 'spec.json');
    expect(timelineJson['scenes'], isA<List<dynamic>>());

    // list 只读元数据：标题 / 片长 / 帧率都对。
    final entries = await store.list();
    expect(entries, hasLength(1));
    expect(entries.single.name, 'friction-demo');
    expect(entries.single.title, '斜面摩擦力');
    expect(entries.single.seconds, closeTo(sample.totalSeconds, 1e-9));
    expect(entries.single.fps, sample.fps);
    expect(entries.single.corrupt, isFalse);

    // read 重新校验并给出可播放文档。
    final snapshot = await store.read('friction-demo');
    expect(snapshot.name, 'friction-demo');
    expect(snapshot.title, '斜面摩擦力');
    expect(snapshot.document.totalSeconds, closeTo(sample.totalSeconds, 1e-9));
    expect(snapshot.document.fps, sample.fps);
    expect(snapshot.dir, '${videoRoot.path}/friction-demo');
    expect(snapshot.timeline['spec'], 'spec.json');
    expect(snapshot.spec['kind'], 'science');
    // 预编译过的文档真的能算出一帧（不是只过了结构校验）。
    expect(snapshot.document.frameSvg(0.0), contains('<svg'));

    // create 的返回值同样可播放。
    expect(created.document.frameSvg(0.5), contains('<svg'));

    await store.delete('friction-demo');
    expect(entriesOf(await store.list()), isEmpty);
    expect(
      (await _failureOf(() => store.read('friction-demo'))).code,
      'no_project',
    );
    expect((await _failureOf(() => store.delete('friction-demo'))).code, 'no_project');
  });

  test('重名拒绝 project_exists：先校验重名，且已有项目不受影响', () async {
    await store.create(name: 'same-name', timeline: _timeline(), spec: _scienceSpec());
    final before = await store.list();

    final failure = await _failureOf(
      () => store.create(name: 'same-name', timeline: _timeline(), spec: _scienceSpec()),
    );
    expect(failure.code, 'project_exists');
    expect(failure.message, contains('同名'));

    final after = await store.list();
    expect(after, hasLength(1));
    expect(after.single.name, before.single.name);
    expect((await store.read('same-name')).document.totalSeconds, 1.0);
  });

  test('非法项目名 invalid_name：空串/分隔符/空格/中文一个目录都不建', () async {
    for (final name in <String>['', '../escape', 'a/b', 'has space', '中文名', r'a\b']) {
      final failure = await _failureOf(
        () => store.create(name: name, timeline: _timeline(), spec: _scienceSpec()),
      );
      expect(failure.code, 'invalid_name', reason: '名字「$name」应被白名单拒绝');
    }
    expect(channelDirs(), isEmpty);
    expect((await store.list()), isEmpty);
  });

  test('缺少规范 spec_missing：spec 缺失或空对象都在写盘前拒绝', () async {
    final nullSpec = await _failureOf(
      () => store.create(name: 'no-spec', timeline: _timeline(), spec: null),
    );
    expect(nullSpec.code, 'spec_missing');
    expect(nullSpec.message, contains('说明规范'));

    final emptySpec = await _failureOf(
      () => store.create(name: 'empty-spec', timeline: _timeline(), spec: const <String, dynamic>{}),
    );
    expect(emptySpec.code, 'spec_missing');

    // 时间线自己声明了 spec 字段也不豁免：没有规范内容照样拒绝。
    final declaredOnly = await _failureOf(
      () => store.create(
        name: 'declared-only',
        timeline: _timeline(withSpecField: true),
        spec: null,
      ),
    );
    expect(declaredOnly.code, 'spec_missing');
    expect(channelDirs(), isEmpty);
  });

  test('规范非法 spec_invalid：kind 不认识 / 缺必填项', () async {
    final badKind = await _failureOf(
      () => store.create(
        name: 'bad-kind',
        timeline: _timeline(),
        spec: const <String, dynamic>{'kind': 'nonsense'},
      ),
    );
    expect(badKind.code, 'spec_invalid');

    final missingFields = await _failureOf(
      () => store.create(
        name: 'missing-fields',
        timeline: _timeline(),
        spec: const <String, dynamic>{'kind': 'science', 'subject': '只有标题'},
      ),
    );
    expect(missingFields.code, 'spec_invalid');
    expect(channelDirs(), isEmpty);
  });

  test('脚本结构硬门：没有场景 no_scenes / 时长为 0 no_frames', () async {
    final noScenes = await _failureOf(
      () => store.create(
        name: 'no-scenes',
        timeline: _timeline(withScenes: false),
        spec: _scienceSpec(),
      ),
    );
    expect(noScenes.code, 'no_scenes');

    final noFrames = await _failureOf(
      () => store.create(
        name: 'no-frames',
        timeline: _timeline(duration: 0),
        spec: _scienceSpec(),
      ),
    );
    expect(noFrames.code, 'no_frames');
    expect(channelDirs(), isEmpty);
  });

  test('时间线非法 timeline_invalid：片长非有限在写盘前拒绝', () async {
    final failure = await _failureOf(
      () => store.create(
        name: 'infinite',
        timeline: <String, dynamic>{
          'fps': 30,
          'scenes': <Map<String, dynamic>>[
            <String, dynamic>{'duration': double.infinity, 'elements': <Object>[]},
          ],
        },
        spec: _scienceSpec(),
      ),
    );
    expect(failure.code, 'timeline_invalid');
    expect(channelDirs(), isEmpty);
  });

  test('失败绝不留半成品：root 下既没有 <name> 也没有暂存目录', () async {
    for (final name in <String>['half-made', 'half-made-2']) {
      String? badCode;
      if (name == 'half-made') {
        badCode = (await _failureOf(
          () => store.create(name: name, timeline: _timeline(), spec: null),
        ))
            .code;
      } else {
        badCode = (await _failureOf(
          () => store.create(
            name: name,
            timeline: _timeline(duration: 0),
            spec: _scienceSpec(),
          ),
        ))
            .code;
      }
      expect(badCode, isNotEmpty);
    }

    // 根目录存在但为空：没有任何项目目录，也没有 `.` 开头的暂存目录。
    expect(channelDirs(), isEmpty);
    final leftovers = videoRoot
        .listSync()
        .map((entity) => entity.path.split(RegExp(r'[/\\]')).last)
        .toList(growable: false);
    expect(leftovers, isEmpty, reason: '校验失败不能触碰磁盘，暂存目录必须清掉');
  });

  test('list：坏项目标 corrupt，不拖垮整张表', () async {
    await store.create(name: 'good-one', timeline: _timeline(), spec: _scienceSpec());

    // 元数据坏掉的目录。
    Directory('${videoRoot.path}/bad-meta').createSync(recursive: true);
    File('${videoRoot.path}/bad-meta/video.json').writeAsStringSync('{ 不是 JSON');
    // 只有目录、没有元数据。
    Directory('${videoRoot.path}/no-meta').createSync(recursive: true);

    final entries = await store.list();
    expect(entries, hasLength(3));
    // 按目录名排序，坏项目降级成 corrupt 行而不是抛异常。
    expect(entries.map((entry) => entry.name).toList(), <String>['bad-meta', 'good-one', 'no-meta']);
    expect(entries[0].corrupt, isTrue);
    expect(entries[0].title, 'bad-meta', reason: '坏项目也要有可展示的名字兜底');
    expect(entries[1].corrupt, isFalse);
    expect(entries[2].corrupt, isTrue);

    // 坏项目不挡好项目读取。
    expect((await store.read('good-one')).document.totalSeconds, 1.0);
  });

  test('list：隐藏目录与不合白名单的目录不是项目', () async {
    for (final name in <String>['.staging-1', 'with space', '中文目录']) {
      Directory('${videoRoot.path}/$name').createSync(recursive: true);
    }
    expect(await store.list(), isEmpty);

    // 正常项目照常出现。
    await store.create(name: 'real', timeline: _timeline(), spec: _scienceSpec());
    final entries = await store.list();
    expect(entries.map((entry) => entry.name).toList(), <String>['real']);
  });

  test('create 归一 spec 字段：时间线没写 spec 也能按 spec.json 落盘', () async {
    await store.create(
      name: 'no-spec-field',
      timeline: _timeline(withSpecField: false),
      spec: _scienceSpec(),
    );
    final raw = jsonDecode(
      File('${videoRoot.path}/no-spec-field/timeline.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(raw['spec'], 'spec.json');
    expect((await store.read('no-spec-field')).document.totalSeconds, 1.0);
  });

  test('标题口径：空标题用项目名兜底，有标题写进元数据与列表', () async {
    await store.create(name: 'untitled', timeline: _timeline(), spec: _scienceSpec());
    await store.create(
      name: 'titled',
      timeline: _timeline(),
      spec: _scienceSpec(subject: '标题主题'),
      title: '人类可读标题',
    );

    final entries = await store.list();
    expect(entries[0].name, 'titled', reason: '按目录名排序');
    expect(entries[0].title, '人类可读标题');
    expect(entries[1].title, 'untitled', reason: '空标题退回项目名');

    final titled = await store.read('titled');
    expect(titled.title, '人类可读标题');
    final untitled = await store.read('untitled');
    expect(untitled.title, 'untitled');
  });

  test('read 重新校验：手改坏规范/时间线如实报 spec_invalid / timeline_invalid', () async {
    await store.create(name: 'hand-edited', timeline: _timeline(), spec: _scienceSpec());

    // 规范被改成不完整。
    File('${videoRoot.path}/hand-edited/spec.json')
        .writeAsStringSync('{"kind": "science"}');
    final specFailure = await _failureOf(() => store.read('hand-edited'));
    expect(specFailure.code, 'spec_invalid');

    // 时间线被改成非 JSON。
    File('${videoRoot.path}/hand-edited/timeline.json')
        .writeAsStringSync('这不是 JSON');
    final timelineFailure = await _failureOf(() => store.read('hand-edited'));
    expect(timelineFailure.code, 'timeline_invalid');

    // list 仍能列出这一行（元数据还在），不会拖垮整表。
    final entries = await store.list();
    expect(entries.single.name, 'hand-edited');
    expect(entries.single.corrupt, isFalse, reason: '元数据没坏，坏的是内容');
  });

  test('read：缺时间线报可读码；规范被指向目录外时按规范非法拒绝', () async {
    Directory('${videoRoot.path}/only-meta').createSync(recursive: true);
    File('${videoRoot.path}/only-meta/video.json').writeAsStringSync('{"title": "只有元数据"}');
    expect((await _failureOf(() => store.read('only-meta'))).code, 'no_project');

    await store.create(name: 'traversal', timeline: _timeline(), spec: _scienceSpec());
    final timelineFile = File('${videoRoot.path}/traversal/timeline.json');
    final decoded = jsonDecode(timelineFile.readAsStringSync()) as Map<String, dynamic>;
    decoded['spec'] = '../outside.json';
    timelineFile.writeAsStringSync(jsonEncode(decoded));
    final failure = await _failureOf(() => store.read('traversal'));
    expect(failure.code, 'spec_invalid');
  });

  test('VideoProjectEntry JSON 稳定：字段名与顺序固定，可 round-trip', () {
    const entry = VideoProjectEntry(
      name: 'stable',
      title: '稳定标题',
      seconds: 3.25,
      fps: 24,
      corrupt: false,
    );
    final json = entry.toJson();
    expect(json.keys.toList(), <String>['name', 'title', 'seconds', 'fps', 'corrupt']);
    expect(json['name'], 'stable');
    expect(json['title'], '稳定标题');
    expect(json['seconds'], 3.25);
    expect(json['fps'], 24);
    expect(json['corrupt'], isFalse);

    final back = VideoProjectEntry.fromJson(json);
    expect(back.name, entry.name);
    expect(back.title, entry.title);
    expect(back.seconds, entry.seconds);
    expect(back.fps, entry.fps);
    expect(back.corrupt, entry.corrupt);

    // corrupt 行缺字段时也要给出安全默认值（不因手改信封崩掉工具）。
    final corrupt = VideoProjectEntry.fromJson(<String, dynamic>{'name': 'broken', 'corrupt': true});
    expect(corrupt.title, '');
    expect(corrupt.seconds, 0);
    expect(corrupt.fps, 30);
    expect(corrupt.corrupt, isTrue);
  });

  test('失败文案：每个机器码都有可行动人话，且不把裸代号当文案', () {
    final codes = <String>[
      'invalid_name',
      'project_exists',
      'no_project',
      'corrupt',
      'spec_missing',
      'spec_invalid',
      'timeline_invalid',
      'no_scenes',
      'no_frames',
      'io_error',
    ];
    for (final code in codes) {
      final message = videoProjectFailureMessage(VideoProjectFailure(code));
      expect(message, isNotEmpty, reason: '$code 必须有用户可见文案');
      expect(message.contains(code), isFalse, reason: '$code 的裸代号不能进文案：$message');
      expect(message.contains('_'), isFalse, reason: '$code 的文案不能带下划线代号：$message');
    }
    // 校验层代号复用视频失败文案（算式写坏有专门说法）。
    expect(
      videoProjectFailureMessage(const VideoProjectFailure('expr_syntax_error')),
      '脚本里有一处算式写错了',
    );
    // 未知代号给通用可重试文案。
    expect(videoProjectFailureMessage('unknown_thing'), contains('重试'));
  });

  test('list 排序稳定与删除后可重建同名项目', () async {
    for (final name in <String>['charlie', 'alpha', 'bravo']) {
      await store.create(name: name, timeline: _timeline(), spec: _scienceSpec());
    }
    final names = (await store.list()).map((entry) => entry.name).toList();
    expect(names, <String>['alpha', 'bravo', 'charlie']);

    await store.delete('bravo');
    expect((await store.list()).map((entry) => entry.name).toList(), <String>['alpha', 'charlie']);

    // 删除后同名重建允许（project_exists 只看当前磁盘）。
    await store.create(name: 'bravo', timeline: _timeline(), spec: _scienceSpec());
    expect((await store.list()).map((entry) => entry.name).toList(), <String>['alpha', 'bravo', 'charlie']);
  });

  test('resolveRoot：注入目录不存在时自动创建，list 空态稳定', () async {
    final missing = Directory('${tmp.path}/not-yet');
    final fresh = VideoProjectStore(root: missing);
    final root = await fresh.resolveRoot();
    expect(root.path, missing.path);
    expect(missing.existsSync(), isTrue);
    expect(await fresh.list(), isEmpty);
  });
}

/// 让「列表里有哪些项目名」的断言读起来更直白。
List<String> entriesOf(List<VideoProjectEntry> entries) =>
    entries.map((entry) => entry.name).toList(growable: false);
