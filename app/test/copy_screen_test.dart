// 运行时文案巡检（批次 13）。
//
// `copy_guard_test.dart` 扫的是**源码字面量**；这里补另一半：把真实界面在五个
// 验收尺寸（390×844、844×390、768×1024、1024×768、1440×900）上渲染出来，遍历
// 「此刻上屏的每一个字符串」（Text / SelectableText / Tooltip / 输入框提示 /
// Semantics 标签），再按 `docs/copy-glossary.md` 的术语表与裸错误码规则判一遍。
//
// 源码扫描漏掉的两类问题都会在这里现形：
//  1. 运行时拼出来的句子（`$id → $action` 这类插值上屏）；
//  2. 引擎/服务回传的数据被直接摆上屏（主题 id、错误码、诊断文本、原始工具名）。
//
// 不扫的东西（刻意的）：
//  * 用户文件名与路径——那是用户数据，不是文案（与「文件选择器保留扩展名」同一条例外）；
//  * 输入框里的**值**（可能含用户输入的地址）——只扫 placeholder/提示等设计文案。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/models.dart' as m show Flow;
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/chat_stream.dart';
import 'package:nondesign/widgets/command_palette.dart';
import 'package:nondesign/widgets/docs_view.dart';
import 'package:nondesign/widgets/hotapp_workspace.dart';
import 'package:nondesign/widgets/left_panel.dart';
import 'package:nondesign/widgets/notification_center.dart';
import 'package:nondesign/widgets/play_view.dart';
import 'package:nondesign/widgets/portfolio_view.dart';
import 'package:nondesign/widgets/right_panel.dart';
import 'package:nondesign/widgets/settings_dialog.dart';
import 'package:nondesign/widgets/shell_host.dart';
import 'package:nondesign/widgets/three_workspace.dart';
import 'package:nondesign/widgets/video_workspace.dart';

// ---------------------------------------------------------------------------
// 规则（与 copy_guard_test.dart 的术语表同源；两份都改才算改）
// ---------------------------------------------------------------------------

final List<(RegExp, String)> _banned = [
  (RegExp(r'\bpython\b', caseSensitive: false), 'python'),
  (RegExp(r'\bflutter\b', caseSensitive: false), 'flutter'),
  (RegExp(r'\bdart\b', caseSensitive: false), 'dart'),
  (RegExp(r'\bwasm\b', caseSensitive: false), 'wasm'),
  (RegExp(r'\bmoonviz\b', caseSensitive: false), 'moonviz'),
  (RegExp(r'\bddp\b', caseSensitive: false), 'ddp'),
  (RegExp(r'\bmbt\b', caseSensitive: false), 'mbt'),
  (RegExp(r'\bcanonical\b', caseSensitive: false), 'canonical'),
  (RegExp(r'\bacp\b', caseSensitive: false), 'acp'),
  (RegExp(r'\bagentgate\b', caseSensitive: false), 'agentgate'),
  (RegExp(r'\bserver\b', caseSensitive: false), 'server'),
  (RegExp(r'服务器'), '服务器'),
  (RegExp(r'桌面服务'), '桌面服务'),
  (RegExp(r'端口'), '端口'),
  (RegExp(r'\blocalhost\b', caseSensitive: false), 'localhost'),
  (RegExp(r'127\.0\.0\.1'), '127.0.0.1'),
  (RegExp(r'\bresvg\b', caseSensitive: false), 'resvg'),
  (RegExp(r'\bffmpeg\b', caseSensitive: false), 'ffmpeg'),
  (RegExp(r'\bblockout\b', caseSensitive: false), 'blockout'),
  (RegExp(r'refine-spec', caseSensitive: false), 'refine-spec'),
  (RegExp(r'\bsqlite\b', caseSensitive: false), 'sqlite'),
  (RegExp(r'models\.dev', caseSensitive: false), 'models.dev'),
  (RegExp(r'\bk=v\b', caseSensitive: false), 'k=v'),
  (RegExp(r'surfaceid', caseSensitive: false), 'surfaceId'),
  (RegExp(r'\ba2ui\b', caseSensitive: false), 'a2ui'),
  (RegExp(r'\bnonapp\b', caseSensitive: false), 'nonapp'),
  (RegExp(r'\.nonapp', caseSensitive: false), '.nonapp'),
  (RegExp(r'\bjsonl\b', caseSensitive: false), 'jsonl'),
  (RegExp(r'\bengine_'), 'engine_* 错误码'),
  (RegExp(r'\bsession_[a-z]'), 'session_* 导出名'),
  (RegExp(r'\btool_[a-z]'), 'tool_* 工具名'),
  (RegExp(r'\bmbt_[a-z]'), 'mbt_* 错误码'),
  (RegExp(r'\bddp_[a-z]'), 'ddp_* 错误码'),
  (RegExp(r'\bwasm_[a-z]'), 'wasm_* 错误码'),
  (RegExp(r'\bagent_[a-z]'), 'agent_* 内部名'),
];

