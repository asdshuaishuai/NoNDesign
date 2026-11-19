/// 右侧「检查」面板：按当前工作区分派。
///
/// 设计检查器（[Inspector]，part of `right_panel.dart`）只对设计画板有意义。
/// 3D / 视频 / 热应用 / 演示 / 作品集下必须换成各自真正有用的检查内容，
/// 否则用户会在 3D 工作台看到「页型判定」「本板交互」这类完全不适用的控件。
///
/// 约定：
/// * tab id 仍是 `inspect`（持久化值不能变），变的只是文案/图标与正文；
/// * 设计 / 文档 / 源码 / 未知视图原样返回现有 [Inspector]，设计检查不退化；
/// * 分支只读 store 与本地库，不写项目、不触发 run；
/// * 文案不得出现内部代号（术语门：`copy_guard_test.dart`）。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/nonapp_library.dart';
import '../core/store.dart';
import '../core/theme.dart';
import '../core/video_clip.dart';
import '../core/video_samples.dart';
import 'common.dart';
// Inspector / AgentPanel 是 right_panel.dart 的 part——只能经库入口导入。
import 'right_panel.dart';

// ---------------------------------------------------------------------------
// tab 文案 / 图标（展开栏与 44px 折叠条共用，随工作区变）
// ---------------------------------------------------------------------------

/// 当前工作区下「检查」tab 的文案。
String inspectTabLabelForView(String view) => switch (view) {
      'plugin:three' => '3D 检查',
      'plugin:video' => '视频检查',
      'plugin:hotapp' => '应用检查',
      'play' => '演示检查',
      'portfolio' => '作品集检查',
      _ => '检查',
    };

/// 当前工作区下「检查」tab 的图标。
IconData inspectTabIconForView(String view) => switch (view) {
      'plugin:three' => Icons.view_in_ar_outlined,
      'plugin:video' => Icons.movie_outlined,
      'plugin:hotapp' => Icons.widgets_outlined,
      _ => Icons.center_focus_strong_outlined,
    };

// ---------------------------------------------------------------------------
// 分派外壳
// ---------------------------------------------------------------------------

/// 检查器外壳：按 `store.view` 分派到对应工作区的检查内容。
class WorkspaceInspector extends StatelessWidget {
  const WorkspaceInspector({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final (String branchKey, Widget branch) = switch (store.view) {
      'plugin:three' => ('wi-three', const _ThreeInspector()),
      'plugin:video' => ('wi-video', const _VideoInspector()),
      'plugin:hotapp' => ('wi-hotapp', const _HotappInspector()),
      'play' => ('wi-play', const _PlayInspector()),
      'portfolio' => ('wi-portfolio', const _PortfolioInspector()),
      // 设计 / 文档 / 源码 / 项目入口 / 未知视图：原设计检查器兜底。
      _ => ('wi-design', const Inspector()),
    };
    return KeyedSubtree(
      key: const ValueKey('workspace-inspector'),
      child: KeyedSubtree(key: ValueKey(branchKey), child: branch),
    );
  }
}

/// Workspace 自带的 348 右栏（NaN / 检查）挂载外壳。
///
/// 桌面壳把右侧唯一窄栏交给 `ChatRail`；独立 Workspace（手机经典主面、
/// 测试）仍渲染这块 348 面板。检查槽位换成分派组件，tab 文案/图标也跟
/// 工作区走——与窄栏是同一套分派，不再各写一份。
class WorkspaceRightPanel extends StatelessWidget {
  const WorkspaceRightPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final view = context.watch<AppStore>().view;
    return RightPanel(
      inspectLabel: inspectTabLabelForView(view),
      inspectIcon: inspectTabIconForView(view),
      inspectBody: const WorkspaceInspector(),
    );
  }
}

// ---------------------------------------------------------------------------
// 3D
// ---------------------------------------------------------------------------

