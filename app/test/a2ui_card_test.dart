// A2uiCard（S0 渲染底座）widget 测试。
// 覆盖：① 静态 surface JSON 渲染；② 动作回流回调（事件动作 + RPC 通道）；
// ③ 流式全链（a2ui_agent 提示词 + openContinuingStream 解析 + 灌 chunk +
// surface 渲染），传输为注入的假流——零网络，不绑 Firebase。
// 格式夹具与卡片同源（A2uiCard.format），保证「教什么格式就喂什么格式」。
import 'dart:async';

import 'package:a2ui_agent/a2ui_agent.dart';
import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/basic_catalog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/a2ui_card.dart';

/// v1.0 basic 目录（与卡片初始化同一构造；openUrl 不传 = 禁用）。
final _catalog = basicCatalog(locale: 'zh-CN');

/// 与卡片相同协商路径的 agent 处理器——只为出流式夹具（decompile+wrap）。
A2uiRequestProcessor _fixtureProcessor() => A2uiGenerator(
      catalogs: [CatalogConfig(_catalog)],
      inferenceFormatFactory: A2uiCard.format,
    ).createProcessor(A2uiRendererCapabilities.forCatalogIds(
      [BasicCatalog.v1_0Id],
      version: A2uiProtocolVersion.v1_0,
    ));

/// 静态路径的 surface 消息 JSON：一列带动作按钮的卡片。
final List<Object?> _surfaceMessages = [
  {
    'version': '1.0',
    'createSurface': {
      'surfaceId': 'demo',
      'catalogId':
          'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json',
      'components': [
        {'id': 'root', 'component': 'Column', 'children': ['title', 'btn']},
        {'id': 'title', 'component': 'Text', 'text': '旅行偏好'},
        {
          'id': 'btn',
          'component': 'Button',
          'child': 'btnLabel',
          'action': {
            'event': {'name': 'submit', 'context': {'place': 'Tokyo'}},
          },
        },
        {'id': 'btnLabel', 'component': 'Text', 'text': '生成行程'},
      ],
    },
  },
];

Widget _host(Widget card, {bool dark = true}) => MaterialApp(
      theme: AppTheme.build(dark: dark),
      home: Scaffold(body: SingleChildScrollView(child: card)),
    );

