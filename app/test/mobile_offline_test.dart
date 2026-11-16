// 移动端网络面与离线体验的锚点测试（审查批次：mobile-1/2/4/5）。
// - mobile-1/4：Android/iOS 平台配置是文件面（flutter test 跑不到系统层），
//   以文件内容锚定——与本仓 scripts/wf/test_server_routes.py 同一纪律。
// - mobile-2：离线 models.json 资产可解析、与 server 快照字节一致、
//   空 registry 的 store 注入后有可用的 toolCall/openai 模型。
// - mobile-5：boot 降级分支的失败可见性裁决（纯函数）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
    test('bundled asset 与 server 快照字节一致（sync_models.py 双写）', () {
      final server = File('../server/models.json').readAsStringSync();
      final asset = File('assets/models.json').readAsStringSync();
      expect(asset, server, reason: '两份快照必须由 scripts/sync_models.py 一起写入，手改一份即漂移');
    });

    test('快照可解析为注册表，空 registry 的 store 注入后模型门控有数据源', () {
      final registry = parseBundledModelsSnapshot(jsonDecode(File('assets/models.json').readAsStringSync()));
      expect(registry, isNotNull);
      final flat = registry!.flatten();
      expect(flat, isNotEmpty);
      expect(flat.any((m) => m.providerId == 'deepseek' && m.toolCall), isTrue,
          reason: '默认服务商 deepseek 必须有 toolCall 模型（_runAgent 的能力门控数据源）');

      // 对照 store.dart:52 空 registry：model getter 返回 null → 门控整体跳过。
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
      // 幂等：registry 已有（更权威的服务器）快照时不重读不覆盖。
      var called = false;
      await store.ensureBundledRegistry(load: (path) async {
        called = true;
        return '';
      });
      expect(called, isFalse);
    });
  });

  group('mobile-5 连接桌面失败可见性', () {
    test('配置过 serverUrl 却连不上 → 返回错误文案（bootError 屏显性呈现）', () {
      final msg = AppStore.mobileDegradedBootError(
        StateError('指定的服务器不可达：http://192.168.1.5:8799（检查桌面端是否在运行、两机是否同一网络）'),
        'http://192.168.1.5:8799',
      );
      expect(msg, contains('不可达'));
    });

    test('未配置 serverUrl → null（移动端正常离线形态，静默降级 PLAN 直连）', () {
      expect(AppStore.mobileDegradedBootError(StateError('spawn 失败'), ''), isNull);
      expect(AppStore.mobileDegradedBootError(StateError('spawn 失败'), '   '), isNull);
    });
  });
}
