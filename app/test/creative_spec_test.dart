import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/creative/creative.dart';

import 'helpers/creative_fixtures.dart';

Set<String> _codes(CreativeValidation validation) =>
    validation.issues.map((CreativeIssue issue) => issue.code).toSet();

void main() {
  group('creative.spec', () {
    test('3D 合法请求：枚举、dims、references 与未知字段', () {
      final CreativeParseResult<CreativeSpec> result = CreativeSpec.parse(
        creativeFixture('spec_3d_ok.json'),
      );
      expect(result.ok, isTrue);
      final CreativeSpec spec = result.value!;
      expect(spec.kind, CreativeKind.threeD);
      expect(spec.track, CreativeTrack.staticObject);
      expect(spec.prompt, '一把中世纪橡木餐椅');
      expect(spec.dims['seat_height_m'], 0.45);
      expect(spec.references.single.role, CreativeReferenceRole.silhouette);
      expect(spec.output.export, CreativeExportFormat.glb);
      expect(spec.style.palette, hasLength(2));
      expect(spec.extra['experimental'], isA<Map<String, Object?>>());
    });

    test('roundtrip：toJson 再 parse 不丢字段且无问题', () {
      final CreativeSpec spec = CreativeSpec.parse(
        creativeFixture('spec_3d_ok.json'),
      ).value!;
      final CreativeParseResult<CreativeSpec> reparsed = CreativeSpec.parse(
        spec.toJson(),
      );
      expect(reparsed.ok, isTrue);
      expect(reparsed.value!.toJson(), equals(spec.toJson()));
    });

    test('视频合法请求：duration/fps/aspect 与风格包', () {
      final CreativeParseResult<CreativeSpec> result = CreativeSpec.parse(
        creativeFixture('spec_video_ok.json'),
      );
      expect(result.ok, isTrue);
      final CreativeSpec spec = result.value!;
      expect(spec.kind, CreativeKind.video);
      expect(spec.track, CreativeTrack.sillySkit);
      expect(spec.duration!.seconds, 15);
      expect(spec.duration!.fps, creativeVideoFps);
      expect(spec.duration!.aspect, '16:9');
      expect(spec.output.export, CreativeExportFormat.none);
    });

    test('坏请求一次列出全部问题（不 fail-fast）', () {
      final CreativeParseResult<CreativeSpec> result = CreativeSpec.parse(
        creativeFixture('spec_bad.json'),
      );
      expect(result.ok, isFalse);
      expect(result.value, isNull);
      expect(
        _codes(result.validation),
        containsAll(<String>[
          'spec_schema_mismatch',
          'spec_track_kind_mismatch',
          'spec_prompt_missing',
          'spec_fps_unsupported',
          'spec_aspect_invalid',
          'spec_reference_path_unsafe',
          'spec_reference_role_invalid',
          'spec_style_pack_invalid',
          'spec_style_palette_invalid',
          'spec_export_blocked',
        ]),
      );
    });

    test('视频缺 duration 是阻断项', () {
      final Map<String, dynamic> raw = creativeFixtureCopy('spec_video_ok.json')
        ..remove('duration');
      final CreativeParseResult<CreativeSpec> result = CreativeSpec.parse(raw);
      expect(result.ok, isFalse);
      expect(_codes(result.validation), contains('spec_duration_required'));
    });

    test('缺省 style/output 用文档默认值', () {
      final CreativeParseResult<CreativeSpec> result = CreativeSpec.parse(
        <String, Object?>{
          'schema': creativeSpecSchema,
          'kind': '3d',
          'track': 'static_object',
          'prompt': '一个简单的方块',
        },
      );
      expect(result.ok, isTrue);
      final CreativeSpec spec = result.value!;
      expect(spec.style.pack, CreativeStylePack.neutral);
      expect(spec.output.preview, isTrue);
      expect(spec.output.source, isTrue);
      expect(spec.output.export, CreativeExportFormat.none);
      expect(spec.mustHave, isEmpty);
      expect(spec.duration, isNull);
    });

    test('3D 请求给了视频 track：kind/track 不匹配', () {
      final Map<String, dynamic> raw = <String, dynamic>{
        'schema': creativeSpecSchema,
        'kind': '3d',
        'track': 'silly_skit',
        'prompt': 'x',
      };
      final CreativeParseResult<CreativeSpec> result = CreativeSpec.parse(raw);
      expect(result.ok, isFalse);
      expect(_codes(result.validation), contains('spec_track_kind_mismatch'));
    });

    test('参考路径不允许逃出项目', () {
      final Map<String, dynamic> raw = <String, dynamic>{
        'schema': creativeSpecSchema,
        'kind': '3d',
        'track': 'static_object',
        'prompt': 'x',
        'references': <Object?>[
          <String, Object?>{'path': 'refs/../../secret.png', 'role': 'style'},
        ],
      };
      final CreativeParseResult<CreativeSpec> result = CreativeSpec.parse(raw);
      expect(_codes(result.validation), contains('spec_reference_path_unsafe'));
    });
  });
}
