/// 视频工作区（代码动画版）。
///
/// 视频模块**不是**「渲染成片再看」，而是代码动画：时间线脚本 + 规范在
/// [VideoDocument] 里编译成算式，每一帧都由 [VideoDocument.frameSvg] 现算。
/// 工作台只有一整块播放面：
///
///  * 主区铺满 [VideoAnimationSurface]（圆角 + 内边距），播放/暂停、回片头、
///    循环、时间条与时间读数都在播放器自己的控制栏里；
///  * 编辑类动作不占画面，全部收进同一条 46px 顶部工具条：示例选择、
///    帧率、编辑脚本、规范对照状态（点开是一张 result sheet）；
///  * 只读/低频入口（「加载示例」与「代码动画直接播放，暂不导出成片」）放在
///    工具条尾部与播放器底部一行，不抢画面。
///
/// 成片导出（mp4）暂时不做：界面上没有任何渲染/导出按钮，也不再有渲染任务、
/// 进度轮询与产物文件夹入口。艺术架里**已有的** mp4 仍可点开播放（走的还是
/// [VideoPlayerSurface]），那是「播放既有产物」，不是本模块的生成路径。
///
/// 数据面全部在 [VideoService]（纯 Dart）：校验、逐帧画面、对照检查都在进程
/// 内，不经过任何端口、不 spawn 外部程序，手机/平板与桌面行为一致。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/capability.dart';
import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
import '../core/toast_service.dart';
import '../core/video_service.dart';
import 'video_animation_surface.dart';
import 'video_player_surface.dart';

/// 视频工作区。
class VideoWorkspace extends StatefulWidget {
  const VideoWorkspace({super.key, this.service});

  /// 测试注入（生产用 [VideoService.instance]，示例与文档在进程内）。
  final VideoService? service;

  @override
  State<VideoWorkspace> createState() => _VideoWorkspaceState();
}

/// 艺术架「打开」直载：切视图前设置**某个产物的 mp4 绝对路径**，本工作台
/// initState 消费后清空（与 threeLoadOnOpen 同构的跨实例通道）。
String? videoLoadOnOpen;

class _VideoWorkspaceState extends State<VideoWorkspace> {
  int _sampleIdx = 0;
  int _fps = 10;
  VideoDocument? _doc;
  VideoReviewResult? _review;

  /// 产物模式：艺术架点开的某个 mp4（非 null 即整个工作台切到播放面）。
  String? _artifactPath;

  /// 脚本编辑器最近一次输入（切示例后仍保留，方便改回去）。
  String _scriptTimeline = '';
  String _scriptSpec = '';

  AppStore get store => context.read<AppStore>();
  VideoService get _service => widget.service ?? VideoService.instance;
  ToastService get _toasts => store.toasts;

