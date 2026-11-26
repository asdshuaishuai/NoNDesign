// 工作台项目单一打包容器（`nan.pack/1`）的行为测试。
//
// 覆盖本任务不可回退的语义：
//  1. 容器模型往返：中文 / unicode / emoji / 嵌套相对路径 / docs / spec /
//     固定 ISO 时间戳全部保留，`toMap()` 字段集合与顺序稳定；
//  2. 编码确定性：同输入（含固定时间戳）→ 同字节，与 Map 插入顺序无关；
//     解码再编码字节一致；
//  3. 线格式锁定：`nan.pack/1` 头 + 单行 JSON payload + `crc32=<8 hex>` 尾；
//  4. 解码显性失败：CRC 篡改 / 版本不支持 / 缺字段 / 未知 kind / 非法字段 /
//     非 JSON spec / 不安全文件路径全部抛出带稳定 code 的
//     `WorkbenchPackFailure`，不返回半成品；
//  5. 扩展名映射：design→.ddp、three→.n3d、video→.nvdo、video3d→.n3v、
//     music→.nmu；未知 kind 显性失败；
//  6. 目录收集：只收 UTF-8 文本；默认排除 build-state.json / history /
//     artifacts / .tmp 等产物缓存；二进制、排除、白名单外、符号链接都进
//     报告（不静默）；include / exclude 通配可用；
//  7. 原子写：同目录临时文件 + rename；成功后可读回、旧文件被完整替换、不留
//     临时文件；失败（目标被目录占位 / 父路径是文件）不破坏旧内容。
//
// 测试一律使用系统临时目录，不碰真实用户项目目录。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/workbench_pack.dart';

const String _createdAt = '2026-11-27T01:00:00Z';
const String _updatedAt = '2026-11-27T02:00:00Z';

/// 一份覆盖全部字段的 3D 视频项目容器（中文 / emoji / 嵌套路径）。
WorkbenchPack _video3dPack() => _pack(
  kind: WorkbenchPackKind.video3d,
  name: '视频项目-01',
  title: '3D 视频 · 中文标题 🎬',
  docs: '# 项目文档\n\n这是中文文档内容。\n',
  spec: <String, Object?>{
    'scene': <String, Object?>{
      'title': '中文场景',
      'objects': <Object?>[
        <String, Object?>{
          'name': '立方体',
          'position': <String, Object?>{'x': 1, 'y': 0.5, 'z': -2},
        },
      ],
    },
    'shots': <Object?>[
      <String, Object?>{'id': '开场', 'duration': 2.5},
    ],
  },
  files: <String, String>{
    'scene3d.json': '{"scene":true}',
    'screenplay3d.json': '{"shots":[]}',
    'src/主场景.js': 'export const 主场景 = { 名称: "中文" };',
    'src/lib/工具/文字.js': '// 注释：🎬\nconst 文字 = "你好，世界";\n',
    'docs/说明.md': '# 说明\n\n中文与 emoji 🎬\n',
  },
  createdAt: _createdAt,
  updatedAt: _updatedAt,
);

