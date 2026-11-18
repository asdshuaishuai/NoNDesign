// 真实模型验收（人工/按需执行，CI 默认跳过）。
//
//   cd app && DEEPSEEK_API_KEY=sk-... \
//     flutter test --dart-define=REAL_ACCEPTANCE=true \
//     test/real_model_acceptance_test.dart -r expanded
//
// 这条测试不碰 mock：真模型（DeepSeek）、真引擎（assets/engine/moonviz.wasm）、
// 真本地服务（3D / 热应用 / 视频），验证四条主链：
//
//  1. design PLAN：一句话 → PRD / UI 说明 / 设计规范落进 docs；
//  2. design BUILD：AgentGate 写画布 → render 信封有画板（画布真的生成了）；
//  3. hotapp workspace：NaN 在热应用工作台里调工具建应用，主面自动切到该工作台；
//  4. three workspace：NaN 在 3D 工作台里建场景，主面自动切到该工作台；
//  5. video：代码动画的机械对照可用，导出被明确拒绝（不落 mp4）。
//
// 只读/临时目录：项目库、聊天与进度快照都落临时目录；3D / 热应用产物落在
// 应用自己的数据目录，测试结束按名字删除。

@Tags(['real-model'])
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/api.dart';
import 'package:nondesign/core/dart_agent.dart';
import 'package:nondesign/core/engine/engine_service.dart';
import 'package:nondesign/core/hotapp_service.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/project_service.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/video_service.dart';

import 'fixtures/engine/test_env.dart';

const bool _enabled = bool.fromEnvironment('REAL_ACCEPTANCE');

/// 验收用的模型（用户 key 是 DeepSeek 官方 key；V4.1 Flash 快且支持工具调用）。
const String _model = 'deepseek-flash';
const String _baseUrl = 'https://api.deepseek.com';

class _Harness {
  _Harness(this.store, this.engine, this.root);

  final AppStore store;
  final EngineService engine;
  final Directory root;

  Future<void> dispose() async {
    try {
      await engine.dispose();
    } catch (_) {}
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  }
}

