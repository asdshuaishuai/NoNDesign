// 设置弹窗「保存步数」的 mounted 守卫回归（审查 ui-3）：_saveSteps 在
// `await store.saveSettings()`（双写 SharedPreferences + settings.json）之后
// 直接 setState——保存写盘在飞期间关闭弹窗即 setState-after-dispose。
// 用注入的慢速 saveSettings store 复现窗口期；同文件同型路径（:66 延迟
// 回调 / :902 ACP 选项）都守了 mounted，唯独这里漏。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/settings_dialog.dart';

class _DelayedSaveStore extends AppStore {
  int saves = 0;
  @override
  Future<void> saveSettings() async {
    saves++;
    // 双写盘的窗口期（磁盘慢时几十毫秒）：测试里拉长到超过弹窗退场动画
    // （NonMotion.slow 240ms）——保存完成时弹窗 State 已确定 dispose，
    // 种族窗口稳定复现。不落真盘（不写 ~/.nondesign/settings.json）。
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

void main() {
  testWidgets('saveSteps：写盘在飞期间关闭弹窗不触发 setState-after-dispose', (tester) async {
    // 「步数+保存」区在 store.model == null（空 registry）时整块不渲染——
    // 注入最小注册表让保存按钮在场。
    final store = _DelayedSaveStore()
      ..ready = true
      ..registry = const ModelRegistry(
        providers: {
          'deepseek': {
            'name': 'DeepSeek',
            'api': 'https://api.deepseek.com',
            'protocol': 'openai',
            'models': {
              'deepseek-chat': {'name': 'DeepSeek Chat', 'tool_call': true},
            },
          },
        },
        fetchedAt: 'test',
      );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStore>.value(
        value: store,
        child: MaterialApp(
          theme: AppTheme.build(dark: true),
          home: Scaffold(
            body: Center(
              // Builder：给出 Navigator 内的 context（showNonDialog 需要）。
              child: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () => showSettingsDialog(ctx),
                  child: const Text('open-settings'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-settings'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);

    // 「步数+保存」在默认「模型与端点」tab 的模型卡内（store.model 非空时渲染）。
    await tester.ensureVisible(find.text('保存'));

    await tester.tap(find.text('保存'));
    // 保存仍在飞（500ms 延迟）时关闭弹窗：退场动画 240ms 先走完，
    // 弹窗 State 已 dispose，保存完成时续体回到死 State。
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    // 越过 500ms：saveSettings 完成 → mounted 守卫挡下 setState。
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(store.saves, 1);
  });
}
