// 设置第二轮（batch 11）回归：
//
// 1. 端点：打开即有值、只读 + 锁图标；模型清单未加载时用内置端点兜底；
//    切服务商同步刷新端点/模型；旧自定义端点显式提示且可一键重置。
// 2. 模型行在服务商下方 → 底部面板（拖拽把手、0.7 高、安全区、搜索、
//    更新清单、勾选），选中写 modelId 并关闭。四档尺寸逐档断言。
// 3. 合并「运行方式」卡：内置（默认）/ 连接桌面二选一；只有选连接桌面
//    才展开地址 + 连接码；「检测连接」内联 检测中/已连接/失败原因；
//    桌面本机显示「本机引擎就绪 / 本机运行」，并带宿主的手机连接开关。
// 4. 本地语义模型卡在设置里可见（≈388 MB），打开设置不自动下载。
//
// 五个尺寸：390×844、844×390、768×1024、1024×768、1440×900。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/mediapipe_service.dart';
import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/remote/desktop_rpc_host.dart';
import 'package:nondesign/core/remote_desktop_client.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/settings_dialog.dart';

const _phoneSmall = Size(390, 844);
const _phoneLandscape = Size(844, 390);
const _padPortrait = Size(768, 1024);
const _padLandscape = Size(1024, 768);
const _desktop = Size(1440, 900);

ModelRegistry _registry() => ModelRegistry.fromJson({
      'providers': {
        'deepseek': {
          'name': 'DeepSeek',
          'api': 'https://api.deepseek.com',
          'protocol': 'openai',
          'models': {
            'deepseek-chat': {
              'name': 'DeepSeek Chat',
              'tool_call': true,
              'limit': {'context': 128000},
            },
            'deepseek-reasoner': {
              'name': 'DeepSeek Reasoner',
              'tool_call': true,
              'reasoning': true,
              'limit': {'context': 64000},
            },
          },
        },
        'openai': {
          'name': 'OpenAI',
          'api': 'https://api.openai.com/v1',
          'protocol': 'openai',
          'models': {
            'gpt-5': {
              'name': 'GPT-5',
              'tool_call': true,
              'limit': {'context': 400000},
            },
          },
        },
      },
      'fetched_at': 'test',
    });

class _TestStore extends AppStore {
  _TestStore({ToastService? toasts})
      : super(toasts: toasts ?? ToastService(autoDismiss: false));

  int saves = 0;
  int refreshes = 0;
  int remoteTests = 0;
  final List<String> calls = [];
  RemoteDesktopStatus nextStatus = const RemoteDesktopStatus.notConfigured();
  Completer<void>? probeGate;
  Duration? probeDelay;
  RpcHostStatus? hostStatus;

  @override
  RpcHostStatus? get desktopHostStatus => hostStatus;

  @override
  bool get desktopHostRunning => hostStatus?.running ?? false;

  @override
  Future<void> saveSettings() async {
    saves++;
  }

  @override
  Future<void> refreshModels() async {
    refreshes++;
  }

  @override
  Future<RemoteDesktopStatus> testRemoteConnection(String url, {String? token}) async {
    remoteTests++;
    calls.add('test:$url:${token ?? ''}');
    if (probeGate != null) await probeGate!.future;
    if (probeDelay != null) await Future<void>.delayed(probeDelay!);
    return nextStatus;
  }

  @override
  Future<RemoteDesktopStatus> applyRemoteDesktop(String url, {String? token}) async {
    calls.add('apply:$url:${token ?? ''}');
    settings.serverUrl = url;
    return nextStatus;
  }
}

bool _isPhoneLayout(Size size) =>
    size.width < 700 || (size.height < 460 && size.width < 960);

TargetPlatform _platformFor(Size size) =>
    _isPhoneLayout(size) ? TargetPlatform.iOS : TargetPlatform.macOS;

Widget _wrap(AppStore store, Widget child, TargetPlatform platform) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true).copyWith(platform: platform),
        builder: (context, child) =>
            withResponsiveTextScale(context, child ?? const SizedBox.shrink()),
        home: child,
      ),
    );

