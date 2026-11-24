import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/project_service.dart';

void main() {
  test('prototype 元数据随 .ddp 的 docs 注释往返（不另开 sidecar）', () {
    final doc = withProjectMetadata('BODY', <String, dynamic>{
      'prd': '# PRD',
      'ui': '# UI',
      'design': <String, dynamic>{},
      'prototype': <String, dynamic>{
        'schema': 'nan.design.prototype/1',
        'html': '<section data-screen="home"></section>',
        'manifest': <String, dynamic>{'entry': 'home'},
        'verified': true,
        'checks': <Object?>[],
      },
    });
    final parsed = parseProjectMetadata(doc);
    expect(parsed['prd'], '# PRD');
    expect(parsed['prototype'], isA<Map<String, dynamic>>());
    final prototype = parsed['prototype'] as Map<String, dynamic>;
    expect(prototype['html'], contains('data-screen="home"'));
    expect((prototype['manifest'] as Map)['entry'], 'home');
    // 无 prototype 时旧形状不变（不逼老项目升级）。
    final plain = withProjectMetadata('BODY', <String, dynamic>{
      'prd': 'p',
      'ui': 'u',
    });
    expect(parseProjectMetadata(plain).containsKey('prototype'), isFalse);
  });

  test('stripProjectMetadata 同时清掉含 prototype 的 docs 注释', () {
    final doc = withProjectMetadata('BODY', <String, dynamic>{
      'prototype': <String, dynamic>{
        'schema': 'x',
        'html': 'h',
        'manifest': <String, dynamic>{},
      },
    });
    final stripped = stripProjectMetadata(doc);
    expect(stripped.contains('nondesign:docs'), isFalse);
    expect(stripped.contains('nondesign:design'), isFalse);
  });
}
