// `nc/open` 通道契约（app/lib/core/nonapp_intake.dart）回归。
//
// 双向：native → Dart `openPath` {path}；Dart → native `takePending` →
// List<String>（返回并清空冷启动队列）。断言：
//   ① 冷启动队列被 drain 且只派发一次；
//   ② native 直投与队列里的同一条路径不重复派发（去重窗口）；
//   ③ attach 幂等（重复调用不重复派发）；
//   ④ handler 未绑定时先排队，bind 后补派发。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/nonapp_intake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = StandardMethodCodec();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 伪 native 侧：takePending 返回队列并清空（与三平台实现同语义）。
  final pending = <String>[];

  setUp(() {
    pending.clear();
    NonAppIntake.instance.resetForTest();
    messenger.setMockMethodCallHandler(NonAppIntake.channel, (call) async {
      if (call.method == 'takePending') {
        final items = List<String>.from(pending);
        pending.clear();
        return items;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(NonAppIntake.channel, null);
    NonAppIntake.instance.resetForTest();
  });

  Future<void> pushNative(String path) async {
    await messenger.handlePlatformMessage(
      'nc/open',
      codec.encodeMethodCall(MethodCall('openPath', {'path': path})),
      (_) {},
    );
  }

  test('冷启动队列被 drain，且同一条不重复派发', () async {
    final seen = <String>[];
    NonAppIntake.instance.bind((p) async => seen.add(p));
    pending.add('/tmp/cold.nonapp');

    await NonAppIntake.instance.attach();
    expect(seen, ['/tmp/cold.nonapp'], reason: 'attach 必须主动拉冷启动队列');

    // 再次 attach（幂等）：队列已空，去重窗口内也不重复。
    await NonAppIntake.instance.attach();
    expect(seen, ['/tmp/cold.nonapp']);
  });

  test('native 直投 + 队列里同一条路径：只派发一次', () async {
    final seen = <String>[];
    NonAppIntake.instance.bind((p) async => seen.add(p));
    await NonAppIntake.instance.attach();

    pending.add('/tmp/hot.nonapp');
    await pushNative('/tmp/hot.nonapp');
    expect(seen, ['/tmp/hot.nonapp'], reason: '直投与 drain 必须去重');
    expect(pending, isEmpty, reason: 'native push 后 Dart 应顺手 drain 清队列');
  });

  test('handler 未绑定时排队，bind 后补派发', () async {
    final seen = <String>[];
    pending.add('/tmp/early.nonapp');
    await NonAppIntake.instance.attach();
    expect(seen, isEmpty);

    NonAppIntake.instance.bind((p) async => seen.add(p));
    await Future<void>.delayed(Duration.zero);
    expect(seen, ['/tmp/early.nonapp']);
  });

  test('空路径与重复 attach 不产生副作用', () async {
    final seen = <String>[];
    NonAppIntake.instance.bind((p) async => seen.add(p));
    await NonAppIntake.instance.attach();
    await pushNative('');
    expect(seen, isEmpty);
    expect(NonAppIntake.instance.attached, isTrue);
  });
}
