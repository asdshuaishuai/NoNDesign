// 创作栈守卫：把 `docs/audit-3d-video-2026-11-27.md` 的核查结论变成自动红绿灯。
//
// 这份测试不是「再测一遍功能」，而是防止**已经对齐的事实**被后来的改动悄悄破坏：
//  1. 3D 栈资源锁定：three.module.js 字节/sha256 与代码常量一致、three-live 许可与
//     内嵌占位、预览页 CSP 不放宽网络；
//  2. ThreeUI 目录一致性：组件数在硬边界内、每个 catalog 条目都有对应文件；
//  3. 视频 v1 短片：clips.json 每条的页面都在、引擎资产在场、页面零网络引用；
//  4. 只参考项零依赖：依赖面与代码/资产/脚本目录里都不出现被裁决「不引入」的运行时；
//  5. 工具面与文案映射：video3d_* 工具在场，每条失败码都有 `toolFailureMessage` 分支；
//  6. SKILL 契约在场且已注入：SKILL.md 与 7 份参考不丢，蒸馏纪律真的被 run 引用。
//
// 全部是只读断言；不启动应用、不打网络。
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/three_service.dart';

/// 仓库内的相对路径统一用 `/`（Windows 下 `p` 可能带 `\`）。
String _norm(String path) => path.replaceAll('\\', '/');

File _file(String path) => File(_norm(path));

String _read(String path) => _file(path).readAsStringSync();

