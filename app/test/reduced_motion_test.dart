// 细节优化A：减少动效（prefers-reduced-motion，WCAG 2.3.3）。
//
// 锚定两件事：
//  1. `context.nonMotion(NonMotion.x)`（core/theme.dart 的 NonMotionX）在
//     `MediaQueryData.disableAnimations` 为 true 时归零、false 时原样透传——
//     只夹取时长，不改终态；
//  2. 受影响的真实组件 `ToastHost` 的入场动效（`ToastEntrance` 的
//     `TweenAnimationBuilder`）：减少动效下首帧即终态、`transientCallbackCount`
//     为 0（不再有持续动画帧）；正常动效下先有动画帧，播完后到达同一个终态。
//
// 说明：任务名单里其余五个文件（chat_stream / video_animation_surface /
// video_clip_surface / workspace_progress / a2ui_card）经逐个清点没有任何
// `Animated*` / `TweenAnimationBuilder` / `AnimationController` 动效节点，
// 因此本文件只对唯一有动效的 ToastHost 做行为锚定（不伪造断言）。

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/toast_host.dart';

/// 在 home 子树里覆盖 `disableAnimations`，其它 MediaQuery 字段保持不变。
Widget _harness({required bool disableAnimations, required Widget child}) {
  return MaterialApp(
    theme: AppTheme.build(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: disableAnimations),
        child: child,
      ),
    ),
  );
}

/// 挂一个独立的 ToastHost（`autoDismiss:false`：测试结束不遗留计时器）。
Future<ToastService> _mountHost(
  WidgetTester tester, {
  required bool disableAnimations,
}) async {
  final svc = ToastService(autoDismiss: false);
  await tester.pumpWidget(
    _harness(
      disableAnimations: disableAnimations,
      child: ToastHost(service: svc, child: const SizedBox.expand()),
    ),
  );
  return svc;
}

/// 入场胶囊当前的不透明度（= TweenAnimationBuilder 的动画值）。
double _entranceOpacity(WidgetTester tester) =>
    tester.widgetList<Opacity>(find.byType(Opacity)).first.opacity;

/// 入场动画实际使用的时长（`context.nonMotion` 夹取后的值）。
Duration _entranceDuration(WidgetTester tester) => tester
    .widgetList<TweenAnimationBuilder<double>>(
      find.byType(TweenAnimationBuilder<double>),
    )
    .first
    .duration;

void main() {
  group('NonMotionX.nonMotion', () {
    testWidgets('disableAnimations=true 归零，false 原样透传（只改时长）', (tester) async {
      Future<Duration> probe(bool disableAnimations, Duration motion) async {
        late Duration seen;
        await tester.pumpWidget(
          _harness(
            disableAnimations: disableAnimations,
            child: Builder(
              builder: (context) {
                seen = context.nonMotion(motion);
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        return seen;
      }

      // 关闭动画：三档令牌都归零。
      expect(await probe(true, NonMotion.fast), Duration.zero);
      expect(await probe(true, NonMotion.base), Duration.zero);
      expect(await probe(true, NonMotion.slow), Duration.zero);
      // 正常动画：原样透传，不被改写。
      expect(await probe(false, NonMotion.fast), NonMotion.fast);
      expect(await probe(false, NonMotion.base), NonMotion.base);
      expect(await probe(false, NonMotion.slow), NonMotion.slow);
    });
  });

  group('ToastHost 入场动效', () {
    testWidgets('减少动效：首帧直达终态，且不再有持续动画帧', (tester) async {
      final svc = await _mountHost(tester, disableAnimations: true);
      expect(tester.binding.transientCallbackCount, 0);

      svc.info('已保存');
      await tester.pump();

      // 时长经 context.nonMotion 夹取为 0（= Animated* duration 为 Duration.zero）。
      expect(_entranceDuration(tester), Duration.zero);
      // 终态：完全不透明；零时长入场在首帧就完成，不依赖后续帧。
      expect(_entranceOpacity(tester), 1.0);
      // 没有 ticker 在跑：减少动效时不再产生持续动画帧。
      expect(tester.binding.transientCallbackCount, 0);

      // 再推进若干帧也必须保持 0，终态不回退。
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.binding.transientCallbackCount, 0);
      expect(_entranceOpacity(tester), 1.0);
    });

    testWidgets('正常动效：先有动画帧，播完到达同一终态', (tester) async {
      final svc = await _mountHost(tester, disableAnimations: false);
      expect(tester.binding.transientCallbackCount, 0);

      svc.info('已保存');
      await tester.pump();

      // 关掉「减少动效」时透传 NonMotion.base，入场按正常节奏播。
      expect(_entranceDuration(tester), NonMotion.base);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      expect(_entranceOpacity(tester), lessThan(1.0));

      // Ticker 在首个 tick 帧才记起始时刻，所以先推一帧让时间轴起跑，
      // 再播满 NonMotion.base；动画结束后不再有动画帧，终态与减少动效时一致。
      await tester.pump(NonMotion.base);
      await tester.pump(NonMotion.base);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      expect(_entranceOpacity(tester), 1.0);
    });
  });
}
