// 工作台文档生成器（`workbench_docs.dart`）的契约测试。
//
// 覆盖本任务不可回退的语义：
//  1. 固定首行：四种工作台文档都以「本文档由项目事实源自动生成…」开头；
//  2. 内容关键行：3D（组件清单/验收项/进度）、视频（总时长/帧率/镜头表）、
//     3D 视频（节点数/镜头表相机/总帧数）、音乐（速度/拍号/调号/轨道表/
//     校验状态）；
//  3. 确定性：同输入两次生成字节相同，且不含时间戳/日期；
//  4. 落盘：`docs.md` 原子写、默认不覆盖（返回 null）、overwrite=true 覆盖、
//     目标被目录占位时显性失败且不破坏其它文件、不留临时文件；
//  5. 读取：`docs.md` 优先、`brief.md` 兜底，空白/缺失/读失败按「没有文档」；
//  6. 空 summary / 未知 kind 不崩（未知 kind 给通用最小文档）；
//  7. 文案门：生成的文档不出现内部术语（Python / server / wasm / DDP / mbt /
//     engine / JSON / localhost / 端口 …）；
//  8. 与事实源的漂移锚点：3D 层名跟 `threePassLabel` 同步、乐器中文名覆盖
//     `musicInstruments` 全部取值。
//
// 全部走系统临时目录，不碰真实用户项目目录、不构造 WebView。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/music/music_score.dart' show musicInstruments;
import 'package:nondesign/core/three_service.dart'
    show ThreePassSpec, threePassLabel, threePasses;
import 'package:nondesign/core/workbench_docs.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const Map<String, Object?> _threeSummary = <String, Object?>{
  'title': '土星',
  'current': 'form',
  'components': <Object?>[
    <String, Object?>{'id': 'planet', 'what': '球体'},
    <String, Object?>{'name': '光环', 'what': '扁平圆环'},
    '尘埃带',
  ],
  'acceptance': <Object?>[
    '行星在场',
    <String, Object?>{'what': '光环可见'},
  ],
  'passes': <Object?>[
    <String, Object?>{'id': 'blockout', 'status': 'verified'},
    <String, Object?>{'id': 'structure', 'status': 'verified'},
    <String, Object?>{'id': 'form', 'status': 'blocked'},
    <String, Object?>{'id': 'material', 'status': 'pending'},
  ],
};

const Map<String, Object?> _videoSummary = <String, Object?>{
  'title': '摩擦力演示',
  'fps': 30,
  'totalSeconds': 7.0,
  'shots': <Object?>[
    <String, Object?>{'duration': 3.5, 'text': '斜面上的滑动摩擦力'},
    <String, Object?>{'duration': 3.5, 'text': '受力分析'},
  ],
};

const Map<String, Object?> _video3dSummary = <String, Object?>{
  'title': '土星环之旅',
  'nodes': 3,
  'totalFrames': 150,
  'shots': <Object?>[
    <String, Object?>{'duration': 5.0, 'camera': 'main'},
    <String, Object?>{
      'duration': 5.0,
      'camera': <String, Object?>{
        'id': 'side',
        'move': <String, Object?>{
          'from': <int>[0, 2, 6],
          'to': <int>[0, 2, 4],
        },
      },
    },
  ],
};

const Map<String, Object?> _musicSummary = <String, Object?>{
  'title': '晨雾',
  'tempo': 120,
  'timeSig': <int>[4, 4],
  'keySig': 'C',
  'tracks': <Object?>[
    <String, Object?>{
      'name': '主旋律',
      'instrument': 'piano',
      'volume': 0.8,
      'measures': <Object?>[
        <String, Object?>{'id': 'm1'},
        <String, Object?>{'id': 'm2'},
        <String, Object?>{'id': 'm3'},
        <String, Object?>{'id': 'm4'},
      ],
    },
    <String, Object?>{
      'name': '低音',
      'instrument': 'bass',
      'volume': 0.5,
      'measures': 4,
    },
  ],
  'verified': true,
};

/// 生成的文档里绝不允许出现的内部术语（`docs/copy-glossary.md` 禁用词）。
const List<String> _forbiddenTerms = <String>[
  'python',
  'server',
  'wasm',
  'ddp',
  'mbt',
  'engine',
  'json',
  'localhost',
  '127.0.0.1',
  '端口',
  'canonical',
  'moonviz',
  'acp',
  'flutter',
  'dart',
  'sqlite',
  'blockout',
  'timeline',
  'resvg',
  'ffmpeg',
];

