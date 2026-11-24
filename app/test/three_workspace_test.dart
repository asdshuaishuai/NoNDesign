import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/creative/creative_plan.dart';
import 'package:nondesign/core/creative/creative_schema.dart';
import 'package:nondesign/core/creative/creative_spec.dart';
import 'package:nondesign/core/three/three_workspace.dart';

import 'helpers/creative_fixtures.dart';

Map<String, dynamic> _legacySpec() => <String, dynamic>{
  'title': 'Saturn',
  'summary': '带环行星自转',
  'components': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'planet', 'what': '球体', 'size_scale': 1.0},
    <String, dynamic>{'id': 'ring', 'what': '扁平圆环', 'size_scale': 1.8},
  ],
  'materials': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'rock', 'color_hex': '#c9a06a'},
  ],
  'acceptance': <String>['行星在场', '环可见 ≤2mm'],
};

void main() {
  late Directory temp;
  late ThreeWorkspaceStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('nondesign-3dws-');
    store = ThreeWorkspaceStore(temp);
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  group('旧布局迁移', () {
    test(
      'three-spec.json/scene.js/build-state.json → spec/plan/src，旧文件保留',
      () async {
        final dir = Directory('${temp.path}/saturn')
          ..createSync(recursive: true);
        File('${dir.path}/three-spec.json')
            .writeAsStringSync(jsonEncode(_legacySpec()));
        File('${dir.path}/scene.js')
            .writeAsStringSync('export default function build() {}\n');
        File('${dir.path}/build-state.json').writeAsStringSync(
          jsonEncode(<String, Object?>{
            'current': 'structure',
            'blocked': false,
            'passes': <Object?>[],
          }),
        );

        final before = await store.list();
        expect(before, hasLength(1));
        expect(before.single.mode, ThreeAuthoringMode.legacy);
        expect(before.single.legacyCurrentPass, 'structure');

        final result = await store.migrateLegacy('saturn');
        expect(result.alreadyMigrated, isFalse);
        expect(result.wroteSpec, isTrue);
        expect(result.wrotePlan, isTrue);
        expect(result.copiedScene, isTrue);
        expect(result.planWarnings.join('\n'), contains('dims 来自'));

        // 旧文件一个都不删。
        expect(File('${dir.path}/three-spec.json').existsSync(), isTrue);
        expect(File('${dir.path}/scene.js').existsSync(), isTrue);
        expect(File('${dir.path}/build-state.json').existsSync(), isTrue);
        // 新布局齐全。
        expect(File('${dir.path}/spec.json').existsSync(), isTrue);
        expect(File('${dir.path}/plan.json').existsSync(), isTrue);
        expect(File('${dir.path}/src/scene.js').existsSync(), isTrue);
        expect(File('${dir.path}/migration.json').existsSync(), isTrue);
        expect(
          File('${dir.path}/artifacts/legacy-build-state.json').existsSync(),
          isTrue,
        );

        final project = await store.read('saturn');
        expect(project.migrated, isTrue);
        expect(project.mode, ThreeAuthoringMode.code);
        expect(project.spec, isA<CreativeSpec>());
        expect(project.spec!.kind.name, 'threeD');
        expect(project.plan, isA<CreativePlan3d>());
        expect(project.plan!.parts, hasLength(2));
        expect(project.sourceFiles, <String>['scene.js']);
        expect(project.issues, isEmpty);

        // 幂等。
        final again = await store.migrateLegacy('saturn');
        expect(again.alreadyMigrated, isTrue);
        expect(again.wroteSpec, isFalse);
      },
    );

    test('缺旧规范 → no_legacy；非法名字 → invalid_name；缺项目 → no_project', () async {
      final dir = Directory('${temp.path}/empty')..createSync(recursive: true);
      expect(dir.existsSync(), isTrue);
      await expectLater(
        () => store.migrateLegacy('empty'),
        throwsA(
          isA<ThreeWorkspaceFailure>().having(
            (f) => f.code,
            'code',
            'no_legacy',
          ),
        ),
      );
      await expectLater(
        () => store.read('nope'),
        throwsA(
          isA<ThreeWorkspaceFailure>().having(
            (f) => f.code,
            'code',
            'no_project',
          ),
        ),
      );
      await expectLater(
        () => store.read('../escape'),
        throwsA(
          isA<ThreeWorkspaceFailure>().having(
            (f) => f.code,
            'code',
            'invalid_name',
          ),
        ),
      );
    });
  });

  group('v2 工作区读写', () {
    test(
      'writeSpec/writePlan/writeSource/writeArtifact → read 反映 code 模式',
      () async {
        final spec = CreativeSpec.parse(creativeFixture('spec_3d_ok.json'))
            .value!;
        final plan =
            CreativePlan.parse(creativeFixture('plan_3d_chair.json')).value!
                as CreativePlan3d;
        Directory('${temp.path}/chair').createSync(recursive: true);
        await store.writeSpec('chair', spec);
        await store.writePlan('chair', plan);
        await store.writeSource(
          'chair',
          'parts/seat.js',
          'export const seat = {};\n',
        );
        await store.writeArtifact('chair', 'gates.json', <String, Object?>{
          'schema': 'x',
        });

        final project = await store.read('chair');
        expect(project.migrated, isTrue);
        expect(project.mode, ThreeAuthoringMode.code);
        expect(project.spec!.track.name, 'staticObject');
        expect(project.plan!.parts, hasLength(3));
        expect(project.sourceFiles, <String>['parts/seat.js']);
        expect(
          File('${temp.path}/chair/artifacts/gates.json').existsSync(),
          isTrue,
        );
        expect(project.issues, isEmpty);
      },
    );

    test('scene.json 存在且无 src → scene 模式', () async {
      Directory('${temp.path}/room').createSync(recursive: true);
      await store.writeSpec(
        'room',
        CreativeSpec.parse(creativeFixture('spec_3d_ok.json')).value!,
      );
      await store.writeScene('room', <String, Object?>{
        'v': 1,
        'nodes': <Object?>[],
      });
      final project = await store.read('room');
      expect(project.mode, ThreeAuthoringMode.scene);
      expect(project.sceneJson, isNotNull);
      expect(project.migrated, isTrue);
    });

    test('非法 plan 拒绝写入；路径逃逸拒绝', () async {
      Directory('${temp.path}/bad').createSync(recursive: true);
      const invalid = CreativePlan3d(
        summary: 'x',
        acceptance: <String>[],
        track: CreativeTrack.staticObject,
        language: 'threejs',
      );
      await expectLater(
        () => store.writePlan('bad', invalid),
        throwsA(
          isA<ThreeWorkspaceFailure>().having(
            (f) => f.code,
            'code',
            'plan_invalid',
          ),
        ),
      );
      final plan =
          CreativePlan.parse(creativeFixture('plan_3d_chair.json')).value!
              as CreativePlan3d;
      await store.writePlan('bad', plan);
      await expectLater(
        () => store.writeSource('bad', '../escape.js', 'x'),
        throwsA(
          isA<ThreeWorkspaceFailure>().having(
            (f) => f.code,
            'code',
            'invalid_path',
          ),
        ),
      );
    });
  });

  test('list：空目录跳过，迁移后显示 migrated', () async {
    Directory('${temp.path}/skip').createSync(recursive: true);
    final dir = Directory('${temp.path}/legacy')..createSync(recursive: true);
    File('${dir.path}/three-spec.json')
        .writeAsStringSync(jsonEncode(_legacySpec()));
    final before = await store.list();
    expect(before.map((entry) => entry.name), <String>['legacy']);
    await store.migrateLegacy('legacy');
    final after = await store.list();
    expect(after.single.migrated, isTrue);
  });
}
