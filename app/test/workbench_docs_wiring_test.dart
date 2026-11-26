// 3D / 视频工作台「生成文档」接线回归。
//
// 文档由项目事实源确定式生成（`lib/core/workbench_docs.dart`，不调模型），
// 原子写进项目目录的 `docs.md`（overwrite: true，可反复重新生成）。本文件锁住
// 接线本身：生成入口的可见性、真实写盘、文档栏立即刷新、toast 提示、失败不
// 伪造成功、以及同一事实源两次生成字节相同（确定性）。
//
//   * 3D：摘要 = 规范里的组件清单 / 验收项 + 进度状态机的当前层与各层状态，
//     生成物含「## 组件清单」；文档栏切正文（`workbench-docs-body`）并出现
//     「重新生成文档」；
//   * 视频：摘要 = 标题 / 总时长 / 帧率 / 镜头表（一幕一行：时长 + 分镜说明），
//     生成物含「## 镜头表」；
//   * 无项目 / 坏项目 / 内置示例（没有磁盘事实源）→ 不显示生成入口；
//   * 写盘失败 → toast「文档没能写入，请重试」，文档栏不伪造正文；
//   * 同一事实源两次生成 docs.md 字节相同。
//
// 全部用测试替身：临时项目根 + 注入的 3D 项目服务（不挂 WebView）+ 临时视频
// 项目库 + 空动效合成清单，不构造真 WebView、不碰真实用户目录、不连网络。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/capability_hub.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/video_clip.dart';
import 'package:nondesign/core/video_project.dart';
import 'package:nondesign/core/video_service.dart';
import 'package:nondesign/core/workbench_docs.dart';
import 'package:nondesign/widgets/aqua.dart';
import 'package:nondesign/widgets/three_workspace.dart';
import 'package:nondesign/widgets/video_workspace.dart';
import 'package:nondesign/widgets/workbench_views.dart';

// ---------------------------------------------------------------------------
// 3D 夹具：旧布局三件套（规范 / 场景 / 进度），与 three_workspace_test 同族。
// ---------------------------------------------------------------------------

Map<String, dynamic> _threeSpec({String title = '土星环'}) => <String, dynamic>{
  'title': title,
  'summary': '带环行星自转',
  'components': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'planet', 'what': '球体'},
    <String, dynamic>{'id': 'ring', 'what': '扁平圆环'},
  ],
  'materials': <Map<String, dynamic>>[
    <String, dynamic>{'id': 'rock', 'color_hex': '#c9a06a'},
  ],
  'acceptance': <String>['行星在场', '环可见'],
};

/// 进度状态机：结构层进行中，占位层已通过。
Map<String, dynamic> _threeState() => <String, dynamic>{
  'current': 'structure',
  'blocked': false,
  'passes': <Object?>[
    <String, Object?>{'id': 'blockout', 'status': 'verified', 'attempts': 0},
    <String, Object?>{'id': 'structure', 'status': 'pending', 'attempts': 0},
  ],
};

/// 落一份可直接被 [ThreeService.readProject] 读出的旧布局项目。
void _seedThreeProject(
  Directory root,
  String name, {
  String title = '土星环',
  String? specText,
}) {
  final Directory dir = Directory('${root.path}/$name')
    ..createSync(recursive: true);
  File('${dir.path}/three-spec.json')
      .writeAsStringSync(specText ?? jsonEncode(_threeSpec(title: title)));
  File('${dir.path}/scene.js')
      .writeAsStringSync('export default function build() { return {}; }\n');
  File('${dir.path}/build-state.json')
      .writeAsStringSync(jsonEncode(_threeState()));
}

/// 不碰真实资源包的资产加载器：组件画廊读不到时工作台降级为一句人话，
/// 不影响文档链路（也不让测试等真实 asset IO）。
Future<Uint8List> _noThreeAssets(String key) async =>
    throw ThreeFailure('asset_missing', key);

ThreeService _threeService(Directory root) =>
    ThreeService(root: root, assets: _noThreeAssets);

// ---------------------------------------------------------------------------
// 视频夹具：先用内置示例的时间线/规范落一个生成项目（等价于 video_create）。
// ---------------------------------------------------------------------------

VideoDocument _sampleDocument() =>
    VideoService(host: VideoHost.macos).loadSample(0);