/// 临时项目目录；测试结束自动递归删除。
Directory _tempDir() {
  final Directory dir = Directory.systemTemp.createTempSync(
    'nan_workbench_docs_test_',
  );
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// 路径最后一段（跨平台比较用，兼容 `\`）。
String _leaf(String path) => path.split(RegExp(r'[/\\]')).last;

/// `dir` 下名字以 `.` 开头的残留（原子写的临时文件都长这样）。
List<String> _hiddenLeftovers(Directory dir) => dir
    .listSync()
    .map((FileSystemEntity entity) => _leaf(entity.path))
    .where((String name) => name.startsWith('.'))
    .toList();

// ---------------------------------------------------------------------------
// 生成：四种 kind 的固定首行与关键内容
// ---------------------------------------------------------------------------

void main() {
  test('固定首行：四种工作台文档都以自动生成声明开头', () {
    final Map<String, Map<String, Object?>> summaries =
        <String, Map<String, Object?>>{
          'three': _threeSummary,
          'video': _videoSummary,
          'video3d': _video3dSummary,
          'music': _musicSummary,
        };
    for (final MapEntry<String, Map<String, Object?>> entry
        in summaries.entries) {
      final String doc = buildWorkbenchDoc(
        kind: entry.key,
        name: entry.key,
        summary: entry.value,
      );
      expect(
        doc.split('\n').first,
        workbenchDocNotice,
        reason: '${entry.key} 的首行必须是固定声明',
      );
      expect(doc.endsWith('\n'), isTrue, reason: '${entry.key} 文档需以换行收尾');
    }
  });

  test('3D 文档：标题/组件清单/验收项/进度（层数 + 层名）', () {
    final String doc = buildWorkbenchDoc(
      kind: 'three',
      name: 'saturn',
      summary: _threeSummary,
    );
    expect(doc, contains('# 土星'));
    expect(doc, contains('## 项目概览'));
    expect(doc, contains('- 类型：3D 场景'));
    expect(doc, contains('- 组件数：3 个'));
    expect(doc, contains('- 验收项数：2 条'));
    expect(doc, contains('- 当前层：造型'));
    expect(doc, contains('## 组件清单'));
    expect(doc, contains('1. 球体'));
    expect(doc, contains('2. 光环（扁平圆环）'));
    expect(doc, contains('3. 尘埃带'));
    expect(doc, contains('## 验收项'));
    expect(doc, contains('- 行星在场'));
    expect(doc, contains('- 光环可见'));
    expect(doc, contains('## 进度'));
    expect(doc, contains('- 已通过 2 / 4 层'));
    expect(doc, contains('- 已通过层：占位、结构'));
    expect(doc, contains('- 未通过层：造型、材质'));
    expect(doc, contains('- 已阻塞层：造型'));
  });

  test('视频文档：标题/总时长/帧率/镜头表（序号 · 时长 · 文本）', () {
    final String doc = buildWorkbenchDoc(
      kind: 'video',
      name: 'friction',
      summary: _videoSummary,
    );
    expect(doc, contains('# 摩擦力演示'));
    expect(doc, contains('- 类型：视频'));
    expect(doc, contains('- 总时长：7 秒'));
    expect(doc, contains('- 帧率：30 帧/秒'));
    expect(doc, contains('- 镜头数：2 个'));
    expect(doc, contains('## 镜头表'));
    expect(doc, contains('| 序号 | 时长 | 文本 |'));
    expect(doc, contains('| 1 | 3.5 秒 | 斜面上的滑动摩擦力 |'));
    expect(doc, contains('| 2 | 3.5 秒 | 受力分析 |'));
  });

  test('3D 视频文档：标题/节点数/镜头表（时长 · 相机）/总帧数', () {
    final String doc = buildWorkbenchDoc(
      kind: 'video3d',
      name: 'saturn-tour',
      summary: _video3dSummary,
    );
    expect(doc, contains('# 土星环之旅'));
    expect(doc, contains('- 类型：3D 视频'));
    expect(doc, contains('- 节点数：3 个'));
    expect(doc, contains('- 镜头数：2 个'));
    expect(doc, contains('- 总帧数：150 帧'));
    expect(doc, contains('## 镜头表'));
    expect(doc, contains('| 序号 | 时长 | 相机 |'));
    expect(doc, contains('| 1 | 5 秒 | main |'));
    expect(doc, contains('| 2 | 5 秒 | side（从 (0, 2, 6) 到 (0, 2, 4)） |'));
  });

  test('音乐文档：标题/速度/拍号/调号/轨道表/校验状态', () {
    final String doc = buildWorkbenchDoc(
      kind: 'music',
      name: 'mist',
      summary: _musicSummary,
    );
    expect(doc, contains('# 晨雾'));
    expect(doc, contains('- 类型：音乐'));
    expect(doc, contains('- 速度：每分钟 120 拍'));
    expect(doc, contains('- 拍号：4/4'));
    expect(doc, contains('- 调号：C'));
    expect(doc, contains('- 轨道数：2 条'));
    expect(doc, contains('## 轨道表'));
    expect(doc, contains('| 序号 | 名称 | 乐器 | 音量 | 小节数 |'));
    expect(doc, contains('| 1 | 主旋律 | 钢琴 | 80% | 4 |'));
    expect(doc, contains('| 2 | 低音 | 贝斯 | 50% | 4 |'));
    expect(doc, contains('## 校验'));
    expect(doc, contains('- 状态：校验通过'));
  });

  test('音乐文档：校验未通过时如实给问题数', () {
    final String doc = buildWorkbenchDoc(
      kind: 'music',
      name: 'broken',
      summary: const <String, Object?>{
        'title': '待修乐谱',
        'tempo': 96,
        'timeSig': <int>[3, 4],
        'keySig': 'G',
        'tracks': <Object?>[
          <String, Object?>{'name': '单轨', 'instrument': 'organ', 'volume': 1},
        ],
        'verified': false,
        'checks': <Object?>[
          <String, Object?>{'pointer': '/tempo'},
          <String, Object?>{'pointer': '/tracks/0'},
        ],
      },
    );
    expect(doc, contains('# 待修乐谱'));
    expect(doc, contains('- 拍号：3/4'));
    expect(doc, contains('- 调号：G'));
    expect(doc, contains('- 状态：校验未通过（2 处问题）'));
    expect(doc, isNot(contains('校验通过')));
  });

  test('未知 kind 返回通用最小文档，不抛异常', () {
    final String doc = buildWorkbenchDoc(
      kind: 'design',
      name: 'my-board',
      summary: const <String, Object?>{'unexpected': 'value'},
    );
    expect(doc.split('\n').first, workbenchDocNotice);
    expect(doc, contains('# my-board'));
    expect(doc, contains('## 项目概览'));
    expect(doc, contains('- 类型：工作台项目'));
    expect(doc, contains('说明：本项目还没有可自动生成的文档结构。'));
    expect(doc.contains('## 轨道表'), isFalse);
    expect(doc.contains('## 镜头表'), isFalse);
  });

  test('空 summary：四种 kind 都不崩且保持骨架', () {
    for (final String kind in const <String>[
      'three',
      'video',
      'video3d',
      'music',
    ]) {
      final String doc = buildWorkbenchDoc(kind: kind, name: kind);
      expect(doc.split('\n').first, workbenchDocNotice);
      expect(doc, contains('## 项目概览'));
    }
    final String three = buildWorkbenchDoc(kind: 'three', name: 't');
    expect(three, contains('- 组件数：0 个'));
    expect(three, contains('- 验收项数：0 条'));
    expect(three, contains('- 暂无进度记录'));
    final String video = buildWorkbenchDoc(kind: 'video', name: 'v');
    expect(video, contains('- 总时长：未记录'));
    expect(video, contains('- 帧率：30 帧/秒'));
    expect(video, contains('- 暂无镜头'));
    final String video3d = buildWorkbenchDoc(kind: 'video3d', name: 'v3');
    expect(video3d, contains('- 节点数：未记录'));
    expect(video3d, contains('- 总帧数：未记录'));
    expect(video3d, contains('- 暂无镜头'));
    final String music = buildWorkbenchDoc(kind: 'music', name: 'm');
    expect(music, contains('- 速度：未记录'));
    expect(music, contains('- 拍号：未记录'));
    expect(music, contains('- 调号：未记录'));
    expect(music, contains('- 暂无轨道'));
    expect(music, contains('- 状态：未校验'));
  });

  test('确定性：同输入两次生成字节相同，且不含时间戳/日期', () {
    final Map<String, Map<String, Object?>> summaries =
        <String, Map<String, Object?>>{
          'three': _threeSummary,
          'video': _videoSummary,
          'video3d': _video3dSummary,
          'music': _musicSummary,
        };
    for (final MapEntry<String, Map<String, Object?>> entry
        in summaries.entries) {
      final String first = buildWorkbenchDoc(
        kind: entry.key,
        name: 'stable',
        title: '固定标题',
        summary: entry.value,
      );
      final String second = buildWorkbenchDoc(
        kind: entry.key,
        name: 'stable',
        title: '固定标题',
        summary: entry.value,
      );
      expect(first, second, reason: '${entry.key} 生成结果必须确定');
      expect(
        RegExp(r'\d{4}-\d{2}-\d{2}').hasMatch(first),
        isFalse,
        reason: '${entry.key} 文档不得带日期',
      );
    }
  });

  test('标题优先级：显式标题 → 摘要标题 → 项目名 → 中性兜底', () {
    const Map<String, Object?> withSummaryTitle = <String, Object?>{
      'title': '摘要里的标题',
    };
    expect(
      buildWorkbenchDoc(
        kind: 'video',
        name: 'raw-name',
        title: '显式标题',
        summary: withSummaryTitle,
      ),
      contains('# 显式标题'),
    );
    expect(
      buildWorkbenchDoc(
        kind: 'video',
        name: 'raw-name',
        summary: withSummaryTitle,
      ),
      contains('# 摘要里的标题'),
    );
    expect(
      buildWorkbenchDoc(kind: 'video', name: 'raw-name'),
      contains('# raw-name'),
    );
    expect(buildWorkbenchDoc(kind: 'video', name: '   '), contains('# 未命名项目'));
    // 标题里的换行压成空格，不破坏 markdown 标题行。
    expect(
      buildWorkbenchDoc(kind: 'video', name: 'raw-name', title: '第一行\n第二行'),
      contains('# 第一行 第二行'),
    );
  });

  test('生成的文档不出现内部术语（禁用词检查）', () {
    final Map<String, Map<String, Object?>> summaries =
        <String, Map<String, Object?>>{
          'three': _threeSummary,
          'video': _videoSummary,
          'video3d': _video3dSummary,
          'music': _musicSummary,
        };
    for (final MapEntry<String, Map<String, Object?>> entry
        in summaries.entries) {
      final String doc = buildWorkbenchDoc(
        kind: entry.key,
        name: 'saturn-ring',
        summary: entry.value,
      );
      final String lowered = doc.toLowerCase();
      for (final String term in _forbiddenTerms) {
        expect(
          lowered.contains(term.toLowerCase()),
          isFalse,
          reason: '${entry.key} 文档出现了内部术语「$term」',
        );
      }
    }
  });

  test('进度：label 优先于 id，未知层名收中性词', () {
    final String doc = buildWorkbenchDoc(
      kind: 'three',
      name: 't',
      summary: const <String, Object?>{
        'passes': <Object?>[
          <String, Object?>{
            'id': 'form',
            'label': '自定义层名',
            'status': 'blocked',
          },
          <String, Object?>{'id': 'lighting', 'status': 'verified'},
        ],
      },
    );
    expect(doc, contains('- 已通过 1 / 2 层'));
    expect(doc, contains('- 已通过层：灯光'));
    expect(doc, contains('- 已阻塞层：自定义层名'));
  });

  test('镜头表单元格：换行压成空格、竖线转义，不破坏表格', () {
    final String doc = buildWorkbenchDoc(
      kind: 'video',
      name: 'v',
      summary: const <String, Object?>{
        'shots': <Object?>[
          <String, Object?>{'duration': 1, 'text': '第一行\n第二行|带竖线'},
        ],
      },
    );
    expect(doc, contains(r'第一行 第二行\|带竖线'));
    expect(
      doc.split('\n').where((String line) => line.startsWith('| ')),
      hasLength(3),
      reason: '表格 = 表头 + 分隔行 + 一行数据，换行不能把表格撑断',
    );
  });

  // -------------------------------------------------------------------------
  // 落盘：原子写、不覆盖、overwrite、失败不破坏旧文件
  // -------------------------------------------------------------------------

  test('writeWorkbenchDoc 写入 docs.md，返回文件且可回读', () async {
    final Directory dir = _tempDir();
    final String expected = buildWorkbenchDoc(
      kind: 'music',
      name: 'mist',
      summary: _musicSummary,
    );
    final File? file = await writeWorkbenchDoc(
      projectDir: dir,
      kind: 'music',
      name: 'mist',
      summary: _musicSummary,
    );
    expect(file, isNotNull);
    expect(_leaf(file!.path), workbenchDocFileName);
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), expected);
    expect(await readWorkbenchDoc(dir), expected);
    expect(_hiddenLeftovers(dir), isEmpty, reason: '写盘不得留下临时文件');
  });

  test('writeWorkbenchDoc 已存在且 overwrite=false：返回 null 且不写盘', () async {
    final Directory dir = _tempDir();
    final File docs = File('${dir.path}/$workbenchDocFileName');
    docs.writeAsStringSync('旧文档\n');
    final File? file = await writeWorkbenchDoc(
      projectDir: dir,
      kind: 'video',
      name: 'v',
      summary: _videoSummary,
    );
    expect(file, isNull);
    expect(docs.readAsStringSync(), '旧文档\n');
    expect(_hiddenLeftovers(dir), isEmpty);
  });

  test('writeWorkbenchDoc overwrite=true：覆盖为最新生成内容', () async {
    final Directory dir = _tempDir();
    final File docs = File('${dir.path}/$workbenchDocFileName');
    docs.writeAsStringSync('旧文档\n');
    final String expected = buildWorkbenchDoc(
      kind: 'video',
      name: 'v',
      title: '新标题',
      summary: _videoSummary,
    );
    final File? file = await writeWorkbenchDoc(
      projectDir: dir,
      kind: 'video',
      name: 'v',
      title: '新标题',
      summary: _videoSummary,
      overwrite: true,
    );
    expect(file, isNotNull);
    expect(docs.readAsStringSync(), expected);
    expect(docs.readAsStringSync(), contains('# 新标题'));
  });

  test('原子性：目标被目录占位时显性失败，不破坏其它文件、不留临时文件', () async {
    final Directory dir = _tempDir();
    Directory('${dir.path}/$workbenchDocFileName').createSync();
    final File brief = File('${dir.path}/$workbenchDocFallbackFileName');
    brief.writeAsStringSync('旧简报正文\n');

    await expectLater(
      writeWorkbenchDoc(
        projectDir: dir,
        kind: 'three',
        name: 't',
        summary: _threeSummary,
        overwrite: true,
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(brief.readAsStringSync(), '旧简报正文\n');
    expect(
      Directory('${dir.path}/$workbenchDocFileName').existsSync(),
      isTrue,
      reason: '失败后占位目录保持原样，不被破坏性兜底删掉',
    );
    expect(_hiddenLeftovers(dir), isEmpty, reason: '失败路径必须清理临时文件');
  });

  test('writeWorkbenchDoc 按需创建缺失的项目目录', () async {
    final Directory parent = _tempDir();
    final Directory dir = Directory('${parent.path}/deep/nested');
    final File? file = await writeWorkbenchDoc(
      projectDir: dir,
      kind: 'three',
      name: 'deep',
      summary: _threeSummary,
    );
    expect(file, isNotNull);
    expect(File('${dir.path}/$workbenchDocFileName').existsSync(), isTrue);
  });

  test('写盘确定性：两次覆盖写字节相同，其它文件不被波及', () async {
    final Directory dir = _tempDir();
    final File other = File('${dir.path}/notes.txt');
    other.writeAsStringSync('别动我\n');
    final String expected = buildWorkbenchDoc(
      kind: 'video3d',
      name: 'v3',
      summary: _video3dSummary,
    );
    await writeWorkbenchDoc(
      projectDir: dir,
      kind: 'video3d',
      name: 'v3',
      summary: _video3dSummary,
    );
    final String first = File('${dir.path}/$workbenchDocFileName')
        .readAsStringSync();
    await writeWorkbenchDoc(
      projectDir: dir,
      kind: 'video3d',
      name: 'v3',
      summary: _video3dSummary,
      overwrite: true,
    );
    final String second = File('${dir.path}/$workbenchDocFileName')
        .readAsStringSync();
    expect(first, expected);
    expect(second, expected);
    expect(other.readAsStringSync(), '别动我\n');
    expect(_hiddenLeftovers(dir), isEmpty);
  });

  // -------------------------------------------------------------------------
  // 读盘：docs.md 优先、brief.md 兜底
  // -------------------------------------------------------------------------

  test('readWorkbenchDoc：docs.md 优先、brief.md 兜底、空白/缺失为 null', () async {
    final Directory dir = _tempDir();
    expect(await readWorkbenchDoc(dir), isNull);

    File('${dir.path}/$workbenchDocFallbackFileName').writeAsStringSync('简报正文');
    expect(await readWorkbenchDoc(dir), '简报正文');

    File('${dir.path}/$workbenchDocFileName').writeAsStringSync('文档正文');
    expect(await readWorkbenchDoc(dir), '文档正文');

    // docs.md 空白时退回 brief.md（与四栏目读盘同口径）。
    File('${dir.path}/$workbenchDocFileName').writeAsStringSync('   \n');
    expect(await readWorkbenchDoc(dir), '简报正文');

    // 两个候选都空白 → 没有文档。
    File('${dir.path}/$workbenchDocFallbackFileName').writeAsStringSync('\n\n');
    expect(await readWorkbenchDoc(dir), isNull);

    // docs.md 被目录占位（读不了）时仍能用 brief.md。
    File('${dir.path}/$workbenchDocFileName').deleteSync();
    Directory('${dir.path}/$workbenchDocFileName').createSync();
    File('${dir.path}/$workbenchDocFallbackFileName').writeAsStringSync('还能读');
    expect(await readWorkbenchDoc(dir), '还能读');
  });

  test('hasWorkbenchDoc：非空文档为 true，空白/缺失/目录不存在为 false', () {
    final Directory dir = _tempDir();
    expect(hasWorkbenchDoc(dir), isFalse);

    final File docs = File('${dir.path}/$workbenchDocFileName');
    docs.writeAsStringSync('  \n');
    expect(hasWorkbenchDoc(dir), isFalse, reason: '空白文件不算有文档');

    docs.writeAsStringSync('正文');
    expect(hasWorkbenchDoc(dir), isTrue);

    docs.deleteSync();
    File('${dir.path}/$workbenchDocFallbackFileName').writeAsStringSync('简报');
    expect(hasWorkbenchDoc(dir), isTrue, reason: 'brief.md 兜底也算有文档');

    expect(hasWorkbenchDoc(Directory('${dir.path}/missing')), isFalse);
  });

  // -------------------------------------------------------------------------
  // 漂移锚点：层名 / 乐器名必须跟事实源同步
  // -------------------------------------------------------------------------

  test('3D 层名与 threePassLabel 保持同步', () {
    for (final ThreePassSpec pass in threePasses) {
      expect(pass.id.isNotEmpty, isTrue, reason: 'threePasses 里每一层都有 id');
      final String doc = buildWorkbenchDoc(
        kind: 'three',
        name: 't',
        summary: <String, Object?>{
          'passes': <Object?>[
            <String, Object?>{'id': pass.id, 'status': 'pending'},
          ],
        },
      );
      expect(
        doc,
        contains(threePassLabel(pass.id)),
        reason: '文档层名必须与事实源（${pass.id}）一致',
      );
    }
  });

  test('音乐乐器中文名覆盖契约允许的全部取值', () {
    // 与 workbench_docs.dart 的映射表同值：契约新增乐器时这里会先失败，
    // 提醒同步生成器（避免文档里冒出未翻译/漏翻的乐器）。
    const Map<String, String> expected = <String, String>{
      'piano': '钢琴',
      'strings': '弦乐',
      'bass': '贝斯',
      'bell': '铃音',
      'organ': '风琴',
      'pluck': '拨弦',
      'drums': '鼓',
    };
    for (final String instrument in musicInstruments) {
      final String? label = expected[instrument];
      expect(label, isNotNull, reason: '契约乐器「$instrument」缺中文名映射');
      final String doc = buildWorkbenchDoc(
        kind: 'music',
        name: 'm',
        summary: <String, Object?>{
          'tracks': <Object?>[
            <String, Object?>{
              'name': '声部',
              'instrument': instrument,
              'volume': 1,
              'measures': 2,
            },
          ],
        },
      );
      expect(doc, contains('| 1 | 声部 | $label |'));
    }
  });
}
