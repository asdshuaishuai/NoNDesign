// 主题对比度守门（2026-11-27，来自 ui-ux-pro-max 的 WCAG 规则）。
//
// 规则：正文/次要文字对比度 >= 4.5:1；强调色作为文字使用时同样 >= 4.5:1。
// 双主题独立校验（浅色值不能假设深色可用），并覆盖所有面板层级表面——
// 历史上 ink4 在 panel2/panel3、浅色 ink3/ink4 在白面上都曾低于门槛。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:nondesign/core/theme.dart';
import 'package:nondesign/widgets/aqua.dart';

void main() {
  final List<(String, NonPalette)> palettes = <(String, NonPalette)>[
    ('dark', NonPalette.dark),
    ('aqua(light)', NonPalette.light),
  ];

  for (final (String name, NonPalette p) in palettes) {
    group('$name 文字对比度', () {
      final Map<String, Color> surfaces = <String, Color>{
        'bg': p.bg,
        'bgElevated': p.bgElevated,
        'panel': p.panel,
        'panel2': p.panel2,
        'panel3': p.panel3,
      };
      final Map<String, Color> inks = <String, Color>{
        'ink': p.ink,
        'ink2': p.ink2,
        'ink3': p.ink3,
        'ink4': p.ink4,
      };

      for (final MapEntry<String, Color> s in surfaces.entries) {
        for (final MapEntry<String, Color> i in inks.entries) {
          test('${i.key} on ${s.key} >= 4.5:1', () {
            final double ratio = AquaMetrics.contrastRatio(i.value, s.value);
            expect(
              ratio,
              greaterThanOrEqualTo(4.5),
              reason:
                  '${i.key} 在 ${s.key} 上只有 ${ratio.toStringAsFixed(2)}:1，'
                  '低于 WCAG 正文门槛 4.5:1',
            );
          });
        }
      }
    });

    group('$name 语义色对比度', () {
      final Map<String, Color> semantics = <String, Color>{
        'accent': p.accent,
        'accent2': p.accent2,
        'success': p.success,
        'warn': p.warn,
        'danger': p.danger,
      };
      for (final MapEntry<String, Color> e in semantics.entries) {
        test('${e.key} 作为文字 ≥ 4.5:1（panel / bgElevated）', () {
          for (final Color bg in <Color>[p.panel, p.bgElevated, p.bg]) {
            final double ratio = AquaMetrics.contrastRatio(e.value, bg);
            expect(
              ratio,
              greaterThanOrEqualTo(4.5),
              reason:
                  '${e.key} 在背景 ${bg.toARGB32().toRadixString(16)} 上只有 '
                  '${ratio.toStringAsFixed(2)}:1',
            );
          }
        });
      }
    });
  }

  test('灰色层级单调：ink 最亮/最深，ink4 最弱', () {
    for (final NonPalette p in <NonPalette>[
      NonPalette.dark,
      NonPalette.light,
    ]) {
      final double l1 = AquaMetrics.contrastRatio(p.ink, p.panel);
      final double l4 = AquaMetrics.contrastRatio(p.ink4, p.panel);
      expect(l1, greaterThan(l4));
    }
  });
}
