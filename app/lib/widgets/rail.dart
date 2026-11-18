import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/store.dart';
import '../core/theme.dart';

class Rail extends StatelessWidget {
  const Rail({super.key, this.onHistory});

  /// 窄屏（无左栏）点「历史」时打开可见面板的出口。
  ///
  /// 手机宽度下 LeftPanel 不渲染，只把 panel 置成 history 会「图标亮着、
  /// 主面不变」（审查 nav-4）；工作区在这里接一块底部面板。
  final VoidCallback? onHistory;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final items = [
      ('project', Icons.dashboard_customize_outlined, '设计'),
      ('docs', Icons.description_outlined, '文档'),
      ('spec', Icons.palette_outlined, '规范'),
      ('history', Icons.history, '历史'),
    ];
    return Container(
      width: 58,
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(right: BorderSide(color: p.line)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Column(
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Material(
                color: store.panel == item.$1 ? p.accentSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () {
                    store.setPanel(item.$1);
                    if (item.$1 == 'docs' || item.$1 == 'spec') {
                      store.setView('docs');
                    } else if (item.$1 == 'project') {
                      store.setView('design');
                    } else if (item.$1 == 'history') {
                      // 有左栏时面板就地可见；窄屏交给宿主打开底部面板。
                      onHistory?.call();
                    }
                  },
                  child: SizedBox(
                    width: 42,
                    height: 46,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(item.$2, size: 17, color: store.panel == item.$1 ? p.accent : p.ink3),
                        const SizedBox(height: 4),
                        Text(item.$3,
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color: store.panel == item.$1 ? p.accent : p.ink3)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}
