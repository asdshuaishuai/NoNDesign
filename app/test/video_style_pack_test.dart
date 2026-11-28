// 风格包 v1（nan.style_pack/1）：白名单字段、颜色格式、VFX 子集、确定性。
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/video/video_screenplay.dart';
import 'package:nondesign/core/video/video_style_pack.dart';

Map<String, Object?> _base() => <String, Object?>{
  'schema': 'nan.style_pack/1',
  'id': 'warm',
  'palette': <String, Object?>{
    'background': '#101010',
    'band': '#202020',
    'accent': '#ff8800',
    'text': '#ffffff',
  },
  'typography': <String, Object?>{'caption': 'lg'},
  'motion': <String, Object?>{'progress': 'ease_out'},
};

VideoStylePackVerification _verify(Map<String, Object?> raw) =>
    verifyVideoStylePack(raw, globalVfxAllowlist: videoVfxCueAllowlist);

void main() {
  test('合法风格包：解析成结构化字段', () {
    final VideoStylePackVerification result = _verify(_base());
    expect(result.verified, isTrue, reason: '${result.toJson()}');
    final VideoStylePack style = result.stylePack!;
    expect(style.id, 'warm');
    expect(style.background, 0x101010);
    expect(style.band, 0x202020);
    expect(style.accent, 0xff8800);
    expect(style.fontScale, 'lg');
    expect(style.motion, 'ease_out');
    // toJson 回环稳定。
    expect(_verify(style.toJson()).verified, isTrue);
  });

  test('schema 不对：拒绝并给 /schema', () {
    final Map<String, Object?> raw = _base()..['schema'] = 'nan.style_pack/2';
    final VideoStylePackVerification result = _verify(raw);
    expect(result.verified, isFalse);
    expect(result.checks.single.pointer, '/schema');
    expect(result.checks.single.code, videoStylePackInvalidSchema);
  });

  test('颜色格式不合法：拒绝并指向具体键', () {
    final Map<String, Object?> raw = _base();
    (raw['palette'] as Map<String, Object?>)['accent'] = 'orange';
    final VideoStylePackVerification result = _verify(raw);
    expect(result.verified, isFalse);
    expect(result.checks.single.pointer, '/palette/accent');
    expect(result.checks.single.code, videoStylePackInvalidColor);
  });

  test('字号/动效档位不在白名单：拒绝', () {
    final Map<String, Object?> raw = _base();
    (raw['typography'] as Map<String, Object?>)['caption'] = 'huge';
    (raw['motion'] as Map<String, Object?>)['progress'] = 'bounce';
    final VideoStylePackVerification result = _verify(raw);
    expect(result.verified, isFalse);
    expect(
      result.checks.map((e) => e.pointer).toList(),
      containsAll(<String>['/typography/caption', '/motion/progress']),
    );
  });

  test('text 与 background 太接近：拒绝（不做看不见的字）', () {
    final Map<String, Object?> raw = _base();
    (raw['palette'] as Map<String, Object?>)['text'] = '#121212';
    final VideoStylePackVerification result = _verify(raw);
    expect(result.verified, isFalse);
    expect(result.checks.single.pointer, '/palette/text');
  });

  test('vfxAllowlist 只能是全局子集：越界值拒绝', () {
    final Map<String, Object?> raw = _base()
      ..['vfxAllowlist'] = <Object?>['fire.campfire', 'movie.explosion'];
    final VideoStylePackVerification result = _verify(raw);
    expect(result.verified, isFalse);
    expect(result.checks.single.code, videoStylePackAllowlistEscape);
    expect(result.checks.single.pointer, '/vfxAllowlist/1');
  });

  test('vfxAllowlist 合法子集：保留', () {
    final Map<String, Object?> raw = _base()
      ..['vfxAllowlist'] = <Object?>['fire.campfire', 'ice.frost-breath'];
    final VideoStylePackVerification result = _verify(raw);
    expect(result.verified, isTrue, reason: '${result.toJson()}');
    expect(result.stylePack!.vfxAllowlist, <String>[
      'fire.campfire',
      'ice.frost-breath',
    ]);
  });

  test('未知字段保留（前向兼容）', () {
    final Map<String, Object?> raw = _base()..['future'] = <String, Object?>{'x': 1};
    final VideoStylePackVerification result = _verify(raw);
    expect(result.verified, isTrue);
    expect(result.stylePack!.raw['future'], isNotNull);
  });
}