  @override
  void initState() {
    super.initState();
    // 艺术架产物直载优先于一切恢复路径：用户点开的是某个产物，不是
    // 「上次编辑态」。消费即清（跨实例通道）。
    final pendingArtifact = videoLoadOnOpen;
    videoLoadOnOpen = null;
    if (pendingArtifact != null && pendingArtifact.isNotEmpty) {
      _artifactPath = pendingArtifact;
      return;
    }

    final settings = store.settings;
    _sampleIdx = settings.videoSampleIdx.clamp(0, _service.samples.length - 1);
    _applySample(_sampleIdx);

    // 旧版本的渲染任务号已经没有对应界面：静默清掉，别让它继续占着设置。
    if (settings.videoJob.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) store.setVideoState(job: '');
      });
    }
  }

  // ------------------------------------------------------------------ 脚本

  void _applySample(int index) {
    try {
      final doc = _service.loadSample(index);
      _doc = doc;
      _fps = doc.fps.clamp(1, 30);
      _scriptTimeline = const JsonEncoder.withIndent('  ').convert(doc.timeline);
      _scriptSpec = const JsonEncoder.withIndent('  ').convert(doc.spec.raw);
      _review = _service.review(timeline: doc.timeline, spec: doc.spec.raw);
    } on VideoRejected catch (error) {
      _doc = null;
      _review = VideoReviewResult(
        ok: false,
        totalSeconds: 0,
        problems: <String>[videoFailureMessage(error)],
        notes: const <String>[],
        technical: <String>[error.technical],
      );
    } catch (error) {
      _doc = null;
      _review = VideoReviewResult(
        ok: false,
        totalSeconds: 0,
        problems: <String>[videoFailureMessage(null)],
        notes: const <String>[],
        technical: <String>['$error'],
      );
    }
  }

  void _selectSample(int index) {
    setState(() {
      _sampleIdx = index;
      _applySample(index);
    });
    store.setVideoState(sampleIdx: index);
  }

  void _reloadSelectedSample() {
    setState(() => _applySample(_sampleIdx));
  }

  Future<void> _editScript() async {
    final result = await showDialog<_ScriptDraft>(
      context: context,
      builder: (context) => _ScriptEditorDialog(
        timeline: _scriptTimeline,
        spec: _scriptSpec,
      ),
    );
    if (result == null || !mounted) return;
    _scriptTimeline = result.timeline;
    _scriptSpec = result.spec;
    setState(() {
      try {
        final doc = VideoDocument.fromScripts(
          timelineJson: result.timeline,
          specJson: result.spec,
        );
        _doc = doc;
        _fps = doc.fps.clamp(1, 30);
        _review = _service.review(timeline: doc.timeline, spec: doc.spec.raw);
      } on VideoRejected catch (error) {
        _doc = null;
        _review = VideoReviewResult(
          ok: false,
          totalSeconds: 0,
          problems: <String>[videoFailureMessage(error)],
          notes: const <String>[],
          technical: <String>[error.technical],
        );
      }
    });
  }

  // ------------------------------------------------------------------ 帧率

  Future<void> _pickFps() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => _FpsDialog(initial: _fps),
    );
    if (selected == null || !mounted) return;
    setState(() => _fps = selected.clamp(1, 30));
  }

  Future<void> _onMoreAction(String action) async {
    switch (action) {
      case 'fps':
        await _pickFps();
      case 'script':
        await _editScript();
    }
  }

  // ------------------------------------------------------------------ 对照

  /// 对照结论三档 + 未知：通过 / 有问题 / 未通过 / 待检查。
  ({String label, Color color, IconData icon}) _reviewStatus(NonPalette p) {
    final review = _review;
    if (review == null) return (label: '待检查', color: p.ink4, icon: Icons.rule_outlined);
    if (!review.ok) return (label: '未通过', color: p.danger, icon: Icons.error_outline);
    if (review.notes.isNotEmpty) return (label: '有问题', color: p.warn, icon: Icons.info_outline);
    return (label: '通过', color: p.accent, icon: Icons.check_circle_outline);
  }

  Future<void> _showReviewSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 680),
      builder: (sheetContext) => _ReviewSheet(
        review: _review,
        hasDocument: _doc != null,
        onEditScript: () {
          Navigator.of(sheetContext).pop();
          _editScript();
        },
      ),
    );
  }

  // ------------------------------------------------------------------ 播放面

  /// 从「播放既有产物」回到创作面：产物模式在 initState 里直接返回，没有载入
  /// 任何示例文档，回来时补上一次（否则主区会是空态）。
  void _leaveArtifact() {
    setState(() {
      _artifactPath = null;
      if (_doc == null) _applySample(_sampleIdx);
    });
  }

  Future<void> _copyArtifactPath() async {
    final path = _artifactPath;
    if (path == null) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    _toasts.info('已复制路径');
  }

  Future<void> _revealArtifact() async {
    final path = _artifactPath;
    if (path == null) return;
    if (!store.capabilities.isUsable(CapabilityId.revealInFolder)) {
      _toasts.warn(store.capabilities.message(CapabilityId.revealInFolder));
      return;
    }
    final ok = await revealInSystemFileManager(path);
    if (!mounted || ok) return;
    _toasts.warn('没能打开文件夹', '可以先用「复制路径」拿到文件位置。');
  }

  static String _artifactName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    // 产物固定是 <job>/frames.mp4：父目录名才是「第几个产物」，帧名没有信息量。
    return parts.length >= 2 ? parts[parts.length - 2] : path;
  }

  // ------------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    final artifact = _artifactPath;
    return Column(
      children: [
        _header(context, artifact: artifact),
        Expanded(
          child: artifact != null
              ? _artifactPane(context, artifact)
              : _authoringBody(context),
        ),
      ],
    );
  }

  /// 一块播放面铺满主区 + 底部一行不抢画面的提示。
  Widget _authoringBody(BuildContext context) {
    return Column(children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
          child: _previewPane(context),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.play_circle_outline, size: 12, color: context.palette.ink4),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '代码动画直接播放，暂不导出成片',
              key: const ValueKey('video-player-hint'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: context.palette.ink4),
            ),
          ),
        ]),
      ),
    ]);
  }

  /// 46px 工具条：返回主页 / 标题 / 示例 / 帧率 / 编辑脚本 / 对照状态 / 加载示例。
  ///
  /// 宽度不够时（手机），低频动作进 ⋯ 菜单；示例与对照状态始终可见。
  Widget _header(BuildContext context, {required String? artifact}) {
    final p = context.palette;
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        final labels = width >= 760;
        final showTitle = width >= 560;
        return Row(children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 18),
            tooltip: '返回主页 ${modCombo('⌘1')}',
            color: p.ink2,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            // 视频是独立工作区：返回的是主页（模块入口），不是某个设计项目
            // 的画布——工作区之间不互相挂靠。
            onPressed: () => store.setView('home'),
          ),
          if (artifact != null) ...[
            const SizedBox(width: 2),
            Icon(Icons.movie_outlined, size: 17, color: p.accent),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '视频产物 · ${_artifactName(artifact)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _leaveArtifact,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('返回创作台', style: TextStyle(fontSize: 11)),
            ),
            const Spacer(),
          ] else ...[
            if (width >= 520) ...[
              const SizedBox(width: 2),
              Icon(Icons.movie_outlined, size: 17, color: p.accent),
              const SizedBox(width: 6),
            ],
            if (showTitle)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  '视频工作台',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink),
                ),
              ),
            if (labels) const Spacer() else const SizedBox(width: 6),
            if (labels) ...[
              _samplePicker(context, maxWidth: 240),
              const SizedBox(width: 8),
              _fpsControl(context),
              const SizedBox(width: 4),
              TextButton.icon(
                key: const ValueKey('video-edit-script'),
                onPressed: _editScript,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: const Icon(Icons.edit_note_outlined, size: 16),
                label: const Text('编辑脚本', style: TextStyle(fontSize: 11)),
              ),
              const SizedBox(width: 4),
              _reviewChip(context, showLabel: true),
              const SizedBox(width: 4),
              _loadSampleButton(context),
            ] else ...[
              Flexible(child: _samplePicker(context, maxWidth: 140)),
              const SizedBox(width: 2),
              _reviewChip(context, showLabel: false),
              const SizedBox(width: 2),
              _loadSampleButton(context),
              const SizedBox(width: 2),
              PopupMenuButton<String>(
                key: const ValueKey('video-more-menu'),
                tooltip: '更多',
                iconSize: 18,
                padding: EdgeInsets.zero,
                iconColor: p.ink2,
                position: PopupMenuPosition.under,
                onSelected: _onMoreAction,
                itemBuilder: (context) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'fps',
                    height: 40,
                    child: Text('帧率 $_fps', style: TextStyle(fontSize: 12, color: p.ink2)),
                  ),
                  PopupMenuItem<String>(
                    value: 'script',
                    height: 40,
                    child: Text('编辑脚本', style: TextStyle(fontSize: 12, color: p.ink2)),
                  ),
                ],
              ),
            ],
          ],
        ]);
      }),
    );
  }

  /// 示例选择：显示当前示例名，点开是三个标杆示例（带一行说明）。
  Widget _samplePicker(BuildContext context, {required double maxWidth}) {
    final p = context.palette;
    final samples = _service.samples;
    return PopupMenuButton<int>(
      key: const ValueKey('video-sample-picker'),
      tooltip: '选择示例',
      position: PopupMenuPosition.under,
      onSelected: _selectSample,
      color: p.panel2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: p.line),
      ),
      itemBuilder: (context) => <PopupMenuEntry<int>>[
        for (var i = 0; i < samples.length; i++)
          PopupMenuItem<int>(
            value: i,
            height: 54,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                samples[i].label,
                style: TextStyle(
                  fontSize: 12,
                  color: i == _sampleIdx ? p.accent : p.ink2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                samples[i].note,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: p.ink4),
              ),
            ]),
          ),
      ],
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: p.panel2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('标杆示例', style: TextStyle(fontSize: 9, color: p.ink4)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                samples.isEmpty ? '' : samples[_sampleIdx.clamp(0, samples.length - 1)].label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: p.ink2),
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.expand_more, size: 14, color: p.ink4),
          ]),
        ),
      ),
    );
  }

  Widget _fpsControl(BuildContext context) {
    final p = context.palette;
    return TextButton(
      key: const ValueKey('video-fps-control'),
      onPressed: _pickFps,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.speed_outlined, size: 14, color: p.ink3),
        const SizedBox(width: 5),
        Text('帧率 $_fps', style: TextStyle(fontSize: 11, color: p.ink2)),
      ]),
    );
  }

  Widget _reviewChip(BuildContext context, {required bool showLabel}) {
    final p = context.palette;
    final status = _reviewStatus(p);
    return InkWell(
      key: const ValueKey('video-review-chip'),
      onTap: _showReviewSheet,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 28,
        padding: EdgeInsets.symmetric(horizontal: showLabel ? 10 : 6),
        decoration: BoxDecoration(
          color: status.color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: status.color.withValues(alpha: 0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(status.icon, size: 13, color: status.color),
          if (showLabel) ...[
            const SizedBox(width: 5),
            Text('规范对照', style: TextStyle(fontSize: 11, color: p.ink2)),
          ],
          const SizedBox(width: 5),
          Text(
            status.label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: status.color),
          ),
        ]),
      ),
    );
  }

  Widget _loadSampleButton(BuildContext context) {
    return TextButton(
      key: const ValueKey('video-load-sample'),
      onPressed: _reloadSelectedSample,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      child: const Text('加载示例', style: TextStyle(fontSize: 11)),
    );
  }

  /// 产物模式：播放面 + 信息行（路径 / 复制 / 桌面端在文件夹中显示）。
  Widget _artifactPane(BuildContext context, String path) {
    final p = context.palette;
    final host = store.capabilities.platform;
    return Column(children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: VideoPlayerSurface(path: path),
          ),
        ),
      ),
      Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: p.bgElevated,
          border: Border(top: BorderSide(color: p.line)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          Icon(Icons.movie_outlined, size: 14, color: p.ink4),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              path,
              maxLines: 1,
              style: TextStyle(fontSize: 11, color: p.ink3, fontFamily: 'monospace'),
            ),
          ),
          TextButton.icon(
            onPressed: _copyArtifactPath,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            icon: const Icon(Icons.copy_all_outlined, size: 14),
            label: const Text('复制路径', style: TextStyle(fontSize: 11)),
          ),
          if (host.supportsRevealInFolder)
            TextButton.icon(
              onPressed: _revealArtifact,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              icon: const Icon(Icons.folder_open_outlined, size: 14),
              label: const Text('在文件夹中显示', style: TextStyle(fontSize: 11)),
            ),
        ]),
      ),
    ]);
  }

  /// 主区：选中的文档直接可播；没有文档时是空态。
  Widget _previewPane(BuildContext context) {
    final p = context.palette;
    final doc = _doc;
    if (doc == null) {
      final problems = _review?.problems ?? const <String>[];
      final problem = problems.isEmpty ? '' : problems.first;
      return Container(
        decoration: BoxDecoration(
          color: p.panel2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.line),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.movie_outlined, size: 38, color: p.ink4),
          const SizedBox(height: 10),
          Text(
            '还没有视频',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink2),
          ),
          const SizedBox(height: 6),
          Text(
            problem.isEmpty ? '选一个例子，点播放就能看到代码动画' : problem,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: p.ink3, height: 1.5),
          ),
        ]),
      );
    }
    return VideoAnimationSurface(
      // 换文档即换实例：时间回到片头、旧计时器彻底停掉。
      key: ObjectKey(doc),
      document: doc,
      fps: _fps,
    );
  }
}

