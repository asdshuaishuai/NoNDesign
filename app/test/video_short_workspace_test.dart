// 视频工作台接入引擎短片：空态入口 → 选项目 → 呈现效果换成短片预览 → 关闭回落。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:nondesign/core/models.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/video/video_screenplay.dart';
import 'package:nondesign/core/video/video_short_project.dart';
import 'package:nondesign/core/video_project.dart';
import 'package:nondesign/widgets/video_short_preview_surface.dart';
import 'package:nondesign/widgets/video_workspace.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.build(dark: true),
  home: Scaffold(body: child),
);

AppStore _store() {
  final AppStore store = AppStore(toasts: ToastService(autoDismiss: false))
    ..ready = true
    ..settings = AppSettings(
      providerId: 'deepseek',
      modelId: 'deepseek-v4.1-flash',
    )
    ..view = 'video';
  store.recoveryDir = Directory.systemTemp
      .createTempSync('nd-video-short-workspace-recovery')
      .path;
  return store;
}

Future<void> _settleIo(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Map<String, Object?> _screenplayMap() => <String, Object?>{
  'schema': 'nan.screenplay/1',
  'width': 320,
  'height': 180,
  'shots': <Object?>[
    <String, Object?>{
      'id': 's1',
      'start': 0.0,
      'duration': 2.0,
      'events': <Object?>[
        <String, Object?>{
          'f': 15,
          'type': 'vfx',
          'cue': 'fire.campfire',
        },
      ],
    },
  ],
};

/// Fake 短片预览控制器：不构造 WebView，状态由测试驱动。
class _FakeShortPreview extends VideoShortPreviewController {
  bool _ready = false;
  bool _playing = false;
  int _frame = 0;

  @override
  bool get ready => _ready;

  @override
  bool get playing => _playing;

  @override
  int get frame => _frame;

  @override
  int get totalFrames => 60;

  @override
  int get fps => 30;

  @override
  String get loadError => '';

  @override
  String get technicalDetail => '';

  @override
  String get renderer => 'phaser4_canvas';

  @override
  String get vfxRenderer => 'pixelfx_pixels';

  @override
  Future<void> start() async {
    _ready = true;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _frame = 0;
    notifyListeners();
  }

  @override
  Future<void> seek(double seconds) async => seekFrame((seconds * 30).round());

  @override
  Future<void> seekFrame(int frame) async {
    _frame = frame.clamp(0, 59);
    notifyListeners();
  }
}

void main() {
  testWidgets('打开引擎短片：呈现效果换成预览面；关闭回到空态入口', (tester) async {
    // 「更多」菜单只在窄屏分支渲染（宽屏分支另有一套工具条），所以用窄视口。
    tester.view.physicalSize = const Size(720, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final Directory temp = Directory.systemTemp.createTempSync(
      'video-short-workspace-',
    );
    addTearDown(() {
      if (temp.existsSync()) {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      }
    });
    final VideoProjectStore projectStore = VideoProjectStore(root: temp);
    final VideoShortProjectStore shortStore = VideoShortProjectStore(
      root: Directory('${temp.path}/short'),
    );
    await shortStore.save('short', _screenplayMap());

    final _FakeShortPreview fake = _FakeShortPreview();
    final AppStore appStore = _store();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStore>.value(
        value: appStore,
        child: _app(
          VideoWorkspace(
            projectStore: projectStore,
            shortProjectStore: shortStore,
            shortPreviewFactory: (VideoScreenplay _) => fake,
          ),
        ),
      ),
    );
    await _settleIo(tester);

    // 固定入口在「更多」菜单里（不依赖空态；示例文档也会载入）。
    await tester.tap(find.byKey(const ValueKey('video-more-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开引擎短片…'));
    await tester.pumpAndSettle();

    // 对话框列出项目（名称 + 摘要）。
    expect(find.text('打开引擎短片'), findsOneWidget);
    expect(find.text('short'), findsOneWidget);
    await tester.tap(find.text('short'));
    await tester.pumpAndSettle();
    await _settleIo(tester);

    // 呈现效果栏目换成短片预览面。
    expect(find.byKey(const ValueKey('video-short-authoring')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-short-close')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('video-short-preview-surface')),
      findsOneWidget,
    );
    expect(fake.ready, isTrue, reason: '打开后没有 start 预览控制器');

    // 关闭：回到空态入口。
    await tester.tap(find.byKey(const ValueKey('video-short-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-short-authoring')), findsNothing);
    expect(
      find.byKey(const ValueKey('video-more-menu')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
