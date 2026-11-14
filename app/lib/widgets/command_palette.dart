import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/keys.dart';
import '../core/store.dart';
import 'common.dart';
import '../core/theme.dart';

Future<void> showCommandPalette(
  BuildContext context, {
  required VoidCallback onNewProject,
  required void Function(String path) onOpenPath,
  required VoidCallback onSettings,
  required VoidCallback onShortcuts,
}) async {
  await showNonDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (context) => _CommandPalette(
      onNewProject: onNewProject,
      onOpenPath: onOpenPath,
      onSettings: onSettings,
      onShortcuts: onShortcuts,
    ),
  );
}

class _CommandPalette extends StatefulWidget {
  final VoidCallback onNewProject;
  final void Function(String path) onOpenPath;
  final VoidCallback onSettings;
  final VoidCallback onShortcuts;

  const _CommandPalette({
    required this.onNewProject,
    required this.onOpenPath,
    required this.onSettings,
    required this.onShortcuts,
  });

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final _search = TextEditingController();
  String _query = '';
  // ↑↓ 选中态：底部文案承诺「↑ ↓ 选择 · ↵ 执行」，回车执行选中行而非固定首行。
  int _selected = 0;
  // build 期缓存过滤结果，键盘处理直接按索引寻址（不重建 actions）。
  List<_Action> _filtered = const [];
  final GlobalKey _selectedKey = GlobalKey();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowDown && key != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    final items = _filtered;
    if (items.isEmpty) return KeyEventResult.ignored;
    setState(() {
      // 循环移动：↓ 到底回第一项，↑ 到顶回最后一项。
      _selected = key == LogicalKeyboardKey.arrowDown
          ? (_selected + 1) % items.length
          : (_selected - 1 + items.length) % items.length;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(ctx, alignment: 0.0, duration: NonMotion.fast, curve: NonMotion.curve);
      }
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final actions = <_Action>[
      _Action('新建项目', '文件', Icons.add_box_outlined, modCombo('⌘N'), () {
        Navigator.pop(context);
        widget.onNewProject();
      }),
      _Action('打开 DDP…', '文件', Icons.folder_open_outlined, modCombo('⌘O'), () {
        Navigator.pop(context);
        widget.onOpenPath('');
      }),
      _Action('保存', '文件', Icons.save_outlined, modCombo('⌘S'), () {
        Navigator.pop(context);
        store.saveProject();
      }),
      _Action('导出 HTML 原型', '文件', Icons.download_outlined, '', () {
        Navigator.pop(context);
        store.exportHtml();
      }),
      _Action('导出当前画板 SVG', '文件', Icons.image_outlined, '', () {
        Navigator.pop(context);
        store.exportSvg();
      }),
      _Action('撤销', '编辑', Icons.undo, modCombo('⌘Z'), () {
        Navigator.pop(context);
        store.undo();
      }),
      _Action('重做', '编辑', Icons.redo, modCombo('⇧⌘Z'), () {
        Navigator.pop(context);
        store.redo();
      }),
      _Action('设计画布', '视图', Icons.dashboard_outlined, modCombo('⌘1'), () {
        Navigator.pop(context);
        store.setView('design');
      }),
      _Action('设计文档', '视图', Icons.description_outlined, modCombo('⌘2'), () {
        Navigator.pop(context);
        store.setView('docs');
      }),
      _Action('MBT 源码', '视图', Icons.code, modCombo('⌘3'), () {
        Navigator.pop(context);
        store.setView('source');
      }),
      _Action('演示模式', '视图', Icons.play_arrow_outlined, modCombo('⌘4'), () {
        Navigator.pop(context);
        store.setView('play');
      }),
      _Action('适配窗口', '视图', Icons.open_in_full, modCombo('⌘0'), () {
        Navigator.pop(context);
        store.setView('design');
        store.bumpFit();
      }),
      _Action('新建空白画板', '画板', Icons.crop_square, '', () {
        Navigator.pop(context);
        store.createBoard();
      }),
      _Action('编辑设计规范', '画板', Icons.palette_outlined, '', () {
        Navigator.pop(context);
        store.setPanel('spec');
        store.setView('docs');
        store.setDocsTab('spec');
      }),
      _Action('打开 NoN 面板', 'Agent', Icons.auto_awesome, '', () {
        Navigator.pop(context);
        store.setRightTab('agent');
      }),
      _Action('设置…', '应用', Icons.settings_outlined, modCombo('⌘,'), () {
        Navigator.pop(context);
        widget.onSettings();
      }),
      _Action('快捷键与命令', '应用', Icons.keyboard_outlined, modCombo('⌘/'), () {
        Navigator.pop(context);
        widget.onShortcuts();
      }),
      for (final t in store.templates.whereType<Map>().take(8))
        _Action('新建模板：${t['name'] ?? t['id']}', '模板', Icons.layers_outlined, '', () {
          Navigator.pop(context);
          store.createBoard(templateId: t['id']?.toString(), name: t['id']?.toString());
        }),
      for (final r in store.recent.take(6))
        _Action('打开：${r['name']}', '最近', Icons.folder_outlined, '', () {
          Navigator.pop(context);
          widget.onOpenPath(r['path']?.toString() ?? '');
        }),
    ];
    final filtered = actions.where((a) {
      if (_query.trim().isEmpty) return true;
      return '${a.label} ${a.group}'.toLowerCase().contains(_query.toLowerCase());
    }).toList();
    _filtered = filtered;
    // _selected 经模运算恒 ≥0；上界防 actions 列表在打开期间缩短。
    final sel = filtered.isEmpty ? 0 : math.min(_selected, filtered.length - 1);

    // canRequestFocus:false 的被动监听节点——搜索框持有焦点，↑↓ 未被它
    // 消费时冒泡到这里移动选中行；esc 关闭仍由对话框自身的 dismiss 处理。
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleKey,
      child: Dialog(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.lineStrong)),
      child: SizedBox(
        width: 620,
        height: 520,
        child: Column(
          children: [
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
              child: Row(
                children: [
                  Icon(Icons.search, size: 16, color: p.ink4),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _search,
                      autofocus: true,
                      style: TextStyle(fontSize: 13, color: p.ink),
                      decoration: InputDecoration(
                        hintText: '搜索命令、模板、最近项目…',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        hintStyle: TextStyle(fontSize: 13, color: p.ink4),
                      ),
                      onChanged: (v) => setState(() {
                        _query = v;
                        _selected = 0; // 过滤集变化，选中回到首行
                      }),
                      onSubmitted: (_) {
                        if (filtered.isNotEmpty) filtered[sel].run();
                      },
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(4)),
                    child: Text('esc', style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(6),
                itemCount: filtered.length,
                itemBuilder: (context, i) {
                  final action = filtered[i];
                  final showGroup = i == 0 || filtered[i - 1].group != action.group;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showGroup)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(9, 6, 9, 3),
                          child: Text(action.group.toUpperCase(),
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1, color: p.ink4)),
                        ),
                      InkWell(
                        key: i == sel ? _selectedKey : null, // 键盘导航后滚动到可见
                        borderRadius: BorderRadius.circular(8),
                        onTap: action.run,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: i == sel ? p.accentSoft : null, // 选中行底色
                          ),
                          child: Row(
                            children: [
                              Icon(action.icon, size: 14, color: p.ink4),
                              const SizedBox(width: 8),
                              Expanded(child: Text(action.label, style: TextStyle(fontSize: 12, color: p.ink2))),
                              if (action.shortcut.isNotEmpty)
                                Text(action.shortcut, style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
              child: Row(
                children: [
                  Text('↑ ↓ 选择 · ↵ 执行', style: TextStyle(fontSize: 10, color: p.ink4)),
                  const Spacer(),
                  Text('NoNDesign Command', style: TextStyle(fontSize: 10, color: p.ink4)),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _Action {
  final String label;
  final String group;
  final IconData icon;
  final String shortcut;
  final VoidCallback run;
  _Action(this.label, this.group, this.icon, this.shortcut, this.run);
}
