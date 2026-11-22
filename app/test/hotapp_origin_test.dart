// 热应用两类区分（用户裁决 2026-11-19）：
// * 可用应用（origin=app）：用户直接描述生成、能长期用的小应用；
// * 原型验证 demo（origin=prototype）：由设计原型生成，只验证逻辑与交互可行性。
//
// manifest 是唯一事实源：旧包没有 origin 字段时必须按「可用应用」读回，
// 否则升级后所有历史应用会变成另一类。
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/nonapp_library.dart';
import 'package:nondesign/core/nonapp_package.dart';

NonAppManifest _manifest({String origin = nonAppOriginApp}) => NonAppManifest(
      formatVersion: nonAppFormatVersion,
      id: 'demo',
      name: 'demo',
      title: 'demo',
      renderer: 'html',
      createdAt: 1700000000,
      minAppVersion: nonAppClientVersion,
      origin: origin,
    );

void main() {
  test('manifest 缺省 origin 是可用应用（旧包兼容）', () {
    final json = _manifest().toJson();
    expect(json['origin'], nonAppOriginApp);
    // 模拟旧包：删掉字段后解析必须仍读成 app。
    final legacy = Map<String, dynamic>.from(json)..remove('origin');
    expect(legacy['origin'], isNull);
    final decoded = NonAppManifest(
      formatVersion: nonAppFormatVersion,
      id: 'demo',
      name: 'demo',
      title: 'demo',
      renderer: 'html',
      createdAt: 1700000000,
      minAppVersion: nonAppClientVersion,
      // 解析层按「缺省 = app」处理（见 NonAppPackage.parse）。
      origin: legacy['origin'] == nonAppOriginPrototype ? nonAppOriginPrototype : nonAppOriginApp,
    );
    expect(decoded.isPrototypeDemo, isFalse);
  });

  test('manifest origin 往返：prototype 标记不丢失', () {
    final json = _manifest(origin: nonAppOriginPrototype).toJson();
    expect(json['origin'], nonAppOriginPrototype);
    final decoded = NonAppManifest(
      formatVersion: nonAppFormatVersion,
      id: 'demo',
      name: 'demo',
      title: 'demo',
      renderer: 'html',
      createdAt: 1700000000,
      minAppVersion: nonAppClientVersion,
      origin: json['origin'] as String,
    );
    expect(decoded.isPrototypeDemo, isTrue);
  });

  test('LibraryApp 类型显示名与货架条目', () {
    LibraryApp app(String origin) => LibraryApp(
          name: 'demo',
          title: 'demo',
          renderer: 'html',
          createdAt: 1700000000,
          dir: '/tmp/demo',
          payloadBytes: 12,
          origin: origin,
        );

    expect(app(nonAppOriginApp).originLabel, '可用应用');
    expect(app(nonAppOriginApp).isPrototypeDemo, isFalse);
    expect(app(nonAppOriginPrototype).originLabel, '原型验证');
    expect(app(nonAppOriginPrototype).isPrototypeDemo, isTrue);

    final shelf = app(nonAppOriginPrototype).toShelfItem();
    expect(shelf['origin'], nonAppOriginPrototype);
    expect(shelf['badge'], '原型验证');
    expect(app(nonAppOriginApp).toShelfItem()['badge'], '可用应用');
  });
}