void main() {
  testWidgets('静态 surface JSON 渲染：文本与按钮组件出现在卡片里', (tester) async {
    await tester.pumpWidget(_host(A2uiCard.messages(messages: _surfaceMessages)));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('旅行偏好'), findsOneWidget);
    expect(find.text('生成行程'), findsOneWidget);
    // 卡片 chrome 取 NonPalette：panel 底（Scaffold 自带的 Material 不是
    // panel 色，按颜色定位卡片自身的 Material）。
    final palette = tester.element(find.text('旅行偏好')).palette;
    final cardMaterial = tester.widget<Material>(
      find.byWidgetPredicate(
        (w) => w is Material && w.color == palette.panel,
      ),
    );
    expect(cardMaterial.color, palette.panel);
  });

  testWidgets('静态 surface JSON 渲染：流式路径字段的卡片不误显错误/进度', (tester) async {
    await tester.pumpWidget(_host(A2uiCard.messages(messages: _surfaceMessages)));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('生成中…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('offlineOnly：Image 的 http 地址不生成网络图（渲染期兜底）', (tester) async {
    final messages = <Object?>[
      {
        'version': '1.0',
        'createSurface': {
          'surfaceId': 'offline',
          'catalogId':
              'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json',
          'components': [
            {
              'id': 'root',
              'component': 'Image',
              'url': 'https://evil.example/x.png',
              'description': '远程图',
            },
          ],
        },
      },
    ];
    await tester.pumpWidget(_host(A2uiCard.messages(messages: messages, offlineOnly: true)));
    await tester.pump(const Duration(milliseconds: 50));

    // 官方 buildImage 会为 http(s) 直接构造 Image.network；离线目录把它换成
    // broken-image 占位，因此树里不应出现任何 Image（也不会有网络请求）。
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.broken_image), findsOneWidget);
  });

  testWidgets('动作回流：点击按钮 → onAction 收到事件名与 context', (tester) async {
    final actions = <A2uiRendererAction>[];
    await tester.pumpWidget(_host(A2uiCard.messages(
      messages: _surfaceMessages,
      onAction: actions.add,
    )));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('生成行程'));
    // dispatchAction 是异步链（binder → surface.dispatchAction → emit）。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(actions, hasLength(1));
    expect(actions.single.name, 'submit');
    expect(actions.single.surfaceId, 'demo');
    expect(actions.single.context['place'], 'Tokyo');
  });

  testWidgets('流式全链：假传输灌 Direct JSON 块 → 文本与 surface 边流边渲',
      (tester) async {
    // 夹具：用与卡片同源的 agent 处理器，把消息 decompile 成 Direct JSON
    // payload，再 wrap 成完整 LLM 回复（文本 + <a2ui-json> 块）。
    final fixture = _fixtureProcessor();
    final payload = fixture.parser.decompile([
      ..._surfaceMessages.map(
        (m) => AgentToRendererMessage.fromJson(
          (m as Map).cast<String, Object?>(),
        ),
      ),
    ]);
    final response = fixture.parser.wrap([
      const TextPart('好的，这是你要的偏好卡片。'),
      RawA2uiPart(payload),
    ]);
    // 按 12 字符切片模拟流式到达。
    final chunks = <String>[
      for (var i = 0; i < response.length; i += 12)
        response.substring(i, (i + 12).clamp(0, response.length)),
    ];

    final deltas = <String>[];
    await tester.pumpWidget(_host(A2uiCard(
      instruction: '给我一张旅行偏好卡',
      transport: (_) async => Stream.fromIterable(chunks),
      onTextChunk: deltas.add,
    )));
    // 每个 pump 推进一批微任务事件，逐块 feed → 文本与 surface 先后出现。
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('好的，这是你要的偏好卡片。'), findsOneWidget);
    expect(find.text('旅行偏好'), findsOneWidget);
    expect(find.text('生成行程'), findsOneWidget);
    expect(deltas.join(), '好的，这是你要的偏好卡片。');
    expect(find.text('生成中…'), findsNothing);
  });

  testWidgets('静态路径：坏 surface 在 initState 抛错也不崩页（错误内联）', (tester) async {
    // 缺 version 的信封会让 a2ui_core 的 processMessages 同步抛
    // A2uiValidationError——修复前异常从 initState 冒泡，打开不受信 .nonapp
    // 直接错误页。卡片必须把它降级为卡内错误行 + onError 回流。
    final errors = <Object>[];
    await tester.pumpWidget(_host(A2uiCard.messages(
      messages: [
        {
          'createSurface': {
            'surfaceId': 'broken',
            'catalogId':
                'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json',
            'components': [
              {'id': 'root', 'component': 'Text', 'text': 'x'},
            ],
          },
        },
      ],
      onError: errors.add,
    )));
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull, reason: '异常不得冒泡出卡片');
    expect(find.byType(A2uiCard), findsOneWidget);
    expect(find.textContaining('surface 消息无效'), findsOneWidget);
    expect(errors, isNotEmpty);
  });

  testWidgets('流式全链：动作同样回流 + 传输失败不炸卡（错误内联）', (tester) async {
    final fixture = _fixtureProcessor();
    final payload = fixture.parser.decompile([
      ..._surfaceMessages.map(
        (m) => AgentToRendererMessage.fromJson(
          (m as Map).cast<String, Object?>(),
        ),
      ),
    ]);
    final response = fixture.parser.wrap([RawA2uiPart(payload)]);
    final actions = <A2uiRendererAction>[];

    await tester.pumpWidget(_host(A2uiCard(
      instruction: '给我一张旅行偏好卡',
      transport: (_) async => Stream.fromIterable([
        response.substring(0, 30),
        response.substring(30),
      ]),
      onAction: actions.add,
    )));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // surface 已渲，动作回流同静态路径。
    expect(find.text('生成行程'), findsOneWidget);
    await tester.tap(find.text('生成行程'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(actions.single.name, 'submit');

    // 传输抛错：新卡片渲染错误文本而非崩溃（运行错误内联 + onError 通道）。
    // 卡片是 run-once-per-mount（聊天流里每张卡自带唯一 key——同一类型无
    // key 会被 pumpWidget 复用 State、initState 不再执行）。
    final errors = <Object>[];
    await tester.pumpWidget(_host(A2uiCard(
      key: const ValueKey('error-card'),
      instruction: '再来一张',
      transport: (_) => Future.error(StateError('gateway down')),
      onError: errors.add,
    )));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(A2uiCard), findsOneWidget);
    expect(find.textContaining('gateway down'), findsOneWidget);
    expect(errors, isNotEmpty);
  });
}
