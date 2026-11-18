// a2ui 载荷查看器（app/lib/widgets/nonapp_viewer.dart）widget 测试。
//
// 覆盖：① 静态 surface 渲染出节点（零服务依赖）；② 组件错误经 onError
// 呈现在顶部红条；③ 动作回流以通知（ToastService）明示（不触发网络/续跑）。
//
// 文案纪律（docs/copy-glossary.md）：用户可见文字不出现协议名，故断言用
// 「本地预览」/「这个应用的内容不受支持」等用户词，而不是内部信封名。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/theme.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/widgets/nonapp_viewer.dart';
import 'package:nondesign/widgets/toast_host.dart';

final List<Object?> _surface = [
  {
    'version': '1.0',
    'createSurface': {
      'surfaceId': 'demo',
      'catalogId': 'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json',
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

Widget _host(Widget child, {ToastService? toasts}) {
  // 注入独立通知服务：自动消退关闭（autoDismiss: false）——测试结束时不留
  // 挂起的计时器，也不污染全局 ToastService.instance。
  final service = toasts ?? ToastService(autoDismiss: false);
  return ToastScope(
    service: service,
    child: MaterialApp(
      theme: AppTheme.build(dark: true),
      builder: (context, inner) =>
          ToastHost(service: service, child: inner ?? const SizedBox.shrink()),
      home: child,
    ),
  );
}

void main() {
  testWidgets('静态 surface 渲染：标题、文本与按钮都在，且无网络依赖', (tester) async {
    await tester.pumpWidget(_host(NonAppA2uiViewer(title: '清单应用', messages: _surface)));
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('清单应用'), findsOneWidget);
    expect(find.text('旅行偏好'), findsOneWidget);
    expect(find.text('生成行程'), findsOneWidget);
    expect(find.text('本地预览'), findsOneWidget);
    // 无错误条
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('动作回流：点击按钮 → 通知显示动作名与 context', (tester) async {
    await tester.pumpWidget(_host(NonAppA2uiViewer(title: '清单应用', messages: _surface)));
    await tester.pump(const Duration(milliseconds: 60));

    await tester.tap(find.text('生成行程'));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));

    // 通知（ToastService）而不是 ScaffoldMessenger 弹条（术语表 §7）。
    expect(find.textContaining('收到一个操作：submit'), findsOneWidget);
    expect(find.textContaining('Tokyo'), findsOneWidget);
  });

  testWidgets('坏 surface（缺 version / 旧 surfaceUpdate 信封）渲染错误页而不是抛异常', (tester) async {
    // res-3：结构门只认 v1.0 信封；这两类包能过 parse 的旧门但会炸
    // MessageProcessor。查看器必须走错误页（红条 + 空态说明），不得抛。
    final cases = <List<Object?>>[
      [
        {
          'createSurface': {
            'surfaceId': 'no-version',
            'catalogId':
                'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json',
            'components': [
              {'id': 'root', 'component': 'Text', 'text': 'x'},
            ],
          },
        },
      ],
      [
        {
          'version': '1.0',
          'surfaceUpdate': {'surfaceId': 'legacy', 'components': <Object>[]},
        },
      ],
    ];
    for (final messages in cases) {
      await tester.pumpWidget(_host(NonAppA2uiViewer(title: '坏包', messages: messages)));
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.byIcon(Icons.error_outline), findsOneWidget, reason: '错误必须可见');
      expect(find.textContaining('这个应用的内容不受支持'), findsOneWidget);
      expect(find.textContaining('这个应用暂时无法在本机显示'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '不得把结构错抛成渲染异常');
    }
  });

  testWidgets('组件错误经 onError 呈现在顶部红条（不崩页）', (tester) async {
    // 非内置组件目录：a2ui 0.3.0 会在渲染期抛 A2uiValidationError（整页崩），
    // 查看器先过浅层结构门 → 顶部红条 + 空态说明，卡片不构建。
    final broken = <Object?>[
      {
        'version': '1.0',
        'createSurface': {
          'surfaceId': 'broken',
          'catalogId': 'https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json',
          'components': [
            {'id': 'root', 'component': 'CustomChart', 'text': '自定义组件不在内置目录'},
          ],
        },
      },
    ];
    await tester.pumpWidget(_host(NonAppA2uiViewer(title: '坏包', messages: broken)));
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.byIcon(Icons.error_outline), findsOneWidget, reason: '错误必须可见（顶部红条）');
    expect(find.textContaining('这个应用的内容不受支持'), findsOneWidget);
    expect(find.textContaining('这个应用暂时无法在本机显示'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得把结构错抛成渲染异常');
  });
}
