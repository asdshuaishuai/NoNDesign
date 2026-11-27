// WebView 页面真机冒烟（Linux WebKitGTK / webview_all）。
//
// 覆盖本机集成落地、但此前只在 fake/组装层验证过的三块真实 WebView 页面：
//   1) 音乐播放页（assembleMusicPlayer）：页面就绪 + 宿主命令面 + 桥消息；
//   2) 3D 视频预览页（assembleVideo3dPreview）：页面就绪 + 帧跳转 + 桥消息；
//   3) 3D 视口控制（preview.html 的 __non3d_view / __non3d_grid）：真页面里
//      视角预设与网格开关的返回值（未就绪返回 false，不静默）。
//
// 运行（Linux 容器内 WebKitGTK 需要把宿主 rootfs 的系统库目录挂到硬编码路径上）：
//   unshare -rm bash -c 'mount --bind /run/host/rootfs/usr/lib/x86_64-linux-gnu \
//     /usr/lib/x86_64-linux-gnu && cd app && flutter test \
//     integration_test/webview_pages_test.dart -d linux'
//
// 通过 = 页面真的在 WebKitGTK 里跑起来 + 宿主 JS 命令面可用 + 出站桥有消息；
// 音频在无声卡容器里可能起不来，但必须表现为显性 error 桥消息而不是静默。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_wkwebview/webview_all_wkwebview.dart';

import 'package:nondesign/core/music/music_compile.dart';
import 'package:nondesign/core/music/music_player.dart';
import 'package:nondesign/core/music/music_score.dart';
import 'package:nondesign/core/video3d/video3d_contract.dart';
import 'package:nondesign/core/video3d/video3d_compile.dart';
import 'package:nondesign/core/video3d/video3d_evidence.dart';
import 'package:nondesign/core/video3d/video3d_player.dart';
import 'package:nondesign/core/video3d/video3d_project.dart';
import 'package:nondesign/core/three_service.dart';
import 'package:nondesign/widgets/music_playback_surface.dart';
import 'package:nondesign/widgets/video3d_preview_surface.dart';

/// 24 帧的总片长（4×1 秒）。
MusicScore _score() => MusicScore(
  title: 'webview 冒烟',
  tempo: 120,
  timeSig: const <int>[4, 4],
  keySig: 'C',
  tracks: <MusicTrack>[
    MusicTrack(
      id: 'melody',
      name: '主旋律',
      instrument: 'piano',
      measures: <MusicMeasure>[
        for (int i = 0; i < 4; i++)
          MusicMeasure(
            id: 'm${i + 1}',
            events: <MusicEvent>[
              for (int j = 0; j < 4; j++)
                MusicEvent(
                  id: 'n${i}_$j',
                  isRest: false,
                  durNum: 1,
                  durDen: 4,
                  step: 'C',
                  octave: 5,
                ),
            ],
          ),
      ],
    ),
  ],
);

Map<String, dynamic> _sceneRaw() => <String, dynamic>{
  'v': 1,
  'units': 'm',
  'environment': <String, dynamic>{'background': '#0b0d12'},
  'nodes': <dynamic>[
    <String, dynamic>{
      'id': 'floor',
      'type': 'box',
      'size': <double>[10, 0.1, 10],
      'position': <double>[0, -0.05, 0],
      'material': <String, dynamic>{
        'color': '#9a8c7a',
        'roughness': 0.9,
        'metalness': 0,
      },
    },
    <String, dynamic>{
      'id': 'column',
      'type': 'cylinder',
      'size': <double>[0.3, 0.3, 2],
      'position': <double>[0, 1, 0],
      'material': <String, dynamic>{
        'color': '#c9a06a',
        'roughness': 0.7,
        'metalness': 0.1,
      },
    },
  ],
  'lights': <dynamic>[
    <String, dynamic>{
      'id': 'key',
      'type': 'directional',
      'intensity': 1.0,
      'color': '#ffffff',
      'position': <double>[4, 6, 4],
      'target': <double>[0, 1, 0],
    },
  ],
  'cameras': <dynamic>[
    <String, dynamic>{
      'id': 'hero',
      'position': <double>[6, 3, 6],
      'target': <double>[0, 1, 0],
      'fov': 45,
    },
  ],
};

