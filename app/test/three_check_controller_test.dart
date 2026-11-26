// 3D 工作台接入通用检查器（task-37）：
// 大纲选中条目 → 右侧「检查」tab 的可编辑属性表 → 写回 three-spec.json。
//
// 纪律：全部临时目录 + `debugThreeWebViewSupported = false`，不构造真 WebView；
// 项目夹具是旧布局三件套（three-spec.json / scene.js / build-state.json），与
// design_layout_responsive_test / three_workspace_test 同形。写回链路走真实的
// ThreeService.saveSpec（原子落盘），所以断言的是磁盘内容，不是内存值。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/capability_hub.dart';
import 'package:nondesign/core/inspect/check_field.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/three_workspace.dart';

// ---------------------------------------------------------------------------
// 项目夹具（旧布局三件套；工作台只读，不新建项目、不碰模型）
// ---------------------------------------------------------------------------

Map<String, dynamic> _legacySpec() => <String, dynamic>{
  'title': 'Saturn',
  'summary': '带环行星自转',
  'components': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'planet',
      'what': '球体',
      'size_scale': 1.0,
      'material': 'rock',
    },
    <String, dynamic>{'id': 'ring', 'what': '扁平圆环', 'size_scale': 1.8},
  ],
  'materials': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'rock',
      'color_hex': '#c9a06a',
      'roughness': 0.8,
      'metalness': 0.1,
    },
    <String, dynamic>{
      'id': 'glass',
      'color_hex': '#66ccff',
      'roughness': 0.1,
      'metalness': 0.0,
    },
  ],
  'camera': <String, dynamic>{'view': '略高处斜看'},
  'acceptance': <String>['行星在场', '环可见 ≤2mm'],
};

void _seedProject(Directory root, String name) {
  final Directory dir = Directory('${root.path}/$name')
    ..createSync(recursive: true);
  File('${dir.path}/three-spec.json')
      .writeAsStringSync(jsonEncode(_legacySpec()));
  File('${dir.path}/scene.js')
      .writeAsStringSync('export default function build() { return {}; }\n');
  File('${dir.path}/build-state.json').writeAsStringSync(
    jsonEncode(<String, Object?>{
      'current': 'structure',
      'blocked': false,
      'passes': <Object?>[],
    }),
  );
}

ThreeService _threeService(Directory root) => ThreeService(
  root: root,
  llm: (request) async => throw const ThreeFailure('llm_error', 'unused'),
  // 空资产字节：本用例不渲染预览（debugThreeWebViewSupported = false 走降级面），
  // 组件清单读取失败只会被 catch 成可读的清单错误。
  assets: (_) async => Uint8List(0),
);

AppStore _threeStore() =>
    AppStore(
        toasts: ToastService(autoDismiss: false),
        // flutter_test 默认平台是 android；显式钉桌面，语义与生产桌面壳一致。
        capabilities: CapabilityHub(
          platform: PlatformCapabilities.forOs(HostOs.macos),
        ),
      )
      ..ready = true
      ..view = 'plugin:three'
      ..settings = AppSettings(
        providerId: 'deepseek',
        modelId: 'deepseek-v4.1-flash',
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'test-key',
      );

Widget _host(AppStore store, {ThreeService? service, Widget? child}) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Scaffold(body: child ?? ThreeWorkspace(service: service)),
      ),
    );

/// 真 IO（项目读盘/落盘）要走 runAsync 才推得动；faked clock 下不能
/// pumpAndSettle（空态/清单的加载指示是无限动画）。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  await tester.pump(const Duration(milliseconds: 120));
}

/// 测试用外部控制器：模拟「别的工作台已接管」。
class _ForeignController extends WorkbenchCheckController {
  @override
  CheckSheet? get sheet => null;

  @override
  Future<bool> update(String key, Object? value) async => false;
}

