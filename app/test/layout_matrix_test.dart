// 响应式壳矩阵（批次 12）——四档验收尺寸逐个钉死。
//
// | 视口               | 宿主   | 壳             | 主面                         |
// |--------------------|--------|----------------|------------------------------|
// | 390×844            | iOS    | ChatPiPShell   | 聊天全屏 + 工作区画中画       |
// | 844×390            | iOS    | ChatPiPShell   | 同上                         |
// | 768×1024           | iOS    | ChatPiPShell   | 同上（明确裁决 C）            |
// | 834×1194           | iOS    | ChatPiPShell   | 同上                         |
// | 1024×768           | iOS    | DesktopShell   | 工作区/Welcome + 右侧聊天窄栏 |
// | 1194×834           | iOS    | DesktopShell   | 同上                         |
// | 1440×900           | macOS  | DesktopShell   | 同上                         |
// | 1080×700（窄 PC）  | macOS  | DesktopShell   | 窄栏折叠成 44px 第二列条带    |
//
// 四个面不得统一：这里同时断言「手机壳不是桌面壳」「竖屏平板不是桌面壳」。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/platform_capabilities.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/chat_pip_shell.dart';
import 'package:nondesign/widgets/chat_rail.dart';
import 'package:nondesign/widgets/desktop_shell.dart';
import 'package:nondesign/widgets/right_panel.dart';
import 'package:nondesign/widgets/shell_host.dart';
import 'package:nondesign/widgets/welcome.dart';
import 'package:nondesign/widgets/workspace.dart';

AppStore _store({bool project = false, bool withModel = false}) {
  // autoDismiss:false —— 本文件的回归会触发通知，测试结束不留定时器。
  final store = AppStore(toasts: ToastService(autoDismiss: false));
  store.ready = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  store.hasProject = project;
  store.projectName = '演示项目';
  if (withModel) {
    // 真实模型胶囊宽度（无 registry 时只显示「选择模型」，会把顶栏溢出藏起来）。
    store.registry = ModelRegistry.fromJson({
      'fetched_at': 'layout-matrix-test',
      'providers': {
        'deepseek': {
          'name': 'DeepSeek',
          'api': 'https://api.deepseek.com',
          'models': {
            'deepseek-v4.1-flash': {
              'name': 'DeepSeek V4.1 Flash',
              'limit': {'context': 128000},
              'tool_call': true,
            },
          },
        },
      },
    });
  }
  if (project) {
    store.mbt = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n';
    store.render = RenderEnvelope(
      ok: true,
      entry: 'home',
      revision: 1,
      mbt: store.mbt,
      artboards: const [
        Artboard(id: 'home', name: 'home', width: 390, height: 844, nodes: []),
      ],
    );
  }
  return store;
}

Widget _wrap(AppStore store, PlatformCapabilities caps) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        builder: (context, child) =>
            withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: ShellHost(capabilities: caps),
      ),
    );