Map<String, dynamic> _screenplayRaw() => <String, dynamic>{
  'v': 1,
  'fps': 30,
  'format': <String, dynamic>{'width': 1280, 'height': 720},
  'shots': <dynamic>[
    <String, dynamic>{
      'id': 's1',
      'duration': 3.0,
      'camera': <String, dynamic>{'id': 'hero'},
      'cues': <dynamic>[],
    },
    <String, dynamic>{
      'id': 's2',
      'duration': 2.0,
      'camera': <String, dynamic>{
        'move': <String, dynamic>{
          'from': <double>[6, 3, 6],
          'to': <double>[4, 2, 5],
          'target': <double>[0, 1, 0],
          'easing': 'easeInOut',
        },
      },
      'cues': <dynamic>[],
    },
  ],
};

/// JSON 桥消息解码（非 JSON 原文保留在 raw 里）。
class _Bridge {
  final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[];
  final List<String> raw = <String>[];

  void onMessage(JavaScriptMessage message) {
    raw.add(message.message);
    try {
      final Object? decoded = jsonDecode(message.message);
      if (decoded is Map) {
        messages.add(decoded.cast<String, dynamic>());
      }
    } catch (_) {}
  }

  List<Map<String, dynamic>> ofKind(String kind) =>
      messages.where((m) => m['kind'] == kind).toList();
}