WorkbenchPack _pack({
  WorkbenchPackKind kind = WorkbenchPackKind.three,
  String name = 'scene-01',
  String title = '主场景',
  String? docs,
  Object? spec,
  Map<String, String>? files,
  String? createdAt,
  String? updatedAt,
}) {
  return WorkbenchPack(
    kind: kind,
    name: name,
    title: title,
    docs: docs,
    spec: spec,
    files: files,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

Matcher _throwsPackFailure(String code) => throwsA(
  isA<WorkbenchPackFailure>().having(
    (WorkbenchPackFailure failure) => failure.code,
    'code',
    code,
  ),
);

/// 与实现相同的 IEEE CRC32（测试只为造「校验和正确、内容非法」的容器；
/// 若实现多项式变化，这里构造的容器会解码失败，测试会立刻暴露）。
int _testCrc32(List<int> data) {
  final List<int> table = List<int>.generate(256, (int n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    return c;
  }, growable: false);
  var crc = 0xFFFFFFFF;
  for (final int byte in data) {
    crc = table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

String _checksumOf(String payload) =>
    _testCrc32(utf8.encode(payload)).toRadixString(16).padLeft(8, '0');

/// 用给定 payload 造一个 CRC32 正确的 `nan.pack/1` 文本，专门测「校验和通过
/// 但字段非法」的解码路径。
String _craftPack(Map<String, Object?> payload, {int headerVersion = 1}) {
  final String payloadText = jsonEncode(payload);
  return 'nan.pack/$headerVersion\n$payloadText\ncrc32=${_checksumOf(payloadText)}\n';
}

void _writeText(Directory root, String relative, String content) {
  final File file = File('${root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void _writeBinary(Directory root, String relative, List<int> bytes) {
  final File file = File('${root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}

/// 目录里所有残留临时文件（原子写失败/成功后都必须为空）。
List<FileSystemEntity> _tempLeftovers(Directory dir) => dir
    .listSync(recursive: true)
    .where((FileSystemEntity entity) => entity.path.endsWith('.tmp'))
    .toList(growable: false);

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('nan_pack_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // 清理失败不影响断言结果。
      }
    }
  });

  group('容器模型', () {
    test('toMap/fromMap 往返：中文、emoji、嵌套路径与全部字段', () {
      final WorkbenchPack pack = _video3dPack();
      final Map<String, Object?> map = pack.toMap();
      final WorkbenchPack restored = WorkbenchPack.fromMap(map);

      expect(restored.version, workbenchPackVersion);
      expect(restored.kind, WorkbenchPackKind.video3d);
      expect(restored.name, '视频项目-01');
      expect(restored.title, '3D 视频 · 中文标题 🎬');
      expect(restored.docs, pack.docs);
      expect(restored.createdAt, _createdAt);
      expect(restored.updatedAt, _updatedAt);
      expect(restored.files, equals(pack.files));
      expect(restored.spec, equals(pack.spec));
      expect(restored.toMap(), equals(map));
    });

    test('toMap 字段集合、顺序、kind wire 与 version 稳定', () {
      final WorkbenchPack pack = _video3dPack();
      final Map<String, Object?> map = pack.toMap();

      expect(map.keys.toList(growable: false), <String>[
        'version',
        'kind',
        'name',
        'title',
        'docs',
        'spec',
        'files',
        'createdAt',
        'updatedAt',
      ]);
      expect(map['version'], 1);
      expect(map['kind'], 'video3d');
      expect(map['files'], isA<Map<String, String>>());
      expect(pack.extension, '.n3v');
      expect(pack.suggestedFileName, '视频项目-01.n3v');
    });

    test('可选字段缺省（null docs/spec、空 files、空标题）可往返', () {
      final WorkbenchPack pack = _pack(
        kind: WorkbenchPackKind.video,
        name: 'video-01',
        title: '',
        files: const <String, String>{},
      );
      final Map<String, Object?> map = pack.toMap();

      expect(map['docs'], isNull);
      expect(map['spec'], isNull);
      expect(map['createdAt'], isNull);
      expect(map['updatedAt'], isNull);
      expect(map['files'], isEmpty);

      final WorkbenchPack decoded = WorkbenchPack.decode(pack.encode());
      expect(decoded.docs, isNull);
      expect(decoded.spec, isNull);
      expect(decoded.files, isEmpty);
      expect(decoded.title, '');
      expect(decoded.toMap(), equals(map));
    });

    test('Windows 反斜杠路径被归一成相对 POSIX 路径', () {
      final WorkbenchPack pack = _pack(
        files: <String, String>{r'src\lib\main.js': 'const x = 1;'},
      );
      expect(pack.files.keys.single, 'src/lib/main.js');
      expect(
        WorkbenchPack.decode(pack.encode()).files.keys.single,
        'src/lib/main.js',
      );
    });
  });

  group('编码与确定性', () {
    test('encode/decode 往返一致，且解码再编码字节相同', () {
      final WorkbenchPack pack = _video3dPack();
      final String encoded = pack.encode();
      final WorkbenchPack decoded = WorkbenchPack.decode(encoded);

      expect(decoded.toMap(), equals(pack.toMap()));
      expect(decoded.encode(), encoded);
    });

    test('固定时间戳下同输入 → 同字节（与 Map 插入顺序无关）', () {
      final WorkbenchPack a = _pack(
        spec: <String, Object?>{'z': 1, 'a': 2},
        files: <String, String>{'b.txt': 'B', 'a.txt': 'A'},
        createdAt: _createdAt,
        updatedAt: _updatedAt,
      );
      final WorkbenchPack b = _pack(
        spec: <String, Object?>{'a': 2, 'z': 1},
        files: <String, String>{'a.txt': 'A', 'b.txt': 'B'},
        createdAt: _createdAt,
        updatedAt: _updatedAt,
      );

      expect(a.encode(), b.encode());
      expect(a.encode(), a.encode());
      expect(WorkbenchPack.decode(a.encode()).encode(), a.encode());
    });

    test('线格式锁定：头部 / 单行 payload / CRC32 尾行 / 末尾单换行', () {
      final String text = _video3dPack().encode();
      expect(text.startsWith('nan.pack/1\n'), isTrue);
      expect(text.endsWith('\n'), isTrue);

      final List<String> lines = text.split('\n');
      expect(lines.length, 4); // header / payload / checksum / 末尾空串
      expect(lines[0], 'nan.pack/1');
      expect(lines[2], matches(RegExp(r'^crc32=[0-9a-f]{8}$')));

      final Object? decoded = jsonDecode(lines[1]);
      expect(decoded, isA<Map<String, Object?>>());
      final Map<String, Object?> payload = decoded! as Map<String, Object?>;
      // payload 顶层键按字典序（与 toMap 的书写顺序无关）。
      expect(payload.keys.toList(growable: false), <String>[
        'createdAt',
        'docs',
        'files',
        'kind',
        'name',
        'spec',
        'title',
        'updatedAt',
        'version',
      ]);
      expect(payload['version'], 1);
      expect(payload['kind'], 'video3d');
    });

    test('CRLF 行尾可解码（内容文本仍按 LF 编码）', () {
      final WorkbenchPack pack = _video3dPack();
      final String encoded = pack.encode();
      final String crlf = encoded.replaceAll('\n', '\r\n');

      expect(WorkbenchPack.decode(crlf).toMap(), equals(pack.toMap()));
    });
  });

  group('解码显性失败', () {
    test('payload 被篡改 → CRC32 校验失败', () {
      final String encoded = _video3dPack().encode();
      final List<String> lines = encoded.split('\n');
      final String tamperedPayload = lines[1].replaceFirst('中文标题', '被改标题');
      final String tampered = '${lines[0]}\n$tamperedPayload\n${lines[2]}\n';

      expect(
        () => WorkbenchPack.decode(tampered),
        _throwsPackFailure(WorkbenchPackFailureCode.checksumFailed),
      );
    });

    test('校验和行被篡改 → CRC32 校验失败', () {
      final String encoded = _video3dPack().encode();
      final List<String> lines = encoded.split('\n');
      final String checksum = lines[2].substring(
        workbenchPackChecksumPrefix.length,
      );
      final String first = checksum[0] == '0' ? '1' : '0';
      final String badChecksum =
          '${lines[0]}\n${lines[1]}\n'
          '$workbenchPackChecksumPrefix$first${checksum.substring(1)}\n';

      expect(
        () => WorkbenchPack.decode(badChecksum),
        _throwsPackFailure(WorkbenchPackFailureCode.checksumFailed),
      );
    });

    test('非容器 / 行数不对 / 校验和行缺失或畸形 → invalid_container', () {
      final WorkbenchPack pack = _video3dPack();
      final List<String> lines = pack.encode().split('\n');
      final List<String> malformed = <String>[
        '',
        'not a pack at all',
        'DDP2\x00\x01garbage',
        'nan.pack/1\n{}',
        '${lines[0]}\n${lines[1]}\ncrc32=00000000\nextra\n',
        '${lines[0]}\n${lines[1]}\n00000000\n',
        '${lines[0]}\n${lines[1]}\n${workbenchPackChecksumPrefix}abc\n',
        'nan.pack/x\n${lines[1]}\n${lines[2]}\n',
      ];

      for (final String text in malformed) {
        expect(
          () => WorkbenchPack.decode(text),
          _throwsPackFailure(WorkbenchPackFailureCode.invalidContainer),
          reason: 'text=$text',
        );
      }
    });

    test('版本不支持：头部版本 2 与 payload version 2 都拒绝', () {
      final WorkbenchPack pack = _video3dPack();
      final String encoded = pack.encode();

      expect(
        () => WorkbenchPack.decode(
          encoded.replaceFirst('nan.pack/1', 'nan.pack/2'),
        ),
        _throwsPackFailure(WorkbenchPackFailureCode.versionUnsupported),
      );

      final Map<String, Object?> map = pack.toMap()..['version'] = 2;
      expect(
        () => WorkbenchPack.fromMap(map),
        _throwsPackFailure(WorkbenchPackFailureCode.versionUnsupported),
      );
      expect(
        () => WorkbenchPack.decode(_craftPack(map)),
        _throwsPackFailure(WorkbenchPackFailureCode.versionUnsupported),
      );
    });

    test('必填字段缺失：fromMap 与 decode 都拒绝', () {
      final WorkbenchPack pack = _video3dPack();
      for (final String field in <String>[
        'version',
        'kind',
        'name',
        'title',
        'files',
      ]) {
        final Map<String, Object?> map = pack.toMap()..remove(field);
        expect(
          () => WorkbenchPack.fromMap(map),
          _throwsPackFailure(WorkbenchPackFailureCode.missingField),
          reason: 'fromMap missing $field',
        );
        expect(
          () => WorkbenchPack.decode(_craftPack(map)),
          _throwsPackFailure(WorkbenchPackFailureCode.missingField),
          reason: 'decode missing $field',
        );
      }
    });

    test('未知 kind：fromMap 与 decode 都拒绝', () {
      final WorkbenchPack pack = _video3dPack();
      final Map<String, Object?> map = pack.toMap()..['kind'] = 'audio';

      expect(
        () => WorkbenchPack.fromMap(map),
        _throwsPackFailure(WorkbenchPackFailureCode.unknownKind),
      );
      expect(
        () => WorkbenchPack.decode(_craftPack(map)),
        _throwsPackFailure(WorkbenchPackFailureCode.unknownKind),
      );
    });

    test('字段类型 / 取值非法 → invalid_field', () {
      final WorkbenchPack pack = _video3dPack();
      final List<(String, void Function(Map<String, Object?>))> cases =
          <(String, void Function(Map<String, Object?>))>[
            (
              'version 不是整数',
              (Map<String, Object?> map) => map['version'] = '1',
            ),
            ('kind 不是字符串', (Map<String, Object?> map) => map['kind'] = 3),
            ('name 是空串', (Map<String, Object?> map) => map['name'] = ''),
            ('name 像路径', (Map<String, Object?> map) => map['name'] = '../evil'),
            ('title 是 null', (Map<String, Object?> map) => map['title'] = null),
            ('docs 不是字符串', (Map<String, Object?> map) => map['docs'] = 42),
            (
              'createdAt 不是 ISO',
              (Map<String, Object?> map) => map['createdAt'] = 'yesterday',
            ),
            (
              'updatedAt 不是 ISO',
              (Map<String, Object?> map) =>
                  map['updatedAt'] = 'not-a-timestamp',
            ),
            (
              'files 不是对象',
              (Map<String, Object?> map) => map['files'] = <Object?>[],
            ),
            (
              'files 值为非字符串',
              (Map<String, Object?> map) =>
                  map['files'] = <String, Object?>{'a.txt': 1},
            ),
          ];

      for (final (String label, void Function(Map<String, Object?>) mutate)
          in cases) {
        final Map<String, Object?> map = pack.toMap();
        mutate(map);
        expect(
          () => WorkbenchPack.fromMap(map),
          _throwsPackFailure(WorkbenchPackFailureCode.invalidField),
          reason: label,
        );
      }
    });

    test('spec 非 JSON 安全值 → invalid_spec', () {
      expect(
        () => _pack(spec: DateTime(2026, 11, 27)),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidSpec),
      );
      expect(
        () => _pack(spec: <String, Object?>{'nan': double.nan}),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidSpec),
      );
      expect(
        () => _pack(spec: <String, Object?>{'inf': double.infinity}),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidSpec),
      );
      expect(
        () => _pack(spec: <Object?, Object?>{1: 'non-string key'}),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidSpec),
      );
      final Map<String, Object?> cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      expect(
        () => _pack(spec: cyclic),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidSpec),
      );
    });

    test('files 路径逃逸 / 盘符 / 空段 / 归一后重名 → invalid_path', () {
      final List<String> badPaths = <String>[
        '',
        '/abs.txt',
        '../escape.txt',
        'a/../b.txt',
        'a//b.txt',
        './a.txt',
        r'C:\temp\x.txt',
        'a:b.txt',
      ];
      for (final String path in badPaths) {
        expect(
          () => _pack(files: <String, String>{path: 'x'}),
          _throwsPackFailure(WorkbenchPackFailureCode.invalidPath),
          reason: 'path=$path',
        );
      }
      expect(
        () => _pack(files: <String, String>{'a/b.txt': '1', r'a\b.txt': '2'}),
        _throwsPackFailure(WorkbenchPackFailureCode.invalidPath),
      );
    });
  });

  group('扩展名映射', () {
    test('五个 kind 的扩展名与未知 kind 显性失败', () {
      const Map<String, String> expected = <String, String>{
        'design': '.ddp',
        'three': '.n3d',
        'video': '.nvdo',
        'video3d': '.n3v',
        'music': '.nmu',
      };
      for (final MapEntry<String, String> entry in expected.entries) {
        expect(packExtensionFor(entry.key), entry.value);
      }
      for (final WorkbenchPackKind kind in WorkbenchPackKind.values) {
        expect(kind.extension, expected[kind.wire]);
      }

      expect(
        () => packExtensionFor('audio'),
        _throwsPackFailure(WorkbenchPackFailureCode.unknownKind),
      );
      expect(WorkbenchPackKind.tryParse('music'), WorkbenchPackKind.music);
      expect(WorkbenchPackKind.tryParse('audio'), isNull);
      expect(WorkbenchPackKind.tryParse(3), isNull);
    });
  });

  group('目录收集', () {
    test('只收 UTF-8 文本；产物/缓存默认排除；二进制与符号链接进报告', () {
      final Directory root = Directory('${tempDir.path}/project')..createSync();
      _writeText(root, 'scene3d.json', '{"scene":1}');
      _writeText(root, 'screenplay3d.json', '{"shots":[]}');
      _writeText(root, 'src/主场景.js', 'const 场景 = "中文";');
      _writeText(root, 'src/lib/工具.js', '// 注释：🎬\n');
      _writeText(root, 'docs/说明.md', '# 中文说明\n');

      // 默认排除的产物 / 缓存。
      _writeText(root, 'build-state.json', '{"state":1}');
      _writeText(root, 'history/old.json', '{}');
      _writeText(root, 'artifacts/gates.json', '{}');
      _writeText(root, '.tmp/half.tmp', 'half');
      _writeText(root, 'node_modules/pkg/index.js', 'x');

      // 二进制（非法 UTF-8）必须跳过而不是收进容器。
      _writeBinary(root, 'assets/logo.png', <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0xFF,
      ]);
      _writeBinary(root, 'assets/font.woff', <int>[0x00, 0xFF, 0xFE]);

      final String? linkPath = !Platform.isWindows
          ? '${root.path}/outside-link'
          : null;
      if (linkPath != null) {
        File('${tempDir.path}/outside-target.txt').writeAsStringSync('x');
        Link(linkPath).createSync('${tempDir.path}/outside-target.txt');
      }

      final WorkbenchPackScan scan = scanWorkbenchDirectory(root);
      expect(scan.files.keys.toList(growable: false), <String>[
        'docs/说明.md',
        'scene3d.json',
        'screenplay3d.json',
        'src/lib/工具.js',
        'src/主场景.js',
      ]);
      expect(scan.skippedBinary, <String>[
        'assets/font.woff',
        'assets/logo.png',
      ]);
      expect(scan.skippedExcluded.toSet(), <String>{
        '.tmp',
        'artifacts',
        'build-state.json',
        'history',
        'node_modules',
      });
      if (linkPath != null) {
        expect(scan.skippedLinks, <String>['outside-link']);
      }
      expect(scan.skippedNotIncluded, isEmpty);
      expect(scan.fileCount, 5);
      expect(scan.isEmpty, isFalse);

      // filesFromDirectory 是 scan 的 files 视图。
      expect(
        filesFromDirectory(root).keys.toList(growable: false),
        scan.files.keys.toList(growable: false),
      );
    });

    test('include / exclude 通配过滤（默认排除仍然生效）', () {
      final Directory root = Directory('${tempDir.path}/filter')..createSync();
      _writeText(root, 'a.json', '{}');
      _writeText(root, 'b.js', 'b');
      _writeText(root, 'scene3d.json', '{}');
      _writeText(root, 'src/a.js', 'src-a');
      _writeText(root, 'src/nested/tool.js', 'src-nested');
      _writeText(root, 'docs/readme.md', 'readme');
      _writeText(root, 'artifacts/x.json', '{}');

      final WorkbenchPackScan jsonOnly = scanWorkbenchDirectory(
        root,
        include: <String>{'*.json'},
      );
      expect(jsonOnly.files.keys.toList(growable: false), <String>[
        'a.json',
        'scene3d.json',
      ]);
      expect(jsonOnly.skippedExcluded, contains('artifacts'));
      expect(
        jsonOnly.skippedNotIncluded,
        containsAll(<String>['b.js', 'docs/readme.md', 'src/a.js']),
      );

      final WorkbenchPackScan srcOnly = scanWorkbenchDirectory(
        root,
        include: <String>{'src/**'},
      );
      expect(srcOnly.files.keys.toList(growable: false), <String>[
        'src/a.js',
        'src/nested/tool.js',
      ]);

      final WorkbenchPackScan filtered = scanWorkbenchDirectory(
        root,
        exclude: <String>{'b.js', 'docs/**'},
      );
      expect(filtered.files.keys.toList(growable: false), <String>[
        'a.json',
        'scene3d.json',
        'src/a.js',
        'src/nested/tool.js',
      ]);
      expect(
        filtered.skippedExcluded,
        containsAll(<String>['b.js', 'docs/readme.md']),
      );
    });

    test('目录不存在 / 不是目录 → io_failed', () {
      expect(
        () => scanWorkbenchDirectory(Directory('${tempDir.path}/missing')),
        _throwsPackFailure(WorkbenchPackFailureCode.ioFailed),
      );
      final File notDir = File('${tempDir.path}/notdir.txt')
        ..writeAsStringSync('x');
      expect(
        () => scanWorkbenchDirectory(Directory(notDir.path)),
        _throwsPackFailure(WorkbenchPackFailureCode.ioFailed),
      );
    });
  });

  group('原子写', () {
    test('writeTo 成功后可读回；覆盖旧文件完整替换；不留临时文件', () async {
      final File target = File('${tempDir.path}/write/project.n3d');
      final WorkbenchPack first = _video3dPack();

      await first.writeTo(target);
      expect(target.existsSync(), isTrue);
      expect(target.readAsStringSync(), first.encode());
      final WorkbenchPack reread = await WorkbenchPack.readFrom(target);
      expect(reread.toMap(), equals(first.toMap()));

      final WorkbenchPack second = _pack(
        kind: WorkbenchPackKind.video3d,
        name: '第三版',
        title: '第三版',
        files: <String, String>{'only.txt': '第三版'},
        createdAt: _createdAt,
        updatedAt: _updatedAt,
      );
      await second.writeTo(target);
      expect(target.readAsStringSync(), second.encode());
      expect((await WorkbenchPack.readFrom(target)).title, '第三版');

      expect(_tempLeftovers(Directory('${tempDir.path}/write')), isEmpty);
    });

    test('目标被目录占位 → 写失败且旧目录内容与临时文件都不被破坏', () async {
      final Directory occupied = Directory('${tempDir.path}/occupied.nmu')
        ..createSync();
      File('${occupied.path}/marker.txt').writeAsStringSync('keep');

      final WorkbenchPack pack = _pack(
        kind: WorkbenchPackKind.music,
        name: '音乐',
        title: '音乐',
        files: <String, String>{'score.json': '{"score":1}'},
      );
      await expectLater(
        pack.writeTo(File(occupied.path)),
        throwsA(
          isA<WorkbenchPackFailure>().having(
            (WorkbenchPackFailure failure) => failure.code,
            'code',
            WorkbenchPackFailureCode.ioFailed,
          ),
        ),
      );

      expect(File('${occupied.path}/marker.txt').readAsStringSync(), 'keep');
      expect(occupied.listSync(), hasLength(1));
      expect(_tempLeftovers(tempDir), isEmpty);
    });

    test('父路径是文件 → 写失败且旧文件原样', () async {
      final File blocker = File('${tempDir.path}/blocker')
        ..writeAsStringSync('keep');
      final File target = File('${blocker.path}/child.nmu');

      await expectLater(
        _pack(
          kind: WorkbenchPackKind.music,
          name: '音乐',
          title: '音乐',
        ).writeTo(target),
        throwsA(
          isA<WorkbenchPackFailure>().having(
            (WorkbenchPackFailure failure) => failure.code,
            'code',
            WorkbenchPackFailureCode.ioFailed,
          ),
        ),
      );

      expect(blocker.readAsStringSync(), 'keep');
      expect(_tempLeftovers(tempDir), isEmpty);
    });

    test('readFrom：文件缺失 / 非容器文本 / 非法 UTF-8 都显性失败', () async {
      final File missing = File('${tempDir.path}/missing.nmu');
      await expectLater(
        WorkbenchPack.readFrom(missing),
        throwsA(
          isA<WorkbenchPackFailure>().having(
            (WorkbenchPackFailure failure) => failure.code,
            'code',
            WorkbenchPackFailureCode.ioFailed,
          ),
        ),
      );

      final File garbage = File('${tempDir.path}/garbage.nmu')
        ..writeAsStringSync('hello');
      await expectLater(
        WorkbenchPack.readFrom(garbage),
        throwsA(
          isA<WorkbenchPackFailure>().having(
            (WorkbenchPackFailure failure) => failure.code,
            'code',
            WorkbenchPackFailureCode.invalidContainer,
          ),
        ),
      );

      final File invalidUtf8 = File('${tempDir.path}/binary.nmu')
        ..writeAsBytesSync(<int>[0xFF, 0xFE, 0x00, 0x41]);
      await expectLater(
        WorkbenchPack.readFrom(invalidUtf8),
        throwsA(
          isA<WorkbenchPackFailure>().having(
            (WorkbenchPackFailure failure) => failure.code,
            'code',
            WorkbenchPackFailureCode.ioFailed,
          ),
        ),
      );
    });
  });
}