Future<VideoProjectSnapshot> _seedVideoProject(
  VideoProjectStore projects,
  String name, {
  String title = '摩擦力演示',
}) {
  final VideoDocument doc = _sampleDocument();
  return projects.create(
    name: name,
    timeline: doc.timeline,
    spec: doc.spec.raw,
    title: title,
  );
}

// ---------------------------------------------------------------------------
// 通用夹具 / 动作
// ---------------------------------------------------------------------------

AppStore _newStore(Directory temp) {
  final AppStore store =
      AppStore(
          toasts: ToastService(autoDismiss: false),
          capabilities: CapabilityHub(
            platform: PlatformCapabilities.forOs(HostOs.macos),
          ),
        )
        ..ready = true
        ..view = 'plugin:video'
        ..settings = AppSettings(
          providerId: 'deepseek',
          modelId: 'deepseek-v4.1-flash',
        );
  store.recoveryDir = '${temp.path}/recovery';
  store.settingsMirrorDir = '${temp.path}/state';
  return store;
}

Widget _app(AppStore store, Widget child) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Scaffold(body: child),
      ),
    );

void _viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 工作台用「同步磁盘读写包在 async 里」：交替 pump 推进微任务即可
/// （与 video3d_workspace_test / workbench_docs_wiring_music_test 同法）。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Finder _docsGenerateButton() =>
    find.byKey(const ValueKey('workbench-docs-generate'));

Finder _docsRegenerateButton() =>
    find.byKey(const ValueKey('workbench-docs-regenerate'));

Finder _docsEmptyState() => find.byKey(const ValueKey('workbench-docs-empty'));

Finder _docsBody() => find.byKey(const ValueKey('workbench-docs-body'));

/// 切到「文档」栏目（Key 走唯一出口 [WorkbenchColumnLabel.tabKey]）。
Future<void> _openDocsColumn(WidgetTester tester) async {
  await tester.tap(find.byKey(ValueKey<String>(WorkbenchColumn.docs.tabKey)));
  await _settle(tester);
}

/// 生成动作按钮内部的凝胶按钮（断言可点 / 禁用）。
AquaGelButton _docsActionGel(WidgetTester tester, Finder actionKey) {
  return tester.widget<AquaGelButton>(
    find.descendant(of: actionKey, matching: find.byType(AquaGelButton)),
  );
}

List<String> _toastTitles(AppStore store) => <String>[
  for (final ToastItem item in store.toasts.visible) item.title,
];

File _docsFile(Directory root, String project) =>
    File('${root.path}/$project/$workbenchDocFileName');

// ---------------------------------------------------------------------------
// 工作台 pump 夹具
// ---------------------------------------------------------------------------

/// pump 3D 工作台：注入临时项目根的服务；不挂预览控制器（平台开关覆盖为
/// 「无内嵌预览」），启动后按 [openProject] 打开指定项目。
Future<void> _pumpThreeWorkspace(
  WidgetTester tester, {
  required AppStore store,
  required ThreeService service,
  String? openProject,
}) async {
  _viewport(tester);
  debugThreeWebViewSupported = false;
  threeLoadOnOpen = openProject;
  await tester.pumpWidget(_app(store, ThreeWorkspace(service: service)));
  await _settle(tester);
}

/// pump 视频工作台：临时项目库 + 空动效合成清单；项目名走设置续接。
Future<void> _pumpVideoWorkspace(
  WidgetTester tester, {
  required AppStore store,
  required VideoProjectStore projects,
  String projectName = '',
}) async {
  _viewport(tester);
  store.settings.videoProjectName = projectName;
  await tester.pumpWidget(
    _app(
      store,
      VideoWorkspace(
        service: VideoService(host: VideoHost.macos),
        projectStore: projects,
        clips: const <VideoClipInfo>[],
      ),
    ),
  );
  await _settle(tester);
}

