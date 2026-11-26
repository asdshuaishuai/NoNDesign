import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/workbench_layout.dart';

void main() {
  group('workbench layout spec', () {
    test('每个工作台规格彼此独立（断点/宽度/底栏不共用）', () {
      final specs = workbenchLayoutSpecs;
      expect(specs.keys, containsAll(WorkbenchKind.values));
      // 3D 视频是独立规格（镜头条更高），但刻意复用视频的左右栏宽度。
      final widths = <double>{
        specs[WorkbenchKind.design]!.leftWidth,
        specs[WorkbenchKind.three]!.leftWidth,
        specs[WorkbenchKind.video]!.leftWidth,
        specs[WorkbenchKind.music]!.leftWidth,
      };
      expect(widths.length, 4, reason: '四个内容面左栏宽度各不相同');
      expect(
        specs[WorkbenchKind.video3d]!.leftWidth,
        specs[WorkbenchKind.video]!.leftWidth,
        reason: '3D 视频复用视频三栏语义',
      );
      expect(
        specs[WorkbenchKind.video3d]!.bottomBarHeight,
        greaterThan(specs[WorkbenchKind.video]!.bottomBarHeight),
        reason: '3D 视频镜头条比常规视频时间线更高',
      );
      expect(specs[WorkbenchKind.three]!.bottomBar, isTrue);
      expect(specs[WorkbenchKind.video]!.bottomBar, isTrue);
      expect(specs[WorkbenchKind.video3d]!.bottomBar, isTrue);
      expect(specs[WorkbenchKind.music]!.bottomBar, isTrue);
      // 设计面仍是画布优先：不新增内容底栏（状态栏由共享外壳提供）。
      expect(specs[WorkbenchKind.design]!.bottomBar, isFalse);
      expect(
        specs[WorkbenchKind.three]!.phoneMaxWidth,
        isNot(specs[WorkbenchKind.video]!.phoneMaxWidth),
      );
    });

    test('设计面：手机两端 sheet；桌面左/右常驻；嵌入窄窗隐藏左栏', () {
      final phone = resolveWorkbenchLayout(
        kind: WorkbenchKind.design,
        width: 390,
        height: 844,
      );
      expect(phone.isPhone, isTrue);
      expect(phone.left, PanelPolicy.sheet);
      expect(phone.right, PanelPolicy.sheet);
      expect(phone.leftWidth, 252);
      expect(phone.rightWidth, 348);

      final tablet = resolveWorkbenchLayout(
        kind: WorkbenchKind.design,
        width: 900,
        height: 700,
      );
      expect(tablet.left, PanelPolicy.docked);
      expect(tablet.right, PanelPolicy.sheet);

      final desktop = resolveWorkbenchLayout(
        kind: WorkbenchKind.design,
        width: 1440,
        height: 900,
      );
      expect(desktop.left, PanelPolicy.docked);
      expect(desktop.right, PanelPolicy.docked);
      expect(desktop.isWide, isTrue);
      expect(desktop.rail, isTrue);

      final pip = resolveWorkbenchLayout(
        kind: WorkbenchKind.design,
        width: 700,
        height: 240,
        embedded: true,
      );
      expect(pip.left, PanelPolicy.hidden);
      expect(pip.rail, isFalse);
    });

    test('3D：左大纲更窄断点、右检查器、自带状态底栏', () {
      final narrow = resolveWorkbenchLayout(
        kind: WorkbenchKind.three,
        width: 800,
        height: 700,
      );
      expect(narrow.left, PanelPolicy.hidden, reason: '800 < 900 不打开大纲');
      expect(narrow.right, PanelPolicy.sheet);

      final wide = resolveWorkbenchLayout(
        kind: WorkbenchKind.three,
        width: 1200,
        height: 800,
      );
      expect(wide.left, PanelPolicy.docked);
      expect(wide.right, PanelPolicy.docked);
      expect(wide.leftWidth, 236);
      expect(wide.rightWidth, 300);
      expect(wide.bottomBar, isTrue);
    });

    test('视频导演台：更宽左栏、时间线底栏；音乐规格独立', () {
      final video = resolveWorkbenchLayout(
        kind: WorkbenchKind.video,
        width: 1100,
        height: 800,
      );
      expect(video.left, PanelPolicy.docked);
      expect(video.leftWidth, 280);
      expect(video.bottomBar, isTrue);

      final music = resolveWorkbenchLayout(
        kind: WorkbenchKind.music,
        width: 1100,
        height: 800,
      );
      expect(music.leftWidth, 220);
      expect(music.bottomBar, isTrue);
      expect(music.leftWidth, isNot(video.leftWidth));
    });

    test('视图映射：plugin 视图各归其位；hotapp 明确不改布局', () {
      expect(workbenchKindForView('plugin:three'), WorkbenchKind.three);
      expect(workbenchKindForView('plugin:video'), WorkbenchKind.video);
      expect(workbenchKindForView('plugin:music'), WorkbenchKind.music);
      expect(
        workbenchKindForView('plugin:hotapp'),
        isNull,
        reason: '热应用暂不改动；调用方必须显式跳过',
      );
      expect(workbenchKindForView('design'), WorkbenchKind.design);
      expect(workbenchKindForView('docs'), WorkbenchKind.design);
    });
  });
}
