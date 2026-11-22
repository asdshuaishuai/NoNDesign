// material_ui × flutter_markdown 主题桥。
//
// flutter_markdown（已 discontinued，replacedBy flutter_markdown_plus）的
// `MarkdownStyleSheet.fromTheme(ThemeData)` 形参是 SDK flutter/material 的
// ThemeData；本仓 Widget 层已迁移到 material_ui（package:flutter/material.dart
// 全库 @Deprecated，v3.47.0-0.0.pre 起）——material_ui 的 `Theme.of(context)`
// 返回 material_ui 自己的 ThemeData，两者是不可互换的具体类型，直接
// `fromTheme(Theme.of(context))` 编译报 argument_type_not_assignable。
//
// 这里按 flutter_markdown 0.7.7+1 `fromTheme` 的字段映射逐项复刻
// （textTheme / cardTheme.color / cardColor / primaryColor / dividerColor，
// material_ui 的 ThemeData 是同构 fork，成员一一对应），渲染结果与迁移前
// 逐字段一致——不引新依赖、不改渲染语义。上游 flutter_markdown_plus 若
// 适配 material_ui 的 ThemeData，删掉本文件换回官方工厂即可。
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:material_ui/material_ui.dart';

/// `MarkdownStyleSheet.fromTheme(Theme.of(context))` 的 material_ui 等价物。
MarkdownStyleSheet markdownStyleSheetOf(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  return MarkdownStyleSheet(
    a: const TextStyle(color: Colors.blue),
    p: theme.textTheme.bodyMedium,
    pPadding: EdgeInsets.zero,
    code: theme.textTheme.bodyMedium!.copyWith(
      backgroundColor: theme.cardTheme.color,
      fontFamily: 'monospace',
      fontSize: theme.textTheme.bodyMedium!.fontSize! * 0.85,
    ),
    h1: theme.textTheme.headlineSmall,
    h1Padding: EdgeInsets.zero,
    h2: theme.textTheme.titleLarge,
    h2Padding: EdgeInsets.zero,
    h3: theme.textTheme.titleMedium,
    h3Padding: EdgeInsets.zero,
    h4: theme.textTheme.bodyLarge,
    h4Padding: EdgeInsets.zero,
    h5: theme.textTheme.bodyLarge,
    h5Padding: EdgeInsets.zero,
    h6: theme.textTheme.bodyLarge,
    h6Padding: EdgeInsets.zero,
    em: const TextStyle(fontStyle: FontStyle.italic),
    strong: const TextStyle(fontWeight: FontWeight.bold),
    del: const TextStyle(decoration: TextDecoration.lineThrough),
    blockquote: theme.textTheme.bodyMedium,
    img: theme.textTheme.bodyMedium,
    checkbox: theme.textTheme.bodyMedium!.copyWith(
      color: theme.primaryColor,
    ),
    blockSpacing: 8.0,
    listIndent: 24.0,
    listBullet: theme.textTheme.bodyMedium,
    listBulletPadding: const EdgeInsets.only(right: 4),
    tableHead: const TextStyle(fontWeight: FontWeight.w600),
    tableBody: theme.textTheme.bodyMedium,
    tableHeadAlign: TextAlign.center,
    tablePadding: const EdgeInsets.only(bottom: 4.0),
    tableBorder: TableBorder.all(
      color: theme.dividerColor,
    ),
    tableColumnWidth: const FlexColumnWidth(),
    tableCellsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    tableCellsDecoration: const BoxDecoration(),
    blockquotePadding: const EdgeInsets.all(8.0),
    blockquoteDecoration: BoxDecoration(
      color: Colors.blue.shade100,
      borderRadius: BorderRadius.circular(2.0),
    ),
    codeblockPadding: const EdgeInsets.all(8.0),
    codeblockDecoration: BoxDecoration(
      color: theme.cardTheme.color ?? theme.cardColor,
      borderRadius: BorderRadius.circular(2.0),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(
        top: BorderSide(
          width: 5.0,
          color: theme.dividerColor,
        ),
      ),
    ),
  );
}
