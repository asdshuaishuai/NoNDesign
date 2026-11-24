import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/project_service.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/workspace_stage.dart';
import 'package:shared_preferences/shared_preferences.dart';

RenderEnvelope _renderWithTwoScreens() => RenderEnvelope(
  ok: true,
  entry: 'home',
  revision: 1,
  artboards: <Artboard>[
    const Artboard(
      id: 'home',
      name: '首页',
      width: 390,
      height: 844,
      nodes: <CanvasNode>[],
      svg: '<svg viewBox="0 0 390 844"></svg>',
    ),
    const Artboard(
      id: 'menu',
      name: '菜单',
      width: 390,
      height: 844,
      nodes: <CanvasNode>[],
    ),
  ],
  flows: <Flow>[const Flow(from: 'home', to: 'menu', trigger: 'tap:n1')],
);

void main() {
  late Directory temp;
  late AppStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('nondesign-proto-');
    store = AppStore(
      projects: ProjectService(root: () async => temp),
      toasts: ToastService(autoDismiss: false),
    );
    store.recoveryDir = '${temp.path}/recovery';
    store.settingsMirrorDir = '${temp.path}/settings';
    store.hasProject = true;
    store.projectName = 'demo';
    store.projectPath = '${temp.path}/demo.ddp';
    store.mbt = 'MBT_BODY';
    store.render = _renderWithTwoScreens();
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('验证原型：构建/覆盖校验/写进 .ddp docs/产物卡/不再调模型', () async {
    expect(store.render.artboards, hasLength(2));
    await store.verifyDesignPrototype();

    final prototype = store.docs.prototype;
    expect(prototype, isNotNull);
    expect(prototype!['schema'], 'nan.design.prototype/1');
    expect(prototype['verified'], isTrue);
    final html = prototype['html'] as String;
    expect(html, contains('data-screen="home"'));
    expect(html, contains('data-screen="menu"'));
    expect(html, contains('data-nav="menu"'));
    expect(html, isNot(contains('http://')));

    // 落进项目文件（不另开 sidecar），重新打开可恢复。
    final opened = await store.projects.open('${temp.path}/demo.ddp');
    expect(opened.ok, isTrue);
    expect(opened.docs?['prototype'], isA<Map<String, dynamic>>());

    // 聊天里出现产物卡（用户可见面）。
    expect(
      store.chatMessages.any(
        (m) =>
            m.kind == chatKindArtifact && m.artifactKind == artifactPrototype,
      ),
      isTrue,
    );

    // 双面组件数据面：阶段条终态 + 结果卡 + 可收起。
    expect(store.designPrototypeResult, isNotNull);
    expect(store.designPrototypeResult!.verified, isTrue);
    expect(store.designPrototypeStages.map((s) => s.id).toList(), <String>[
      'build',
      'verify',
      'persist',
    ]);
    expect(store.designPrototypeStages.last.state, WorkspaceStageState.done);
    store.dismissDesignPrototypeResult();
    expect(store.designPrototypeResult, isNull);
    expect(store.designPrototypeStages, isEmpty);
  });

  test('未保存项目：验证原型留在内存并标 dirty，不假装已保存', () async {
    store.projectPath = null;
    store.dirty = false;
    await store.verifyDesignPrototype();
    expect(store.docs.prototype, isNotNull);
    expect(store.dirty, isTrue);
    expect(File('${temp.path}/demo.ddp').existsSync(), isFalse);
  });

  test('画布没有原型：给出人话提示，不写 prototype', () async {
    store.render = RenderEnvelope.empty();
    await store.verifyDesignPrototype();
    expect(store.docs.prototype, isNull);
  });
}