void main() {
  late Directory temp;
  late AppStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = Directory.systemTemp.createTempSync('nd-workbench-docs-wiring-');
    store = _newStore(temp);
  });

  tearDown(() {
    debugThreeWebViewSupported = null;
    threeLoadOnOpen = null;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  group('3D 工作台 · 生成文档接线', () {
    testWidgets('点生成 → docs.md 落盘含「## 组件清单」，文档栏立即显示正文并出现重新生成', (
      WidgetTester tester,
    ) async {
      final Directory root = Directory('${temp.path}/three')
        ..createSync(recursive: true);
      _seedThreeProject(root, 'saturn');

      await _pumpThreeWorkspace(
        tester,
        store: store,
        service: _threeService(root),
        openProject: 'saturn',
      );
      await _openDocsColumn(tester);

      // 还没有 docs.md → 可行动空态 + 生成入口。
      expect(_docsEmptyState(), findsOneWidget);
      expect(_docsBody(), findsNothing);
      expect(_docsGenerateButton(), findsOneWidget);
      expect(_docsRegenerateButton(), findsNothing);

      await tester.tap(_docsGenerateButton());
      await _settle(tester);

      // 落盘：标题/组件/验收项/进度全部来自项目事实源。
      final File docs = _docsFile(root, 'saturn');
      expect(docs.existsSync(), isTrue, reason: '生成后 docs.md 必须存在');
      final String text = docs.readAsStringSync();
      expect(text, startsWith(workbenchDocNotice));
      expect(text, contains('# 土星环'));
      expect(text, contains('## 项目概览'));
      expect(text, contains('- 类型：3D 场景'));
      expect(text, contains('- 组件数：2 个'));
      expect(text, contains('- 验收项数：2 条'));
      expect(text, contains('- 当前层：结构'));
      expect(text, contains('## 组件清单'));
      expect(text, contains('1. 球体'), reason: '组件按规范原文列出');
      expect(text, contains('2. 扁平圆环'));
      expect(text, contains('## 验收项'));
      expect(text, contains('- 行星在场'));
      expect(text, contains('## 进度'));
      expect(text, contains('- 已通过 1 / 2 层'));
      expect(text, contains('- 已通过层：占位'));
      expect(text, contains('- 未通过层：结构'));

      // 文档栏立即显示正文：空态消失、正文出现、动作换成「重新生成文档」。
      expect(_docsEmptyState(), findsNothing);
      expect(_docsBody(), findsOneWidget);
      expect(_docsRegenerateButton(), findsOneWidget);
      expect(
        _docsActionGel(tester, _docsRegenerateButton()).onPressed,
        isNotNull,
      );
      expect(find.text('组件清单'), findsOneWidget, reason: '正文标题渲染');
      expect(find.text('组件数：2 个'), findsOneWidget, reason: '概览行渲染');
      expect(_toastTitles(store), contains('文档已生成'), reason: '成功必须有提示');
      expect(tester.takeException(), isNull);
    });

    testWidgets('重新生成：overwrite 覆盖旧文档，同一事实源两次生成字节相同', (
      WidgetTester tester,
    ) async {
      final Directory root = Directory('${temp.path}/three')
        ..createSync(recursive: true);
      _seedThreeProject(root, 'saturn');

      await _pumpThreeWorkspace(
        tester,
        store: store,
        service: _threeService(root),
        openProject: 'saturn',
      );
      await _openDocsColumn(tester);
      await tester.tap(_docsGenerateButton());
      await _settle(tester);

      final File docs = _docsFile(root, 'saturn');
      expect(docs.existsSync(), isTrue);
      final List<int> first = docs.readAsBytesSync();

      // 重新生成入口出现；再点一次走 overwrite: true，覆盖而非拒绝。
      expect(_docsRegenerateButton(), findsOneWidget);
      await tester.tap(_docsRegenerateButton());
      await _settle(tester);

      final List<int> second = docs.readAsBytesSync();
      expect(second, orderedEquals(first), reason: '同一事实源两次生成必须字节相同');
      expect(docs.readAsStringSync(), contains('## 组件清单'));
      expect(_docsBody(), findsOneWidget);
      expect(_docsRegenerateButton(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('坏项目（规范读不出来）：文档栏空态，不出现生成按钮', (WidgetTester tester) async {
      final Directory root = Directory('${temp.path}/three')
        ..createSync(recursive: true);
      // 坏项目：目录存在但规范不是 JSON → readProject 失败 → 没有快照。
      _seedThreeProject(root, 'broken', specText: '{ 这不是 JSON');

      await _pumpThreeWorkspace(
        tester,
        store: store,
        service: _threeService(root),
        openProject: 'broken',
      );
      await _openDocsColumn(tester);

      expect(_docsEmptyState(), findsOneWidget);
      expect(_docsBody(), findsNothing);
      expect(_docsGenerateButton(), findsNothing, reason: '坏项目没有事实源可生成');
      expect(_docsRegenerateButton(), findsNothing);
      expect(
        _docsFile(root, 'broken').existsSync(),
        isFalse,
        reason: '没有入口就不该有生成物',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('没有项目：文档栏空态，不出现生成按钮', (WidgetTester tester) async {
      final Directory root = Directory('${temp.path}/three')
        ..createSync(recursive: true);

      await _pumpThreeWorkspace(
        tester,
        store: store,
        service: _threeService(root),
      );
      await _openDocsColumn(tester);

      expect(_docsEmptyState(), findsOneWidget);
      expect(_docsGenerateButton(), findsNothing);
      expect(_docsRegenerateButton(), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('写盘失败：toast「文档没能写入，请重试」，不伪造成功且入口复位', (
      WidgetTester tester,
    ) async {
      final Directory root = Directory('${temp.path}/three')
        ..createSync(recursive: true);
      _seedThreeProject(root, 'saturn');
      // docs.md 被目录占位 → 原子改名失败，必然走失败路径且不破坏现场。
      Directory('${root.path}/saturn/$workbenchDocFileName')
          .createSync(recursive: true);

      await _pumpThreeWorkspace(
        tester,
        store: store,
        service: _threeService(root),
        openProject: 'saturn',
      );
      await _openDocsColumn(tester);
      expect(_docsGenerateButton(), findsOneWidget);

      await tester.tap(_docsGenerateButton());
      await _settle(tester);

      expect(
        _toastTitles(store),
        contains('文档没能写入，请重试'),
        reason: '失败给人话提示，不静默',
      );
      // 失败不伪造成功：文档栏仍是空态，入口复位为「生成文档」且可点。
      expect(_docsEmptyState(), findsOneWidget);
      expect(_docsBody(), findsNothing);
      expect(_docsGenerateButton(), findsOneWidget);
      expect(
        _docsActionGel(tester, _docsGenerateButton()).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('视频工作台 · 生成文档接线', () {
    testWidgets('点生成 → docs.md 落盘含「## 镜头表」，文档栏立即显示正文并出现重新生成', (
      WidgetTester tester,
    ) async {
      final Directory root = Directory('${temp.path}/video')
        ..createSync(recursive: true);
      final VideoProjectStore projects = VideoProjectStore(root: root);
      final VideoProjectSnapshot seeded = await _seedVideoProject(
        projects,
        'friction',
      );

      await _pumpVideoWorkspace(
        tester,
        store: store,
        projects: projects,
        projectName: 'friction',
      );
      await _openDocsColumn(tester);

      expect(_docsEmptyState(), findsOneWidget);
      expect(_docsBody(), findsNothing);
      expect(_docsGenerateButton(), findsOneWidget);
      expect(_docsRegenerateButton(), findsNothing);

      await tester.tap(_docsGenerateButton());
      await _settle(tester);

      // 落盘：标题（video.json）/ 总时长与帧率 / 镜头表（时长 + 分镜说明）。
      final File docs = _docsFile(root, 'friction');
      expect(docs.existsSync(), isTrue, reason: '生成后 docs.md 必须存在');
      final String text = docs.readAsStringSync();
      expect(text, startsWith(workbenchDocNotice));
      expect(text, contains('# 摩擦力演示'));
      expect(text, contains('## 项目概览'));
      expect(text, contains('- 类型：视频'));
      expect(
        text,
        contains('- 总时长：${seeded.document.totalSeconds.toStringAsFixed(0)} 秒'),
      );
      expect(text, contains('- 帧率：${seeded.document.fps} 帧/秒'));
      expect(text, contains('- 镜头数：2 个'));
      expect(text, contains('## 镜头表'));
      expect(text, contains('| 序号 | 时长 | 文本 |'));
      expect(
        text,
        contains('| 1 | 3.5 秒 | 斜面+滑块从顶部起动，重力/法向/摩擦三箭头跟随滑块 |'),
        reason: '镜头行：时长取时间线、文本取规范分镜说明',
      );
      expect(text, contains('| 2 | 4.5 秒 | 滑到底后镜头保留斜面，叠加大号实时读数'));

      // 文档栏立即显示正文：空态消失、正文出现、动作换成「重新生成文档」。
      expect(_docsEmptyState(), findsNothing);
      expect(_docsBody(), findsOneWidget);
      expect(_docsRegenerateButton(), findsOneWidget);
      expect(
        _docsActionGel(tester, _docsRegenerateButton()).onPressed,
        isNotNull,
      );
      expect(find.text('镜头表'), findsOneWidget, reason: '正文标题渲染');
      expect(_toastTitles(store), contains('文档已生成'), reason: '成功必须有提示');
      expect(tester.takeException(), isNull);
    });

    testWidgets('重新生成：overwrite 覆盖旧文档，同一事实源两次生成字节相同', (
      WidgetTester tester,
    ) async {
      final Directory root = Directory('${temp.path}/video')
        ..createSync(recursive: true);
      final VideoProjectStore projects = VideoProjectStore(root: root);
      await _seedVideoProject(projects, 'friction');

      await _pumpVideoWorkspace(
        tester,
        store: store,
        projects: projects,
        projectName: 'friction',
      );
      await _openDocsColumn(tester);
      await tester.tap(_docsGenerateButton());
      await _settle(tester);

      final File docs = _docsFile(root, 'friction');
      expect(docs.existsSync(), isTrue);
      final List<int> first = docs.readAsBytesSync();

      expect(_docsRegenerateButton(), findsOneWidget);
      await tester.tap(_docsRegenerateButton());
      await _settle(tester);

      final List<int> second = docs.readAsBytesSync();
      expect(second, orderedEquals(first), reason: '同一事实源两次生成必须字节相同');
      expect(docs.readAsStringSync(), contains('## 镜头表'));
      expect(_docsBody(), findsOneWidget);
      expect(_docsRegenerateButton(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('内置示例（没有磁盘项目）：文档栏空态，不出现生成按钮', (WidgetTester tester) async {
      final Directory root = Directory('${temp.path}/video')
        ..createSync(recursive: true);
      final VideoProjectStore projects = VideoProjectStore(root: root);

      await _pumpVideoWorkspace(tester, store: store, projects: projects);
      await _openDocsColumn(tester);

      expect(_docsEmptyState(), findsOneWidget);
      expect(
        _docsGenerateButton(),
        findsNothing,
        reason: '内置示例没有磁盘目录，没有事实源可写文档',
      );
      expect(_docsRegenerateButton(), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('坏项目（video.json 读不出来）：不出现生成按钮', (WidgetTester tester) async {
      final Directory root = Directory('${temp.path}/video')
        ..createSync(recursive: true);
      final VideoProjectStore projects = VideoProjectStore(root: root);
      // 坏项目：目录里只有坏元数据 → 读盘失败 → 没有快照 = 没有事实源。
      final Directory broken = Directory('${root.path}/broken')
        ..createSync(recursive: true);
      File('${broken.path}/video.json').writeAsStringSync('{ 这不是 JSON');

      await _pumpVideoWorkspace(
        tester,
        store: store,
        projects: projects,
        projectName: 'broken',
      );
      await _openDocsColumn(tester);

      expect(_docsEmptyState(), findsOneWidget);
      expect(_docsBody(), findsNothing);
      expect(_docsGenerateButton(), findsNothing, reason: '坏项目不提供生成入口');
      expect(_docsRegenerateButton(), findsNothing);
      expect(
        File('${broken.path}/$workbenchDocFileName').existsSync(),
        isFalse,
        reason: '没有入口就不该有生成物',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('写盘失败：toast「文档没能写入，请重试」，不伪造成功且入口复位', (
      WidgetTester tester,
    ) async {
      final Directory root = Directory('${temp.path}/video')
        ..createSync(recursive: true);
      final VideoProjectStore projects = VideoProjectStore(root: root);
      await _seedVideoProject(projects, 'friction');
      // docs.md 被目录占位 → 原子替换失败，走失败路径。
      Directory('${root.path}/friction/$workbenchDocFileName')
          .createSync(recursive: true);

      await _pumpVideoWorkspace(
        tester,
        store: store,
        projects: projects,
        projectName: 'friction',
      );
      await _openDocsColumn(tester);
      expect(_docsGenerateButton(), findsOneWidget);

      await tester.tap(_docsGenerateButton());
      await _settle(tester);

      expect(
        _toastTitles(store),
        contains('文档没能写入，请重试'),
        reason: '失败给人话提示，不静默',
      );
      expect(_docsEmptyState(), findsOneWidget);
      expect(_docsBody(), findsNothing);
      expect(_docsGenerateButton(), findsOneWidget);
      expect(
        _docsActionGel(tester, _docsGenerateButton()).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
