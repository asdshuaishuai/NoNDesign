// 批次 04：Toast 服务与宿主。
//
// 锚定用户验收标准 H 的四件事：
//  1. 顶部左侧堆叠 + 圆角胶囊 + 毛玻璃（低端 Android 可关）；
//  2. 1–5s 分级时长（info 2 / success 2.5 / warn 4 / error 5），错误不早退；
//  3. 服务内部历史缓冲（100 条、时间与级别不丢）——**回看 UI 已于 2026-11-19
//     退役**（通知中心删除，见 AGENTS.md Toast 节登记）；历史只剩去重刷新与
//     replay 入参两个服务内用途，本文件末尾的「无历史入口」测试防守回接；
//  4. 连续相同只保留一条并刷新计时。
//
// 另外守住两条结构性约束：
//  * 通知链路不依赖 ScaffoldMessenger / SnackBar（散点弹条统一改走本服务）；
//  * 新增文案不触碰 docs/copy-glossary.md 的禁用词（复用 copy_guard 的扫描器）。

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
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
        '详情也会比较长：磁盘空间不足，请清理后重试；如果仍然失败，请在日志里查看这条记录。',
      );
      await tester.pump(const Duration(milliseconds: 220));

      expect(tester.takeException(), isNull);
      expect(find.textContaining('这是一条比较长的通知标题'), findsOneWidget);
      expect(tester.getSize(find.byType(ToastCapsule)).width, lessThanOrEqualTo(ToastVisuals.maxWidth));
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

    test('无历史入口：除服务自身外，lib/ 不得消费 history/replay/clearHistory', () {
      // 登记性防守（2026-11-19）：通知中心 UI 退役后，「通知历史可回看」不再
      // 是验收项——历史降为 ToastService 内部缓冲（去重刷新 / replay 入参）。
      // 若要在界面回接历史入口，先推翻 AGENTS.md Toast 节与
      // docs/copy-glossary.md §7 的登记，再删掉本测试。
      const serviceFile = 'lib/core/toast_service.dart';
      const hostFile = 'lib/widgets/toast_host.dart';
      // 只匹配 toast 服务专属的 API 形态：引擎撤销历史（store.history）、
      // 3D（three_service 的 history 字段）、Icons.history 等同名但不同形，
      // 不会命中这三个 token。宿主文件额外全禁 'history'——渲染层不得出现
      // 任何历史面（只读回看也算入口）。
      final patterns = <Pattern>[RegExp(r'\breplay\('), RegExp(r'\bclearHistory\('), 'maxHistory'];
      final libDir = Directory('${_appDir().path}/lib');
      final offenders = <String>[];
      for (final file in libDir.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        // Windows 的 path 用 `\`：先归一化再和 POSIX 形态的常量比较，
        // 否则服务自身会被当成消费者（历史假红）。
        final posixPath = file.path.replaceAll('\\', '/');
        if (posixPath.endsWith(serviceFile)) continue;
        final isHost = posixPath.endsWith(hostFile);
        final code = _codeOnly(file.readAsStringSync());
        final tokens = isHost ? <Pattern>[...patterns, 'history'] : patterns;
        for (final token in tokens) {
          if (code.contains(token)) {
            final lineNo = code.split('\n').indexWhere((l) => l.contains(token)) + 1;
            offenders.add('${file.path}:$lineNo → $token');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: '通知历史无 UI 入口是已登记的产品决策；'
              '回接前先撤销登记：\n${offenders.join('\n')}');
    });
  });
}