Future<String> _sha256Hex(List<int> bytes) async {
  final hash = await Sha256().hash(bytes);
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// 递归收集目录下的文本文件（跳过明显二进制与超大产物）。
Iterable<File> _textFiles(Directory dir) {
  if (!dir.existsSync()) return const <File>[];
  const Set<String> suffixes = <String>{
    '.dart',
    '.js',
    '.mjs',
    '.json',
    '.html',
    '.css',
    '.yaml',
    '.yml',
    '.py',
    '.sh',
    '.md',
    '.txt',
    '.lock',
  };
  final List<File> files = <File>[];
  for (final FileSystemEntity entity in dir.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    final String name = _norm(entity.path).toLowerCase();
    final int dot = name.lastIndexOf('.');
    if (dot < 0 || !suffixes.contains(name.substring(dot))) continue;
    files.add(entity);
  }
  return files;
}

/// 标识符边界：`a-z0-9_-` 视作单词字符（`material-painter` 的连字符要算进去）。
bool _isIdentifierChar(int codeUnit) =>
    (codeUnit >= 0x61 && codeUnit <= 0x7a) ||
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    codeUnit == 0x5f ||
    codeUnit == 0x2d;

/// 作为**独立标识符**出现（不是藏在 base64/随机串里的巧合子串）。
///
/// 例：threeui 页面里一张 base64 图片恰好含 `RAeaYf`，lowercase 后有 `raea`，
/// 但它前后都是字母，不是对 raea 项目的引用——必须判为不命中。
bool _hasStandaloneToken(String text, String token) {
  int index = text.indexOf(token);
  while (index >= 0) {
    final int before = index == 0 ? 0x20 : text.codeUnitAt(index - 1);
    final int afterPos = index + token.length;
    final int after = afterPos >= text.length ? 0x20 : text.codeUnitAt(afterPos);
    if (!_isIdentifierChar(before) && !_isIdentifierChar(after)) return true;
    index = text.indexOf(token, index + 1);
  }
  return false;
}

/// 去掉 `data:` 内联资源（base64 图/字体），它们的字节不是「引用」证据。
String _stripDataUris(String text) =>
    text.replaceAll(RegExp(r'''data:[^"')]+'''), ' ');

void main() {
  group('3D 栈资源锁定', () {
    test('three.module.js 字节与 sha256 与代码常量一致（CRLF/裁剪都会红）', () async {
      final File module = _file('assets/three/three.module.js');
      expect(module.existsSync(), isTrue);
      expect(module.lengthSync(), threeModuleByteLength);
      final String digest = await _sha256Hex(module.readAsBytesSync());
      expect(digest, threeModuleSha256);
    });

    test('three-live 在库且许可/NOTICE 完整，版本与字节记录可对账', () {
      final File live = _file(threeLiveAssetKey);
      expect(live.existsSync(), isTrue);
      expect(live.lengthSync(), greaterThan(200000));
      expect(_file('assets/three/vendor/THREE-LIVE-LICENSE').existsSync(), isTrue);
      final String notice = _read('assets/three/vendor/NOTICE.md');
      expect(notice, contains('1.4.0'));
      expect(notice, contains('Apache-2.0'));
    });

    test('预览页：three-live 占位恰好一处，外联通道整体关闭', () {
      final String page = _read('assets/three/preview.html');
      // 占位符字面量含 `*`/`/`，用字符串切分数，别写成正则（会被当量词）。
      final int occurrences =
          page.split('/*__THREE_LIVE__*/').length - 1;
      expect(occurrences, 1, reason: 'three-live 占位必须恰好一处');
      expect(page, contains("default-src 'none'"));
      // 沙箱只放开 eval 与 blob worker；外联通道必须显式关掉（不是"没写"）。
      expect(page, contains("connect-src 'none'"));
      expect(page, isNot(contains("connect-src 'self'")));
    });
  });

  group('ThreeUI 目录一致性', () {
    test('组件数在硬边界内，且每个 catalog 条目都有页面文件', () {
      final Map<String, dynamic> catalog =
          jsonDecode(_read('assets/three/threeui/catalog.json'))
              as Map<String, dynamic>;
      final List<dynamic> components = catalog['components'] as List<dynamic>;
      expect(components.length, greaterThanOrEqualTo(threeUiMinComponents));
      expect(components.length, lessThanOrEqualTo(threeUiMaxComponents));

      final Set<String> ids = <String>{};
      for (final dynamic raw in components) {
        final Map<String, dynamic> item = raw as Map<String, dynamic>;
        final String id = (item['id'] ?? '').toString();
        final String file = (item['file'] ?? '').toString();
        expect(id.isNotEmpty, isTrue, reason: 'catalog 条目缺 id');
        expect(ids.add(id), isTrue, reason: 'catalog 里 $id 重复');
        expect(file.isNotEmpty, isTrue, reason: '$id 缺 file');
        final File page = _file('assets/three/threeui/$file');
        expect(page.existsSync(), isTrue, reason: '$id 的页面 $file 不在库');
        expect(page.lengthSync(), greaterThan(1000), reason: '$id 的页面是空壳');
      }
      for (final String extra in <String>[
        'NOTICE.md',
        'LICENSE',
        'FONT-LICENSES.md',
      ]) {
        expect(
          _file('assets/three/threeui/$extra').existsSync(),
          isTrue,
          reason: '$extra 不在库',
        );
      }
    });
  });

  group('视频 v1 短片资源', () {
    test('clips.json 每条的页面都在，引擎资产在场', () {
      final List<dynamic> clips =
          jsonDecode(_read('assets/video/clip/clips.json')) as List<dynamic>;
      expect(clips, isNotEmpty);
      for (final dynamic raw in clips) {
        final Map<String, dynamic> clip = raw as Map<String, dynamic>;
        final String id = (clip['id'] ?? '').toString();
        final String file = (clip['file'] ?? '').toString();
        expect(id.isNotEmpty, isTrue);
        expect(
          _file('assets/video/clip/$file').existsSync(),
          isTrue,
          reason: '短片 $id 的页面 $file 不在库',
        );
      }
      expect(_file('assets/video/clip/engine.js').existsSync(), isTrue);
      expect(_file('assets/video/clip/engine.css').existsSync(), isTrue);
    });

    test('短片页面零网络引用（只有 SVG 命名空间这类标识符）', () {
      for (final File page in _textFiles(
        Directory('assets/video/clip'),
      ).where((f) => _norm(f.path).endsWith('.html'))) {
        final String html = page.readAsStringSync().toLowerCase();
        expect(html, isNot(contains('src="http')), reason: '${page.path} 有外链脚本');
        expect(html, isNot(contains("src='http")), reason: '${page.path} 有外链脚本');
        expect(html, isNot(contains('href="http')), reason: '${page.path} 有外链样式/资源');
        expect(html, isNot(contains('fetch(')), reason: '${page.path} 有网络请求');
      }
    });
  });

  group('只参考项零依赖（防回归）', () {
    // 用户裁决「只参考、不引入」的运行时/产品：出现即说明有人把参考当依赖了。
    const List<String> banned = <String>[
      'raea',
      'material-painter',
      'material_painter',
      'openmotion',
      'hyperframes',
      'remotion',
      'bevy',
      'phaser',
    ];

    test('依赖面不含被禁运行时', () {
      final String pubspec = _read('pubspec.yaml').toLowerCase();
      for (final String name in banned) {
        expect(
          pubspec,
          isNot(contains(name)),
          reason: 'pubspec.yaml 出现了 $name（被裁决不引入）',
        );
      }
    });

    test('代码/资产/脚本目录不含被禁运行时的字样', () {
      final List<Directory> roots = <Directory>[
        Directory('lib'),
        Directory('assets'),
        Directory('../third_party'),
        Directory('../plugins'),
        Directory('../scripts'),
      ];
      final List<String> hits = <String>[];
      for (final Directory root in roots) {
        for (final File file in _textFiles(root)) {
          final String text;
          try {
            text = _stripDataUris(file.readAsStringSync()).toLowerCase();
          } on FileSystemException {
            continue; // 读不出来的文件不参与判定（不是证据）
          }
          for (final String name in banned) {
            if (_hasStandaloneToken(text, name)) {
              hits.add('${_norm(file.path)} → $name');
            }
          }
        }
      }
      expect(hits, isEmpty, reason: '被禁运行时的残留：${hits.join('; ')}');
    });
  });

  group('工具面与文案映射', () {
    late String agentSource;

    setUpAll(() {
      agentSource = _read('lib/core/dart_agent.dart');
    });

    test('3D / 视频 / 3D 视频工具全部注册', () {
      const List<String> tools = <String>[
        'three_list',
        'three_create',
        'three_status',
        'three_pass',
        'three_continue',
        'three_feedback',
        'three_workspace_migrate',
        'three_plan_validate',
        'three_measure',
        'three_build',
        'three_check',
        'three_check_placement',
        'video_list',
        'video_sample',
        'video_create',
        'video_review',
        'video_render',
        'video3d_list',
        'video3d_status',
        'video3d_create',
        'creative_judge',
      ];
      for (final String name in tools) {
        expect(agentSource, contains("'$name'"), reason: '工具 $name 没注册');
      }
    });

    test('每条 video3d 失败码都有 toolFailureMessage 分支', () {
      // 字面量码（`video3d_${error.code}` 这类动态拼接不在此列）。
      final Set<String> literalCodes = RegExp(
        r"'video3d_[a-z_]+'",
      ).allMatches(agentSource).map((m) => m.group(0)!.replaceAll("'", '')).toSet();
      // 存储层抛出的 code 会自动拼成 video3d_<code>，这里保证六个都有映射。
      const List<String> storeCodes = <String>[
        'invalid_name',
        'path_escape',
        'no_project',
        'corrupt',
        'invalid_input',
        'io_error',
      ];
      final Set<String> codes = <String>{
        ...literalCodes,
        for (final String code in storeCodes) 'video3d_$code',
      };
      for (final String code in codes) {
        expect(
          agentSource,
          contains("case '$code':"),
          reason: '$code 没有 toolFailureMessage 人话映射',
        );
      }
    });
  });

  group('SKILL 契约在场且已注入', () {
    test('SKILL.md 与 7 份参考都在，且不是空壳', () {
      final File skill = _file('../docs/skills/creative-workbench/SKILL.md');
      expect(skill.existsSync(), isTrue);
      expect(skill.readAsLinesSync().length, greaterThanOrEqualTo(300));
      final String body = skill.readAsStringSync();
      expect(body, contains('applies_to'));
      expect(body, contains('intake'));
      expect(body, contains('deliver'));

      const List<String> refs = <String>[
        '3d-pipeline.md',
        'video-pipeline.md',
        'vfx-pixelfx.md',
        'story-short.md',
        'schemas.md',
        'judging.md',
        'prompt-anatomy.md',
      ];
      for (final String name in refs) {
        final File ref = _file(
          '../docs/skills/creative-workbench/references/$name',
        );
        expect(ref.existsSync(), isTrue, reason: '参考 $name 不在库');
        expect(
          ref.readAsLinesSync().length,
          greaterThanOrEqualTo(80),
          reason: '参考 $name 被写空了',
        );
      }
    });

    test('蒸馏纪律真的被 run 引用（不是只写在文档里）', () {
      final String discipline = _read('lib/core/creative/creative_skill.dart');
      expect(discipline, contains('creativeWorkbenchCore'));
      expect(discipline, contains('creativeSkillForWorkspace'));
      expect(
        _read('lib/core/dart_agent.dart'),
        contains('creativeWorkbenchCore'),
        reason: 'dart_agent 没有注入创作纪律',
      );
    });
  });
}
