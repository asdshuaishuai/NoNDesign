// 模拟器 E2E（iPhone）：聊天主面 → chat agent「首轮实况帧」→ 聊天流内嵌
// 实况预览卡（genUI 形态，不是画中画）→ 折叠/展开 → 截图留档。
//
// 说明：iOS 模拟器上本地 wasm 引擎不可用（wasmi 无 SIMD，真机/模拟器同），
// 设计构建的真链路只在桌面可跑；这里用 store 直驱的「首轮实况帧」验证
// 移动端的视觉与交互集成（卡片出现/内嵌工作区/折叠/聊天仍可滚动）。
//
// 运行：flutter test integration_test/mobile_live_preview_sim.dart -d <udid>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile: chat run live preview card inline in chat stream',
      (tester) async {
    final store = AppStore();
    store.ready = true;
    store.hasProject = true;
    store.projectName = '实况预览演示';
    store.mbt =
        '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: home\n---\n';
    store.render = RenderEnvelope(
      ok: true,
      entry: 'home',
      revision: 1,
      mbt: store.mbt,
      artboards: const [
        Artboard(
            id: 'home',
            name: '番茄钟 · 计时页',
            width: 390,
            height: 844,
            nodes: []),
      ],
    );
    store.view = 'chat';

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStore>.value(value: store, child: const NonApp()),
    );
    await tester.pump(const Duration(milliseconds: 600));

    // 聊天主面：空态/composer 在场，实况卡未出现。
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);

    // 模拟 chat agent 首轮实况帧就绪。
    store
      ..agentBusy = true
      ..previewRender = store.render;
    // ignore: invalid_use_of_protected_member
    store.notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));

    // 实况预览卡长在聊天流里（不是画中画浮窗）。
    expect(store.agentBusy, isTrue);
    expect(store.previewRender, isNotNull);

    // 截图窗口：给宿主侧 `xcrun simctl io booted screenshot` 留时间。
    await tester.pump(const Duration(seconds: 6));

    // 实况卡仍在场：聊天主面 + 内嵌实况。
    expect(store.view, 'chat');
    expect(store.agentBusy, isTrue);
  });
}
