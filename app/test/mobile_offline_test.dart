// Mobile network surface and offline experience anchors (mobile-1/2/4/5).
//
// - mobile-1/4: Android/iOS platform configuration is file-level (flutter test
//   cannot reach the OS layer), so it is anchored by file content.
// - mobile-2: the bundled model snapshot is the *only* registry source now —
//   it is no longer a mirror of a repo-side copy, so this test reads
//   `assets/models.json` alone.
// - mobile-5: the connect-desktop failure visibility decision (pure function).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/remote_desktop_client.dart';
import 'package:nondesign/core/store.dart';

void main() {
  group('mobile-1 Android 打包网络面', () {
    test('main manifest 声明 INTERNET 并放开明文 HTTP', () {
      // release APK 只合并 main manifest（debug/profile 各自的 INTERNET
      // 不进 release）；targetSdk≥28 默认禁明文 HTTP——连接桌面是手输
      // http://<局域网 IP>，两项缺一网络面即断。
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android.permission.INTERNET'));
      expect(manifest, contains('android:usesCleartextTraffic="true"'));
    });
  });

  group('mobile-4 iOS 本地网络声明', () {
    test('Info.plist 声明 NSLocalNetworkUsageDescription 与 ATS 本地放行', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(plist, contains('NSLocalNetworkUsageDescription'));
      expect(plist, contains('NSAllowsLocalNetworking'));
    });
  });

  group('mobile-2 离线模型注册表', () {
    test('随包快照可解析，且默认服务商有可用的工具调用模型', () {
      final raw = File('assets/models.json').readAsStringSync();
      final decoded = jsonDecode(raw);
      expect(decoded, isA<Map<String, dynamic>>());
      expect((decoded as Map)['providers'], isA<Map>());

      final registry = parseBundledModelsSnapshot(decoded);
      expect(registry, isNotNull);
      final flat = registry!.flatten();
      expect(flat, isNotEmpty);
      expect(flat.any((m) => m.providerId == 'deepseek' && m.toolCall), isTrue,
          reason: '默认服务商 deepseek 必须有 toolCall 模型（能力门控的数据源）');

      // 空 registry 的 store：model 为 null → 门控整体跳过；注入后有数据源。
      final store = AppStore();
      expect(store.model, isNull);
      store.registry = registry;
      final selected = store.model;
      expect(selected, isNotNull);
      expect(selected!.toolCall, isTrue);
      expect(selected.protocol, 'openai');
      expect(selected.baseUrl, isNotEmpty);
    });

    test('parseBundledModelsSnapshot 对坏形状返回 null（离线回退尽力而为）', () {
      expect(parseBundledModelsSnapshot(null), isNull);
      expect(parseBundledModelsSnapshot('not-a-map'), isNull);
      expect(parseBundledModelsSnapshot(<String, dynamic>{}), isNull);
      expect(parseBundledModelsSnapshot(<String, dynamic>{'providers': <String, dynamic>{}}), isNull);
    });

    test('ensureBundledRegistry 装载注入来源并保持幂等', () async {
      // 生产路径是 rootBundle.loadString（pubspec 声明的资产）；widget test
      // 的 flutter/assets 通道无人应答会挂死，故注入 File loader 测方法本身。
      final store = AppStore();
      expect(store.registry.providers, isEmpty);
      await store.ensureBundledRegistry(load: (path) async {
        expect(path, 'assets/models.json');
        return File('assets/models.json').readAsStringSync();
      });
      expect(store.registry.providers, isNotEmpty);
      expect(store.model, isNotNull);
      expect(store.model!.toolCall, isTrue);
      // 幂等：registry 已有快照时不重读不覆盖。
      var called = false;
      await store.ensureBundledRegistry(load: (path) async {
        called = true;
        return '';
      });
      expect(called, isFalse);
    });
  });

  group('mobile-5 连接桌面失败可见性', () {
    test('配置过地址却连不上 → 返回人性化文案（错误正文只进日志）', () {
      final msg = AppStore.mobileDegradedBootError(
        StateError('SocketException: Connection refused (port 1)'),
        'http://192.168.1.5:9000',
      );
      expect(msg, contains('连接桌面没有成功'));
      expect(msg, isNot(contains('SocketException')));
      expect(msg, isNot(contains('port')));
      expect(msg, isNot(contains('错误')), reason: '默认文案不暴露原始错误');
    });

    test('未配置地址 → null（本地运行时是正常形态）', () {
      expect(AppStore.mobileDegradedBootError(StateError('boom'), ''), isNull);
      expect(AppStore.mobileDegradedBootError(StateError('boom'), '   '), isNull);
    });

    test('未连接时的状态文案是「还没有连接桌面」', () {
      const status = RemoteDesktopStatus.notConfigured();
      expect(status.configured, isFalse);
      expect(status.connected, isFalse);
      expect(status.message, '还没有连接桌面');
    });

    test('连接桌面地址规范化：无协议自动补 http、去尾斜杠', () {
      expect(RemoteDesktopClient.normalizeBaseUrl(' 192.168.1.5:9000 '), 'http://192.168.1.5:9000');
      expect(RemoteDesktopClient.normalizeBaseUrl('http://h:9000///'), 'http://h:9000');
    });
  });
}
