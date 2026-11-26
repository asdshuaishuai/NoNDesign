// 设计令牌守门（2026-11-26 引入）。
//
// 背景：`lib/widgets` 里曾有 884 处硬编码 `fontSize`，横跨 16 个档位，导致同一
// 层级的标签在不同工作台里大小不一致；间距也散落 3/5/6/7/9 之类随手值。
//
// 规则：
//  * 新代码只允许用 `NonType` / `NonSpace` / `NonRadius` 常量；
//  * 裸 `fontSize:` 字面量数量是**棘轮**：只许下降，不许上升。迁移一批就把
//    [rawFontSizeCeiling] 调低到新数量，并在提交说明里写清楚。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/theme.dart';

/// 棘轮上限：`lib/widgets/**` 中 `fontSize: <数字>` 的出现次数。
/// 2026-11-26 首次盘点为 870；每完成一个工作台的令牌迁移就下调。
const int rawFontSizeCeiling = 870;

void main() {
  test('排版尺度严格递增且覆盖 8 个档位', () {
    const List<double> scale = <double>[
      NonType.micro,
      NonType.caption,
      NonType.body,
      NonType.bodyStrong,
      NonType.subtitle,
      NonType.title,
      NonType.display,
      NonType.hero,
    ];
    expect(scale.length, 8);
    for (int i = 1; i < scale.length; i++) {
      expect(scale[i], greaterThan(scale[i - 1]), reason: '档位 $i 必须大于前一档');
    }
    expect(NonType.micro, 10);
    expect(NonType.hero, 34);
  });

  test('间距与圆角尺度严格递增', () {
    const List<double> space = <double>[
      NonSpace.xxs,
      NonSpace.xs,
      NonSpace.sm,
      NonSpace.md,
      NonSpace.lg,
      NonSpace.xl,
      NonSpace.xxl,
    ];
    for (int i = 1; i < space.length; i++) {
      expect(space[i], greaterThan(space[i - 1]));
    }
    expect(NonRadius.sm, lessThan(NonRadius.md));
    expect(NonRadius.md, lessThan(NonRadius.lg));
  });

  test('裸 fontSize 字面量不超过棘轮上限（只许下降）', () {
    final Directory widgets = Directory('lib/widgets');
    expect(widgets.existsSync(), isTrue, reason: '请在 app/ 目录下运行');
    final RegExp raw = RegExp(r'fontSize: [0-9.]+');
    int count = 0;
    final Map<String, int> perFile = <String, int>{};
    for (final FileSystemEntity entity in widgets.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String source = entity.readAsStringSync();
      final int hits = raw.allMatches(source).length;
      if (hits > 0) {
        count += hits;
        perFile[entity.path] = hits;
      }
    }
    expect(
      count,
      lessThanOrEqualTo(rawFontSizeCeiling),
      reason:
          '裸 fontSize 数量上升了（现 $count，上限 $rawFontSizeCeiling）。'
          '新增/修改界面请用 NonType 常量（lib/core/theme.dart）。'
          '迁移完成后把上限调低。最多的文件：${_top(perFile)}',
    );
  });
}

String _top(Map<String, int> perFile) {
  final List<MapEntry<String, int>> sorted = perFile.entries.toList()
    ..sort(
      (MapEntry<String, int> a, MapEntry<String, int> b) =>
          b.value.compareTo(a.value),
    );
  return sorted
      .take(5)
      .map((MapEntry<String, int> e) => '${e.key}=${e.value}')
      .join(', ');
}
