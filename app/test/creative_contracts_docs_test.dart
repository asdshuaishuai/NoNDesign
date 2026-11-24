import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// R0 契约文档门：四份模块契约 + 决策冻结必须存在、带状态行、被总纲索引，
/// 且与 Dart 契约常量对得上。文档是目标态，不是现状——这里只锁「契约是否在
/// 位」，不锁实现。
void main() {
  final Directory docsDir = Directory('../docs');
  final String readme = File('${docsDir.path}/README.md').readAsStringSync();

  const List<String> contracts = <String>[
    'design-contract.md',
    'three-contract.md',
    'video-screenplay-contract.md',
    'music-contract.md',
    'creative-refactor-decisions.md',
  ];

  group('R0 契约文档', () {
    for (final String name in contracts) {
      test('$name 存在且带 R0 状态行', () {
        final File file = File('${docsDir.path}/$name');
        expect(file.existsSync(), isTrue, reason: '缺少 $name');
        final List<String> lines = file.readAsLinesSync();
        expect(lines.first.startsWith('# '), isTrue, reason: '$name 第一行必须是标题');
        final String head = lines.take(6).join('\n');
        expect(head.contains('状态：'), isTrue, reason: '$name 缺状态行');
        expect(
          head.contains('R0') ||
              head.contains('R3') ||
              head.contains('已实施') ||
              head.contains('已落地'),
          isTrue,
          reason: '$name 状态行必须写明 R0 冻结或已实施',
        );
      });

      test('$name 已进 docs/README 索引', () {
        expect(
          readme.contains(name),
          isTrue,
          reason: 'docs/README.md 未索引 $name',
        );
      });
    }

    test('决策冻结记录 Genkit 迁移裁决', () {
      final String decisions = File(
        '${docsDir.path}/creative-refactor-decisions.md',
      ).readAsStringSync();
      expect(decisions.contains('Genkit'), isTrue);
      expect(decisions.contains('ai_sdk'), isTrue);
    });

    test('契约文档引用了 Dart 侧 schema 常量', () {
      final String three = File('${docsDir.path}/three-contract.md')
          .readAsStringSync();
      final String video = File('${docsDir.path}/video-screenplay-contract.md')
          .readAsStringSync();
      expect(
        three.contains('nan.creative.plan/1') || three.contains('schemas.md'),
        isTrue,
      );
      expect(
        video.contains('nan.screenplay/1') || video.contains('screenplay'),
        isTrue,
      );
    });
  });
}
