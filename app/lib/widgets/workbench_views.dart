// 工作台四栏目（呈现效果 / 文档 / 规范 / 源码）的共享实现。
//
// 用户裁决 2026-11-27：**所有工作台都按设计模块的四栏目展示**，不再出现独立的
// "项目管理 / IDE" 模块；源码统一在源码栏目里，多文件时以**项目结构树**展示
// （且只展示源码结构，不含产物/缓存）。
//
// 这一层只负责"栏目框架 + 只读呈现"，不持有项目事实源：
//   * 文档 / 规范 / 源码的数据由各工作台从自己的项目快照里取；
//   * 呈现效果由各工作台把**现有**的预览/编辑面作为 child 传进来（行为不变）。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import 'aqua.dart';

/// 四个固定栏目。
enum WorkbenchColumn { present, docs, spec, source }

/// 栏目文案（唯一出口，不要在别处硬编码）。
extension WorkbenchColumnLabel on WorkbenchColumn {
  String get label => switch (this) {
    WorkbenchColumn.present => '呈现效果',
    WorkbenchColumn.docs => '文档',
    WorkbenchColumn.spec => '规范',
    WorkbenchColumn.source => '源码',
  };

  IconData get icon => switch (this) {
    WorkbenchColumn.present => Icons.play_circle_outline,
    WorkbenchColumn.docs => Icons.article_outlined,
    WorkbenchColumn.spec => Icons.rule,
    WorkbenchColumn.source => Icons.code,
  };

  /// 稳定 Key（测试/自动化契约；浅色与深色都保留）。
  String get tabKey => 'workbench-column-$name';
}

/// 一个源码文件（只读展示用）。
final class WorkbenchSourceFile {
  const WorkbenchSourceFile({required this.path, required this.content});

  /// 相对项目根的路径（用于结构树，如 `src/scene.js`）。
  final String path;
  final String content;
}

/// 四栏目的数据袋：由各工作台按自己的项目类型填充。
final class WorkbenchColumnData {
  const WorkbenchColumnData({
    this.docsMarkdown,
    this.specJson,
    this.specSummary,
    this.sourceFiles = const <WorkbenchSourceFile>[],
  });

  /// 人读文档（markdown 子集）；null = 该项目还没有文档。
  final String? docsMarkdown;

  /// 机器可读规范（JSON 对象）；null = 未生成规范。
  final Object? specJson;

  /// 规范栏顶部的摘要句（如"已通过校验 · 4 轨道 / 8 小节"）。
  final String? specSummary;

  /// 源码文件（多文件时按路径成树）。
  final List<WorkbenchSourceFile> sourceFiles;

  bool get hasAnySource => sourceFiles.isNotEmpty;
}

/// 四栏目框架：顶部栏目条 + 内容区。
///
/// [present] 是各工作台原有的呈现/编辑面，切到它时原样渲染（行为零改动）。
class WorkbenchColumns extends StatelessWidget {
  const WorkbenchColumns({
    super.key,
    required this.column,
    required this.onColumnChanged,
    required this.data,
    required this.present,
    this.headerActions,
  });

  final WorkbenchColumn column;
  final ValueChanged<WorkbenchColumn> onColumnChanged;
  final WorkbenchColumnData data;
  final Widget present;

  /// 栏目条右侧附加动作（如刷新/新建），可空。
  final List<Widget>? headerActions;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    final bool aqua = isAquaTheme(context);
    final List<WorkbenchColumn> columns = WorkbenchColumn.values;
    final int index = columns.indexOf(column);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          key: const ValueKey('workbench-columns-bar'),
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: NonSpace.md),
          decoration: BoxDecoration(
            color: aqua ? Colors.white : p.bgElevated,
            border: Border(bottom: BorderSide(color: p.line)),
          ),
          child: Row(
            children: <Widget>[
              AquaSegmentedTabs(
                labels: <String>[
                  for (final WorkbenchColumn c in columns) c.label,
                ],
                icons: <IconData>[
                  for (final WorkbenchColumn c in columns) c.icon,
                ],
                itemKeys: <Key>[
                  for (final WorkbenchColumn c in columns) ValueKey(c.tabKey),
                ],
                selectedIndex: index,
                height: 28,
                compact: true,
                onSelected: (int i) => onColumnChanged(columns[i]),
              ),
              const Spacer(),
              ...?headerActions,
            ],
          ),
        ),
        Expanded(
          child: switch (column) {
            WorkbenchColumn.present => present,
            WorkbenchColumn.docs => WorkbenchDocsPanel(
              markdown: data.docsMarkdown,
            ),
            WorkbenchColumn.spec => WorkbenchSpecPanel(
              json: data.specJson,
              summary: data.specSummary,
            ),
            WorkbenchColumn.source => WorkbenchSourcePanel(
              files: data.sourceFiles,
            ),
          },
        ),
      ],
    );
  }
}