/// 帧率小面板：滑块 + 数值，确认后只影响播放（不改脚本本身）。
class _FpsDialog extends StatefulWidget {
  const _FpsDialog({required this.initial});

  final int initial;

  @override
  State<_FpsDialog> createState() => _FpsDialogState();
}

class _FpsDialogState extends State<_FpsDialog> {
  late int _value = widget.initial.clamp(1, 30);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AlertDialog(
      title: const Text('播放帧率', style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 300,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('$_value 帧/秒', style: TextStyle(fontSize: 12, color: p.ink2)),
            const Spacer(),
            Text('1–30', style: TextStyle(fontSize: 10, color: p.ink4)),
          ]),
          Slider(
            key: const ValueKey('video-fps-slider'),
            value: _value.toDouble(),
            min: 1,
            max: 30,
            divisions: 29,
            label: '$_value',
            activeColor: p.accent,
            onChanged: (value) => setState(() => _value = value.round().clamp(1, 30)),
          ),
          Text('越高画面越连贯；改动只影响播放，不改脚本本身。',
              style: TextStyle(fontSize: 10, color: p.ink4)),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_value),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

/// 对照结果 sheet：problems / notes / 折叠的原始诊断。
class _ReviewSheet extends StatelessWidget {
  const _ReviewSheet({
    required this.review,
    required this.hasDocument,
    required this.onEditScript,
  });