final RegExp _bareCode = RegExp(r'^[a-z0-9]+(_[a-z0-9]+)+$');
final RegExp _fileName = RegExp(r'[\\/]|\.(ddp|nonapp|mbt|md|json|png|svg|mp4|html)$', caseSensitive: false);

String? _violation(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  // 文件名/路径是用户数据，不是文案。
  if (_fileName.hasMatch(text)) return null;
  for (final (re, label) in _banned) {
    if (re.hasMatch(text)) return label;
  }
  if (_bareCode.hasMatch(text)) return '裸错误码';
  return null;
}

// ---------------------------------------------------------------------------
// 上屏文本收集
// ---------------------------------------------------------------------------

Set<String> _visibleStrings(WidgetTester tester) {
  final out = <String>{};
  void add(String? s) {
    if (s == null) return;
    final t = s.trim();
    if (t.isNotEmpty) out.add(t);
  }

  for (final w in tester.allWidgets) {
    switch (w) {
      case Text():
        add(w.data);
        add(w.textSpan?.toPlainText());
      case SelectableText():
        add(w.data);
        add(w.textSpan?.toPlainText());
      case Tooltip():
        add(w.message);
      case TextField():
        final d = w.decoration;
        if (d != null) {
          add(d.hintText);
          add(d.labelText);
          add(d.helperText);
          add(d.errorText);
          add(d.prefixText);
          add(d.suffixText);
        }
      case Semantics():
        add(w.properties.label);
        add(w.properties.tooltip);
      case IconButton():
        add(w.tooltip);
      case PopupMenuButton<Object?>():
        add(w.tooltip);
      case Chip():
        add(w.label is Text ? (w.label as Text).data : null);
      default:
        break;
    }
  }
  return out;
}

/// 把一个尺寸下的所有上屏字符串过一遍术语表；命中即带着上下文失败。
void _expectCopyClean(WidgetTester tester, String where) {
  final hits = <String>[];
  for (final s in _visibleStrings(tester)) {
    final term = _violation(s);
    if (term != null) hits.add('"$s"  ← $term');
  }
  expect(hits, isEmpty, reason: '$where 出现内部代称/裸码:\n  ${hits.join('\n  ')}');
}

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

const ModelRegistry _registry = ModelRegistry(
  providers: {
    'deepseek': {
      'name': 'DeepSeek',
      'api': 'https://api.deepseek.com',
      'protocol': 'openai',
      'models': {
        'deepseek-v4.1-flash': {'name': 'DeepSeek V4.1 Flash', 'tool_call': true, 'context': 128000},
      },
    },
  },
  fetchedAt: 'test',
);

AppStore _store({bool project = false}) {
  final store = AppStore()
    ..ready = true
    ..registry = _registry
    ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.toasts.blurEnabled = false;
  if (!project) return store;
  store
    ..hasProject = true
    ..projectName = '演示项目'
    ..projectPath = '/tmp/demo'
    ..activeBoard = 'home'
    ..selectedNode = 'title'
    ..mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n';
  store.render = RenderEnvelope(
    ok: true,
    entry: 'home',
    revision: 3,
    mbt: store.mbt,
    artboards: const [
      Artboard(
        id: 'home',
        name: '首页',
        width: 390,
        height: 844,
        nodes: [
          CanvasNode(
            id: 'title',
            parent: 'root',
            kind: 'text',
            component: 'heading',
            name: 'title',
            text: '欢迎回来',
            x: 24,
            y: 48,
            w: 300,
            h: 40,
            style: NodeStyle(fill: 'none', fontSize: 24),
          ),
          CanvasNode(
            id: 'cta',
            parent: 'root',
            kind: 'rect',
            component: 'button',
            name: 'cta',
            text: '开始',
            x: 24,
            y: 120,
            w: 160,
            h: 44,
            style: NodeStyle(fill: '#7C8CFF', radius: 8),
          ),
        ],
      ),
      Artboard(id: 'detail', name: '详情', width: 390, height: 844, nodes: const []),
    ],
    flows: const [m.Flow(from: 'home', to: 'detail', trigger: 'tap:cta')],
  );
  store.history = [store.mbt, store.mbt];
  store.historyIndex = 1;
  store.chatMessages = [
    ChatMessage.user('把登录页做出来'),
    ChatMessage(
      kind: chatKindProgress,
      text: '正在构建设计稿',
      steps: [
        ChatStep(label: 'design_op', ok: true, ms: 12),
        ChatStep(label: 'read_mbt', ok: true),
      ],
    ),
    ChatMessage(
      kind: chatKindProgress,
      text: '调整没有完成',
      ok: false,
      detail: '这次改动未通过设计校验',
      steps: [ChatStep(label: 'design_op', ok: false, ms: 4)],
    ),
    ChatMessage.assistant('完成，共 2 个画板'),
  ];
  return store;
}