/// 文档栏：只读渲染 markdown 子集（标题/列表/代码块/段落）。
class WorkbenchDocsPanel extends StatelessWidget {
  const WorkbenchDocsPanel({super.key, required this.markdown});

  final String? markdown;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    final String? text = markdown;
    if (text == null || text.trim().isEmpty) {
      return _EmptyColumn(
        key: const ValueKey('workbench-docs-empty'),
        icon: Icons.article_outlined,
        title: '还没有文档',
        note: '让 NaN 先写需求/设计文档；文档与项目一起保存。',
      );
    }
    final List<String> lines = text.split('\n');
    return ListView.builder(
      key: const ValueKey('workbench-docs-body'),
      padding: const EdgeInsets.fromLTRB(
        NonSpace.xl,
        NonSpace.lg,
        NonSpace.xl,
        NonSpace.xxl,
      ),
      itemCount: lines.length,
      itemBuilder: (BuildContext context, int i) {
        final String line = lines[i];
        if (line.startsWith('# ')) {
          return Padding(
            padding: const EdgeInsets.only(bottom: NonSpace.md),
            child: Text(
              line.substring(2),
              style: NonType.of(
                NonType.title,
                color: p.ink,
                weight: FontWeight.w700,
              ),
            ),
          );
        }
        if (line.startsWith('## ') || line.startsWith('### ')) {
          final String t = line.replaceFirst(RegExp(r'^#+\s*'), '');
          return Padding(
            padding: const EdgeInsets.only(
              top: NonSpace.lg,
              bottom: NonSpace.sm,
            ),
            child: Text(
              t,
              style: NonType.of(
                NonType.subtitle,
                color: p.ink,
                weight: FontWeight.w600,
              ),
            ),
          );
        }
        if (line.trim().isEmpty) {
          return const SizedBox(height: NonSpace.sm);
        }
        if (line.trimLeft().startsWith('- ') ||
            line.trimLeft().startsWith('* ')) {
          return Padding(
            padding: const EdgeInsets.only(bottom: NonSpace.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('·', style: NonType.of(NonType.body, color: p.accent)),
                const SizedBox(width: NonSpace.sm),
                Expanded(
                  child: Text(
                    line.trimLeft().substring(2),
                    style: NonType.of(
                      NonType.body,
                      color: p.ink2,
                      height: NonType.lineBody,
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        if (line.trimLeft().startsWith('```')) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: NonSpace.xs),
          child: Text(
            line,
            style: NonType.of(
              NonType.body,
              color: p.ink2,
              height: NonType.lineBody,
            ),
          ),
        );
      },
    );
  }
}

/// 规范栏：顶部摘要 + 只读 JSON。
class WorkbenchSpecPanel extends StatelessWidget {
  const WorkbenchSpecPanel({super.key, required this.json, this.summary});

  final Object? json;
  final String? summary;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    final Object? value = json;
    if (value == null) {
      return _EmptyColumn(
        key: const ValueKey('workbench-spec-empty'),
        icon: Icons.rule,
        title: '还没有规范',
        note: '规范是机器可校验的事实源；生成项目时会一起写入。',
      );
    }
    String pretty;
    try {
      pretty = const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      pretty = value.toString();
    }
    return Column(
      key: const ValueKey('workbench-spec-body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (summary != null && summary!.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: NonSpace.md,
              vertical: NonSpace.sm,
            ),
            decoration: BoxDecoration(
              color: p.accentSoft,
              border: Border(bottom: BorderSide(color: p.line)),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.verified_outlined,
                  size: NonType.body,
                  color: p.accent,
                ),
                const SizedBox(width: NonSpace.sm),
                Expanded(
                  child: Text(
                    summary!,
                    style: NonType.of(NonType.body, color: p.ink2),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(NonSpace.md),
            child: SelectableText(
              pretty,
              style: NonType.of(
                NonType.body,
                color: p.ink2,
                height: NonType.lineBody,
              ).copyWith(fontFamily: 'monospace'),
            ),
          ),
        ),
      ],
    );
  }
}

/// 源码栏：按路径成树（只源代码结构），点文件看只读内容。
class WorkbenchSourcePanel extends StatefulWidget {
  const WorkbenchSourcePanel({super.key, required this.files});

