// 3D 场景质检（spatial lint）：把「场景为什么看起来不对」变成可判定、可修的条目。
// 参照 three-live 的空间 linter 思路，但全部是本地的、只读的确定性检查。
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/three_kits.dart';
import 'package:nondesign/core/three_lint.dart';
import 'package:nondesign/core/three_service.dart';

ThreeProjectSnapshot _snapshot({
  Map<String, dynamic>? spec,
  Map<String, dynamic>? state,
  String sceneJs = '',
}) =>
    ThreeProjectSnapshot(
      name: 'demo',
      spec: spec ??
          <String, dynamic>{
            'summary': '一个带环行星',
            'components': <String>['行星', '环', '星空'],
            'acceptance': <String>['主体居中', '有主光'],
          },
      state: state ?? initialThreeState(),
      sceneJs: sceneJs,
      history: const <Map<String, dynamic>>[],
      dir: '/tmp/demo',
    );

void main() {
  test('空场景 + 空规范：三条必修（没有代码/没有组件/没有验收）', () {
    final report = lintThreeProject(_snapshot(
      spec: const <String, dynamic>{'summary': 'x'},
      sceneJs: '',
    ));
    expect(report.errors, greaterThanOrEqualTo(3));
    final titles = report.issues.map((i) => i.title).toList();
    expect(titles, contains('还没有场景代码'));
    expect(titles, contains('规范缺少组件清单'));
    expect(titles, contains('规范缺少验收标准'));
  });

  test('骨架场景被判定为「还是骨架」', () {
    final report = lintThreeProject(_snapshot(sceneJs: threeSceneSkeleton));
    expect(report.issues.any((i) => i.title == '场景还是骨架'), isTrue);
  });

  test('完整场景：没有灯光/材质时给出建议，具备后只剩进度提示', () {
    const scene = '''
export default function build(THREE, scene, camera, controls, renderer) {
  const m = new THREE.Mesh(new THREE.SphereGeometry(1, 32, 32),
      new THREE.MeshStandardMaterial({ color: 0x88aaff }));
  scene.add(m);
}
''';
    final withLights = lintThreeProject(_snapshot(
      sceneJs: '$scene\nconst light = new THREE.DirectionalLight(0xffffff, 1);',
      state: <String, dynamic>{
        ...initialThreeState(),
        'passes': [
          for (final pass in threePasses)
            <String, dynamic>{'id': pass.id, 'status': 'done', 'attempts': 1, 'evidence': <String>[]},
        ],
        'current': 'done',
      },
    ));
    expect(withLights.issues.any((i) => i.title == '场景没有灯光'), isFalse);
    expect(withLights.issues.any((i) => i.title == '材质还没定义'), isFalse);
    expect(withLights.issues.any((i) => i.title == '还有 5 层没做'), isFalse);
    expect(withLights.clean, isTrue);
  });

  test('缺少相机 → 建议；循环卡住 → 必修', () {
    final report = lintThreeProject(_snapshot(
      sceneJs: 'const mesh = new THREE.Mesh(new THREE.BoxGeometry(1,1,1), '
          'new THREE.MeshStandardMaterial({color: 0xffffff})); scene.add(mesh);'
          ' const light = new THREE.DirectionalLight(0xffffff, 1);',
      state: <String, dynamic>{
        ...initialThreeState(),
        'blocked': true,
        'blocked_reason': '材质层连续 3 次未通过',
      },
    ));
    expect(report.issues.any((i) => i.title == '没有找到相机设置'), isTrue);
    final blocked = report.issues.where((i) => i.title == '场景推进被卡住').toList();
    expect(blocked, hasLength(1));
    expect(blocked.first.level, ThreeLintLevel.error);
    expect(blocked.first.detail, contains('材质层'));
  });

  test('物体数量偏多只给提示，不算必修', () {
    final many = List<String>.generate(
        130, (i) => 'scene.add(new THREE.Mesh(geo$i, mat));').join('\n');
    final report = lintThreeProject(_snapshot(
      sceneJs: 'const camera = new THREE.PerspectiveCamera();\nconst light = 1;\n$many',
      state: <String, dynamic>{
        ...initialThreeState(),
        'passes': [
          for (final pass in threePasses)
            <String, dynamic>{'id': pass.id, 'status': 'done', 'attempts': 1, 'evidence': <String>[]},
        ],
      },
    ));
    final perf = report.issues.where((i) => i.title.startsWith('物体数量偏多')).toList();
    expect(perf, hasLength(1));
    expect(perf.first.level, ThreeLintLevel.info);
  });

  test('场景套件目录：六个套件、id/名称/目标/brief 均非空且 id 唯一', () {
    expect(threeKits, hasLength(6));
    final ids = threeKits.map((k) => k.id).toSet();
    expect(ids, hasLength(threeKits.length));
    for (final kit in threeKits) {
      expect(kit.id, isNotEmpty);
      expect(kit.name, isNotEmpty);
      expect(kit.brief.trim().length, greaterThan(16), reason: '${kit.id} 的 brief 要有可生成的信息量');
      expect(kit.tags, isNotEmpty);
      expect(kit.hint, isNotEmpty);
    }
    expect(threeKits.map((k) => k.id), contains('product_turntable'));
  });
}
