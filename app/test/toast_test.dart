// 批次 04：Toast 服务与通知中心。
//
// 锚定用户验收标准 H 的四件事：
//  1. 顶部左侧堆叠 + 圆角胶囊 + 毛玻璃（低端 Android 可关）；
//  2. 1–5s 分级时长（info 2 / success 2.5 / warn 4 / error 5），错误不早退；
//  3. 通知历史（100 条、时间与级别不丢、可回看可重放）；
//  4. 连续相同只保留一条并刷新计时。
//
// 另外守住两条结构性约束：
//  * 通知链路不依赖 ScaffoldMessenger / SnackBar（散点弹条统一改走本服务）；
//  * 新增文案不触碰 docs/copy-glossary.md 的禁用词（复用 copy_guard 的扫描器）。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/common.dart' show formatTime;
import 'package:nondesign/widgets/notification_center.dart';
import 'package:nondesign/widgets/toast_host.dart';

import 'copy_guard_test.dart' show findCopyViolations;

Directory _appDir() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('cannot locate app/ from ${Directory.current.path}');
}

const List<String> _toastFiles = [
  'lib/core/toast_service.dart',
  'lib/widgets/toast_host.dart',
  'lib/widgets/notification_center.dart',
];

/// 去掉行注释后再扫描：文件头注释里点名「被本服务取代的旧机制」是为了
/// 说明为什么禁止它，不算依赖。只检查可执行代码。
String _codeOnly(String source) => source
    .split('\n')
    .map((line) {
      final at = line.indexOf('//');
      return at < 0 ? line : line.substring(0, at);
    })
    .join('\n');

/// 挂一个独立宿主（不触碰全局单例）。
Future<ToastService> _mountHost(WidgetTester tester, {bool? blur}) async {
  final svc = ToastService(blurEnabled: blur);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(),
      home: ToastHost(service: svc, child: const SizedBox.expand()),
    ),
  );
  return svc;
}