Future<_Harness> _harness({int maxSteps = 60}) async {
  final apiKey = Platform.environment['DEEPSEEK_API_KEY'] ?? '';
  if (apiKey.isEmpty) {
    fail('缺少 DEEPSEEK_API_KEY：真实模型验收必须显式给 key');
  }

  final root = Directory.systemTemp.createTempSync('nondesign-real-accept');
  final projectDir = Directory('${root.path}/projects')..createSync(recursive: true);
  final engine = await EngineService.start(wasmBytes: engineBytes());
  final store = AppStore(
    localCore: LocalCore(
      // 生产同一条适配路径（store.boot 也是 EngineServiceAdapter）。
      engine: EngineServiceAdapter(engine),
      projects: ProjectService(root: () async => projectDir),
    ),
    toasts: ToastService(autoDismiss: false),
  );
  store.recoveryDir = '${root.path}/recovery';
  store.settingsMirrorDir = '${root.path}/settings';
  store.registry = ModelRegistry.fromJson(
    jsonDecode(File('${appDir().path}/assets/models.json').readAsStringSync())
        as Map<String, dynamic>,
  );
  store.settings
    ..providerId = 'deepseek'
    ..modelId = _model
    ..baseUrl = _baseUrl
    ..apiKey = apiKey
    ..thinkingLevel = 'auto'
    ..maxSteps = maxSteps
    ..agentRuntime = agentRuntimeLocal;
  store.ready = true;

  expect(store.engineReady, isTrue, reason: '真实引擎没起来，后面全是假绿');
  expect(store.model?.toolCall, isTrue, reason: '验收模型必须支持工具调用');

  final created = await store.newProject(name: 'real-acceptance', empty: true);
  expect(created, isTrue, reason: '空项目建不起来：${AppStore.failureMessage(store.agentError)}');
  return _Harness(store, engine, root);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认把所有 HttpClient 请求拦成 400（空 body）——真实模型验收
  // 必须还原真实网络，否则永远是「API error (400)」。
  HttpOverrides.global = null;
  SharedPreferences.setMockInitialValues(const <String, Object>{});

  group(
    '真实模型验收（DeepSeek · 真引擎 · 真工作区服务）',
    () {
      test('1/2 design：PLAN 落文档 → BUILD 落画布（AgentGate + render）', () async {
        final h = await _harness();
        addTearDown(h.dispose);
        final store = h.store;

        final planOk = await store.runPlan(
          '做一个极简记账 App：首页显示本月支出合计和最近三笔，底部两个 Tab（记账 / 统计），'
          '支持「记一笔」弹出金额+分类+备注。移动端优先，风格克制。',
        );
        expect(planOk, isTrue,
            reason: 'PLAN 失败：${store.agentError} / ${AppStore.failureMessage(store.agentError)}');
        expect(store.docs.prd.trim(), isNotEmpty, reason: 'PRD 没落盘');
        expect(store.docs.ui.trim(), isNotEmpty, reason: 'UI 说明没落盘');
        expect(store.docs.design.palette, isNotEmpty, reason: '设计规范没落盘');
        // 终态必须成对可判：时间线有 finish 行。
        expect(
          store.timeline.where((t) => t.kind == 'finish').length,
          greaterThanOrEqualTo(1),
          reason: 'run 没有终态行',
        );

        final buildOk = await store.runBuild(
          '根据 PRD 与 UI 说明生成完整可交互原型：先 create 首页画板，'
          '再生成「记账」「统计」两个页面并连起来。',
        );
        expect(buildOk, isTrue,
            reason: 'BUILD 失败：${store.agentError} / ${AppStore.failureMessage(store.agentError)}');
        expect(store.render.artboards, isNotEmpty, reason: 'render 信封没有画板：画布没生成');
        expect(store.render.artboards.first.width, greaterThan(0));
        expect(store.agentError, isNull);
        // ignore: avoid_print
        print('[acceptance] design OK · artboards=${store.render.artboards.length} '
            'nodes=${store.render.artboards.map((a) => a.nodes.length).toList()} '
            'prd=${store.docs.prd.length}c ui=${store.docs.ui.length}c');
      }, timeout: const Timeout(Duration(minutes: 12)));

      test('3 hotapp：NaN 在热应用工作台建应用，主面自动切过去', () async {
        final h = await _harness();
        addTearDown(h.dispose);
        final store = h.store;
        final name = 'acceptance-invoice-${DateTime.now().millisecondsSinceEpoch}';

        final ok = await store.runWorkspace(
          '做一个热应用，名字叫 $name：一个发票金额计算器，输入金额和税率，'
          '实时显示税额与合计。用本机数据能力记住最近一次输入。',
          mode: workspaceModeHotapp,
        );
        expect(ok, isTrue,
            reason: '热应用 run 失败：${store.agentError} / ${AppStore.failureMessage(store.agentError)}');
        expect(store.view, 'plugin:hotapp',
            reason: '工具调用后主面应自动切到热应用工作台（实际 ${store.view}）');
        expect(store.settings.chatWorkspaceMode, workspaceModeHotapp);

        final service = await HotAppService.open();
        final apps = await service.list();
        final created = apps.where((a) => a.name == name).toList();
        expect(created, isNotEmpty, reason: '热应用没有落盘：$name');
        // ignore: avoid_print
        print('[acceptance] hotapp OK · app=$name files=${created.length}');
        await service.delete(name);
      }, timeout: const Timeout(Duration(minutes: 12)));

      test('4 three：NaN 在 3D 工作台建场景，主面自动切过去', () async {
        final h = await _harness();
        addTearDown(h.dispose);
        final store = h.store;
        final name = 'acceptance-scene-${DateTime.now().millisecondsSinceEpoch}';

        final ok = await store.runWorkspace(
          '建一个 3D 场景，名字叫 $name：一个漂浮在深色海面上的发光立方体，'
          '缓慢旋转，背景有薄雾。',
          mode: workspaceModeThree,
        );
        expect(ok, isTrue,
            reason: '3D run 失败：${store.agentError} / ${AppStore.failureMessage(store.agentError)}');
        expect(store.view, 'plugin:three',
            reason: '工具调用后主面应自动切到 3D 工作台（实际 ${store.view}）');

        final service = await ThreeService.open();
        final scenes = await service.listProjects();
        final created = scenes.where((s) => s.name == name).toList();
        expect(created, isNotEmpty, reason: '3D 场景没有落盘：$name');
        // ignore: avoid_print
        print('[acceptance] three OK · scene=$name');
        await service.deleteProject(name);
      }, timeout: const Timeout(Duration(minutes: 12)));

      test('5 video：代码动画对照可用，导出被明确拒绝（不落 mp4）', () async {
        final h = await _harness();
        addTearDown(h.dispose);

        final service = VideoService.instance;
        final doc = service.loadSample(0);
        expect(doc.totalSeconds, greaterThan(0));
        // 逐帧画面确实是算出来的（不是解码出来的文件）。
        final frame = doc.frameSvg(0.5);
        expect(frame.contains('<svg'), isTrue, reason: '帧不是矢量算式输出');

        final services = LocalWorkspaceServices(
          model: _model,
          baseUrl: _baseUrl,
          apiKey: Platform.environment['DEEPSEEK_API_KEY'] ?? '',
        );
        final review = await services.videoReview(
          timeline: doc.timeline,
          spec: doc.spec.raw,
        );
        expect(review['ok'], isTrue, reason: '规范对照失败：${review['error']}');
        expect(review['summary'], isNotEmpty);

        final render = await services.videoRender(timeline: doc.timeline, spec: doc.spec.raw);
        expect(render['ok'], isFalse);
        expect(render['error'], 'video_export_disabled');
        // ignore: avoid_print
        print('[acceptance] video OK · seconds=${doc.totalSeconds} frames=${doc.frameCount(10)}');
      }, timeout: const Timeout(Duration(minutes: 2)));
    },
    skip: _enabled ? false : 'REAL_ACCEPTANCE 未开启（--dart-define=REAL_ACCEPTANCE=true）',
  );
}