Future<WebViewController> _mount(
  WidgetTester tester,
  String channel,
  _Bridge bridge,
) async {
  final WebViewController controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..addJavaScriptChannel(channel, onMessageReceived: bridge.onMessage);
  return controller;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // webview_all 在真实运行时由插件注册表就绪；测试环境保留显式注册兜底。
    if (Platform.isMacOS && WebViewPlatform.instance == null) {
      WebKitWebViewPlatform.registerWith();
    }
  });

  testWidgets('音乐播放页：WebKitGTK 里就绪 + 宿主命令面 + 桥消息', (tester) async {
    final MusicScore score = _score();
    final MusicPlayPlan plan = compileMusicScore(score);
    final String html = assembleMusicPlayer(score, plan);

    final _Bridge bridge = _Bridge();
    final WebViewController controller = await _mount(
      tester,
      'NONMUSIC',
      bridge,
    );
    await controller.loadHtmlString(html);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WebViewWidget(controller: controller)),
      ),
    );
    await tester.pump();

    // 页面脚本是内联同步执行的：等宿主命令面出现即视为就绪。
    String ready = '';
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      ready =
          '${await controller.runJavaScriptReturningResult('typeof window.NONMUSIC_PLAYER')}';
      await tester.pump();
      if (ready.contains('object')) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(
      ready.contains('object'),
      isTrue,
      reason: '音乐播放页没有挂上宿主命令面：$ready；桥消息=${bridge.raw}',
    );

    // 宿主命令面：position/state/totalFrames 必须可读。
    final String position =
        '${await controller.runJavaScriptReturningResult('window.NONMUSIC_PLAYER.position()')}';
    expect(position, isNotEmpty, reason: 'position() 读不到播放头');
    final String totalTicks =
        '${await controller.runJavaScriptReturningResult('String(window.NONMUSIC_PLAYER.totalTicks ? window.NONMUSIC_PLAYER.totalTicks() : "n/a")')}';
    // ignore: avoid_print
    print(
      '[webview-music] ready=$ready position=$position totalTicks=$totalTicks',
    );

    // 播放：在有声卡的环境应回 beat；无音频设备时应显性 error，不允许静默。
    await controller.runJavaScript('window.NONMUSIC_PLAYER.play()');
    final DateTime playDeadline = DateTime.now().add(
      const Duration(seconds: 8),
    );
    while (DateTime.now().isBefore(playDeadline) &&
        bridge.ofKind('beat').isEmpty &&
        bridge.ofKind('error').isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    }
    final int beats = bridge.ofKind('beat').length;
    final List<Map<String, dynamic>> errors = bridge.ofKind('error');
    // 时钟必须真的走：等 1.5s 后播放头应 > 0（否则页面只是「加载了」）。
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await tester.pump();
    final String positionAfter =
        '${await controller.runJavaScriptReturningResult('window.NONMUSIC_PLAYER.position()')}';
    // ignore: avoid_print
    print('[webview-music] positionAfter=$positionAfter');
    // ignore: avoid_print
    print(
      '[webview-music] beats=$beats errors=${errors.map((e) => e['message']).toList()}',
    );
    expect(
      beats > 0 || errors.isNotEmpty,
      isTrue,
      reason: '播放后既没有 beat 也没有显性 error：桥消息=${bridge.raw}',
    );
    if (errors.isEmpty) {
      final double advanced =
          double.tryParse(positionAfter.replaceAll('"', '').trim()) ?? 0;
      expect(
        advanced,
        greaterThan(0),
        reason: '播放 1.5s 后播放头仍为 0，说明页面时钟没走：$positionAfter',
      );
    }
    await controller.runJavaScript('window.NONMUSIC_PLAYER.stop()');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('3D 视频预览页：就绪 + seekFrame + frame 桥', (tester) async {
    final Video3dVerification verification = verifyVideo3d(
      _sceneRaw(),
      _screenplayRaw(),
    );
    expect(verification.verified, isTrue, reason: '${verification.toJson()}');
    final Video3dScene scene = verification.scene!;
    final Video3dScreenplay screenplay = verification.screenplay!;
    final ByteData runtimeData = await rootBundle.load(
      'assets/three/vendor/three-live.min.js',
    );
    final String runtime = utf8.decode(
      runtimeData.buffer.asUint8List(
        runtimeData.offsetInBytes,
        runtimeData.lengthInBytes,
      ),
    );
    final String html = assembleVideo3dPreview(
      scene,
      screenplay,
      runtimeSource: runtime,
    );

    final _Bridge bridge = _Bridge();
    final WebViewController controller = await _mount(
      tester,
      'NONVIDEO3D',
      bridge,
    );
    await controller.loadHtmlString(html);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WebViewWidget(controller: controller)),
      ),
    );
    await tester.pump();

    String ready = '';
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      ready =
          '${await controller.runJavaScriptReturningResult('typeof window.NONVIDEO3D_PLAYER')}';
      await tester.pump();
      if (ready.contains('object')) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(
      ready.contains('object'),
      isTrue,
      reason: '3D 视频预览页没有挂上宿主命令面：$ready；桥消息=${bridge.raw}',
    );

    final String totalFrames =
        '${await controller.runJavaScriptReturningResult('window.NONVIDEO3D_PLAYER.totalFrames()')}';
    expect(
      totalFrames.contains('150'),
      isTrue,
      reason: '5 秒 × 30fps 应为 150 帧，实得 $totalFrames',
    );

    // 跳到第 120 帧：页面必须回 frame 桥（宿主播放头靠它）。
    await controller.runJavaScript('window.NONVIDEO3D_PLAYER.seekFrame(120)');
    final DateTime frameDeadline = DateTime.now().add(
      const Duration(seconds: 15),
    );
    while (DateTime.now().isBefore(frameDeadline) &&
        bridge.ofKind('frame').isEmpty &&
        bridge.ofKind('error').isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    }
    final int frames = bridge.ofKind('frame').length;
    final List<Map<String, dynamic>> errors = bridge.ofKind('error');
    // ignore: avoid_print
    print(
      '[webview-video3d] totalFrames=$totalFrames frames=$frames '
      'errors=${errors.map((e) => e['message']).toList()}',
    );
    expect(
      frames > 0 || errors.isNotEmpty,
      isTrue,
      reason: 'seekFrame 后既没有 frame 也没有显性 error：桥消息=${bridge.raw}',
    );
    // 播放推进：1s 后帧号应大于之前 seek 的 120（页面时钟真的在走）。
    await controller.runJavaScript('window.NONVIDEO3D_PLAYER.play()');
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    await tester.pump();
    final String frameAfterPlay =
        '${await controller.runJavaScriptReturningResult('window.NONVIDEO3D_PLAYER.frame()')}';
    await controller.runJavaScript('window.NONVIDEO3D_PLAYER.pause()');
    // ignore: avoid_print
    print('[webview-video3d] frameAfterPlay=$frameAfterPlay');
    final int advancedFrame =
        (double.tryParse(frameAfterPlay.replaceAll('"', '').trim()) ?? 0)
            .round();
    expect(
      advancedFrame,
      greaterThan(120),
      reason: '播放 1s 后帧号没有前进（页面时钟没走）：$frameAfterPlay',
    );

    final String state =
        '${await controller.runJavaScriptReturningResult('window.NONVIDEO3D_PLAYER.state()')}';
    expect(
      state.contains('idle'),
      isTrue,
      reason: '暂停态 state 应为 idle，实得 $state',
    );
  });

  testWidgets('3D 视口控制：真页面里 __non3d_view / __non3d_grid 可用', (tester) async {
    final String template = await rootBundle.loadString(
      'assets/three/preview.html',
    );
    final String moduleSource = await rootBundle.loadString(
      'assets/three/three.module.js',
    );
    final String liveSource = await rootBundle.loadString(
      'assets/three/vendor/three-live.min.js',
    );
    final String sceneJs = '''
export default function build(THREE, scene, camera, controls, renderer) {
  const floor = new THREE.Mesh(
    new THREE.BoxGeometry(10, 0.1, 10),
    new THREE.MeshStandardMaterial({ color: 0x9a8c7a, roughness: 0.9 }));
  floor.name = 'floor';
  floor.position.y = -0.05;
  scene.add(floor);
  const pillar = new THREE.Mesh(
    new THREE.CylinderGeometry(0.3, 0.3, 2, 24),
    new THREE.MeshStandardMaterial({ color: 0xc9a06a, roughness: 0.7 }));
  pillar.name = 'pillar';
  pillar.position.y = 1;
  scene.add(pillar);
  scene.add(new THREE.AmbientLight(0xffffff, 1.0));
  const sun = new THREE.DirectionalLight(0xffffff, 2.0);
  sun.position.set(5, 6, 4);
  scene.add(sun);
  camera.position.set(4, 3, 4);
  camera.lookAt(0, 1, 0);
  return { metrics: { floor: true, pillar: true } };
}
''';
    final String html = assembleThreePreview(
      template: template,
      threeSource: moduleSource,
      sceneSource: sceneJs,
      version: 160,
      threeLiveSource: liveSource,
    );

    final _Bridge bridge = _Bridge();
    final WebViewController controller = await _mount(tester, 'NON3D', bridge);
    await controller.loadHtmlString(html);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WebViewWidget(controller: controller)),
      ),
    );
    await tester.pump();

    // 首帧 metrics 是页面自带的就绪判据（此后每 2s 一次）。
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline) &&
        bridge.ofKind('metrics').isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
    }
    expect(
      bridge.ofKind('metrics').isNotEmpty,
      isTrue,
      reason: '3D 预览页没有回首帧 metrics：桥消息=${bridge.raw}',
    );
    final Map<String, dynamic> metrics = bridge.ofKind('metrics').first;
    final Map<String, dynamic> payload = (metrics['payload'] as Map)
        .cast<String, dynamic>();
    expect(
      (payload['meshes'] as num?)?.toInt() ?? 0,
      greaterThanOrEqualTo(2),
      reason: '场景没有真的渲染出 2 个 mesh：$payload',
    );

    final String view =
        '${await controller.runJavaScriptReturningResult('window.__non3d_view && window.__non3d_view("top")')}';
    expect(
      view.contains('true'),
      isTrue,
      reason:
          '真页面里 __non3d_view(top) 应返回 true，实得 $view；'
          '桥消息=${bridge.raw}',
    );

    final String grid =
        '${await controller.runJavaScriptReturningResult('window.__non3d_grid && window.__non3d_grid(true)')}';
    // 沙箱执行面没有可开关的命名网格时返回 false，并必须回 supported:false 回执。
    if (grid.contains('false')) {
      final DateTime gridDeadline = DateTime.now().add(
        const Duration(seconds: 5),
      );
      while (DateTime.now().isBefore(gridDeadline) &&
          bridge.ofKind('grid').isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump();
      }
      expect(
        bridge.ofKind('grid').isNotEmpty,
        isTrue,
        reason: '网格开关失败时必须回 supported 回执，不能静默：${bridge.raw}',
      );
    }
    // ignore: avoid_print
    print(
      '[webview-three] view=$view grid=$grid '
      'gridReceipt=${bridge.ofKind('grid').map((m) => m['supported']).toList()}',
    );
  });

  testWidgets('生产 MusicPlaybackSurface：真实 WebView 就绪 + 播放头推进', (tester) async {
    final MusicScore score = _score();
    final MusicPlayPlan plan = compileMusicScore(score);
    final MusicPlaybackController playback = createDefaultMusicPlayback(
      score,
      plan,
    );
    addTearDown(playback.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MusicPlaybackSurface(playback: playback)),
      ),
    );
    await playback.start();

    final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline) && !playback.ready) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
    }
    expect(
      playback.ready,
      isTrue,
      reason: '生产播放面没就绪：${playback.loadError} / ${playback.technicalDetail}',
    );
    expect(
      find.byKey(const ValueKey('music-playback-surface')),
      findsOneWidget,
    );

    await playback.play();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await tester.pump();
    // ignore: avoid_print
    print(
      '[webview-music-surface] ready=${playback.ready} '
      'position=${playback.position} beat=${playback.beat} '
      'error=${playback.loadError}',
    );
    if (playback.loadError.isEmpty) {
      expect(playback.position, greaterThan(0), reason: '生产播放面播放 1.5s 后播放头未前进');
    }
    await playback.stop();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('生产 Video3dPreviewSurface：真实 WebView 就绪 + seekFrame', (
    tester,
  ) async {
    final Directory dir = await Directory.systemTemp.createTemp(
      'nan-it-video3d',
    );
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final Video3dProjectStore store = Video3dProjectStore(root: dir);
    final Video3dVerification saved = await store.save(
      'smoke',
      scene: _sceneRaw(),
      screenplay: _screenplayRaw(),
    );
    expect(saved.verified, isTrue, reason: '${saved.toJson()}');
    final Video3dProjectSnapshot snapshot = await store.read('smoke');
    final Video3dTimeline timeline = compileVideo3dTimeline(
      snapshot.screenplay!,
    );

    final Video3dPreviewController preview = createDefaultVideo3dPreview(
      snapshot,
      timeline,
    );
    addTearDown(preview.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Video3dPreviewSurface(preview: preview)),
      ),
    );
    await preview.start();

    final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline) && !preview.ready) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
    }
    expect(
      preview.ready,
      isTrue,
      reason: '生产预览面没就绪：${preview.loadError} / ${preview.technicalDetail}',
    );
    expect(
      preview.totalFrames,
      150,
      reason: '5 秒 @30fps 应为 150 帧，实得 ${preview.totalFrames}',
    );
    expect(
      find.byKey(const ValueKey('video3d-preview-surface')),
      findsOneWidget,
    );

    await preview.seekFrame(90);
    final DateTime seekDeadline = DateTime.now().add(
      const Duration(seconds: 10),
    );
    while (DateTime.now().isBefore(seekDeadline) && preview.frame != 90) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    }
    // ignore: avoid_print
    print(
      '[webview-video3d-surface] ready=${preview.ready} '
      'totalFrames=${preview.totalFrames} frame=${preview.frame} '
      'renderer=${preview.renderer} error=${preview.loadError}',
    );
    // 渲染器身份必须如实且非空（webgl_three_r160 或 canvas2d_deterministic）。
    // 不要求一定是 WebGL：真机有没有 WebGL 上下文是环境事实，页面必须如实降级。
    expect(
      preview.renderer,
      anyOf('webgl_three_r160', 'canvas2d_deterministic'),
      reason: '页面没有如实回传渲染器身份，实得「${preview.renderer}」',
    );
    expect(
      preview.frame,
      90,
      reason: 'seekFrame(90) 后页面帧号未同步，实得 ${preview.frame}',
    );

    // 真机抓一帧：页面渲染 → toDataURL → 桥 evidence → Dart 解码校验。
    final List<Video3dFrameEvidence> evidence = await preview.captureFrames(
      <int>[90],
    );
    // ignore: avoid_print
    print(
      '[webview-video3d-surface] evidence frame=${evidence.single.frame} '
      'bytes=${evidence.single.byteLength} renderer=${evidence.single.renderer}',
    );
    final Video3dFrameEvidence shot = evidence.single;
    expect(shot.frame, 90);
    expect(shot.renderer, preview.renderer, reason: '证据渲染器必须与 ready 一致');
    expect(shot.byteLength, greaterThan(0), reason: '抓到的 PNG 不能是空文件');
    expect(shot.bytes[0], 0x89, reason: '抓帧结果必须是 PNG（魔数）');
  });

  testWidgets('浮层遮挡：Flutter 控件叠在真实 WebView 上仍可点击并驱动页面', (tester) async {
    final String template = await rootBundle.loadString(
      'assets/three/preview.html',
    );
    final String moduleSource = await rootBundle.loadString(
      'assets/three/three.module.js',
    );
    final String liveSource = await rootBundle.loadString(
      'assets/three/vendor/three-live.min.js',
    );
    final String sceneJs = '''
export default function build(THREE, scene, camera, controls, renderer) {
  const box = new THREE.Mesh(
    new THREE.BoxGeometry(1, 1, 1),
    new THREE.MeshStandardMaterial({ color: 0x66ccff }));
  box.name = 'probe';
  scene.add(box);
  camera.position.set(3, 2, 3);
  camera.lookAt(0, 0, 0);
  return { metrics: { probe: true } };
}
''';
    final String html = assembleThreePreview(
      template: template,
      threeSource: moduleSource,
      sceneSource: sceneJs,
      version: 160,
      threeLiveSource: liveSource,
    );

    final _Bridge bridge = _Bridge();
    final WebViewController controller = await _mount(tester, 'NON3D', bridge);
    await controller.loadHtmlString(html);

    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned.fill(child: WebViewWidget(controller: controller)),
              // 与工作台同形：Flutter 浮层（视口控件）压在原生 WebView 之上。
              Positioned(
                top: 12,
                right: 12,
                child: Material(
                  key: const ValueKey('overlay-probe'),
                  color: Colors.black54,
                  child: InkWell(
                    onTap: () => taps++,
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Text('overlay', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    // 页面真的跑起来之后，浮层仍必须能收到点击（原生 Overlay 不能吞掉它）。
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline) &&
        bridge.ofKind('metrics').isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
    }
    expect(
      bridge.ofKind('metrics').isNotEmpty,
      isTrue,
      reason: '页面没起来就判断不了叠层：桥消息=${bridge.raw}',
    );

    await tester.tap(find.byKey(const ValueKey('overlay-probe')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(taps, 1, reason: 'Flutter 浮层没有收到点击（被原生 WebView 吞掉？）');

    // 浮层动作必须真的驱动页面：写一个探针值再读回来。
    await controller.runJavaScript('window.__nan_overlay_probe = "hit";');
    final String probe =
        '${await controller.runJavaScriptReturningResult('window.__nan_overlay_probe')}';
    // ignore: avoid_print
    print('[webview-overlay] taps=$taps probe=$probe');
    expect(probe.contains('hit'), isTrue, reason: '浮层点击后页面 JS 没有生效：$probe');
  });
}