void main() {
  // -------------------------------------------------------------------------
  // 时长分级
  // -------------------------------------------------------------------------

  group('分级时长', () {
    test('info 2s / success 2.5s / warn 4s / error 5s', () {
      expect(ToastLevel.info.duration, const Duration(seconds: 2));
      expect(ToastLevel.success.duration, const Duration(milliseconds: 2500));
      expect(ToastLevel.warn.duration, const Duration(seconds: 4));
      expect(ToastLevel.error.duration, const Duration(seconds: 5));
    });

    test('全部级别都落在 1–5s', () {
      for (final level in ToastLevel.values) {
        expect(
          level.duration.inMilliseconds,
          inInclusiveRange(ToastVisuals.minDuration.inMilliseconds,
              ToastVisuals.maxDuration.inMilliseconds),
          reason: '$level',
        );
      }
    });

    test('显式时长钳在 1–5s', () {
      expect(ToastService.resolveDuration(ToastLevel.info, const Duration(seconds: 9)),
          const Duration(seconds: 5));
      expect(ToastService.resolveDuration(ToastLevel.error, const Duration(milliseconds: 50)),
          const Duration(seconds: 1));
      expect(ToastService.resolveDuration(ToastLevel.warn, null), const Duration(seconds: 4));
    });
  });

  // -------------------------------------------------------------------------
  // 服务行为（无计时器路径）
  // -------------------------------------------------------------------------

  group('服务行为', () {
    test('连续相同只保留一条并刷新计时（repeatCount 计数）', () {
      final svc = ToastService(autoDismiss: false);
      final a = svc.error('保存失败', '磁盘空间不足');
      final b = svc.error('保存失败', '磁盘空间不足');
      final c = svc.error('保存失败', '磁盘空间不足');
      expect(a, isNotNull);
      expect(b!.id, a!.id);
      expect(c!.id, a.id);
      expect(c.repeatCount, 3);
      expect(c.createdAt.isBefore(a.createdAt), isFalse);
      expect(svc.visible.length, 1);
      expect(svc.history.length, 1);
      svc.dispose();
    });

    test('级别或内容不同则分开成两条', () {
      final svc = ToastService(autoDismiss: false);
      svc.info('已保存');
      svc.success('已保存');
      svc.info('已保存', '另一个项目');
      expect(svc.visible.length, 3);
      expect(svc.history.length, 3);
      svc.dispose();
    });

    test('历史封顶 100 条，最新在前', () {
      final svc = ToastService(autoDismiss: false);
      for (var i = 1; i <= 105; i++) {
        svc.info('事件 $i');
      }
      expect(svc.history.length, 100);
      expect(svc.history.first.title, '事件 105');
      expect(svc.history.last.title, '事件 6');
      // 同时显示的条数另有上限，其余留在历史里。
      expect(svc.visible.length, lessThanOrEqualTo(svc.maxVisible));
      svc.dispose();
    });

    test('历史保留时间与级别（可回看）', () {
      final before = DateTime.now();
      final svc = ToastService(autoDismiss: false);
      final item = svc.warn('导出较慢', '仍在处理');
      final entry = svc.history.first;
      expect(entry.level, ToastLevel.warn);
      expect(entry.title, '导出较慢');
      expect(entry.detail, '仍在处理');
      expect(entry.createdAt.isBefore(before), isFalse);
      expect(item!.level, ToastLevel.warn);
      svc.dispose();
    });

    test('重放把历史条目重新显示出来', () {
      final svc = ToastService(autoDismiss: false);
      final item = svc.error('导出失败');
      svc.dismiss(item!.id);
      expect(svc.visible, isEmpty);
      expect(svc.history.length, 1);

      svc.replay(svc.history.first);
      expect(svc.visible.length, 1);
      expect(svc.visible.first.title, '导出失败');
      expect(svc.visible.first.level, ToastLevel.error);
      svc.dispose();
    });

    test('清空历史同时收回当前显示', () {
      final svc = ToastService(autoDismiss: false);
      svc.info('一');
      svc.info('二');
      expect(svc.history, isNotEmpty);
      svc.clearHistory();
      expect(svc.history, isEmpty);
      expect(svc.visible, isEmpty);
      svc.dispose();
    });

    test('空白标题不发通知', () {
      final svc = ToastService(autoDismiss: false);
      expect(svc.show('   '), isNull);
      expect(svc.show(''), isNull);
      expect(svc.history, isEmpty);
      svc.dispose();
    });

    test('文案整形：压平换行 / 截断 / 脱敏', () {
      expect(ToastService.sanitize('第一行\n第二行   第三行'), '第一行 第二行 第三行');

      final long = '很长的标题' * 20;
      final cut = ToastService.sanitize(long, maxLength: 40);
      expect(cut.length, 41);
      expect(cut.endsWith('…'), isTrue);

      expect(ToastService.sanitize('/Users/alice/Projects/demo'), startsWith('~'));

      final named = ToastService.sanitize('请求失败 key-sk-1234567890abcdef');
      expect(named.contains('sk-1234567890abcdef'), isFalse);
      expect(named.contains('••••'), isTrue);

      final bearer = ToastService.sanitize('Authorization: Bearer abc.def.ghi');
      expect(bearer.contains('abc.def.ghi'), isFalse);

      final opaque = ToastService.sanitize('token=${'a' * 48}');
      expect(opaque.contains('a' * 48), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // 宿主：堆叠 / 分级消退 / 去重刷新 / 降级 / 空态穿透
  // -------------------------------------------------------------------------

  group('ToastHost', () {
    testWidgets('顶部左侧堆叠，新通知在最上面', (tester) async {
      final svc = await _mountHost(tester);
      svc.info('第一条提示');
      await tester.pump(const Duration(milliseconds: 220));
      svc.info('第二条提示');
      await tester.pump(const Duration(milliseconds: 220));

      final first = tester.getTopLeft(find.text('第一条提示'));
      final second = tester.getTopLeft(find.text('第二条提示'));

      expect(second.dy, lessThan(first.dy), reason: '新通知在上');
      expect(first.dy - second.dy, greaterThan(20), reason: '两条垂直堆叠');
      expect(first.dx, closeTo(second.dx, 0.5), reason: '左缘对齐');
      expect(second.dx, lessThan(120), reason: '靠左');
      expect(second.dy, lessThan(80), reason: '靠上');

      svc.dispose();
    });

    testWidgets('info 2s 后自动消退', (tester) async {
      final svc = await _mountHost(tester);
      svc.info('提示已完成');
      await tester.pump();
      expect(find.text('提示已完成'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1900));
      expect(find.text('提示已完成'), findsOneWidget, reason: '2s 未到不早退');

      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('提示已完成'), findsNothing);
      svc.dispose();
    });

    testWidgets('success 2.5s 后自动消退', (tester) async {
      final svc = await _mountHost(tester);
      svc.success('已保存');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2400));
      expect(find.text('已保存'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('已保存'), findsNothing);
      svc.dispose();
    });

    testWidgets('warn 4s 后自动消退', (tester) async {
      final svc = await _mountHost(tester);
      svc.warn('网络较慢');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 3900));
      expect(find.text('网络较慢'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('网络较慢'), findsNothing);
      svc.dispose();
    });

    testWidgets('error 5s 不早退', (tester) async {
      final svc = await _mountHost(tester);
      svc.error('保存失败');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 4900));
      expect(find.text('保存失败'), findsOneWidget, reason: '错误级必须停留满 5s');
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('保存失败'), findsNothing);
      svc.dispose();
    });

    testWidgets('连续相同只保留一条并刷新计时', (tester) async {
      final svc = await _mountHost(tester);
      svc.error('保存失败');
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('保存失败'), findsOneWidget);
      expect(find.text('×2'), findsNothing);

      // 距离首次已 4s：再来一条相同通知，应当刷新计时而不是新建一条。
      svc.error('保存失败');
      await tester.pump();
      expect(find.text('×2'), findsOneWidget);
      expect(find.text('保存失败'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      expect(find.text('保存失败'), findsOneWidget, reason: '计时已刷新（按 5s 重新计）');

      await tester.pump(const Duration(milliseconds: 1100));
      expect(find.text('保存失败'), findsNothing);
      expect(svc.history.length, 1);
      expect(svc.history.first.repeatCount, 2);
      svc.dispose();
    });

    testWidgets('点按关闭按钮立即收回（历史保留）', (tester) async {
      final svc = await _mountHost(tester);
      svc.info('可关闭的提示');
      await tester.pump();
      expect(find.text('可关闭的提示'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.text('可关闭的提示'), findsNothing);
      expect(svc.history.length, 1);
      svc.dispose();
    });

    testWidgets('毛玻璃默认开、可降级为实底', (tester) async {
      final blurred = await _mountHost(tester);
      blurred.success('已保存');
      await tester.pump();
      expect(find.byType(BackdropFilter), findsOneWidget);
      blurred.dispose();

      final plain = await _mountHost(tester, blur: false);
      plain.success('已保存');
      await tester.pump();
      expect(find.byType(BackdropFilter), findsNothing, reason: '低端设备降级后不再模糊');
      expect(find.text('已保存'), findsOneWidget);
      plain.dispose();
    });

    testWidgets('空态不拦截指针', (tester) async {
      final svc = ToastService(blurEnabled: false);
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(),
          home: ToastHost(
            service: svc,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => tapped++,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.tapAt(const Offset(24, 20));
      expect(tapped, 1, reason: '没有通知时左上角必须可点');
      svc.dispose();
    });

    testWidgets('手机宽度下长文案不溢出', (tester) async {
      // 用 view 尺寸而不是 setSurfaceSize：面板宽度取自 MediaQuery，
      // 只有改 view 才能让「屏幕宽度」与「布局约束」同时变成 390。
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final svc = await _mountHost(tester);
      svc.error(
        '这是一条比较长的通知标题用来检查窄屏换行与省略',
        '详情也会比较长：磁盘空间不足，请清理后重试；如果仍然失败，可以在通知中心回看这条记录。',
      );
      await tester.pump(const Duration(milliseconds: 220));

      expect(tester.takeException(), isNull);
      expect(find.textContaining('这是一条比较长的通知标题'), findsOneWidget);
      expect(tester.getSize(find.byType(ToastCapsule)).width, lessThanOrEqualTo(ToastVisuals.maxWidth));
      svc.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // 通知中心
  // -------------------------------------------------------------------------

  group('NotificationCenter', () {
    testWidgets('空态 → 历史（级别/时间在）→ 点按重放', (tester) async {
      final svc = ToastService();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(),
          home: Scaffold(body: Center(child: NotificationCenter(service: svc))),
        ),
      );
      expect(find.text('还没有通知'), findsOneWidget);

      final item = svc.error('导出失败', '磁盘空间不足');
      await tester.pump();
      expect(find.text('导出失败'), findsOneWidget);
      expect(find.text('磁盘空间不足'), findsOneWidget);
      expect(find.text(formatTime(item!.createdAt)), findsOneWidget);
      expect(find.text('×2'), findsNothing);

      svc.dismiss(item.id);
      await tester.pump();
      expect(svc.visible, isEmpty, reason: '关掉当前显示后历史还在');

      await tester.tap(find.text('导出失败'));
      await tester.pump();
      expect(svc.visible.length, 1, reason: '点按历史行可重放');
      expect(svc.visible.first.level, ToastLevel.error);

      await tester.pump(const Duration(seconds: 6));
      svc.dispose();
    });

    testWidgets('清空按钮清掉历史', (tester) async {
      final svc = ToastService();
      svc.info('一条通知');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(),
          home: Scaffold(body: Center(child: NotificationCenter(service: svc))),
        ),
      );
      await tester.pump();
      expect(find.text('一条通知'), findsOneWidget);

      await tester.tap(find.text('清空'));
      await tester.pump();
      expect(find.text('还没有通知'), findsOneWidget);
      expect(svc.history, isEmpty);
      svc.dispose();
    });

    testWidgets('showNotificationCenter 可弹出并关闭', (tester) async {
      final svc = ToastService();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: TextButton(
                  onPressed: () => showNotificationCenter(ctx, service: svc),
                  child: const Text('打开通知'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开通知'));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationCenter), findsOneWidget);
      expect(find.text('还没有通知'), findsOneWidget);
      expect(
        tester.getCenter(find.byType(NotificationCenter)).dx,
        closeTo(tester.getCenter(find.byType(MaterialApp)).dx, 1),
        reason: '面板居中',
      );

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationCenter), findsNothing);
      svc.dispose();
    });

    testWidgets('手机尺寸下历史名单不溢出', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final svc = ToastService();
      for (var i = 0; i < 30; i++) {
        svc.info('通知 $i', '第 $i 条说明');
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: TextButton(
                  onPressed: () => showNotificationCenter(ctx, service: svc),
                  child: const Text('打开通知'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开通知'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(NotificationCenter), findsOneWidget);
      expect(tester.getSize(find.byType(NotificationCenter)).width, lessThanOrEqualTo(390 - 32));
      svc.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // 结构性约束
  // -------------------------------------------------------------------------

  group('结构性约束', () {
    test('通知链路不依赖页面级弹条（ScaffoldMessenger / SnackBar）', () {
      final appDir = _appDir();
      for (final name in _toastFiles) {
        final code = _codeOnly(File('${appDir.path}/$name').readAsStringSync());
        expect(code.contains('ScaffoldMessenger'), isFalse, reason: name);
        expect(code.contains('SnackBar'), isFalse, reason: name);
      }
    });

    test('通知相关文案通过术语表扫描', () {
      final appDir = _appDir();
      for (final name in _toastFiles) {
        final findings = findCopyViolations(File('${appDir.path}/$name').readAsStringSync());
        expect(findings, isEmpty, reason: '$name: ${findings.join("; ")}');
      }
    });
  });
}
