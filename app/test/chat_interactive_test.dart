// 聊天流交互面的回归（补充 chat_stream_test.dart 的 store 全链之外的
// widget 行为）：
// - 建议 chips 只挂在**最后一条**助手消息上；点一下 = 发一条用户消息；
// - 围栏代码块渲染出带复制按钮的代码块；
// - 生成中 composer 显示停止按钮、不显示发送；
// - 产物卡右侧的显式打开按钮（文案按产物种类）沿用同一打开动作；
// - 失败进度卡给「重试」按钮，点击走 _sendText 的同一发送出口；
// - 320 宽（桌面右栏 railMode）下全部卡片渲染不溢出。
//
// 发送侧用 _RecordingSendStore 记录 sendChat 并落一条用户消息，避免在
// widget 测试里造网络/模型配置；真实发送全链由 chat_stream_test.dart 的
// store 级用例覆盖。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/chat_stream.dart';

/// 只记录发送的 store：聊天流的三个发送出口（输入框 / 建议 chip / 重试）
/// 最终都调 store.sendChat，这里记录文案并落一条用户消息——断言「点了确实
/// 发出去、发的就是这句话」，不触发真实模型运行。
class _RecordingSendStore extends AppStore {
  _RecordingSendStore() : super(toasts: ToastService(autoDismiss: false));

  final List<String> sent = [];

  @override
  Future<bool> sendChat(String text) async {
    sent.add(text);
    appendChat(ChatMessage.user(text));
    return true;
  }
}

AppStore _store() {
  // toasts: autoDismiss=false —— 默认服务带 5s 计时器，测试结束会被判成
  // 「Timer is still pending」（chat_stream_test 同款处理）。
  final store = AppStore(toasts: ToastService(autoDismiss: false));
  store.ready = true;
  store.view = 'chat';
  store.hasProject = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  return store;
}

_RecordingSendStore _recordingStore() {
  final store = _RecordingSendStore();
  store.ready = true;
  store.view = 'chat';
  store.hasProject = true;
  store.settings = AppSettings(providerId: 'deepseek', modelId: 'deepseek-v4.1-flash');
  return store;
}

Widget _host(AppStore store, {bool railMode = false}) =>
    ChangeNotifierProvider<AppStore>.value(
      value: store,
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: ChatStreamView(railMode: railMode),
      ),
    );

Future<void> _pumpChat(
  WidgetTester tester,
  AppStore store, {
  Size size = const Size(1200, 900),
  bool railMode = false,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_host(store, railMode: railMode));
  await tester.pump(const Duration(milliseconds: 80));
}

/// 建议 chip（同一条消息上 4 个，key 相同）。
final Finder _chip = find.byKey(const ValueKey('chat-suggestion-chip'));