  final List<WorkbenchSourceFile> files;

  @override
  State<WorkbenchSourcePanel> createState() => _WorkbenchSourcePanelState();
}

class _WorkbenchSourcePanelState extends State<WorkbenchSourcePanel> {
  int _selected = 0;

  @override
  void didUpdateWidget(WorkbenchSourcePanel old) {
    super.didUpdateWidget(old);
    if (_selected >= widget.files.length) {
      _selected = widget.files.isEmpty ? 0 : widget.files.length - 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    if (widget.files.isEmpty) {
      return _EmptyColumn(
        key: const ValueKey('workbench-source-empty'),
        icon: Icons.code,
        title: '还没有源码',
        note: '源码是这个世界的事实源；让 NaN 生成后会出现在这里。',
      );
    }
    final WorkbenchSourceFile file = widget.files[_selected];
    return Row(
      key: const ValueKey('workbench-source-body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: 220,
          child: Container(
            decoration: BoxDecoration(
              color: p.panel2,
              border: Border(right: BorderSide(color: p.line)),
            ),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: NonSpace.xs),
              itemCount: widget.files.length,
              itemExtent: 28,
              itemBuilder: (BuildContext context, int i) {
                final WorkbenchSourceFile f = widget.files[i];
                final bool active = i == _selected;
                final String name = f.path.split('/').last;
                final int depth = f.path.split('/').length - 1; // 目录层级缩进
                return InkWell(
                  key: ValueKey('workbench-source-file:${f.path}'),
                  onTap: () => setState(() => _selected = i),
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: NonSpace.sm + depth * NonSpace.md,
                      right: NonSpace.sm,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.description_outlined,
                          size: NonType.body,
                          color: active ? p.accent : p.ink4,
                        ),
                        const SizedBox(width: NonSpace.xs),
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NonType.of(
                              NonType.body,
                              color: active ? p.accent : p.ink2,
                              weight: active
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Expanded(
          child: Container(
            color: p.panel,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: NonSpace.md),
                  decoration: BoxDecoration(
                    color: p.bgElevated,
                    border: Border(bottom: BorderSide(color: p.line)),
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          file.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NonType.of(NonType.caption, color: p.ink3),
                        ),
                      ),
                      Text(
                        '${file.content.length} 字符',
                        style: NonType.of(NonType.micro, color: p.ink4),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    key: const ValueKey('workbench-source-content'),
                    padding: const EdgeInsets.all(NonSpace.md),
                    child: SelectableText(
                      file.content,
                      style: NonType.of(
                        NonType.body,
                        color: p.ink2,
                        height: NonType.lineBody,
                      ).copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyColumn extends StatelessWidget {
  const _EmptyColumn({
    super.key,
    required this.icon,
    required this.title,
    required this.note,
  });

  final IconData icon;
  final String title;
  final String note;

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NonSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 28, color: p.ink4),
            const SizedBox(height: NonSpace.md),
            Text(
              title,
              style: NonType.of(
                NonType.subtitle,
                color: p.ink,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: NonSpace.sm),
            Text(
              note,
              textAlign: TextAlign.center,
              style: NonType.of(
                NonType.body,
                color: p.ink3,
                height: NonType.lineBody,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