class _ThreeInspector extends StatelessWidget {
  const _ThreeInspector();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final project = store.settings.threeProjectName.trim();
    if (project.isEmpty) {
      return Center(
        child: EmptyHint(
          icon: Icons.view_in_ar_outlined,
          title: '3D 场景还没打开',
          detail: '去 3D 工作台新建或打开一个场景；这里会显示项目名、场景状态与生成入口。',
          action: _WiPrimary(
            key: const ValueKey('wi-open-workspace'),
            label: '去 3D 工作台',
            icon: Icons.arrow_forward,
            onTap: () => store.setView('plugin:three'),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _WiHeader(
          icon: Icons.view_in_ar_outlined,
          title: '3D 场景',
          subtitle: project,
          trailing: Pill(label: '已打开', color: p.success),
        ),
        const SizedBox(height: 12),
        _WiCard(
          children: [
            _WiRow(label: '项目名', value: project),
            const SizedBox(height: 6),
            _WiRow(
              label: '场景状态',
              trailing: Pill(label: '已打开', color: p.success, background: p.panel3),
            ),
            const SizedBox(height: 8),
            Text(
              '切到 3D 工作台会回到这个场景；预览、测量与修复都在那边进行。',
              style: TextStyle(fontSize: 10, height: 1.5, color: p.ink4),
            ),
          ],
        ),
        _WiCard(
          children: [
            const SectionLabel('生成入口'),
            const SizedBox(height: 6),
            Text(
              '要新建场景，去 3D 工作台描述需求：先出规范，再逐层生成场景与代码。',
              style: TextStyle(fontSize: 10, height: 1.5, color: p.ink3),
            ),
          ],
        ),
        _WiPrimary(
          key: const ValueKey('wi-open-workspace'),
          label: '去 3D 工作台',
          icon: Icons.arrow_forward,
          onTap: () => store.setView('plugin:three'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 视频
// ---------------------------------------------------------------------------

/// 内置示例的播放规格（从时间线脚本静态解析，不触发渲染）。
class _VideoSampleStats {
  const _VideoSampleStats({
    required this.fps,
    required this.seconds,
    required this.frames,
    required this.width,
    required this.height,
  });

  final int fps;
  final double seconds;
  final int frames;
  final int width;
  final int height;

  static final Map<String, _VideoSampleStats?> _cache = <String, _VideoSampleStats?>{};

  static _VideoSampleStats? of(VideoSampleInfo sample) {
    if (_cache.containsKey(sample.id)) return _cache[sample.id];
    _VideoSampleStats? stats;
    try {
      final decoded = jsonDecode(sample.timelineJson);
      if (decoded is Map) {
        final fps = (decoded['fps'] is num) ? (decoded['fps'] as num).toInt() : 0;
        final scenes = decoded['scenes'];
        var seconds = 0.0;
        if (scenes is List) {
          for (final scene in scenes) {
            if (scene is Map && scene['duration'] is num) {
              seconds += (scene['duration'] as num).toDouble();
            }
          }
        }
        if (fps > 0 && seconds > 0) {
          stats = _VideoSampleStats(
            fps: fps,
            seconds: seconds,
            frames: (seconds * fps).floor(),
            width: (decoded['width'] is num) ? (decoded['width'] as num).toInt() : 0,
            height: (decoded['height'] is num) ? (decoded['height'] as num).toInt() : 0,
          );
        }
      }
    } catch (_) {
      stats = null;
    }
    _cache[sample.id] = stats;
    return stats;
  }
}

class _VideoInspector extends StatelessWidget {
  const _VideoInspector();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    if (videoSamples.isEmpty) {
      return Center(
        child: EmptyHint(
          icon: Icons.movie_outlined,
          title: '还没有视频示例',
          detail: '去视频工作台选择或新建一个示例；这里会显示示例名、帧率与片长。',
          action: _WiPrimary(
            key: const ValueKey('wi-open-workspace'),
            label: '打开视频工作台',
            icon: Icons.arrow_forward,
            onTap: () => store.setView('plugin:video'),
          ),
        ),
      );
    }
    final clipId = store.settings.videoClipId;
    if (clipId.isNotEmpty) {
      return _VideoClipInspector(clipId: clipId);
    }
    final idx = store.settings.videoSampleIdx.clamp(0, videoSamples.length - 1);
    final sample = videoSamples[idx];
    final stats = _VideoSampleStats.of(sample);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _WiHeader(
          icon: Icons.movie_outlined,
          title: '视频检查',
          subtitle: sample.label,
        ),
        const SizedBox(height: 12),
        _WiCard(
          children: [
            _WiRow(label: '当前示例', value: sample.label),
            const SizedBox(height: 6),
            Text(
              sample.note,
              style: TextStyle(fontSize: 10, height: 1.5, color: p.ink4),
            ),
          ],
        ),
        if (stats != null)
          _WiCard(
            children: [
              const SectionLabel('播放参数'),
              const SizedBox(height: 6),
              _WiRow(label: '帧率', value: '${stats.fps} fps'),
              const SizedBox(height: 4),
              _WiRow(label: '时长', value: '${stats.seconds.toStringAsFixed(1)} 秒'),
              const SizedBox(height: 4),
              _WiRow(label: '帧数', value: '${stats.frames} 帧'),
              if (stats.width > 0 && stats.height > 0) ...[
                const SizedBox(height: 4),
                _WiRow(label: '画面', value: '${stats.width}×${stats.height}'),
              ],
            ],
          ),
        _WiCard(
          children: [
            Text(
              '规范对照与逐帧预览在视频工作台里进行；这里只读当前示例的播放规格。',
              style: TextStyle(fontSize: 10, height: 1.5, color: p.ink3),
            ),
          ],
        ),
        _WiPrimary(
          key: const ValueKey('wi-open-workspace'),
          label: '打开视频工作台',
          icon: Icons.arrow_forward,
          onTap: () => store.setView('plugin:video'),
        ),
      ],
    );
  }
}

/// 动效合成短片的只读检查：当前选中的片子 + 播放规格 + 去哪看。
class _VideoClipInspector extends StatelessWidget {
  const _VideoClipInspector({required this.clipId});

  final String clipId;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    return FutureBuilder<VideoClipCatalog>(
      future: sharedVideoClips(),
      builder: (context, snapshot) {
        final catalog = snapshot.data;
        final clip = catalog?.clips
            .where((c) => c.id == clipId)
            .cast<VideoClipInfo?>()
            .firstWhere((c) => true, orElse: () => null);
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: Text('正在读动效合成…', style: TextStyle(fontSize: 11, color: p.ink4)),
          );
        }
        if (clip == null) {
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _WiHeader(
                  icon: Icons.movie_outlined, title: '视频检查', subtitle: '动效合成'),
              const SizedBox(height: 12),
              _WiCard(
                children: [
                  Text(
                    catalog?.error.isNotEmpty == true
                        ? catalog!.error
                        : '这支短片不在示例清单里了，回工作台重新选一支。',
                    style: TextStyle(fontSize: 10, height: 1.5, color: p.ink3),
                  ),
                ],
              ),
              _WiPrimary(
                key: const ValueKey('wi-open-workspace'),
                label: '打开视频工作台',
                icon: Icons.arrow_forward,
                onTap: () => store.setView('plugin:video'),
              ),
            ],
          );
        }
        final styleLabel = switch (clip.style) {
          'hand' => '简笔手绘',
          'motion' => '动效排版',
          'ui' => '界面演示',
          'data' => '数据动效',
          _ => '动效合成',
        };
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _WiHeader(
              icon: Icons.movie_outlined,
              title: '视频检查',
              subtitle: clip.title,
            ),
            const SizedBox(height: 12),
            _WiCard(
              children: [
                _WiRow(label: '当前示例', value: clip.title),
                const SizedBox(height: 6),
                Text(clip.subtitle,
                    style: TextStyle(fontSize: 10, height: 1.5, color: p.ink4)),
              ],
            ),
            _WiCard(
              children: [
                const SectionLabel('播放参数'),
                const SizedBox(height: 6),
                _WiRow(label: '类型', value: styleLabel),
                const SizedBox(height: 4),
                _WiRow(label: '时长', value: '${clip.duration.toStringAsFixed(1)} 秒'),
                const SizedBox(height: 4),
                _WiRow(label: '画面', value: '1280×720'),
                const SizedBox(height: 4),
                _WiRow(label: '帧率', value: '30 fps'),
              ],
            ),
            if (clip.tags.isNotEmpty)
              _WiCard(
                children: [
                  const SectionLabel('看点'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in clip.tags)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: p.accent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(tag, style: TextStyle(fontSize: 9.5, color: p.accent)),
                        ),
                    ],
                  ),
                ],
              ),
            _WiCard(
              children: [
                Text(
                  '这支是 HTML/CSS/JS 动效合成：应用内实时播放，可拖动进度逐帧看；成片导出暂未开放。',
                  style: TextStyle(fontSize: 10, height: 1.5, color: p.ink3),
                ),
              ],
            ),
            _WiPrimary(
              key: const ValueKey('wi-open-workspace'),
              label: '打开视频工作台',
              icon: Icons.arrow_forward,
              onTap: () => store.setView('plugin:video'),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 热应用
// ---------------------------------------------------------------------------

class _HotappInspector extends StatefulWidget {
  const _HotappInspector();

  @override
  State<_HotappInspector> createState() => _HotappInspectorState();
}

class _HotappInspectorState extends State<_HotappInspector> {
  /// 展示的是哪个应用的读数（异步加载回来时用它挡过期结果）。
  String _loadedName = '';
  LibraryApp? _entry;
  int? _screens;
  int? _jumps;
  bool _loading = false;
  String _error = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 名字来自 store（应用名是唯一跨视图续接点）；变化时重读本地库。
    final name = context.read<AppStore>().settings.hotappApp.trim();
    if (name != _loadedName) {
      _loadedName = name;
      _load(name);
    }
  }

  Future<void> _load(String name) async {
    // 同步段直接改字段：调用点（didChangeDependencies）之后必然紧跟一次 build，
    // 不要在生命周期回调里 setState（会把同一帧标脏两次）。
    _entry = null;
    _screens = null;
    _jumps = null;
    _error = '';
    _loading = name.isNotEmpty;
    if (name.isEmpty) return;
    try {
      final library = await NonAppLibrary.open();
      final entry = await library.read(name);
      int? screens;
      int? jumps;
      if (entry != null && entry.renderer != 'a2ui') {
        final html = await library.readHtml(name);
        if (html != null) {
          // 应用页面结构：每个画板一个 data-screen 段落，每条跳转一个 data-nav。
          screens = RegExp(r'data-screen="').allMatches(html).length;
          jumps = RegExp(r'data-nav="').allMatches(html).length;
        }
      }
      if (!mounted || _loadedName != name) return;
      setState(() {
        _entry = entry;
        _screens = screens;
        _jumps = jumps;
        _loading = false;
        _error = entry == null ? '本地应用库里没有这个应用' : '';
      });
    } catch (_) {
      if (!mounted || _loadedName != name) return;
      setState(() {
        _loading = false;
        _error = '应用信息暂时读不出来';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final name = store.settings.hotappApp.trim();
    if (name.isEmpty) {
      return Center(
        child: EmptyHint(
          icon: Icons.widgets_outlined,
          title: '还没有打开热应用',
          detail: '去热应用工作台新建或打开一个应用；这里会显示应用名、类型与屏数/跳转数。',
          action: _WiPrimary(
            key: const ValueKey('wi-open-workspace'),
            label: '打开热应用工作台',
            icon: Icons.arrow_forward,
            onTap: () => store.setView('plugin:hotapp'),
          ),
        ),
      );
    }
    final entry = _entry;
    final prototype = entry?.isPrototypeDemo ?? false;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _WiHeader(
          icon: Icons.widgets_outlined,
          title: '热应用',
          subtitle: entry?.title ?? name,
        ),
        const SizedBox(height: 12),
        _WiCard(
          children: [
            _WiRow(label: '当前应用', value: entry?.title ?? name),
            const SizedBox(height: 6),
            _WiRow(
              label: '类型',
              // 旧数据缺 origin 字段时 LibraryApp 已归一为可用应用（不是原型验证）。
              trailing: Pill(
                label: entry?.originLabel ?? '可用应用',
                color: prototype ? p.warn : p.accent,
                background: prototype ? p.warn.withValues(alpha: 0.12) : p.accentSoft,
              ),
            ),
            if (_loading) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.4, color: p.ink4),
                  ),
                  const SizedBox(width: 6),
                  Text('正在读取应用信息…', style: TextStyle(fontSize: 10, color: p.ink4)),
                ],
              ),
            ] else if (_error.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(_error, style: TextStyle(fontSize: 10, color: p.danger)),
            ] else if (_screens != null || _jumps != null) ...[
              const SizedBox(height: 6),
              _WiRow(label: '屏数', value: '${_screens ?? 0} 屏'),
              const SizedBox(height: 4),
              _WiRow(label: '跳转数', value: '${_jumps ?? 0} 条'),
            ],
          ],
        ),
        _WiCard(
          children: [
            Text(
              '应用内容来自本地应用库；类型徽标区分可用应用与原型验证 demo。',
              style: TextStyle(fontSize: 10, height: 1.5, color: p.ink4),
            ),
          ],
        ),
        _WiPrimary(
          key: const ValueKey('wi-open-workspace'),
          label: '打开热应用工作台',
          icon: Icons.arrow_forward,
          onTap: () => store.setView('plugin:hotapp'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 演示 / 作品集
// ---------------------------------------------------------------------------

class _PlayInspector extends StatelessWidget {
  const _PlayInspector();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Center(
      child: EmptyHint(
        icon: Icons.play_circle_outline,
        title: '演示模式不写文档',
        detail: '演示只读当前原型：点热区会跳转，但不会改动项目内容，也没有画板检查项。',
        action: _WiPrimary(
          key: const ValueKey('wi-open-workspace'),
          label: '回到设计',
          icon: Icons.design_services_outlined,
          onTap: () => store.setView('design'),
        ),
      ),
    );
  }
}

class _PortfolioInspector extends StatelessWidget {
  const _PortfolioInspector();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Center(
      child: EmptyHint(
        icon: Icons.collections_bookmark_outlined,
        title: '作品集不适用检查',
        detail: '作品集用来浏览项目与产物；打开项目后可回到设计画布继续检查。',
        action: _WiPrimary(
          key: const ValueKey('wi-open-workspace'),
          label: '回到设计',
          icon: Icons.design_services_outlined,
          onTap: () => store.setView('design'),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 共用小件（视觉对齐 Inspector：12 内边距、10 圆角卡片、p.ink/p.panel2 令牌）
// ---------------------------------------------------------------------------

class _WiHeader extends StatelessWidget {
  const _WiHeader({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, size: 14, color: p.accent),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink),
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4),
                ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _WiCard extends StatelessWidget {
  const _WiCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: p.panel2.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _WiRow extends StatelessWidget {
  const _WiRow({required this.label, this.value, this.trailing});

  final String label;
  final String? value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        SizedBox(
          width: 62,
          child: Text(label, style: TextStyle(fontSize: 11, color: p.ink3)),
        ),
        if (value != null)
          Expanded(
            child: Text(
              value!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: p.ink2),
            ),
          )
        else
          const Spacer(),
        ?trailing,
      ],
    );
  }
}

class _WiPrimary extends StatelessWidget {
  const _WiPrimary({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      onPressed: onTap,
      icon: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}