Future<void> _pumpAt(
  WidgetTester tester,
  AppStore store,
  Size size, {
  HostOs os = HostOs.ios,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrap(store, PlatformCapabilities.forOs(os)));
  // 壳层持久化读取是异步的（SharedPreferences），一帧让它落地。
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('验收矩阵：壳类型', () {
    testWidgets('390×844 手机竖屏 → ChatPiPShell（聊天全屏 + 画中画）', (tester) async {
      final store = _store();
      await _pumpAt(tester, store, const Size(390, 844));
      expect(find.byType(ChatPiPShell), findsOneWidget);
      expect(find.byType(DesktopShell), findsNothing);
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(find.byKey(const ValueKey('pip-edge-capsule')), findsOneWidget);
      expect(find.byType(Workspace), findsNothing, reason: '工作区在画中画里，不常驻');
      expect(tester.takeException(), isNull);
    });

    testWidgets('844×390 手机横屏 → ChatPiPShell', (tester) async {
      await _pumpAt(tester, _store(), const Size(844, 390));
      expect(find.byType(ChatPiPShell), findsOneWidget);
      expect(find.byType(DesktopShell), findsNothing);
      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final size in const [Size(768, 1024), Size(834, 1194)]) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()} iPad 竖屏 → ChatPiPShell（裁决 C）',
          (tester) async {
        await _pumpAt(tester, _store(project: true), size);
        expect(find.byType(ChatPiPShell), findsOneWidget);
        expect(find.byType(DesktopShell), findsNothing,
            reason: '竖屏平板放不下「工作区 + 320–420 聊天栏」，禁止落桌面壳');
        expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
        expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    for (final entry in const [
      (Size(1024, 768), HostOs.ios),
      (Size(1194, 834), HostOs.ios),
      (Size(1440, 900), HostOs.macos),
    ]) {
      testWidgets('${entry.$1.width.toInt()}×${entry.$1.height.toInt()} → DesktopShell',
          (tester) async {
        await _pumpAt(tester, _store(), entry.$1, os: entry.$2);
        expect(find.byType(DesktopShell), findsOneWidget);
        expect(find.byType(ChatPiPShell), findsNothing);
        expect(find.byType(Welcome), findsOneWidget, reason: '无项目的主面是经典 Welcome');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('1080×700 窄 PC → DesktopShell + 44px 折叠条带', (tester) async {
      await _pumpAt(tester, _store(project: true), const Size(1080, 700), os: HostOs.macos);
      expect(find.byType(DesktopShell), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing,
          reason: '窄 PC 默认折叠，不占主面宽度');
      final strip = find.byKey(const ValueKey('desktop-chat-rail-strip'));
      expect(strip, findsOneWidget);
      expect(tester.getSize(strip).width, 44);
      expect(find.byKey(const ValueKey('agent-input')), findsNothing,
          reason: '折叠态 NaN 内容不渲染，点图标才展开');
      expect(tester.takeException(), isNull);
    });
  });

  group('主面与唯一的右侧窄栏', () {
    testWidgets('无项目桌面：主面 Welcome（最近项目/作品集/一句话起步），不是空工作区', (tester) async {
      await _pumpAt(tester, _store(), const Size(1440, 900), os: HostOs.macos);
      expect(find.byType(Welcome), findsOneWidget);
      expect(find.byKey(const ValueKey('welcome-wide')), findsOneWidget);
      expect(find.text('最近项目'), findsOneWidget);
      expect(find.text('作品集'), findsOneWidget);
      expect(find.byKey(const ValueKey('welcome-brief')), findsOneWidget);
      expect(find.byType(Workspace), findsNothing);
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing,
          reason: '主页默认不显示右侧栏');
      expect(find.byKey(const ValueKey('desktop-chat-rail-strip')), findsNothing,
          reason: '折叠条带也不应出现在主页');
      expect(find.byKey(const ValueKey('welcome-open-chat')), findsNothing,
          reason: '主页没有右栏，聊天入口隐藏');
      expect(tester.takeException(), isNull);
    });

    testWidgets('有项目桌面：Workspace 主面 + 右侧唯一窄栏（无 348 RightPanel 双栏）',
        (tester) async {
      await _pumpAt(tester, _store(project: true), const Size(1440, 900), os: HostOs.macos);
      expect(find.byType(Workspace), findsOneWidget);
      expect(tester.widget<Workspace>(find.byType(Workspace)).embedded, isFalse);
      expect(find.byType(RightPanel), findsNothing, reason: '右侧只能有一个窄栏');
      final rail = find.byKey(const ValueKey('desktop-chat-rail'));
      expect(rail, findsOneWidget);
      expect(tester.getSize(rail).width, 360, reason: '默认 360');
      expect(find.byKey(const ValueKey('agent-input')), findsOneWidget,
          reason: '窄栏默认落在 NaN tab');
      expect(find.byKey(const ValueKey('chat-input')), findsNothing,
          reason: '独立聊天 tab 已并入 NaN');
      expect(tester.takeException(), isNull);
    });

    testWidgets('1024 横版默认折叠（保证主面 ≥700）', (tester) async {
      await _pumpAt(tester, _store(project: true), const Size(1024, 768));
      expect(find.byType(DesktopShell), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-chat-rail-strip')), findsOneWidget,
          reason: '1024 默认折叠（或 320 展开）——这里选折叠');
      expect(tester.takeException(), isNull);
    });

    testWidgets('1024 横版持久化展开：栏 clamp 到 320/324，主面仍 ≥700', (tester) async {
      SharedPreferences.setMockInitialValues({ShellStorage.railExpandedKey: true});
      await _pumpAt(tester, _store(project: true), const Size(1024, 768));
      final rail = find.byKey(const ValueKey('desktop-chat-rail'));
      expect(rail, findsOneWidget);
      final railWidth = tester.getSize(rail).width;
      expect(railWidth, greaterThanOrEqualTo(kChatRailMinWidth));
      expect(railWidth, lessThanOrEqualTo(kChatRailMaxWidth));
      final mainWidth = tester.getSize(find.byType(Workspace)).width;
      expect(mainWidth, greaterThanOrEqualTo(kDesktopMainMinWidth),
          reason: '主面不得掉进 Workspace 手机档（$mainWidth < ${kDesktopMainMinWidth}）');
      expect(tester.takeException(), isNull);
    });

    for (final size in const [Size(1024, 768), Size(1054, 700)]) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()} 展开边界：主面 ≥700 且无溢出',
          (tester) async {
        SharedPreferences.setMockInitialValues({ShellStorage.railExpandedKey: true});
        await _pumpAt(tester, _store(project: true), size, os: HostOs.macos);
        expect(find.byType(DesktopShell), findsOneWidget);
        expect(find.byKey(const ValueKey('desktop-chat-rail')), findsOneWidget);
        expect(tester.getSize(find.byType(Workspace)).width,
            greaterThanOrEqualTo(kDesktopMainMinWidth),
            reason: '展开窄栏仍要给画布 ≥700（$size）');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('窄栏宽度拖拽 + 折叠态持久化（重启恢复）', (tester) async {
      await _pumpAt(tester, _store(project: true), const Size(1440, 900), os: HostOs.macos);
      final rail = find.byKey(const ValueKey('desktop-chat-rail'));
      expect(tester.getSize(rail).width, 360);

      await tester.drag(find.byKey(const ValueKey('desktop-chat-rail-split')), const Offset(-40, 0));
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getSize(rail).width, 400, reason: '向左拖 40 → 400（clamp 420 内）');

      await tester.tap(find.byKey(const ValueKey('desktop-chat-rail-collapse')));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing);
      expect(find.byKey(const ValueKey('desktop-chat-rail-strip')), findsOneWidget);

      // 「重启」：同一份 SharedPreferences 重新建壳 → 折叠态与宽度都恢复。
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpAt(tester, _store(project: true), const Size(1440, 900), os: HostOs.macos);
      expect(find.byKey(const ValueKey('desktop-chat-rail-strip')), findsOneWidget,
          reason: '折叠态被持久化');
      await tester.tap(find.byKey(const ValueKey('desktop-rail-strip-expand')));
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getSize(find.byKey(const ValueKey('desktop-chat-rail'))).width, 400,
          reason: '宽度被持久化');
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄栏两个 tab：NaN / 检查（聊天已并入 NaN）', (tester) async {
      await _pumpAt(tester, _store(project: true), const Size(1440, 900), os: HostOs.macos);
      for (final id in ['agent', 'inspect']) {
        expect(find.byKey(ValueKey('desktop-chat-rail-tab-$id')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('desktop-chat-rail-tab-chat')), findsNothing,
          reason: '独立聊天 tab 与 NaN 重复，已移除');
      expect(find.byKey(const ValueKey('agent-input')), findsOneWidget,
          reason: '默认落在 NaN（聊天 + 任务指令）');
      await tester.tap(find.byKey(const ValueKey('desktop-chat-rail-tab-inspect')));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byKey(const ValueKey('agent-input')), findsNothing,
          reason: '切到检查后 NaN 内容让位（同一栏，不叠两栏）');
      expect(tester.takeException(), isNull);
    });
  });

  // 桌面壳层回归（批次：折叠栏不盖顶栏，命令条与软键盘自适应）。
  //
  // 折叠态条带曾是叠在主面右缘的 44px 覆盖层：顶栏最右侧「设置 ⌘,」被
  // 完全盖住（点不动也看不见）、「切换主题」被盖一半，状态栏右段同样。
  group('桌面壳层：折叠条带 / 命令条 / 软键盘', () {
    testWidgets('1080×700 折叠条带不覆盖顶栏右端与状态栏右段（设置可点开）', (tester) async {
      await _pumpAt(tester, _store(project: true, withModel: true), const Size(1080, 700),
          os: HostOs.macos);
      final stripRect = tester.getRect(find.byKey(const ValueKey('desktop-chat-rail-strip')));
      expect(stripRect.width, 44);

      final settings = find.byKey(const ValueKey('title-bar-settings'));
      final theme = find.byKey(const ValueKey('title-bar-theme'));
      final settingsRect = tester.getRect(settings);
      final themeRect = tester.getRect(theme);
      expect(settingsRect.overlaps(stripRect), isFalse,
          reason: '设置齿轮不得被折叠条带盖住（$settingsRect vs $stripRect）');
      expect(themeRect.overlaps(stripRect), isFalse,
          reason: '切换主题不得被折叠条带盖住（$themeRect vs $stripRect）');
      expect(settingsRect.right, lessThanOrEqualTo(stripRect.left));
      expect(themeRect.right, lessThanOrEqualTo(stripRect.left));

      // 状态栏右段（上下文百分比）同样留在主面内，不被条带吞掉。
      final ctxRect = tester.getRect(find.byKey(const ValueKey('status-context')));
      expect(ctxRect.overlaps(stripRect), isFalse);

      // 真点一下：设置对话框必须能打开（此前点击被条带吞掉）。
      await tester.tap(settings);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('设置'), findsOneWidget, reason: '设置对话框应打开');
      expect(tester.takeException(), isNull);
    });

    // (视口宽, 命令条是否完整展示)。顶栏实际宽 = 视口 - 折叠条 44 / 展开栏 360：
    // 900→856、980→936、1100→740、1240→880（断点边界）、1280→920。
    for (final entry in const [
      (900.0, false),
      (980.0, true),
      (1100.0, false),
      (1240.0, true),
      (1280.0, true),
    ]) {
      testWidgets('顶栏 ${entry.$1.toInt()} 宽（真模型胶囊）无溢出', (tester) async {
        SharedPreferences.setMockInitialValues({});
        await _pumpAt(tester, _store(project: true, withModel: true), Size(entry.$1, 800),
            os: HostOs.macos);
        final icon = find.byKey(const ValueKey('title-bar-command-icon'));
        final bar = find.byKey(const ValueKey('title-bar-command-bar'));
        if (entry.$2) {
          expect(bar, findsOneWidget, reason: '${entry.$1.toInt()} 上命令条完整展示');
          expect(icon, findsNothing);
        } else {
          expect(icon, findsOneWidget, reason: '${entry.$1.toInt()} 上命令条收成搜索图标');
          expect(bar, findsNothing);
        }
        expect(tester.takeException(), isNull, reason: '顶栏不得溢出（${entry.$1}）');
      });
    }

    testWidgets('1023 宽可展开折叠栏：主面仍 ≥700', (tester) async {
      await _pumpAt(tester, _store(project: true), const Size(1023, 768), os: HostOs.macos);
      expect(find.byKey(const ValueKey('desktop-chat-rail-strip')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desktop-rail-strip-expand')));
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsOneWidget,
          reason: '1023 ≥ 700 + 320，放得下就必须能展开');
      expect(tester.getSize(find.byType(Workspace)).width,
          greaterThanOrEqualTo(kDesktopMainMinWidth));
      expect(tester.takeException(), isNull);
    });

    testWidgets('1000 宽放不下：条带点击给出人话提示而不是静默无效', (tester) async {
      final store = _store(project: true);
      await _pumpAt(tester, store, const Size(1000, 700), os: HostOs.macos);
      await tester.tap(find.byKey(const ValueKey('desktop-rail-strip-agent')));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing);
      expect(store.toasts.history, isNotEmpty);
      expect(store.toasts.history.first.title, '窗口太窄，聊天栏展不开');
      expect(tester.takeException(), isNull);
    });

    testWidgets('显式右栏命令（命令面板/检查器同入口）在放不下时给出提示', (tester) async {
      final store = _store(project: true);
      await _pumpAt(tester, store, const Size(900, 700), os: HostOs.macos);
      // 命令面板/检查器按钮的同一个入口：store.setRightTab('agent'|'inspect')。
      store.setRightTab('inspect');
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing);
      expect(store.toasts.history, isNotEmpty, reason: '显式命令不得静默丢弃');
      expect(store.toasts.history.first.title, '窗口太窄，聊天栏展不开');
      expect(tester.takeException(), isNull);
    });

    testWidgets('iPad 1024×768 软键盘：右侧栏输入框缩到键盘之上', (tester) async {
      SharedPreferences.setMockInitialValues({ShellStorage.railExpandedKey: true});
      await _pumpAt(tester, _store(project: true), const Size(1024, 768), os: HostOs.ios);
      final input = find.byKey(const ValueKey('agent-input'));
      expect(input, findsOneWidget);
      final before = tester.getRect(input);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump(const Duration(milliseconds: 80));
      final after = tester.getRect(input);
      expect(after.bottom, lessThanOrEqualTo(768 - 300),
          reason: '输入框底边必须在键盘顶之上（keyboardTop=468）');
      expect(after.bottom, lessThan(before.bottom), reason: '壳层确实消费了底部 inset');
      expect(tester.takeException(), isNull);
    });

    testWidgets('右栏 tab 文案统一 NaN', (tester) async {
      await _pumpAt(tester, _store(project: true), const Size(1440, 900), os: HostOs.macos);
      final agentTab = find.byKey(const ValueKey('desktop-chat-rail-tab-agent'));
      expect(find.descendant(of: agentTab, matching: find.text('NaN')), findsOneWidget);
      // 独立「聊天」tab 已并入 NaN（用户实测 2026-11-18），不能再出现。
      expect(find.descendant(of: agentTab, matching: find.text('聊天')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('整壳全幅视图先于壳路由', () {
    for (final view in const ['play', 'portfolio']) {
      testWidgets('view=$view：手机与桌面都无右侧窄栏', (tester) async {
        final phone = _store(project: true)..view = view;
        await _pumpAt(tester, phone, const Size(390, 844));
        expect(find.byType(ChatPiPShell), findsNothing);
        expect(find.byType(DesktopShell), findsNothing);
        expect(find.byType(Workspace), findsOneWidget);
        expect(find.byType(ChatRail), findsNothing);

        final desktop = _store(project: true)..view = view;
        await _pumpAt(tester, desktop, const Size(1440, 900), os: HostOs.macos);
        expect(find.byType(DesktopShell), findsNothing);
        expect(find.byType(Workspace), findsOneWidget);
        expect(find.byKey(const ValueKey('desktop-chat-rail')), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    // 插件工作台不是全幅：桌面壳里左侧工作区 + 右侧 NaN 常驻（用户裁决
    // 2026-11-18）；手机聊天优先壳里是整屏工作区（壳内 classic face）。
    testWidgets('plugin:three：手机整屏，桌面带 NaN 窄栏', (tester) async {
      await _pumpAt(tester, _store(project: true)..view = 'plugin:three', const Size(390, 844));
      expect(find.byType(ChatPiPShell), findsOneWidget);
      expect(find.byType(Workspace), findsOneWidget);
      expect(find.byType(ChatRail), findsNothing);

      await _pumpAt(tester, _store(project: true)..view = 'plugin:three',
          const Size(1440, 900), os: HostOs.macos);
      expect(find.byType(DesktopShell), findsOneWidget);
      expect(find.byType(Workspace), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-chat-rail')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('四个面不统一：同一 store 在手机与桌面落不同壳', (tester) async {
    await _pumpAt(tester, _store(project: true), const Size(390, 844));
    expect(find.byType(ChatPiPShell), findsOneWidget);
    await _pumpAt(tester, _store(project: true), const Size(1440, 900), os: HostOs.macos);
    expect(find.byType(DesktopShell), findsOneWidget);
    expect(find.byType(ChatPiPShell), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