Widget _host(AppStore store, Widget child, {HostOs os = HostOs.ios}) => ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        builder: (context, child) => withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: child,
      ),
    );

Widget _scaffold(Widget body) => Scaffold(body: body);

const List<(String, Size, HostOs)> _sizes = [
  ('390×844 手机竖屏', Size(390, 844), HostOs.ios),
  ('844×390 手机横屏', Size(844, 390), HostOs.ios),
  ('768×1024 平板竖屏', Size(768, 1024), HostOs.ios),
  ('1024×768 平板横屏', Size(1024, 768), HostOs.ios),
  ('1440×900 桌面', Size(1440, 900), HostOs.macos),
];

/// 每个面渲染完都把挂起的异常取干净：文案巡检必须在「界面真的画出来」的
/// 前提下做，所以布局溢出（RenderFlex overflow 等）与文案命中共用一个出口，
/// 一律失败——五个尺寸都得无异常上屏。
void _drain(WidgetTester tester) {
  Object? e;
  while ((e = tester.takeException()) != null) {
    fail('渲染异常（$e）');
  }
}

Future<void> _pump(WidgetTester tester, Size size, Widget app) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(app);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.pump(const Duration(milliseconds: 80));
  _drain(tester);
}

/// 一帧 + 异常出口（面板切换、浮层开关都用它）。
Future<void> _tick(WidgetTester tester, [int ms = 60]) async {
  await tester.pump(Duration(milliseconds: ms));
  _drain(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (label, size, os) in _sizes) {
    group(label, () {
      testWidgets('壳层：Welcome / Workspace / 状态栏 / 聊天', (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // 无项目 → Welcome
        await _pump(
          tester,
          size,
          _host(_store(), ShellHost(capabilities: PlatformCapabilities.forOs(os)), os: os),
        );
        _expectCopyClean(tester, '$label · Welcome');

        // 有项目 → Workspace（桌面/iPad 横屏）或聊天+画中画（手机/iPad 竖屏）
        await _pump(
          tester,
          size,
          _host(_store(project: true), ShellHost(capabilities: PlatformCapabilities.forOs(os)), os: os),
        );
        _expectCopyClean(tester, '$label · Workspace');

        // 状态栏术语（docs/copy-glossary.md §5）：宽屏露出摘要，格式固定，
        // 不出现 rev / ctx / 板 / 节点 这类缩写；上下文用百分比。手机壳把
        // 工作区放进画中画、没有状态栏——桌面档必须露出（下面单独断言）。
        final summary = find.byKey(const ValueKey('status-summary'));
        if (summary.evaluate().isNotEmpty) {
          final text = tester.widget<Text>(summary).data ?? '';
          expect(text, matches(RegExp(r'^版本 \d+ · \d+ 画板 · \d+ 节点$')), reason: '$label 状态栏摘要：$text');
          final ctx = tester.widget<Text>(find.byKey(const ValueKey('status-context'))).data ?? '';
          expect(ctx, matches(RegExp(r'^上下文 (\d+%|—)$')), reason: '$label 状态栏上下文：$ctx');
        }
        if (os == HostOs.macos) {
          expect(summary, findsOneWidget, reason: '$label 桌面工作区必须露出状态栏摘要');
        }
      });

      testWidgets('左栏三面板 / 检查器 / 文档 / 演示', (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = _store(project: true);
        await _pump(tester, size, _host(store, _scaffold(const LeftPanel())));
        for (final panel in ['project', 'docs', 'spec', 'history']) {
          store.setPanel(panel);
          await _tick(tester, 40);
          _expectCopyClean(tester, '$label · 左栏 $panel');
        }

        await _pump(tester, size, _host(store, _scaffold(const Inspector())));
        _expectCopyClean(tester, '$label · 检查器');

        await _pump(tester, size, _host(store, _scaffold(const DocsView())));
        for (final tab in ['prd', 'ui', 'spec']) {
          store.setDocsTab(tab);
          await _tick(tester, 40);
          _expectCopyClean(tester, '$label · 文档 $tab');
        }

        await _pump(tester, size, _host(store, _scaffold(const PlayView())));
        await _tick(tester, 120);
        _expectCopyClean(tester, '$label · 演示');
      });

      testWidgets('工作台：3D / 热应用 / 视频 / 作品集', (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = _store(project: true);
        final surfaces = <String, Widget>{
          '3D 场景': const ThreeWorkspace(),
          '热应用': const HotAppWorkspace(),
          '视频': const VideoWorkspace(),
          '作品集': const PortfolioView(),
        };
        for (final entry in surfaces.entries) {
          await _pump(tester, size, _host(store, _scaffold(entry.value)));
          await _tick(tester, 200);
          await _tick(tester, 120);
          _expectCopyClean(tester, '$label · ${entry.key}');
        }
      });

      testWidgets('浮层：命令面板 / 通知历史 / 设置', (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = _store(project: true);
        await _pump(
          tester,
          size,
          _host(
            store,
            _scaffold(
              Builder(
                builder: (ctx) => Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () => showCommandPalette(
                        ctx,
                        onNewProject: () {},
                        onOpenPath: (_) {},
                        onSettings: () {},
                        onShortcuts: () {},
                      ),
                      child: const Text('打开命令面板'),
                    ),
                    TextButton(
                      onPressed: () => showSettingsDialog(ctx),
                      child: const Text('打开设置'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('打开命令面板'));
        await _tick(tester, 120);
        await _tick(tester, 120);
        _expectCopyClean(tester, '$label · 命令面板');
        // 关掉浮层再开下一个。
        Navigator.of(tester.element(find.byType(Dialog))).pop();
        await _tick(tester, 120);

        await tester.tap(find.text('打开设置'));
        await _tick(tester, 200);
        await _tick(tester, 200);
        _expectCopyClean(tester, '$label · 设置');
      });

      testWidgets('通知历史（四个级别 + 详情）', (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = _store(project: true);
        final toasts = ToastService(autoDismiss: false);
        toasts.success('已保存', '演示项目');
        toasts.info('已复制路径');
        toasts.warn('这台设备不支持在文件夹中显示');
        toasts.error('模型下载失败', '请检查网络后重试');
        await _pump(
          tester,
          size,
          _host(store, _scaffold(Center(child: NotificationCenter(service: toasts)))),
        );
        _expectCopyClean(tester, '$label · 通知历史');
        toasts.dispose();
      });
    });
  }

  testWidgets('Agent 面板：工具名走术语表，op 原文与错误码只在折叠详情', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _store(project: true);
    store.timeline = [
      TimelineEntry(
        kind: 'tool',
        tool: 'design_op',
        args: {'op': 'place home text x 1 2 3 4'},
      ),
      TimelineEntry(
        kind: 'tool',
        tool: 'design_op',
        args: {'op': 'update home x'},
        ok: false,
        error: 'mbt_gate_block',
        message: '这次改动未通过设计校验',
      ),
    ];
    await _pump(
      tester,
      const Size(1024, 768),
      _host(store, _scaffold(const RightPanel()), os: HostOs.macos),
    );

    expect(find.text('设计变更'), findsNWidgets(2));
    // 常驻面：人话失败句可见，原始 op/错误码不可见。
    expect(find.text('这次改动未通过设计校验'), findsOneWidget);
    expect(find.textContaining('place home'), findsNothing);
    expect(find.textContaining('mbt_gate_block'), findsNothing);
    _expectCopyClean(tester, 'Agent 面板 · 折叠态');

    // 展开失败行：原始错误码与 op 才出现在技术详情里。
    await tester.tap(find.byIcon(Icons.close_rounded).first);
    await _tick(tester, 80);
    expect(find.textContaining('mbt_gate_block'), findsOneWidget);
    expect(find.textContaining('update home'), findsOneWidget);
  });

  testWidgets('聊天轨迹：原始工具名经 toolLabel 上屏', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(tester, const Size(390, 844), _host(_store(project: true), _scaffold(const ChatStreamView())));
    // 轨迹里出现的是中文动作名，不是 design_op / read_mbt。
    expect(find.text('设计变更'), findsWidgets);
    expect(find.text('读取设计稿'), findsWidgets);
    expect(find.text('design_op'), findsNothing);
    expect(find.text('read_mbt'), findsNothing);
    _expectCopyClean(tester, '390×844 · 聊天轨迹');
  });
}
