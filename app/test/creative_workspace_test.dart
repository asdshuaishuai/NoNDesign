import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/creative/creative.dart';

void main() {
  group('creative.workspace 轮次协议', () {
    test('轮次标签：零填充、解析与比较', () {
      const CreativeRoundId zero = CreativeRoundId(0);
      expect(zero.label, 'r00');
      expect(const CreativeRoundId(7).label, 'r07');
      expect(const CreativeRoundId(100).label, 'r100');
      expect(CreativeRoundId.parse('r03')!.number, 3);
      expect(CreativeRoundId.parse('r100')!.number, 100);
      expect(CreativeRoundId.parse('r1'), isNull);
      expect(CreativeRoundId.parse('x01'), isNull);
      expect(CreativeRoundId.parse(null), isNull);
      expect(const CreativeRoundId(1) == const CreativeRoundId(1), isTrue);
      expect(
        const CreativeRoundId(1).compareTo(const CreativeRoundId(2)),
        lessThan(0),
      );
    });

    test('judge/rNN 路径视图', () {
      const CreativeRoundPaths paths = CreativeRoundPaths(CreativeRoundId(3));
      expect(paths.label, 'r03');
      expect(paths.dir, 'judge/r03');
      expect(paths.brief, 'judge/r03/brief.md');
      expect(paths.judgment, 'judge/r03/judgment.json');
      expect(paths.score, 'judge/r03/score.json');
      expect(CreativeWorkspaceLayout.specFile, 'spec.json');
      expect(CreativeWorkspaceLayout.planFile, 'plan.json');
      expect(CreativeWorkspaceLayout.srcDir, 'src');
      expect(CreativeWorkspaceLayout.artifactsDir, 'artifacts');
      expect(CreativeWorkspaceLayout.roundDir('r00'), 'judge/r00');
    });

    test('项目名与项目内相对路径安全校验', () {
      expect(creativeIsSafeProjectName('chair_01'), isTrue);
      expect(creativeIsSafeProjectName('a-b'), isTrue);
      expect(creativeIsSafeProjectName('椅子'), isFalse);
      expect(creativeIsSafeProjectName(''), isFalse);
      expect(creativeIsSafeProjectName('-bad'), isFalse);

      expect(creativeIsSafeRelativePath('refs/chair.png'), isTrue);
      expect(creativeIsSafeRelativePath('src/scene.js'), isTrue);
      expect(creativeIsSafeRelativePath('../escape.png'), isFalse);
      expect(creativeIsSafeRelativePath('/abs.png'), isFalse);
      expect(creativeIsSafeRelativePath('C:/abs.png'), isFalse);
      expect(creativeIsSafeRelativePath('a//b.png'), isFalse);
      expect(creativeIsSafeRelativePath(''), isFalse);
    });
  });

  group('creative.round manifest', () {
    test('合法清单：git-first + 快照回退字段', () {
      final Map<String, Object?> raw = <String, Object?>{
        'round': 'r01',
        'gitTag': 'r01',
        'gitCommit': 'abcdef0',
        'srcHash': 'a' * 64,
        'createdAt': '2026-11-23T10:00:00Z',
        'note': 'keep me',
      };
      final CreativeParseResult<CreativeRoundManifest> result =
          CreativeRoundManifest.parse(raw);
      expect(result.ok, isTrue);
      final CreativeRoundManifest manifest = result.value!;
      expect(manifest.round.label, 'r01');
      expect(manifest.gitTag, 'r01');
      expect(manifest.srcHash, 'a' * 64);
      expect(manifest.createdAt!.isUtc, isTrue);
      expect(manifest.extra['note'], 'keep me');
      final CreativeParseResult<CreativeRoundManifest> reparsed =
          CreativeRoundManifest.parse(manifest.toJson());
      expect(reparsed.ok, isTrue);
      expect(reparsed.value!.toJson(), equals(manifest.toJson()));
    });

    test('坏清单：轮次/哈希/时间', () {
      final CreativeParseResult<CreativeRoundManifest> result =
          CreativeRoundManifest.parse(<String, Object?>{
            'round': 'r1',
            'srcHash': 'not-a-hash',
            'createdAt': 'yesterday',
          });
      expect(result.ok, isFalse);
      final Set<String> codes = result.validation.issues
          .map((CreativeIssue issue) => issue.code)
          .toSet();
      expect(
        codes,
        containsAll(<String>[
          'round_manifest_round_invalid',
          'round_manifest_hash_invalid',
          'round_manifest_created_invalid',
        ]),
      );
    });
  });
}
