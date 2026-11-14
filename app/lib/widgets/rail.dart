import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';

class Rail extends StatelessWidget {
  const Rail({super.key});

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