  final VideoReviewResult? review;
  final bool hasDocument;
  final VoidCallback onEditScript;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final review = this.review;
    final problems = review?.problems ?? const <String>[];
    final notes = review?.notes ?? const <String>[];
    final ok = review?.ok ?? false;
    final statusLabel = review == null ? '待检查' : (ok ? (notes.isEmpty ? '通过' : '有问题') : '未通过');
    final color = review == null ? p.ink4 : (ok ? (notes.isEmpty ? p.accent : p.warn) : p.danger);
    return Material(
      key: const ValueKey('video-review-sheet'),
      color: p.bgElevated,
      clipBehavior: Clip.antiAlias,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.rule_outlined, size: 16, color: color),
              const SizedBox(width: 6),
              Text('规范对照',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: color.withValues(alpha: 0.5)),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Text(review?.summary ?? '还没有对照结果',
                style: TextStyle(fontSize: 11, color: p.ink3)),
            if (!hasDocument) ...[
              const SizedBox(height: 8),
              Text('选一个例子，点播放就能看到代码动画',
                  style: TextStyle(fontSize: 11, color: p.ink4)),
            ],
            if (problems.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('需要修正',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: p.danger)),
              for (final problem in problems)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.error_outline, size: 13, color: p.danger),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(problem,
                          style: TextStyle(fontSize: 11, color: p.ink2, height: 1.5)),
                    ),
                  ]),
                ),
            ],
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('值得留意',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: p.warn)),
              for (final note in notes)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.info_outline, size: 13, color: p.warn),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(note,
                          style: TextStyle(fontSize: 11, color: p.ink2, height: 1.5)),
                    ),
                  ]),
                ),
            ],
            if (review != null && review.technical.isNotEmpty) ...[
              const SizedBox(height: 8),
              _TechnicalDetails(text: review.technical.join('\n')),
            ],
            const SizedBox(height: 12),
            Row(children: [
              Icon(Icons.play_circle_outline, size: 12, color: p.ink4),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '代码动画直接播放，暂不导出成片',
                  style: TextStyle(fontSize: 10, color: p.ink4),
                ),
              ),
              TextButton.icon(
                onPressed: onEditScript,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: const Icon(Icons.edit_note_outlined, size: 15),
                label: const Text('编辑脚本', style: TextStyle(fontSize: 11)),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// 折叠的「技术详情」：原始诊断只在这里出现，默认不展开。
class _TechnicalDetails extends StatelessWidget {
  const _TechnicalDetails({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        dense: true,
        title: Text('技术详情',
            style: TextStyle(fontSize: 11, color: p.ink4, fontWeight: FontWeight.w600)),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: p.panel2,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              text,
              style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: p.ink4, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScriptDraft {
  const _ScriptDraft(this.timeline, this.spec);
  final String timeline;
  final String spec;
}

/// 脚本编辑器：左时间线、右规范（窄屏上下排）。
class _ScriptEditorDialog extends StatefulWidget {
  const _ScriptEditorDialog({required this.timeline, required this.spec});

  final String timeline;
  final String spec;

  @override
  State<_ScriptEditorDialog> createState() => _ScriptEditorDialogState();
}

class _ScriptEditorDialogState extends State<_ScriptEditorDialog> {
  late final TextEditingController _timeline =
      TextEditingController(text: widget.timeline);
  late final TextEditingController _spec = TextEditingController(text: widget.spec);

  @override
  void dispose() {
    _timeline.dispose();
    _spec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextStyle(fontSize: 11, fontFamily: 'monospace', color: p.ink2, height: 1.5);
    return AlertDialog(
      title: const Text('编辑脚本', style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 680,
        height: 460,
        child: LayoutBuilder(builder: (context, constraints) {
          final wide = constraints.maxWidth >= 560;
          final timelineField = _field(context, '时间线脚本', _timeline, style);
          final specField = _field(context, '规范', _spec, style);
          if (wide) {
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: timelineField),
              const SizedBox(width: 12),
              Expanded(child: specField),
            ]);
          }
          return Column(children: [
            Expanded(child: timelineField),
            const SizedBox(height: 10),
            Expanded(child: specField),
          ]);
        }),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _ScriptDraft(_timeline.text, _spec.text),
          ),
          child: const Text('检查并载入'),
        ),
      ],
    );
  }

  Widget _field(
    BuildContext context,
    String label,
    TextEditingController controller,
    TextStyle style,
  ) {
    final p = context.palette;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: p.ink3)),
      const SizedBox(height: 6),
      Expanded(
        child: TextField(
          controller: controller,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: style,
          decoration: InputDecoration(
            filled: true,
            fillColor: p.panel2,
            contentPadding: const EdgeInsets.all(10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
    ]);
  }
}