void main() {
  group('建议 chips', () {
    testWidgets('最后一条助手消息显示建议 chips', (tester) async {
      final store = _store()
        ..appendChat(ChatMessage.user('做一个记账应用'))
        ..appendChat(ChatMessage.assistant('先定信息架构，再逐屏生成可交互原型。'));
      await _pumpChat(tester, store);

      expect(_chip, findsNWidgets(4));
      expect(find.text('继续完善细节'), findsOneWidget);
      expect(find.text('换一版布局看看'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('历史助手消息不显示建议 chips', (tester) async {
      final early = ChatMessage(
        kind: chatKindAssistant,
        text: '第一轮：先定信息架构。',
        ts: DateTime(2020, 1, 1),
      );
      final last = ChatMessage(
        kind: chatKindAssistant,
        text: '第二轮：原型已更新。',
        ts: DateTime(2020, 1, 2),
      );
      final store = _store()
        ..appendChat(ChatMessage.user('做个工具'))
        ..appendChat(early)
        ..appendChat(last);
      await _pumpChat(tester, store);

      expect(_chip, findsNWidgets(4), reason: '整屏只出现一组建议');
      expect(
        find.descendant(
          of: find.byKey(ValueKey('chat-assistant-${last.ts.microsecondsSinceEpoch}')),
          matching: _chip,
        ),
        findsNWidgets(4),
        reason: '建议挂在最后一条助手消息上',
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('chat-assistant-${early.ts.microsecondsSinceEpoch}')),
          matching: _chip,
        ),
        findsNothing,
        reason: '历史助手消息保持干净',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('点建议 chip → store 收到 sendChat，用户消息入列', (tester) async {
      final store = _recordingStore()
        ..appendChat(ChatMessage.user('做一个记账应用'))
        ..appendChat(ChatMessage.assistant('原型已生成，可以继续完善。'));
      await _pumpChat(tester, store);

      await tester.tap(find.text('补上空状态和错误态'));
      await tester.pump(const Duration(milliseconds: 60));

      expect(store.sent, ['补上空状态和错误态'],
          reason: 'chip 点击走与输入框同一条 store.sendChat 出口');
      expect(store.chatMessages.last.kind, chatKindUser);
      expect(store.chatMessages.last.text, '补上空状态和错误态');
      expect(tester.takeException(), isNull);
    });
  });

  group('围栏代码块', () {
    testWidgets('渲染出 chat-code-block 且带复制按钮', (tester) async {
      final store = _store()
        ..appendChat(ChatMessage.user('给个示例'))
        ..appendChat(ChatMessage.assistant(
            '可以这样写：\n\n```dart\nvoid main() {\n  runApp(const App());\n}\n```\n\n以上。'));
      await _pumpChat(tester, store);

      expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('chat-code-block-')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-copy-code')), findsOneWidget);
      expect(find.text('DART'), findsOneWidget, reason: '语言标签大写显示');
      expect(find.textContaining('void main()'), findsOneWidget,
          reason: '围栏内容原样渲染');
      expect(tester.takeException(), isNull);
    });
  });

  group('生成中 composer', () {
    testWidgets('agentBusy 时显示停止按钮、不显示发送', (tester) async {
      final store = _store()
        ..appendChat(ChatMessage.user('做个仪表盘'))
        ..appendChat(ChatMessage.assistant('好的，开始生成。'));
      store.agentBusy = true;
      await _pumpChat(tester, store);

      expect(find.byKey(const ValueKey('chat-stop-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-send')), findsNothing);
      expect(_chip, findsNothing, reason: '生成中不给新建议，避免并发发送');
      expect(tester.takeException(), isNull);
    });
  });

  group('产物卡显式打开按钮', () {
    testWidgets('文案按产物种类区分，点击沿用同一打开动作', (tester) async {
      final store = _store()
        ..appendChat(ChatMessage.artifact(kind: artifactPrototype, title: '记账'))
        ..appendChat(ChatMessage.artifact(kind: artifactHotapp, title: '发票计算器'))
        ..appendChat(ChatMessage.artifact(kind: artifactVideo, title: '开场动画'))
        ..appendChat(ChatMessage.artifact(kind: artifactThree, title: '小场景'))
        ..appendChat(ChatMessage.artifact(kind: 'portfolio', title: '作品集'));
      await _pumpChat(tester, store);

      expect(find.byKey(const ValueKey('chat-artifact-open')), findsNWidgets(5));
      expect(find.text('打开设计'), findsOneWidget);
      expect(find.text('打开应用'), findsOneWidget);
      expect(find.text('看视频'), findsOneWidget);
      expect(find.text('看 3D'), findsOneWidget);
      expect(find.text('打开作品集'), findsOneWidget);

      await tester.tap(find.text('看视频'));
      await tester.pump(const Duration(milliseconds: 40));
      expect(store.view, 'plugin:video');

      await tester.tap(find.text('打开应用'));
      await tester.pump(const Duration(milliseconds: 40));
      expect(store.view, 'plugin:hotapp');
      expect(store.settings.hotappApp, '发票计算器', reason: '热应用落当前应用名');

      await tester.tap(find.text('打开设计'));
      await tester.pump(const Duration(milliseconds: 40));
      expect(store.view, 'design', reason: '原型 → 工作区（无宿主时的回退路径）');

      await tester.tap(find.text('打开作品集'));
      await tester.pump(const Duration(milliseconds: 40));
      expect(store.view, 'portfolio');
      expect(tester.takeException(), isNull);
    });

    testWidgets('3D 产物卡按钮打开 3D 工作台', (tester) async {
      final store = _store()
        ..appendChat(ChatMessage.artifact(kind: artifactThree, title: '小场景'));
      await _pumpChat(tester, store);

      await tester.tap(find.text('看 3D'));
      await tester.pump(const Duration(milliseconds: 40));
      expect(store.view, 'plugin:three');
      expect(tester.takeException(), isNull);
    });
  });

  group('失败进度卡重试', () {
    testWidgets('ok=false 且有人话原因 → 重试按钮发送「重试上一步」', (tester) async {
      final failed = ChatMessage.progress('按指令更新原型')
        ..running = false
        ..ok = false
        ..detail = '引擎没有响应，这一步没有生效';
      final done = ChatMessage.progress('原型已生成')..running = false;
      final noDetail = ChatMessage.progress('规划页面')
        ..running = false
        ..ok = false;
      final store = _recordingStore()
        ..appendChat(ChatMessage.user('做个工具'))
        ..appendChat(failed)
        ..appendChat(done)
        ..appendChat(noDetail);
      await _pumpChat(tester, store);

      expect(find.textContaining('引擎没有响应'), findsOneWidget,
          reason: '原有错误文案保留');
      expect(find.byKey(const ValueKey('chat-retry-step')), findsOneWidget,
          reason: '只有 ok=false 且有人话原因的那张卡给按钮');
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('chat-retry-step')));
      await tester.pump(const Duration(milliseconds: 60));

      expect(store.sent, ['重试上一步'],
          reason: '重试走与输入框/chip 同一条 _sendText → store.sendChat 出口');
      expect(store.chatMessages.last.kind, chatKindUser);
      expect(store.chatMessages.last.text, '重试上一步');
      expect(tester.takeException(), isNull);
    });
  });

  group('窄栏（320 宽）', () {
    testWidgets('railMode 下全部卡片渲染不溢出', (tester) async {
      final failed = ChatMessage.progress('按指令更新原型')
        ..running = false
        ..ok = false
        ..detail = '引擎没有响应，这一步没有生效';
      failed.steps.add(ChatStep(label: 'design_op', ms: 42));
      failed.steps.add(ChatStep(label: 'design_op', ok: false, detail: '引擎超时'));

      final store = _store()
        ..appendChat(ChatMessage.user('做一个超长的记账小应用，移动端优先，带统计与导出'))
        ..appendChat(ChatMessage.assistant(
            '先给一版代码：\n\n```dart\nvoid main() {\n  runApp(const App());\n}\n```\n\n然后生成原型。'))
        ..appendChat(failed)
        ..appendChat(ChatMessage.artifact(
            kind: artifactPrototype, title: '记账', detail: '可交互原型已生成'))
        ..appendChat(ChatMessage.artifact(kind: artifactVideo, title: '开场动画'))
        ..appendChat(ChatMessage.assistant('还需要我继续完善哪一块？'));
      await _pumpChat(tester, store, size: const Size(320, 800), railMode: true);

      expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-artifact-open')), findsNWidgets(2));
      expect(find.byKey(const ValueKey('chat-retry-step')), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('chat-code-block-')), findsOneWidget);
      expect(_chip, findsNWidgets(4));
      expect(tester.takeException(), isNull, reason: '320 窄栏不得 RenderFlex 溢出');
    });
  });
}