void main() {
  group('3D 通用检查器', () {
    late Directory temp;
    late String specPath;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      temp = await Directory.systemTemp.createTemp('nondesign-3d-check-');
      specPath = '${temp.path}/saturn/three-spec.json';
      _seedProject(temp, 'saturn');
    });

    tearDown(() async {
      debugThreeWebViewSupported = null;
      threeLoadOnOpen = null;
      await temp.delete(recursive: true);
    });

    Map<String, dynamic> diskSpec() =>
        (jsonDecode(File(specPath).readAsStringSync()) as Map)
            .cast<String, dynamic>();

    /// 挂载 3D 工作台（宽屏 1280：大纲常驻；不构造 WebView），等 boot 完成。
    Future<AppStore> pumpWorkspace(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final AppStore store = _threeStore();
      debugThreeWebViewSupported = false;
      threeLoadOnOpen = 'saturn';
      await tester.pumpWidget(_host(store, service: _threeService(temp)));
      await _settle(tester);
      return store;
    }

    testWidgets('挂载后注册控制器；未选中 → sheet 为 null', (tester) async {
      final AppStore store = await pumpWorkspace(tester);
      expect(
        store.checkController,
        isNotNull,
        reason: '挂载后必须把检查控制器注册到 store（右栏检查 tab 读它）',
      );
      expect(
        store.checkController!.sheet,
        isNull,
        reason: '没有选中条目时检查器给空态，不编造属性表',
      );
    });

    testWidgets('选中组件：标题/来源/真实可编辑字段齐全', (tester) async {
      final AppStore store = await pumpWorkspace(tester);
      await tester.tap(
        find.byKey(const ValueKey('three-outliner-component:planet')),
      );
      await tester.pump();

      final CheckSheet sheet = store.checkController!.sheet!;
      expect(sheet.title, '组件「planet」');
      expect(sheet.kindLabel, '组件');
      expect(sheet.subtitle, contains('three-spec.json'));
      expect(sheet.fields.map((CheckField f) => f.key).toList(), <String>[
        'what',
        'size_scale',
        'material',
      ], reason: '只映射 three-spec.json 的真实可编辑键');
      expect(sheet.field('what')!.kind, CheckFieldKind.text);
      expect(sheet.field('what')!.value, '球体');
      expect(sheet.field('size_scale')!.kind, CheckFieldKind.number);
      expect(sheet.field('size_scale')!.value, 1.0);
      expect(
        sheet.field('size_scale')!.min,
        greaterThan(0),
        reason: '尺寸比例必须大于 0',
      );
      expect(sheet.field('material')!.kind, CheckFieldKind.select);
      expect(sheet.field('material')!.value, 'rock');
      expect(sheet.field('material')!.options, <String>[
        'rock',
        'glass',
      ], reason: '材质下拉的选项来自项目现有材质 id');
    });

    testWidgets('选中材质 / 相机：字段与真实值齐全', (tester) async {
      final AppStore store = await pumpWorkspace(tester);
      await tester.tap(
        find.byKey(const ValueKey('three-outliner-material:rock')),
      );
      await tester.pump();
      final CheckSheet material = store.checkController!.sheet!;
      expect(material.title, '材质「rock」');
      expect(material.kindLabel, '材质');
      expect(material.fields.map((CheckField f) => f.key).toList(), <String>[
        'color_hex',
        'roughness',
        'metalness',
      ]);
      expect(material.field('color_hex')!.kind, CheckFieldKind.color);
      expect(material.field('color_hex')!.value, 0xFFC9A06A);
      expect(material.field('roughness')!.value, 0.8);
      expect(material.field('roughness')!.min, 0);
      expect(material.field('roughness')!.max, 1);
      expect(material.field('metalness')!.value, 0.1);

      await tester.tap(find.byKey(const ValueKey('three-outliner-camera')));
      await tester.pump();
      final CheckSheet camera = store.checkController!.sheet!;
      expect(camera.title, '相机');
      expect(camera.kindLabel, '相机');
      expect(camera.fields.map((CheckField f) => f.key).toList(), <String>[
        'view',
      ]);
      expect(camera.field('view')!.value, '略高处斜看');

      await tester.tap(
        find.byKey(const ValueKey('three-outliner-component:planet')),
      );
      await tester.pump();
      expect(
        store.checkController!.sheet!.title,
        '组件「planet」',
        reason: '切选中后检查表跟着换',
      );
    });

    testWidgets('改 roughness → update true 且 three-spec.json 落盘值变化', (
      tester,
    ) async {
      final AppStore store = await pumpWorkspace(tester);
      await tester.tap(
        find.byKey(const ValueKey('three-outliner-material:rock')),
      );
      await tester.pump();
      final String before = File(specPath).readAsStringSync();
      final WorkbenchCheckController check = store.checkController!;
      expect((check.sheet!.field('roughness')!.value! as num).toDouble(), 0.8);

      final bool? ok = await tester.runAsync(
        () => check.update('roughness', 0.25),
      );
      expect(ok, isTrue, reason: '合法值必须真的保存成功');

      final Map<String, dynamic> disk = diskSpec();
      final Map<dynamic, dynamic> rock =
          (disk['materials'] as List).first as Map<dynamic, dynamic>;
      expect(rock['roughness'], closeTo(0.25, 1e-9));
      expect(
        rock['metalness'],
        closeTo(0.1, 1e-9),
        reason: '只写改动过的字段，未动字段保持磁盘原值',
      );
      expect(rock['color_hex'], '#c9a06a');
      expect(
        File(specPath).readAsStringSync(),
        isNot(equals(before)),
        reason: '保存后磁盘内容必须真的变了',
      );

      await tester.pump();
      expect(
        (check.sheet!.field('roughness')!.value! as num).toDouble(),
        closeTo(0.25, 1e-9),
        reason: '保存成功后检查表刷新成磁盘值',
      );
    });

    testWidgets('非法值（空组件名 / 超范围数值）→ update false 且文件不变', (tester) async {
      final AppStore store = await pumpWorkspace(tester);
      final String before = File(specPath).readAsStringSync();
      final WorkbenchCheckController check = store.checkController!;

      await tester.tap(
        find.byKey(const ValueKey('three-outliner-component:planet')),
      );
      await tester.pump();
      final bool? emptyWhat = await tester.runAsync(
        () => check.update('what', '   '),
      );
      expect(emptyWhat, isFalse);
      final bool? zeroSize = await tester.runAsync(
        () => check.update('size_scale', 0),
      );
      expect(zeroSize, isFalse, reason: '尺寸比例必须大于 0');

      await tester.tap(
        find.byKey(const ValueKey('three-outliner-material:rock')),
      );
      await tester.pump();
      final bool? tooRough = await tester.runAsync(
        () => check.update('roughness', 1.5),
      );
      expect(tooRough, isFalse, reason: '粗糙度必须在 0..1');

      expect(
        File(specPath).readAsStringSync(),
        before,
        reason: '非法值不得进入保存链路、不得落盘',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('three-refresh-error')),
        findsOneWidget,
        reason: '拒绝写入要有可读提示，不能静默失败',
      );
    });

    testWidgets('无选中时 update 也拒绝，不写盘', (tester) async {
      final AppStore store = await pumpWorkspace(tester);
      final String before = File(specPath).readAsStringSync();
      final bool? ok = await tester.runAsync(
        () => store.checkController!.update('roughness', 0.25),
      );
      expect(ok, isFalse);
      expect(File(specPath).readAsStringSync(), before);
    });

    testWidgets('卸载：清空自己的控制器注册', (tester) async {
      final AppStore store = await pumpWorkspace(tester);
      expect(store.checkController, isNotNull);
      await tester.pumpWidget(_host(store, child: const SizedBox.shrink()));
      await tester.pump();
      expect(store.checkController, isNull);
    });

    testWidgets('卸载：不清别的工作台已接管的控制器', (tester) async {
      final AppStore store = await pumpWorkspace(tester);
      final WorkbenchCheckController foreign = _ForeignController();
      addTearDown(foreign.dispose);
      store.setCheckController(foreign);
      await tester.pumpWidget(_host(store, child: const SizedBox.shrink()));
      await tester.pump();
      expect(
        store.checkController,
        same(foreign),
        reason: '清空必须先判身份，不能把别的工作台的控制器清掉',
      );
    });
  });
}
