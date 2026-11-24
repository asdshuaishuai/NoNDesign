import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/design_prototype.dart';

DesignPrototypeScreen _screen(String id, String title, {String svg = ''}) =>
    DesignPrototypeScreen(
      id: id,
      title: title,
      width: 390,
      height: 844,
      svg: svg,
    );

void main() {
  group('design prototype build', () {
    test('每屏 data-screen + 每条连线 data-nav，且零网络引用', () {
      final doc = DesignPrototypeBuilder.build(
        projectName: '咖啡点单',
        entry: 'home',
        screens: <DesignPrototypeScreen>[
          _screen('home', '首页', svg: '<svg viewBox="0 0 390 844"></svg>'),
          _screen('menu', '菜单'),
        ],
        flows: const <DesignPrototypeFlow>[
          DesignPrototypeFlow(from: 'home', to: 'menu', trigger: 'tap:n1'),
        ],
        builtAt: '2026-11-24T00:00:00Z',
      );
      expect(doc.html, contains('data-screen="home"'));
      expect(doc.html, contains('data-screen="menu"'));
      expect(doc.html, contains('data-nav="menu"'));
      expect(doc.html, contains('<svg viewBox="0 0 390 844">'));
      expect(doc.html, isNot(contains('http://')));
      expect(doc.html, isNot(contains('https://')));
      expect(doc.html, contains('nan-prototype-manifest'));
      expect(doc.verified, isTrue, reason: doc.checks.toString());
      expect(doc.manifest['entry'], 'home');
      expect((doc.manifest['screens'] as List), hasLength(2));
      expect((doc.manifest['flows'] as List), hasLength(1));
    });

    test('缺屏/缺连线时如实报 verified=false，并给逐条 detail', () {
      final screens = <DesignPrototypeScreen>[
        _screen('home', '首页'),
        _screen('cart', '购物车'),
      ];
      final doc = DesignPrototypeBuilder.build(
        projectName: 'demo',
        entry: 'home',
        screens: screens,
        flows: const <DesignPrototypeFlow>[
          DesignPrototypeFlow(from: 'home', to: 'cart'),
        ],
      );
      // 正确构建的产物应全绿。
      expect(doc.verified, isTrue);

      final broken = DesignPrototypeBuilder.verify(
        '<section data-screen="home"></section>',
        screens,
        const <DesignPrototypeFlow>[
          DesignPrototypeFlow(from: 'home', to: 'cart'),
        ],
        entry: 'home',
      );
      expect(
        broken.firstWhere((DesignPrototypeCheck c) => c.id == 'screen_cart').ok,
        isFalse,
      );
      expect(
        broken
            .firstWhere((DesignPrototypeCheck c) => c.id == 'flow_home_cart')
            .ok,
        isFalse,
      );
    });

    test('入口缺失单独报错', () {
      final checks = DesignPrototypeBuilder.verify(
        '<section data-screen="home"></section>',
        <DesignPrototypeScreen>[_screen('home', '首页')],
        const <DesignPrototypeFlow>[],
        entry: 'ghost',
      );
      expect(
        checks
            .firstWhere((DesignPrototypeCheck c) => c.id == 'entry_screen')
            .ok,
        isFalse,
      );
    });

    test('外部引用被 offline 检查抓住', () {
      final checks = DesignPrototypeBuilder.verify(
        '<section data-screen="home"></section><script src="https://evil.example/x.js"></script>',
        <DesignPrototypeScreen>[_screen('home', '首页')],
        const <DesignPrototypeFlow>[],
        entry: 'home',
      );
      expect(
        checks.firstWhere((DesignPrototypeCheck c) => c.id == 'offline').ok,
        isFalse,
      );
    });
  });

  group('design prototype project metadata', () {
    test('toProjectMetadata 往返恢复 html/manifest/checks', () {
      final doc = DesignPrototypeBuilder.build(
        projectName: 'p',
        entry: 'home',
        screens: <DesignPrototypeScreen>[_screen('home', '首页')],
        flows: const <DesignPrototypeFlow>[],
        builtAt: '2026-11-24T00:00:00Z',
      );
      final raw = doc.toProjectMetadata();
      final restored = DesignPrototypeDocument.fromProjectMetadata(raw);
      expect(restored, isNotNull);
      expect(restored!.html, doc.html);
      expect(restored.verified, doc.verified);
      expect(restored.checks.length, doc.checks.length);
      expect(restored.manifest['entry'], 'home');
      expect(restored.builtAt, '2026-11-24T00:00:00Z');
    });

    test('坏形状不崩、返回 null', () {
      expect(DesignPrototypeDocument.fromProjectMetadata(null), isNull);
      expect(
        DesignPrototypeDocument.fromProjectMetadata(<String, Object?>{
          'html': 3,
        }),
        isNull,
      );
      expect(
        DesignPrototypeDocument.fromProjectMetadata(<String, Object?>{
          'html': 'x',
          'manifest': 'nope',
        }),
        isNull,
      );
    });
  });
}
