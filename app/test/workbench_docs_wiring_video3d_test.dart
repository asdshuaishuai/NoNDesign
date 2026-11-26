// 3D 视频工作台「生成文档」接线回归（task-45）。
//
// 文档由项目事实源确定式生成（`lib/core/workbench_docs.dart`，不调模型）：
// 3D 视频的摘要取节点数 / 镜头表（时长 + 相机）/ 真实帧表总帧数 / 校验状态，
// 原子写进项目目录的 `docs.md`（overwrite: true，可反复重新生成）。本文件锁住
// 接线本身（生成入口的可见性、写盘、文档栏刷新、toast、失败降级与确定性）：
//
//   * 点「生成文档」→ docs.md 落盘且含「## 镜头表」；
//   * 文档栏切到正文（`workbench-docs-body`），空态消失，出现「重新生成文档」；
//   * 生成成功 toast「文档已生成」；写盘失败 toast「文档没能写入，请重试」且
//     不伪造成功、不破坏既有文件；
//   * 坏项目 / 没有项目 → 不显示生成入口（onGenerateDocs == null）；
//   * 未过校验项目仍可从原始事实源生成（总帧数如实记 0，不编造帧表）；
//   * 同一事实源两次生成字节相同（确定性）。
//
// 全部用测试替身：临时项目库 + Fake 预览控制器，不构造真 WebView、不碰真实
// 用户目录、不连网络。
library;

import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/video3d/video3d_compile.dart';
import 'package:nondesign/core/video3d/video3d_project.dart';
import 'package:nondesign/core/workbench_docs.dart';
import 'package:nondesign/widgets/aqua.dart';
import 'package:nondesign/widgets/video3d_preview_surface.dart';
import 'package:nondesign/widgets/video3d_workspace.dart';
import 'package:nondesign/widgets/workbench_views.dart';

// ---------------------------------------------------------------------------
// 契约层合法夹具（与 video3d_workspace_test / video3d_contract_test 同族）。
// ---------------------------------------------------------------------------

/// 3 个场景节点 + 一盏主光 + 一台 hero 相机；[title] 是场景显示名。
Map<String, Object?> _validScene({String? title}) => <String, Object?>{
  'v': 1,
  'units': 'm',
  'title': ?title,
  'environment': <String, Object?>{'background': '#0b0d12'},
  'nodes': <Object?>[
    <String, Object?>{
      'id': 'floor',
      'type': 'box',
      'size': <double>[10, 0.1, 10],
      'position': <double>[0, -0.05, 0],
      'material': <String, Object?>{
        'color': '#9a8c7a',
        'roughness': 0.9,
        'metalness': 0.0,
      },
    },
    <String, Object?>{
      'id': 'table',
      'type': 'plane',
      'size': <double>[2, 1, 0],
      'position': <double>[0, 0.5, 0],
      'parent': 'floor',
    },
    <String, Object?>{
      'id': 'lamp',
      'type': 'sphere',
      'size': <double>[0.12, 0.12, 0.12],
    },
  ],
  'lights': <Object?>[
    <String, Object?>{
      'id': 'key',
      'type': 'directional',
      'intensity': 1.0,
      'color': '#ffffff',
      'position': <double>[4, 6, 4],
      'target': <double>[0, 0, 0],
    },
    <String, Object?>{'type': 'ambient', 'intensity': 0.2},
  ],
  'cameras': <Object?>[
    <String, Object?>{
      'id': 'hero',
      'position': <double>[4, 2, 4],
      'target': <double>[0, 1, 0],
      'fov': 45,
    },
  ],
};

/// 两个镜头（5s + 3s，30fps）→ 真实帧表 240 帧。
Map<String, Object?> _validScreenplay({String cameraId = 'hero'}) =>
    <String, Object?>{
      'v': 1,
      'fps': 30,
      'format': <String, Object?>{'width': 720, 'height': 1280},
      'shots': <Object?>[
        <String, Object?>{
          'id': 's1',
          'duration': 5.0,
          'camera': <String, Object?>{'id': cameraId},
        },
        <String, Object?>{
          'id': 's2',
          'duration': 3.0,
          'camera': <String, Object?>{'id': cameraId},
        },
      ],
    };

String _prettyJson(Object? value) =>
    '${const JsonEncoder.withIndent('  ').convert(value)}\n';