Future<void> _openSettings(
  WidgetTester tester,
  AppStore store,
  Size size, {
  MediaPipeService? mediaPipe,
  TargetPlatform? platform,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_wrap(
    store,
    Builder(builder: (context) {
      return Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => showSettingsDialog(context, mediaPipeService: mediaPipe),
            child: const Text('open'),
          ),
        ),
      );
    }),
    platform ?? _platformFor(size),
  ));
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(milliseconds: 320));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 同一 testWidgets 里换尺寸时必须先拆掉整棵树：MaterialApp/Navigator 同型
/// 会被原地复用，旧对话框路由会留在栈上，后续 tap 会点到遮罩而不是按钮。
Future<void> _resetTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// 手机走「分组根页 → 模型与端点」；平板/桌面直接落在模型面板。
Future<void> _openModels(WidgetTester tester, Size size) async {
  if (find.byKey(const ValueKey('settings-mobile-root')).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const ValueKey('settings-m-models')));
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _openAgent(WidgetTester tester, Size size) async {
  if (_isPhoneLayout(size)) {
    await tester.tap(find.byKey(const ValueKey('settings-m-agent')));
    await tester.pump(const Duration(milliseconds: 300));
  } else {
    await tester.tap(find.byKey(const ValueKey('settings-nav-agent')));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

String _endpointKey(Size size) =>
    _isPhoneLayout(size) ? 'settings-m-endpoint' : 'settings-endpoint';

Future<MediaPipeService> _mediaPipeService(http.Client client, Directory dir) async =>
    MediaPipeService(
      rootOverride: dir,
      httpClient: client,
      platformSupport: const MediaPipePlatformSupport(supported: true, platform: 'test/arm64'),
    );

Directory _tempDir(String name) {
  final dir = Directory.systemTemp.createTempSync('nondesign-$name-');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return dir;
}

void main() {
  testWidgets('五个尺寸：端点在打开时即有值、只读并带锁图标', (tester) async {
    for (final size in [_phoneSmall, _phoneLandscape, _padPortrait, _padLandscape, _desktop]) {
      final store = _TestStore()
        ..ready = true
        ..registry = _registry()
        ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');

      await _openSettings(tester, store, size);
      await _openModels(tester, size);

      final field = tester.widget<TextField>(find.byKey(ValueKey(_endpointKey(size))));
      expect(field.readOnly, isTrue, reason: '$size：内置端点只读');
      expect(field.controller!.text, 'https://api.deepseek.com', reason: '$size：打开即有值');
      expect(find.byIcon(Icons.lock_outline), findsWidgets, reason: '$size：只读锁图标');
      expect(store.settings.baseUrl, 'https://api.deepseek.com');
      expect(store.saves, 0, reason: '$size：打开设置只回填内存，不落盘');
      expect(tester.takeException(), isNull);
      await _resetTree(tester);
    }
  });

  testWidgets('五个尺寸：四档布局判定（手机/Pad 竖/Pad 横/桌面各走各的）', (tester) async {
    for (final size in [_phoneSmall, _phoneLandscape]) {
      final store = _TestStore()
        ..ready = true
        ..registry = _registry()
        ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');
      await _openSettings(tester, store, size);
      expect(find.byKey(const ValueKey('settings-mobile-root')), findsOneWidget,
          reason: '$size：手机（含横屏）走分组根页');
      expect(find.byKey(const ValueKey('settings-topnav')), findsNothing);
      expect(find.byKey(const ValueKey('settings-rail')), findsNothing);
      await _resetTree(tester);
    }
    for (final size in [_padPortrait]) {
      final store = _TestStore()
        ..ready = true
        ..registry = _registry()
        ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');
      await _openSettings(tester, store, size);
      expect(find.byKey(const ValueKey('settings-topnav')), findsOneWidget,
          reason: '$size：Pad 竖屏全屏 + 顶部导航');
      expect(find.byKey(const ValueKey('settings-rail')), findsNothing);
      await _resetTree(tester);
    }
    for (final size in [_padLandscape, _desktop]) {
      final store = _TestStore()
        ..ready = true
        ..registry = _registry()
        ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');
      await _openSettings(tester, store, size);
      expect(find.byKey(const ValueKey('settings-rail')), findsOneWidget,
          reason: '$size：Pad 横屏/桌面走居中对话框 + 左导航');
      expect(find.byKey(const ValueKey('settings-topnav')), findsNothing);
      await _resetTree(tester);
    }
  });

  testWidgets('模型清单未加载时端点用内置兜底（不显示空态）', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = const ModelRegistry(providers: {}, fetchedAt: '')
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');

    await _openSettings(tester, store, _padLandscape);
    final field = tester.widget<TextField>(find.byKey(const ValueKey('settings-endpoint')));
    expect(field.controller!.text, 'https://api.deepseek.com',
        reason: '快照不可用时用内置端点表兜底');
    expect(store.settings.baseUrl, 'https://api.deepseek.com');
    expect(find.text('模型清单未加载'), findsOneWidget);
  });

  testWidgets('切服务商同步刷新端点与模型（手机选择面板）', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');

    await _openSettings(tester, store, _phoneSmall);
    await tester.tap(find.byKey(const ValueKey('settings-m-models')));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('settings-m-provider')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('settings-m-provider-openai')), findsOneWidget,
        reason: '服务商选择面板已打开');
    await tester.tap(find.byKey(const ValueKey('settings-m-provider-openai')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(store.settings.providerId, 'openai');
    expect(store.settings.modelId, 'gpt-5');
    expect(store.settings.baseUrl, 'https://api.openai.com/v1');
    final field = tester.widget<TextField>(find.byKey(const ValueKey('settings-m-endpoint')));
    expect(field.controller!.text, 'https://api.openai.com/v1');
    expect(store.saves, 1, reason: '切服务商是一次显式保存');
    expect(tester.takeException(), isNull);
  });

  for (final size in [_phoneSmall, _padPortrait, _padLandscape, _desktop]) {
    testWidgets('模型行在服务商下方 → 0.7 底部面板：搜索/更新/勾选 @ $size', (tester) async {
      final store = _TestStore()
        ..ready = true
        ..registry = _registry()
        ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');
      await _openSettings(tester, store, size);
      await _openModels(tester, size);

      final phone = _isPhoneLayout(size);
      // 模型行在服务商下方（同一列，顺序由布局保证）。
      final row = find.byKey(ValueKey(phone ? 'settings-m-model-row' : 'settings-model-row'));
      expect(row, findsOneWidget);
      final rowRect = tester.getRect(row);
      if (!phone) {
        final providerRect = tester.getRect(find.byKey(const ValueKey('settings-provider')));
        expect(rowRect.top, greaterThanOrEqualTo(providerRect.bottom));
      }

      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 320));

      expect(find.byKey(const ValueKey('model-picker-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('model-picker-handle')), findsOneWidget,
          reason: '底部面板有拖拽把手');
      final sheetHeight =
          tester.getSize(find.byKey(const ValueKey('model-picker-sheet'))).height;
      expect(sheetHeight, closeTo(size.height * 0.7, 2),
          reason: '$size：面板占 0.7 屏高');
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('model-picker-list')),
          matching: find.byType(SafeArea),
        ),
        findsWidgets,
        reason: '面板内容在安全区内',
      );

      // 搜索过滤。
      await tester.enterText(find.byKey(const ValueKey('model-picker-search')), 'reasoner');
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byKey(const ValueKey('model-picker-deepseek-reasoner')), findsOneWidget);
      expect(find.byKey(const ValueKey('model-picker-deepseek-chat')), findsNothing);

      // 更新清单按钮走 store.refreshModels（测试注入计数）。
      await tester.tap(find.byKey(const ValueKey('model-picker-refresh')));
      await tester.pump(const Duration(milliseconds: 120));
      expect(store.refreshes, 1);

      // 勾选 → 写 modelId 并关闭面板。
      await tester.tap(find.byKey(const ValueKey('model-picker-deepseek-reasoner')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(store.settings.modelId, 'deepseek-reasoner');
      expect(store.saves, 1);
      expect(find.byKey(const ValueKey('model-picker-sheet')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('合并运行方式卡：内置默认 + 本机运行提示 + 连接桌面展开地址', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');
    await _openSettings(tester, store, _desktop, platform: TargetPlatform.macOS);
    await _openAgent(tester, _desktop);

    expect(find.byKey(const ValueKey('settings-runtime-local')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-runtime-remote')), findsOneWidget);
    expect(store.settings.agentRuntime, agentRuntimeLocal, reason: '默认内置');
    expect(find.text('本机运行'), findsOneWidget, reason: '测试宿主没有引擎，如实显示本机运行');
    expect(find.byKey(const ValueKey('settings-remote-url')), findsNothing,
        reason: '内置时不展开地址');

    await tester.tap(find.byKey(const ValueKey('settings-runtime-remote')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(store.settings.agentRuntime, agentRuntimeServer);
    expect(store.saves, 1);
    expect(find.byKey(const ValueKey('settings-remote-url')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-remote-token')), findsOneWidget);
    final urlField = tester.widget<TextField>(find.byKey(const ValueKey('settings-remote-url')));
    expect(urlField.readOnly, isFalse, reason: '选连接桌面后地址可编辑');
  });

  testWidgets('桌面宿主卡：开启后显示实际地址与一次性连接码', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat')
      ..hostStatus = const RpcHostStatus(
        running: true,
        lanEnabled: false,
        token: 'tok-9',
        address: '127.0.0.1',
        port: 1234,
      );
    await _openSettings(tester, store, _desktop, platform: TargetPlatform.macOS);
    await _openAgent(tester, _desktop);

    expect(find.text('局域网远程'), findsOneWidget);
    expect(find.text('http://127.0.0.1:1234'), findsOneWidget);
    expect(find.text('tok-9'), findsOneWidget);
    expect(find.text('本机地址（手机需开启局域网访问）'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-desktop-host-switch')), findsOneWidget);
  });

  testWidgets('桌面智能体页：上下文说明用用户语言，不出现工程内部代号', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');
    await _openSettings(tester, store, _desktop, platform: TargetPlatform.macOS);
    await _openAgent(tester, _desktop);

    for (final term in ['前缀缓存分层', 'PROJECT MAP', 'L0', 'L1', 'L2', 'L3', '会话键', '确定性上下文治理']) {
      expect(find.text(term), findsNothing, reason: '$term 不应作为用户文案');
    }
    expect(find.text('上下文与缓存'), findsOneWidget);
    expect(find.text('上下文管理'), findsOneWidget);
    expect(find.text('项目位置'), findsOneWidget);
  });

  testWidgets('「主面」开关只在聊天优先壳出现（桌面隐藏 / iPad 竖屏保留）', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');
    await _openSettings(tester, store, _desktop, platform: TargetPlatform.macOS);
    await tester.tap(find.byKey(const ValueKey('settings-nav-appearance')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('主面'), findsNothing, reason: '桌面工作区壳的主面由壳裁决，不显示无效开关');
    expect(find.text('主题'), findsOneWidget);

    await _resetTree(tester);
    await _openSettings(tester, store, _padPortrait, platform: TargetPlatform.iOS);
    await tester.tap(find.byKey(const ValueKey('settings-nav-appearance')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('主面'), findsOneWidget, reason: 'iPad 竖屏是聊天优先壳，开关有效');
  });

  testWidgets('检测连接：检测中 → 已连接（地址与连接码都带上）', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');
    await _openSettings(tester, store, _desktop, platform: TargetPlatform.macOS);
    await _openAgent(tester, _desktop);
    await tester.tap(find.byKey(const ValueKey('settings-runtime-remote')));
    await tester.pump(const Duration(milliseconds: 120));

    await tester.enterText(find.byKey(const ValueKey('settings-remote-url')), '192.168.1.5:8799');
    await tester.enterText(find.byKey(const ValueKey('settings-remote-token')), 'tok-1');

    store.nextStatus = const RemoteDesktopStatus(
      configured: true,
      reachable: true,
      authorized: true,
      compatible: true,
      message: '已连接桌面',
    );
    store.probeGate = Completer<void>();

    await tester.tap(find.byKey(const ValueKey('settings-remote-test')));
    await tester.pump();
    expect(find.text('正在检测…'), findsOneWidget, reason: '检测中内联状态');

    store.probeGate!.complete();
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('已连接'), findsWidgets, reason: '成功内联“已连接”');
    expect(store.calls.first, 'test:192.168.1.5:8799:tok-1');
    expect(store.calls.last, 'apply:192.168.1.5:8799:tok-1',
        reason: '检测通过即接线到桌面端');
    expect(store.toasts.history.first.title, '已连接桌面');
    expect(tester.takeException(), isNull);

    // 断开入口：清掉地址/连接码并回到内置，下次冷启动不再探测旧桌面。
    await tester.tap(find.byKey(const ValueKey('settings-remote-disconnect')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(store.settings.serverUrl, isEmpty);
    expect(store.serverToken, isEmpty);
    expect(store.settings.agentRuntime, agentRuntimeLocal);
  });

  testWidgets('连接码留空且没有已保存的码：提示先填写，不发出必然 401 的探测', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');
    await _openSettings(tester, store, _desktop, platform: TargetPlatform.macOS);
    await _openAgent(tester, _desktop);
    await tester.tap(find.byKey(const ValueKey('settings-runtime-remote')));
    await tester.pump(const Duration(milliseconds: 120));

    await tester.enterText(find.byKey(const ValueKey('settings-remote-url')), '10.0.0.9:8799');
    await tester.tap(find.byKey(const ValueKey('settings-remote-test')));
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('先填写连接码（桌面端显示的连接码）'), findsOneWidget);
    expect(store.remoteTests, 0, reason: '空码不发探测请求');
  });

  testWidgets('检测连接失败：内联显示失败原因，不静默回落', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');
    await _openSettings(tester, store, _desktop, platform: TargetPlatform.macOS);
    await _openAgent(tester, _desktop);
    await tester.tap(find.byKey(const ValueKey('settings-runtime-remote')));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.enterText(find.byKey(const ValueKey('settings-remote-url')), '10.0.0.9:8799');
    // 连接码是必填项（宿主对 health/rpc 都要求 Bearer）；没有码时界面应
    // 先提示填写，而不是发一个必然 401 的探测。
    await tester.enterText(find.byKey(const ValueKey('settings-remote-token')), 'tok-1');

    store.nextStatus = const RemoteDesktopStatus(
      configured: true,
      reachable: false,
      authorized: true,
      compatible: false,
      message: '连接桌面没有成功，请检查地址与桌面端是否已开启连接',
      reason: 'remote_unreachable',
      technicalDetail: 'SocketException: Connection refused',
    );

    await tester.tap(find.byKey(const ValueKey('settings-remote-test')));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('连接桌面没有成功，请检查地址与桌面端是否已开启连接'), findsOneWidget);
    expect(find.textContaining('SocketException'), findsNothing,
        reason: '原始错误不进界面');
    expect(store.calls.any((c) => c.startsWith('apply:')), isFalse,
        reason: '检测失败不接线');
    expect(find.text('已连接'), findsNothing);
  });

  testWidgets('手机：运行方式卡同样二选一并可展开地址', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');
    await _openSettings(tester, store, _phoneSmall);
    await _openAgent(tester, _phoneSmall);

    expect(find.byKey(const ValueKey('settings-m-runtime-local')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-m-runtime-remote')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-m-desktop-host')), findsNothing,
        reason: '手机端不显示「手机连接这台电脑」宿主卡');

    await tester.tap(find.byKey(const ValueKey('settings-m-runtime-remote')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(store.settings.agentRuntime, agentRuntimeServer);
    expect(find.byKey(const ValueKey('settings-m-remote-url')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-m-remote-token')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-m-remote-test')), findsOneWidget);
  });

  testWidgets('旧自定义端点：自动落入自定义态，可恢复内置端点（桌面）', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');
    store.settings.baseUrl = 'https://proxy.example.com/v1';

    await _openSettings(tester, store, _padLandscape);
    // 旧自定义端点自动派生为自定义态：开关打开、端点可编辑。
    final customSwitch = find.byKey(const ValueKey('settings-endpoint-custom'));
    expect(customSwitch, findsOneWidget);
    expect(
      tester.widget<Switch>(customSwitch).value,
      isTrue,
    );

    await tester.tap(find.byTooltip('恢复内置端点'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(store.settings.baseUrl, 'https://api.deepseek.com');
    expect(
      tester.widget<Switch>(customSwitch).value,
      isFalse,
      reason: '恢复内置后回到只读内置态',
    );
    expect(store.saves, 1);
  });

  testWidgets('自定义服务商（桌面）：下拉里有「自定义」选项，选中后端点/模型 ID 全自由填', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');

    await _openSettings(tester, store, _padLandscape);
    // 下拉里出现显式「自定义」选项。
    await tester.tap(find.byKey(const ValueKey('settings-provider')));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.tap(find.text('自定义').last);
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(store.settings.providerId, 'custom');

    // 端点立刻可编辑（无锁、无开关）；开关行已隐藏。
    final endpoint = find.byKey(const ValueKey('settings-endpoint'));
    expect(endpoint, findsOneWidget);
    expect(tester.widget<TextField>(endpoint).readOnly, isFalse,
        reason: '自定义服务商端点天然可编辑');
    expect(find.byKey(const ValueKey('settings-endpoint-custom')), findsNothing,
        reason: '自定义服务商不需要开关');
    expect(find.text('自定义服务商：端点与模型 ID 均自由填写'), findsOneWidget);

    // 模型行变成自由输入框：填清单外模型 ID，落盘生效。
    final modelField = find.byKey(const ValueKey('settings-model-custom'));
    expect(modelField, findsOneWidget);
    await tester.enterText(modelField, 'my-gateway-model');
    await tester.pump(const Duration(milliseconds: 120));
    expect(store.settings.modelId, 'my-gateway-model');
    expect(store.saves, greaterThanOrEqualTo(1),
        reason: '切服务商已落盘一次');
  });

  testWidgets('自定义服务商（手机）：picker 里有「自定义」，选中后模型 ID 直接填', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');

    await _openSettings(tester, store, _phoneSmall);
    await _openModels(tester, _phoneSmall);
    await tester.tap(find.byKey(const ValueKey('settings-m-provider')));
    await tester.pump(const Duration(milliseconds: 320));
    // 「自定义」是 picker 末项：小屏 sheet 里在视口外，先滚进可见区再点。
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-m-provider-custom')),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('settings-m-provider-custom')));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pump();

    expect(store.settings.providerId, 'custom');

    // 端点可编辑、开关行隐藏。
    expect(tester.widget<TextField>(find.byKey(const ValueKey('settings-m-endpoint')))
        .readOnly, isFalse);
    expect(find.byKey(const ValueKey('settings-m-endpoint-custom')), findsNothing);

    // 模型 ID 直接输入并落盘。
    final modelField = find.byKey(const ValueKey('settings-m-model-custom'));
    expect(modelField, findsOneWidget);
    await tester.enterText(modelField, 'gateway-model-x');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 120));
    expect(store.settings.modelId, 'gateway-model-x');
    expect(store.saves, greaterThanOrEqualTo(1));
  });

  testWidgets('自定义端点开关：打开后端点可编辑，关闭恢复内置（手机）', (tester) async {
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');

    await _openSettings(tester, store, _phoneSmall);
    await _openModels(tester, _phoneSmall);
    final customSwitch = find.byKey(const ValueKey('settings-m-endpoint-custom'));
    await tester.scrollUntilVisible(
      customSwitch,
      240,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('settings-m-detail-models')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump(const Duration(milliseconds: 120));

    // 默认只读内置态 → 打开开关进入自定义态 → 关闭恢复内置。
    expect(tester.widget<Switch>(customSwitch).value, isFalse);
    await tester.tap(customSwitch);
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.widget<Switch>(customSwitch).value, isTrue);
    expect(store.saves, greaterThanOrEqualTo(1));

    await tester.tap(find.byTooltip('恢复内置端点'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(store.settings.baseUrl, 'https://api.deepseek.com');
    expect(tester.takeException(), isNull);
  });

  testWidgets('本地语义模型卡：可见、约 388 MB、打开设置不自动下载', (tester) async {
    var requests = 0;
    final dir = _tempDir('settings-mediapipe');
    final service = await _mediaPipeService(MockClient((req) async {
      requests++;
      return http.Response('unexpected', 500);
    }), dir);
    final store = _TestStore()
      ..ready = true
      ..registry = _registry()
      ..settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-chat');

    await _openSettings(tester, store, _desktop, mediaPipe: service);
    await tester.ensureVisible(find.byKey(const ValueKey('mediapipe-model-card')));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey('mediapipe-model-card')), findsOneWidget);
    expect(find.text('本地语义模型'), findsOneWidget);
    expect(find.textContaining('约 388 MB'), findsOneWidget);
    expect(find.byKey(const ValueKey('mediapipe-download')), findsOneWidget);
    expect(requests, 0, reason: '打开设置绝不自动下载模型');
    expect(tester.takeException(), isNull);
  });
}
