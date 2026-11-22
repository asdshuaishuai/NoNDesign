/// Real WKWebView smoke for the full-platform engine host.
///
/// `flutter test` cannot create platform views, so this runs as an
/// integration test on a real macOS app process. It proves the offscreen
/// `webview_all` session can boot the classic artifact, pass the ABI probe,
/// render a document, apply an op through the human gate and reuse the
/// document session — the same contract the Node probe checks, but through the
/// actual WebView bridge.
library;

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_wkwebview/webview_all_wkwebview.dart';

import 'package:nondesign/core/engine/engine_service.dart';

const String _seedDoc = '---\nmoonviz:\n  format: visual-document\n  revision: 1\n  entry: __seed\n---\n\n'
    '# __seed\n\n'
    '<!-- moonviz:artboard __seed -->\n'
    '```mbt\n'
    'fn visual___seed() -> @decl.Prototype {\n'
    '  let page = @decl.prototype(name="__seed", width=390.0, height=844.0)\n'
    '  page\n'
    '}\n'
    '```\n';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('offscreen WebView boots the classic engine and serves calls', (tester) async {
    if (Platform.isMacOS && WebViewPlatform.instance == null) {
      WebKitWebViewPlatform.registerWith();
    }
    final data = await rootBundle.load('assets/engine/moonviz.wasm');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

    // Exercise the production entry point: startAuto must pick the WebView
    // host, not silently fall back to wasm_run.
    final service = await EngineService.startAuto(wasmBytes: bytes);
    addTearDown(service.dispose);
    expect(service.isReady, isTrue, reason: service.startupError ?? '');

    final runtime = service.runtime!;
    expect(runtime.runtime, 'webview');
    expect(runtime.exportCount, greaterThanOrEqualTo(70));
    expect(runtime.sessionExportCount, greaterThanOrEqualTo(50));
    expect(runtime.fuelSupported, isFalse, reason: 'WebAssembly has no fuel metering');

    final rendered = await service.render(_seedDoc);
    expect(rendered['ok'], isTrue, reason: '$rendered');
    expect((rendered['artboards'] as List?)?.isNotEmpty, isTrue);

    final applied = await service.apply(
      _seedDoc,
      'place __seed button web_probe - 30 110 140 44 text=下一页',
      gate: 'human',
    );
    expect(applied['ok'], isTrue, reason: '$applied');
    final mbt = applied['mbt'] as String;
    expect(mbt, contains('web_probe'));

    final boards = await service.session(mbt, 'session_list_artboards');
    expect(boards['ok'], isTrue, reason: '$boards');

    final stats = await service.stats();
    expect(stats.calls, greaterThan(2));
    expect(stats.sessionMisses, greaterThanOrEqualTo(1));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