/// 直接按磁盘形态落一份项目（坏/未过校验项目用，绕过 save 的校验门）。
void _writeProjectJson(
  Directory root,
  String name, {
  required Map<String, Object?> scene,
  required Map<String, Object?> screenplay,
}) {
  final Directory dir = Directory('${root.path}/$name')
    ..createSync(recursive: true);
  File('${dir.path}/scene3d.json').writeAsStringSync(_prettyJson(scene));
  File('${dir.path}/screenplay3d.json')
      .writeAsStringSync(_prettyJson(screenplay));
}

// ---------------------------------------------------------------------------
// Fake 预览控制器（不构造真 WebView）。
// ---------------------------------------------------------------------------

class _FakePreview extends Video3dPreviewController {
  _FakePreview({required this.fps, required this.totalFrames});

  @override
  final int fps;

  @override
  final int totalFrames;

  bool disposed = false;

  @override
  bool get ready => true;

  @override
  bool get playing => false;

  @override
  int get frame => 0;

  @override
  String get loadError => '';

  @override
  String get technicalDetail => '';

  @override
  Future<void> start() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(double seconds) async {}

  @override
  Future<void> seekFrame(int frame) async {}

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _PreviewFactory {
  final List<_FakePreview> created = <_FakePreview>[];

  Video3dPreviewController call(
    Video3dProjectSnapshot snapshot,
    Video3dTimeline timeline,
  ) {
    final _FakePreview fake = _FakePreview(
      fps: timeline.fps,
      totalFrames: timeline.totalFrames,
    );
    created.add(fake);
    return fake;
  }
}

// ---------------------------------------------------------------------------
// 通用夹具 / 动作
// ---------------------------------------------------------------------------

Widget _app(Widget child, {AppStore? store}) {
  final Widget page = MaterialApp(
    theme: AppTheme.build(dark: true),
    home: Scaffold(body: child),
  );
  if (store == null) return page;
  return ChangeNotifierProvider<AppStore>.value(value: store, child: page);
}

void _viewport(WidgetTester tester, {Size size = const Size(1440, 900)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 工作台用「同步磁盘读写包在 async 里」：交替 pump 推进微任务即可（与
/// video3d_workspace_test / workbench_columns_workspaces_test 同法，不 need
/// 真 IO 的 runAsync）。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

/// 带壳层的 AppStore（toast 走它；不碰真实用户目录）。
AppStore _store() {
  final AppStore store = AppStore(toasts: ToastService(autoDismiss: false))
    ..ready = true
    ..settings = AppSettings(
      providerId: 'deepseek',
      modelId: 'deepseek-v4.1-flash',
    )
    ..view = 'design';
  store.recoveryDir = Directory.systemTemp
      .createTempSync('nd-video3d-docs-wiring-recovery')
      .path;
  return store;
}

/// pump 一个注入临时项目库 + Fake 预览的工作台，并等首轮列表/项目加载完成。
Future<_PreviewFactory> _pumpWorkspace(
  WidgetTester tester, {
  required Video3dProjectStore projectStore,
  AppStore? store,
}) async {
  _viewport(tester);
  final _PreviewFactory factory = _PreviewFactory();
  await tester.pumpWidget(
    _app(
      Video3dWorkspace(
        projectStore: projectStore,
        previewFactory: factory.call,
      ),
      store: store,
    ),
  );
  await _settle(tester);
  return factory;
}

/// 切到「文档」栏目（Key 走唯一出口 [WorkbenchColumnLabel.tabKey]）。
Future<void> _openDocsColumn(WidgetTester tester) async {
  await tester.tap(find.byKey(ValueKey<String>(WorkbenchColumn.docs.tabKey)));
  await _settle(tester);
}

Finder _docsGenerateButton() =>
    find.byKey(const ValueKey('workbench-docs-generate'));

Finder _docsRegenerateButton() =>
    find.byKey(const ValueKey('workbench-docs-regenerate'));

Finder _docsEmptyState() => find.byKey(const ValueKey('workbench-docs-empty'));

Finder _docsBody() => find.byKey(const ValueKey('workbench-docs-body'));

File _docsFile(Directory root, String project) =>
    File('${root.path}/$project/$workbenchDocFileName');

/// 点「生成文档」或「重新生成文档」并等写盘/重读链路完成。
Future<void> _tapGenerate(WidgetTester tester) async {
  await tester.tap(_docsGenerateButton());
  await _settle(tester);
}

Future<void> _tapRegenerate(WidgetTester tester) async {
  await tester.tap(_docsRegenerateButton());
  await _settle(tester);
}

/// 生成动作按钮内部的凝胶按钮（生成中必须禁用）。
AquaGelButton _docsActionGel(WidgetTester tester, Finder actionKey) {
  return tester.widget<AquaGelButton>(
    find.descendant(of: actionKey, matching: find.byType(AquaGelButton)),
  );
}

void main() {
  late Directory temp;
  late Video3dProjectStore projectStore;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = Directory.systemTemp.createTempSync('nd-video3d-docs-wiring-');
    projectStore = Video3dProjectStore(root: temp);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('3D 视频工作台 · 生成文档接线', () {
    testWidgets('点生成 → docs.md 落盘含「## 镜头表」，文档栏切正文并出现重新生成', (
      WidgetTester tester,
    ) async {
      // 场景 title 进文档标题；事实源 = 3 节点 / 2 镜头 / 240 帧。
      await projectStore.save(
        'alpha',
        scene: _validScene(title: '火星漫游'),
        screenplay: _validScreenplay(),
      );

      await _pumpWorkspace(tester, projectStore: projectStore);
      await _openDocsColumn(tester);

      // 还没有 docs.md → 空态 + 生成入口。
      expect(_docsEmptyState(), findsOneWidget);
      expect(_docsBody(), findsNothing);
      expect(_docsGenerateButton(), findsOneWidget);
      expect(_docsRegenerateButton(), findsNothing);

      await _tapGenerate(tester);

      // 落盘：概览 / 镜头表 / 标题都来自事实源（生成器确定性拼装）。
      final File doc = _docsFile(temp, 'alpha');
      expect(doc.existsSync(), isTrue, reason: '生成后 docs.md 必须存在');
      final String content = doc.readAsStringSync();
      expect(content, startsWith(workbenchDocNotice));
      expect(content, contains('# 火星漫游'));
      expect(content, contains('## 项目概览'));
      expect(content, contains('- 节点数：3 个'));
      expect(content, contains('- 镜头数：2 个'));
      expect(content, contains('- 总帧数：240 帧'));
      expect(content, contains('## 镜头表'));
      expect(content, contains('| 1 | 5 秒 | hero |'));
      expect(content, contains('| 2 | 3 秒 | hero |'));

      // 文档栏立即显示正文：空态消失、正文出现、重新生成入口出现且可点。
      expect(_docsEmptyState(), findsNothing);
      expect(_docsBody(), findsOneWidget);
      expect(_docsRegenerateButton(), findsOneWidget);
      expect(
        _docsActionGel(tester, _docsRegenerateButton()).onPressed,
        isNotNull,
      );
      expect(find.text('镜头表'), findsOneWidget, reason: '正文标题渲染');
      expect(find.text('节点数：3 个'), findsOneWidget, reason: '概览行渲染');
      expect(tester.takeException(), isNull);
    });

    testWidgets('重新生成：overwrite 覆盖旧文档，同一事实源两次生成字节相同', (
      WidgetTester tester,
    ) async {
      await projectStore.save(
        'alpha',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );

      await _pumpWorkspace(tester, projectStore: projectStore);
      await _openDocsColumn(tester);
      await _tapGenerate(tester);

      final File doc = _docsFile(temp, 'alpha');
      expect(doc.existsSync(), isTrue);
      final List<int> first = doc.readAsBytesSync();

      // 重新生成按钮出现；再点一次走 overwrite: true，覆盖而不是拒绝。
      expect(_docsRegenerateButton(), findsOneWidget);
      await _tapRegenerate(tester);

      final List<int> second = doc.readAsBytesSync();
      expect(second, equals(first), reason: '同一事实源两次生成必须字节相同（确定性）');
      expect(_docsBody(), findsOneWidget);
      expect(_docsRegenerateButton(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('生成成功：有壳层时 toast「文档已生成」', (WidgetTester tester) async {
      await projectStore.save(
        'alpha',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      final AppStore store = _store();

      await _pumpWorkspace(tester, projectStore: projectStore, store: store);
      await _openDocsColumn(tester);
      await _tapGenerate(tester);

      expect(_docsFile(temp, 'alpha').existsSync(), isTrue);
      expect(
        store.toasts.visible.map((ToastItem t) => t.title),
        contains('文档已生成'),
        reason: '成功必须给用户可见提示，不静默',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('写盘失败：toast「文档没能写入，请重试」，不伪造成功、生成状态复位', (
      WidgetTester tester,
    ) async {
      await projectStore.save(
        'alpha',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      // docs.md 被目录占位 → 原子改名失败，必然走失败路径且不破坏现场。
      Directory('${temp.path}/alpha/$workbenchDocFileName')
          .createSync(recursive: true);
      final AppStore store = _store();

      await _pumpWorkspace(tester, projectStore: projectStore, store: store);
      await _openDocsColumn(tester);
      expect(_docsGenerateButton(), findsOneWidget);

      await _tapGenerate(tester);

      expect(
        store.toasts.visible.map((ToastItem t) => t.title),
        contains('文档没能写入，请重试'),
        reason: '失败给人话提示，不静默',
      );
      // 失败不伪造成功：文档栏仍是空态，入口复位为「生成文档」（非忙碌标签）。
      expect(_docsEmptyState(), findsOneWidget);
      expect(_docsBody(), findsNothing);
      expect(_docsGenerateButton(), findsOneWidget);
      expect(find.text('生成文档'), findsOneWidget);
      expect(
        _docsActionGel(tester, _docsGenerateButton()).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('坏项目：不显示生成入口（onGenerateDocs == null）', (
      WidgetTester tester,
    ) async {
      // 两份事实源都不是合法 JSON → 读取失败（坏项目），列表保留但打开显性报错。
      final Directory dir = Directory('${temp.path}/broken')
        ..createSync(recursive: true);
      File('${dir.path}/scene3d.json').writeAsStringSync('not json');
      File('${dir.path}/screenplay3d.json').writeAsStringSync('{}');

      await _pumpWorkspace(tester, projectStore: projectStore);
      await _openDocsColumn(tester);

      expect(_docsEmptyState(), findsOneWidget);
      expect(_docsBody(), findsNothing);
      expect(_docsGenerateButton(), findsNothing, reason: '坏项目没有事实源可生成');
      expect(_docsRegenerateButton(), findsNothing);
      expect(
        File('${dir.path}/$workbenchDocFileName').existsSync(),
        isFalse,
        reason: '没有入口就不该有生成物',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('没有项目：不显示生成入口（onGenerateDocs == null）', (
      WidgetTester tester,
    ) async {
      await _pumpWorkspace(tester, projectStore: projectStore);
      await _openDocsColumn(tester);

      expect(_docsEmptyState(), findsOneWidget);
      expect(_docsGenerateButton(), findsNothing);
      expect(_docsRegenerateButton(), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('未过校验项目：仍可从原始事实源生成，总帧数如实记 0', (WidgetTester tester) async {
      // 镜头引用场景里不存在的相机 → 联合校验不通过，但两份文件可读。
      _writeProjectJson(
        temp,
        'unverified',
        scene: _validScene(),
        screenplay: _validScreenplay(cameraId: 'ghost'),
      );

      final _PreviewFactory factory = await _pumpWorkspace(
        tester,
        projectStore: projectStore,
      );
      expect(factory.created, isEmpty, reason: '未过校验不得编译进预览');

      await _openDocsColumn(tester);
      // 可读项目仍有生成入口（坏项目才没有）。
      expect(_docsGenerateButton(), findsOneWidget);
      await _tapGenerate(tester);

      final File doc = _docsFile(temp, 'unverified');
      expect(doc.existsSync(), isTrue);
      final String content = doc.readAsStringSync();
      expect(content, contains('## 镜头表'));
      expect(content, contains('- 节点数：3 个'), reason: '原始场景字段兜底');
      expect(content, contains('- 镜头数：2 个'), reason: '原始镜头表兜底');
      expect(content, contains('- 总帧数：0 帧'), reason: '编译不了帧表就记 0，不编造');
      expect(content, contains('| 1 | 5 秒 | ghost |'));
      expect(_docsBody(), findsOneWidget);
      expect(_docsRegenerateButton(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('切项目：旧项目的文档不会带进新项目的文档栏', (WidgetTester tester) async {
      await projectStore.save(
        'alpha',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );
      await projectStore.save(
        'beta',
        scene: _validScene(),
        screenplay: _validScreenplay(),
      );

      // 先给 alpha 生成文档，再把正文留在界面。
      await _pumpWorkspace(tester, projectStore: projectStore);
      await _openDocsColumn(tester);
      await _tapGenerate(tester);
      expect(_docsBody(), findsOneWidget);

      // 切到 beta（beta 还没有 docs.md）：先回「呈现效果」点项目列表，再回
      // 文档栏——旧项目的正文不能带进新项目。
      await tester.tap(
        find.byKey(ValueKey<String>(WorkbenchColumn.present.tabKey)),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('video3d-project-beta')));
      await _settle(tester);
      await _openDocsColumn(tester);
      expect(_docsEmptyState(), findsOneWidget);
      expect(_docsBody(), findsNothing);
      expect(_docsGenerateButton(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
