/// 视频工作区（两种渲染面）。
///
/// 视频模块**不是**「渲染成片再看」，而是应用内实时播放：
///
///  * **矢量动画**：时间线脚本 + 规范在 [VideoDocument] 里编译成算式，每一帧
///    都由 [VideoDocument.frameSvg] 现算，铺满 [VideoAnimationSurface]；
///  * **动效合成**：自包含 HTML/CSS/JS 短片（`assets/video/clip/`）在
///    [VideoClipSurface] 的 WebView 里实时播放，运输条读同一份
///    [VideoClipPlayback]；工具条只留返回主页 / 规格对照（只读卡）/ 加示例。
///
/// 两种模式共用同一条 46px 顶部工具条与示例选择器（分「矢量动画」与
/// 「动效合成」两组）；编辑类动作（帧率、编辑脚本）只在矢量动画下出现，
/// 动效合成是成品短片，没有脚本可编辑。切示例/切模式时旧播放器当场释放。
///
/// 矢量动画的编辑类动作不占画面：示例选择、帧率、编辑脚本、对照状态（点开
/// 是一张 result sheet）都收进工具条；低频入口放在工具条尾部与播放器底部
/// 一行，不抢画面。
///
/// 成片导出（mp4）暂时不做：界面上没有任何渲染/导出按钮，也不再有渲染任务、
/// 进度轮询与产物文件夹入口。艺术架里**已有的** mp4 仍可点开播放（走的还是
/// [VideoPlayerSurface]），那是「播放既有产物」，不是本模块的生成路径。
///
/// 数据面全部在 [VideoService]（纯 Dart）：校验、逐帧画面、对照检查都在进程
/// 内，不经过任何端口、不 spawn 外部程序，手机/平板与桌面行为一致。
library;

import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/capability.dart';
import '../core/store.dart';
import '../core/theme.dart';
import '../core/workbench_layout.dart';
import '../core/toast_service.dart';
import '../core/video_clip.dart';
import '../core/video_project.dart';
import '../core/video_service.dart';
import 'video_animation_surface.dart';
import 'video_clip_surface.dart';
import 'video_workbench_panels.dart';
import 'video_player_surface.dart';

/// 视频工作区。
///
/// 两种渲染面并存：
///  * **矢量动画**（默认）：[VideoAnimationSurface] 逐帧播放代码动画；
///  * **动效合成**：自包含 HTML 短片在 [VideoClipSurface] 里实时播放，
///    运输条（[VideoClipTransport]）读同一份 [VideoClipPlayback]。
///
/// 两种模式共用同一条 46px 工具条与示例选择器；切换示例/模式时旧播放器
/// 当场释放（矢量面随 widget 销毁停表，动效合成的 WebView/计时器随播放源
/// dispose），不会把旧计时器留到后台。
class VideoWorkspace extends StatefulWidget {
  const VideoWorkspace({
    super.key,
    this.service,
    this.clips,
    this.clipPlaybackFactory,
    this.projectStore,
  });

  /// 测试注入（生产用 [VideoService.instance]，示例与文档在进程内）。
  final VideoService? service;

  /// 测试注入：动效合成清单（生产从 `assets/video/clip/clips.json` 加载）。
  final List<VideoClipInfo>? clips;

  /// 测试注入：不构造真 WebView 的播放源工厂（生产为 null，由播放面自建）。
  final VideoClipPlayback Function(VideoClipInfo clip)? clipPlaybackFactory;

  /// 测试注入：生成项目库（生产用 [VideoProjectStore.instance]）。
  ///
  /// 注入时指向临时目录，工作台测试因此不会去扫真实用户项目目录。
  final VideoProjectStore? projectStore;

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
  // UI-3：导演台当前选中镜头（只读检查器/时间线联动；不写事实源）。
  int? _selectedShotIndex;
  // 导演台共享播放头（由预览面回调；时间线只读呈现）。
  double _playheadSeconds = 0;
  bool _previewPlaying = false;

  /// 产物模式：艺术架点开的某个 mp4（非 null 即整个工作台切到播放面）。
  String? _artifactPath;

  /// 脚本编辑器最近一次输入（切示例后仍保留，方便改回去）。
  String _scriptTimeline = '';
  String _scriptSpec = '';

  // ---- 生成项目（NaN 的 video_create 落盘后在这里出现） --------------------

  /// 当前打开的生成项目名（null = 内置示例 / 动效合成 / 产物）。
  String? _projectName;

  /// 已校验的项目全貌（读失败时为空，改用 [_projectFailure] 展示）。
  VideoProjectSnapshot? _project;

  /// 读失败/内容被手改坏时的失败对象（面板给可行动人话 + 折叠技术详情）。
  VideoProjectFailure? _projectFailure;

  /// 项目读取是否在飞（面板给「正在打开」而不是空白）。
  bool _projectBusy = false;

  /// 生成项目列表（只读元数据；坏项目标 corrupt 也在列表里）。
  List<VideoProjectEntry> _projects = const <VideoProjectEntry>[];
  bool _projectsLoading = true;
  String _projectsError = '';

  /// store 监听快照：只有这些值真的变化才刷新/自动切换，避免 store 的高频
  /// notifyListeners 引起无谓读盘。
  AppStore? _appStore;
  String _lastStoreProjectName = '';
  bool _lastAgentBusy = false;

  // ---- 动效合成（第二渲染面） -------------------------------------------

  /// 短片清单（`clips.json` 顺序；测试可注入）。
  List<VideoClipInfo> _clips = const <VideoClipInfo>[];

  /// 清单加载失败的一句人话；空串 = 正常。
  String _clipsError = '';

  /// 清单是否还在读（读的时候选择器给一条「载入中」）。
  bool _clipsLoading = true;

  /// 非 null = 动效合成模式；null = 矢量动画模式。
  VideoClipInfo? _clip;

  /// 运输条的数据源（生产是播放面自建的 WebView 播放源，测试是注入的 Fake）。
  VideoClipPlayback? _clipPlayback;

  /// 测试注入的播放源：本工作台拥有其生命周期，切示例/离开模式时 dispose。
  VideoClipPlayback? _injectedClipPlayback;

  AppStore get store => context.read<AppStore>();
  VideoService get _service => widget.service ?? VideoService.instance;
  VideoProjectStore get _projectStore =>
      widget.projectStore ?? VideoProjectStore.instance;
  ToastService get _toasts => store.toasts;

  @override
  void initState() {
    super.initState();
    // store 是 ChangeNotifier：NaN 生成完写 videoProjectName 后必须自动切过去，
    // run 收尾再刷新一次项目列表（生成中的项目跑完要立刻出现在选择器里）。
    final appStore = context.read<AppStore>();
    _appStore = appStore;
    _lastStoreProjectName = appStore.settings.videoProjectName;
    _lastAgentBusy = appStore.agentBusy;
    appStore.addListener(_onStoreChanged);

    // 清单先读：它不依赖恢复路径，切回创作面时选择器要已经能列出短片。
    _initClips();
    // 生成项目列表也先读：选择器里的「生成项目」组不能等恢复路径走完才出现。
    unawaited(_refreshProjects());

    // 艺术架产物直载优先于一切恢复路径：用户点开的是某个产物，不是
    // 「上次编辑态」。消费即清（跨实例通道）。
    final pendingArtifact = videoLoadOnOpen;
    videoLoadOnOpen = null;
    if (pendingArtifact != null && pendingArtifact.isNotEmpty) {
      _artifactPath = pendingArtifact;
      return;
    }

    final settings = appStore.settings;
    final samples = _service.samples;
    if (samples.isEmpty) {
      // 没有内置示例时不能 clamp(0, -1)（ArgumentError）——直接落到空态，
      // 并给一句可行动的人话。
      _applySample(0);
    } else {
      _sampleIdx = settings.videoSampleIdx.clamp(0, samples.length - 1);
      _applySample(_sampleIdx);
    }

    // 上次离开时选中的生成项目：回来续接（视图切换即 dispose，内存态不保活，
    // 项目名在设置里）。读坏了就保留失败面板，让用户能重试或回退示例。
    final restoredProject = settings.videoProjectName.trim();
    if (restoredProject.isNotEmpty) {
      _openProject(restoredProject, announce: false, refresh: false);
    }

    // 旧版本的渲染任务号已经没有对应界面：静默清掉，别让它继续占着设置。
    if (settings.videoJob.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) store.setVideoState(job: '');
      });
    }
  }

  @override
  void dispose() {
    // 切视图即销毁工作台：store 监听与注入的播放源都不能留下。
    _appStore?.removeListener(_onStoreChanged);
    _appStore = null;
    _releaseClipPlayback();
    super.dispose();
  }

  // ------------------------------------------------------------ 动效合成清单

  void _initClips() {
    final injected = widget.clips;
    if (injected != null) {
      _clips = injected;
      _clipsLoading = false;
      return;
    }
    loadVideoClips().then((catalog) {
      if (!mounted) return;
      setState(() {
        _clips = catalog.clips;
        _clipsError = catalog.error;
        _clipsLoading = false;
      });
    });
  }

  // ------------------------------------------------------------ 生成项目

  /// 全部项目列表（只读元数据）；读不到时给空表 + 一句人话，不让面板空白。
  Future<void> _refreshProjects() async {
    List<VideoProjectEntry> entries;
    String problem = '';
    try {
      entries = await _projectStore.list();
    } catch (error) {
      entries = const <VideoProjectEntry>[];
      problem = videoProjectFailureMessage(error);
    }
    if (!mounted) return;
    setState(() {
      _projects = entries;
      _projectsError = problem;
      _projectsLoading = false;
    });
  }

  /// store 通知：只处理三种真正会改变画面的变化，其余（进度、历史……）
  /// 直接忽略，避免每次 notify 都读盘。
  void _onStoreChanged() {
    final appStore = _appStore;
    if (!mounted || appStore == null) return;
    final storeName = appStore.settings.videoProjectName.trim();
    final busy = appStore.agentBusy;
    final nameChanged = storeName != _lastStoreProjectName;
    final runEnded = _lastAgentBusy && !busy;
    _lastStoreProjectName = storeName;
    _lastAgentBusy = busy;

    if (nameChanged && storeName.isNotEmpty && storeName != _projectName) {
      // NaN 的 video_create 成功（store 写 videoProjectName + notify）：
      // 工作台自动切到新项目并读盘播放，用户不会再看到「跑完却什么都没有」。
      _openProject(storeName, announce: true, fromStore: true);
    } else if (nameChanged && storeName.isEmpty && _projectName != null) {
      // 别处清掉了当前项目名（例如删除后）：回退到内置示例，不留空面板。
      _fallBackToSample(persist: false);
    }

    if (runEnded) {
      // run 收尾再刷一次列表：生成过程中落盘的项目现在必须出现在选择器里。
      unawaited(_refreshProjects());
    }
  }

  /// 打开一个生成项目：记下选中、异步读盘（[VideoProjectSnapshot] 里的
  /// [VideoDocument] 直接铺播放面）。
  void _openProject(
    String name, {
    bool announce = true,
    bool fromStore = false,
    bool refresh = true,
  }) {
    final appStore = _appStore;
    if (appStore != null) {
      _lastStoreProjectName = name;
      _lastAgentBusy = appStore.agentBusy;
      if (appStore.settings.videoProjectName != name) {
        // 用户当前项目写进设置：切视图再回来仍停在同一个项目。
        appStore.setVideoProjectName(name);
      }
    }
    _releaseClipPlayback();
    setState(() {
      _artifactPath = null;
      _clip = null;
      _injectedClipPlayback = null;
      _clipPlayback = null;
      _projectName = name;
      _project = null;
      _projectFailure = null;
      _projectBusy = true;
      _doc = null;
      _review = null;
    });
    unawaited(_loadProject(name, announce: announce, fromStore: fromStore));
    if (refresh) unawaited(_refreshProjects());
  }

  /// 读盘并重新校验；失败落到 [VideoProjectFailure] 面板，绝不静默空白。
  Future<void> _loadProject(
    String name, {
    bool announce = false,
    bool fromStore = false,
  }) async {
    try {
      final snapshot = await _projectStore.read(name);
      if (!mounted || _projectName != name) return;
      setState(() {
        _project = snapshot;
        _projectFailure = null;
        _projectBusy = false;
        _doc = snapshot.document;
        _fps = snapshot.document.fps.clamp(1, 30);
        _scriptTimeline = const JsonEncoder.withIndent('  ')
            .convert(snapshot.timeline);
        _scriptSpec = const JsonEncoder.withIndent('  ').convert(snapshot.spec);
        _review = _service.review(
          timeline: snapshot.timeline,
          spec: snapshot.spec,
        );
      });
      if (announce) {
        final title = snapshot.title.isEmpty ? name : snapshot.title;
        _toasts.info(
          fromStore ? 'NaN 刚生成了「$title」，已切到这个视频' : '已打开生成项目「$title」',
        );
      }
    } on VideoProjectFailure catch (failure) {
      _applyProjectFailure(name, failure);
    } catch (error) {
      _applyProjectFailure(name, VideoProjectFailure('io_error', '$error'));
    }
  }

  void _applyProjectFailure(String name, VideoProjectFailure failure) {
    if (!mounted || _projectName != name) return;
    setState(() {
      _project = null;
      _projectFailure = failure;
      _projectBusy = false;
      _doc = null;
      _review = VideoReviewResult(
        ok: false,
        totalSeconds: 0,
        problems: <String>[failure.message],
        notes: const <String>[],
        technical: <String>[failure.technical],
      );
    });
    // 坏项目在列表里也标出来（corrupt / 可重试）。
    unawaited(_refreshProjects());
  }

  /// 清除生成项目选中态（切到示例/动效合成/产物前调用）。
  ///
  /// [persist] 为 true 时把设置里的项目名也清掉，避免下次回来续接一个
  /// 用户已经离开的项目。
  void _clearProject({bool persist = true}) {
    final appStore = _appStore;
    if (persist &&
        appStore != null &&
        appStore.settings.videoProjectName.isNotEmpty) {
      _lastStoreProjectName = '';
      _lastAgentBusy = appStore.agentBusy;
      appStore.setVideoProjectName('');
    }
    _projectName = null;
    _project = null;
    _projectFailure = null;
    _projectBusy = false;
  }

  /// 回退到内置示例（删除当前项目 / 读失败后用户选择示例时用）。
  void _fallBackToSample({bool persist = true}) {
    _releaseClipPlayback();
    setState(() {
      _clip = null;
      _injectedClipPlayback = null;
      _clipPlayback = null;
      _clearProject(persist: persist);
      _applySample(_sampleIdx);
    });
  }

  /// 手动选择生成项目（选择器里点一行）；actions 都经 setState 收口。
  void _selectProject(String name) {
    if (_projectName == name && _project != null && _projectFailure == null) {
      // 再选一次同一个项目：重新读盘（手改过的文件也能重新校验）。
      unawaited(_loadProject(name));
      return;
    }
    _openProject(name, announce: true);
  }

  void _retryProject() {
    final name = _projectName;
    if (name == null) return;
    setState(() {
      _projectFailure = null;
      _projectBusy = true;
    });
    unawaited(_loadProject(name));
    unawaited(_refreshProjects());
  }

  void _useSampleFromProjectFailure() {
    _fallBackToSample();
  }

  /// 删除当前生成项目（确认后删目录、清设置、回退到内置示例）。
  Future<void> _deleteProject() async {
    final name = _projectName;
    if (name == null) return;
    final title = _project?.title.isNotEmpty == true ? _project!.title : name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除生成项目', style: TextStyle(fontSize: 15)),
        content: Text(
          '「$title」会从磁盘上删除，删掉后不能恢复。',
          style: TextStyle(fontSize: 12, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('video-project-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _projectStore.delete(name);
    } on VideoProjectFailure catch (failure) {
      if (!mounted) return;
      _toasts.warn(failure.message);
      return;
    }
    if (!mounted) return;
    _toasts.info('已删除生成项目「$title」');
    _fallBackToSample();
    unawaited(_refreshProjects());
  }

  // ------------------------------------------------------------ 动效合成选择

  /// 切到某个矢量动画示例（会先释放动效合成的播放源、清掉生成项目选中）。
  void _selectSample(int index) {
    if (index < 0 || index >= _service.samples.length) return;
    _clearProject();
    _releaseClipPlayback();
    setState(() {
      _clip = null;
      _sampleIdx = index;
      _applySample(index);
    });
    store.setVideoState(sampleIdx: index, clipId: '');
  }

  /// 切到某支动效合成短片（会先释放上一个播放源、清掉生成项目选中）。
  void _selectClip(int index) {
    if (index < 0 || index >= _clips.length) return;
    _clearProject();
    _releaseClipPlayback();
    final clip = _clips[index];
    final injected = widget.clipPlaybackFactory?.call(clip);
    setState(() {
      _clip = clip;
      _injectedClipPlayback = injected;
      _clipPlayback = injected;
    });
    store.setVideoState(clipId: clip.id);
  }

  /// 播放面自建了 WebView 播放源后回传一次（生产路径）。
  void _onClipPlayback(VideoClipPlayback? playback) {
    if (!mounted || playback == null) return;
    // 已经切回矢量动画：迟到的挂载回调不能再把运输条接回已离开的播放源。
    if (_clip == null) return;
    if (identical(_clipPlayback, playback)) return;
    // 回调来自子 widget 的 post-frame：再等一帧落 setState，避免构建期标脏。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _clipPlayback = playback);
    });
  }

  /// 释放动效合成的播放源：
  ///  * 注入的 Fake 归本工作台；WebView 播放源归播放面（随 widget 销毁释放）。
  void _releaseClipPlayback() {
    final owned = _injectedClipPlayback;
    _injectedClipPlayback = null;
    _clipPlayback = null;
    owned?.dispose();
  }

  /// 「加示例」：重播当前这支（成品合成没有脚本可编辑，能做的就是重新载入）。
  void _restartClip() {
    final playback = _clipPlayback;
    if (playback == null) {
      _toasts.warn('动效合成还没准备好', '稍等一下再试，或换一支示例。');
      return;
    }
    playback.restart();
  }

  Future<void> _showClipReviewSheet() async {
    final clip = _clip;
    if (clip == null) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 680),
      builder: (sheetContext) => _ClipReviewSheet(clip: clip),
    );
  }

  // ------------------------------------------------------------------ 脚本

  void _applySample(int index) {
    final samples = _service.samples;
    if (samples.isEmpty) {
      _doc = null;
      _review = VideoReviewResult(
        ok: false,
        totalSeconds: 0,
        problems: <String>[videoFailureMessage('sample_missing')],
        notes: const <String>[],
        technical: const <String>['sample_missing: 没有内置示例'],
      );
      return;
    }
    if (index < 0 || index >= samples.length) {
      _doc = null;
      _review = VideoReviewResult(
        ok: false,
        totalSeconds: 0,
        problems: <String>[videoFailureMessage('sample_missing')],
        notes: const <String>[],
        technical: <String>['sample_missing: index=$index'],
      );
      return;
    }
    try {
      final doc = _service.loadSample(index);
      _doc = doc;
      _fps = doc.fps.clamp(1, 30);
      _scriptTimeline = const JsonEncoder.withIndent('  ')
          .convert(doc.timeline);
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
        problems: <String>[videoFailureMessage(error)],
        notes: const <String>[],
        technical: <String>['$error'],
      );
    }
  }

  void _reloadSelectedSample() {
    setState(() => _applySample(_sampleIdx));
  }

  Future<void> _editScript() async {
    final result = await showDialog<_ScriptDraft>(
      context: context,
      builder: (context) =>
          _ScriptEditorDialog(timeline: _scriptTimeline, spec: _scriptSpec),
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
      } catch (error) {
        // 解析/编译里任何没归到 VideoRejected 的异常也不能把红屏留给演示：
        // 统一落到「这次操作没有成功」+ 折叠详情。
        _doc = null;
        _review = VideoReviewResult(
          ok: false,
          totalSeconds: 0,
          problems: <String>[videoFailureMessage(error)],
          notes: const <String>[],
          technical: <String>['$error'],
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
      case 'delete':
        await _deleteProject();
    }
  }

  // ------------------------------------------------------------------ 对照

  /// 对照结论三档 + 未知：通过 / 有问题 / 未通过 / 待检查。
  ({String label, Color color, IconData icon}) _reviewStatus(NonPalette p) {
    final review = _review;
    if (review == null) {
      return (label: '待检查', color: p.ink4, icon: Icons.rule_outlined);
    }
    if (!review.ok) {
      return (label: '未通过', color: p.danger, icon: Icons.error_outline);
    }
    if (review.notes.isNotEmpty) {
      return (label: '有问题', color: p.warn, icon: Icons.info_outline);
    }
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
  /// 任何示例文档，回来时补上一次（否则主区会是空态）。上次选中的生成项目
  /// 优先续接。
  void _leaveArtifact() {
    final projectName = store.settings.videoProjectName.trim();
    setState(() => _artifactPath = null);
    if (projectName.isNotEmpty) {
      _openProject(projectName, announce: false, refresh: false);
    } else if (_doc == null) {
      _applySample(_sampleIdx);
    }
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
  ///
  /// 矢量动画与动效合成共用同一块留边：主区 14 边距，播放面自己圆角；
  /// 动效合成在播放面下方多一条运输条（它不抢画面，只是控制条）。
  Widget _authoringBody(BuildContext context) {
    final clip = _clip;
    if (clip != null) return _clipAuthoringBody(context, clip);
    final doc = _doc;
    if (doc == null) {
      return Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
              child: _previewPane(context),
            ),
          ),
          _playerHint(context),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = resolveWorkbenchLayout(
          kind: WorkbenchKind.video,
          width: constraints.maxWidth,
          height: MediaQuery.sizeOf(context).height,
        );
        final shots = videoShotsFromTimeline(doc.timeline);
        int? selected;
        for (final shot in shots) {
          if (shot.index == _selectedShotIndex) selected = shot.index;
        }
        final VideoShotItem? selectedShot = selected == null
            ? null
            : shots[selected];
        final title = _project?.title.isNotEmpty == true
            ? _project!.title
            : (doc.timeline['title'] ?? '').toString();
        final fps = _project?.document.fps ?? doc.fps;
        final total = _project?.document.totalSeconds ?? doc.totalSeconds;

        final preview = _previewPane(context);
        final tree = VideoScriptTree(
          shots: shots,
          selectedIndex: selectedShot?.index,
          onSelect: _selectShot,
        );
        final inspector = VideoShotInspector(
          shot: selectedShot,
          title: title,
          fps: fps,
          totalSeconds: total,
          shotCount: shots.length,
        );
        final director = Column(
          children: <Widget>[
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (layout.left == PanelPolicy.docked && !layout.isPhone)
                    SizedBox(width: layout.leftWidth, child: tree),
                  if (layout.left == PanelPolicy.docked && !layout.isPhone)
                    Container(width: 1, color: context.palette.line),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                      child: preview,
                    ),
                  ),
                  if (layout.right == PanelPolicy.docked)
                    Container(width: 1, color: context.palette.line),
                  if (layout.right == PanelPolicy.docked)
                    SizedBox(width: layout.rightWidth, child: inspector),
                ],
              ),
            ),
            if (!layout.isPhone)
              VideoTimelineStrip(
                shots: shots,
                selectedIndex: selectedShot?.index,
                onSelect: _selectShot,
                fps: fps,
                playheadSeconds: _playheadSeconds,
                playing: _previewPlaying,
              ),
            if (layout.isPhone) _playerHint(context),
          ],
        );
        return director;
      },
    );
  }

  Widget _playerHint(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
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
      ],
    ),
  );

  /// 动效合成主区：16:9 播放面 + 运输条 + 模式口径。
  Widget _clipAuthoringBody(BuildContext context, VideoClipInfo clip) {
    final playback = _clipPlayback;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
            child: VideoClipSurface(
              // 换短片即换实例：旧 WebView/计时器随旧播放面释放。
              key: ObjectKey(clip),
              clip: clip,
              host: store.capabilities.platform,
              playback: _injectedClipPlayback,
              onPlaybackChanged: _onClipPlayback,
            ),
          ),
        ),
        if (playback != null)
          VideoClipTransport(
            playback: playback,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.play_circle_outline,
                size: 12,
                color: context.palette.ink4,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'HTML/CSS/JS 动效合成，应用内实时播放，暂不导出成片',
                  key: const ValueKey('video-clip-hint'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: context.palette.ink4),
                ),
              ),
            ],
          ),
        ),
      ],
    );
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final labels = width >= 760;
          final showTitle = width >= 560;
          return Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 18),
                tooltip: '返回主页',
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
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
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
              ] else if (_clip != null) ...[
                // 动效合成：成品短片没有脚本可编辑，工具条只留返回主页 /
                // 规格对照（只读卡）/ 加示例。
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
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                  ),
                if (labels) const Spacer() else const SizedBox(width: 6),
                if (labels) ...[
                  _samplePicker(context, maxWidth: 260),
                  const SizedBox(width: 8),
                  _clipReviewChip(context, showLabel: true),
                  const SizedBox(width: 4),
                  _addClipSampleButton(context),
                ] else ...[
                  Flexible(child: _samplePicker(context, maxWidth: 150)),
                  const SizedBox(width: 2),
                  _clipReviewChip(context, showLabel: false),
                  const SizedBox(width: 2),
                  _addClipSampleButton(context),
                ],
              ] else ...[
                if (width >= 520) ...[
                  const SizedBox(width: 2),
                  Icon(
                    _projectName != null
                        ? Icons.video_library_outlined
                        : Icons.movie_outlined,
                    size: 17,
                    color: p.accent,
                  ),
                  const SizedBox(width: 6),
                ],
                if (showTitle)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      _projectName != null ? _projectTitle() : '视频工作台',
                      key: const ValueKey('video-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                  ),
                if (labels) const Spacer() else const SizedBox(width: 6),
                if (labels) ...[
                  _samplePicker(context, maxWidth: 240),
                  const SizedBox(width: 8),
                  _fpsControl(context),
                  const SizedBox(width: 4),
                  // 生成项目是 NaN 产出的成品，不给「编辑脚本」入口（改了也不
                  // 落盘）；示例仍保留脚本编辑。
                  if (_projectName != null)
                    _deleteProjectButton(context)
                  else
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
                  if (_projectName == null) _loadSampleButton(context),
                ] else ...[
                  Flexible(child: _samplePicker(context, maxWidth: 140)),
                  const SizedBox(width: 2),
                  _reviewChip(context, showLabel: false),
                  if (_projectName == null) _loadSampleButton(context),
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
                        child: Text(
                          '帧率 $_fps',
                          style: TextStyle(fontSize: 12, color: p.ink2),
                        ),
                      ),
                      if (_projectName != null)
                        PopupMenuItem<String>(
                          value: 'delete',
                          height: 40,
                          child: Text(
                            '删除项目',
                            style: TextStyle(fontSize: 12, color: p.ink2),
                          ),
                        )
                      else
                        PopupMenuItem<String>(
                          value: 'script',
                          height: 40,
                          child: Text(
                            '编辑脚本',
                            style: TextStyle(fontSize: 12, color: p.ink2),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ],
          );
        },
      ),
    );
  }

  /// 示例选择：两组——「矢量动画」（3 个内置示例）与「动效合成」
  /// （`clips.json` 的短片，展示 title + subtitle）。
  ///
  /// 选中即切换渲染面：矢量走 [VideoAnimationSurface]，动效合成走
  /// [VideoClipSurface] + 运输条；旧播放器在切换时释放。
  Widget _samplePicker(BuildContext context, {required double maxWidth}) {
    final p = context.palette;
    final samples = _service.samples;
    final clip = _clip;
    final clipTitle = clip?.title ?? '';
    return PopupMenuButton<Object>(
      key: const ValueKey('video-sample-picker'),
      tooltip: '选择示例',
      position: PopupMenuPosition.under,
      onSelected: (value) {
        if (value is int) {
          _selectSample(value);
        } else if (value is _ClipPick) {
          _selectClip(value.index);
        } else if (value is _ProjectPick) {
          _selectProject(value.name);
        }
      },
      color: p.panel2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: p.line),
      ),
      itemBuilder: (context) => <PopupMenuEntry<Object>>[
        // 生成项目放最上面：它是用户自己产出的内容，不是标杆示例。
        PopupMenuItem<Object>(
          enabled: false,
          height: 26,
          child: Text('生成项目', style: TextStyle(fontSize: 10, color: p.ink4)),
        ),
        if (_projectsLoading)
          PopupMenuItem<Object>(
            enabled: false,
            height: 34,
            child: Text('载入中…', style: TextStyle(fontSize: 11, color: p.ink4)),
          )
        else if (_projects.isEmpty)
          PopupMenuItem<Object>(
            enabled: false,
            height: 52,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(
                _projectsError.isEmpty
                    ? '还没有生成项目 · 在工作区里让 NaN 做一个视频，跑完后会出现在这里'
                    : _projectsError,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: p.ink4, height: 1.4),
              ),
            ),
          )
        else
          for (final entry in _projects)
            PopupMenuItem<Object>(
              value: _ProjectPick(entry.name),
              height: 54,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title.isEmpty ? entry.name : entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: clip == null && _projectName == entry.name
                          ? p.accent
                          : p.ink2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    entry.corrupt
                        ? '打不开 · 文件可能被改动'
                        : '片长 ${formatVideoTime(entry.seconds)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: p.ink4),
                  ),
                ],
              ),
            ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          enabled: false,
          height: 26,
          child: Text('矢量动画', style: TextStyle(fontSize: 10, color: p.ink4)),
        ),
        for (var i = 0; i < samples.length; i++)
          PopupMenuItem<Object>(
            value: i,
            height: 54,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  samples[i].label,
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        clip == null && _projectName == null && i == _sampleIdx
                        ? p.accent
                        : p.ink2,
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
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          enabled: false,
          height: 26,
          child: Text('动效合成', style: TextStyle(fontSize: 10, color: p.ink4)),
        ),
        if (_clipsLoading)
          PopupMenuItem<Object>(
            enabled: false,
            height: 34,
            child: Text('载入中…', style: TextStyle(fontSize: 11, color: p.ink4)),
          )
        else if (_clips.isEmpty)
          PopupMenuItem<Object>(
            enabled: false,
            height: 40,
            child: Text(
              _clipsError.isEmpty ? '暂无动效合成示例' : _clipsError,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: p.ink4),
            ),
          )
        else
          for (var i = 0; i < _clips.length; i++)
            PopupMenuItem<Object>(
              value: _ClipPick(i),
              height: 54,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _clips[i].title,
                    style: TextStyle(
                      fontSize: 12,
                      color: clip?.id == _clips[i].id ? p.accent : p.ink2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _clips[i].subtitle.isEmpty
                        ? _clips[i].file
                        : _clips[i].subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: p.ink4),
                  ),
                ],
              ),
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                clip != null
                    ? '动效合成'
                    : (_projectName != null ? '生成项目' : '标杆示例'),
                style: TextStyle(fontSize: 9, color: p.ink4),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  clip != null
                      ? clipTitle
                      : (_projectName != null
                            ? _projectTitle()
                            : (samples.isEmpty
                                  ? ''
                                  : samples[_sampleIdx.clamp(
                                          0,
                                          samples.length - 1,
                                        )]
                                        .label)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: p.ink2),
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.expand_more, size: 14, color: p.ink4),
            ],
          ),
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.speed_outlined, size: 14, color: p.ink3),
          const SizedBox(width: 5),
          Text('帧率 $_fps', style: TextStyle(fontSize: 11, color: p.ink2)),
        ],
      ),
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(status.icon, size: 13, color: status.color),
            if (showLabel) ...[
              const SizedBox(width: 5),
              Text('规范对照', style: TextStyle(fontSize: 11, color: p.ink2)),
            ],
            const SizedBox(width: 5),
            Text(
              status.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: status.color,
              ),
            ),
          ],
        ),
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

  /// 动效合成的「规格对照」：只读卡（subtitle + tags），没有脚本可对照。
  Widget _clipReviewChip(BuildContext context, {required bool showLabel}) {
    final p = context.palette;
    return InkWell(
      key: const ValueKey('video-clip-review-chip'),
      onTap: _showClipReviewSheet,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 28,
        padding: EdgeInsets.symmetric(horizontal: showLabel ? 10 : 6),
        decoration: BoxDecoration(
          color: p.accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.accent.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.rule_outlined, size: 13, color: p.accent),
            if (showLabel) ...[
              const SizedBox(width: 5),
              Text('规格对照', style: TextStyle(fontSize: 11, color: p.ink2)),
              const SizedBox(width: 5),
              Text(
                '只读',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: p.accent,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 动效合成的「加示例」：重新载入当前短片（成品合成没有脚本可编辑）。
  Widget _addClipSampleButton(BuildContext context) {
    return TextButton(
      key: const ValueKey('video-clip-add-sample'),
      onPressed: _restartClip,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      child: const Text('加示例', style: TextStyle(fontSize: 11)),
    );
  }

  /// 产物模式：播放面 + 信息行（路径 / 复制 / 桌面端在文件夹中显示）。
  Widget _artifactPane(BuildContext context, String path) {
    final p = context.palette;
    final host = store.capabilities.platform;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: VideoPlayerSurface(
                path: path,
                // 平台判定交给能力矩阵（唯一事实源）：macos/ios 走内嵌
                // WebKit，Windows/Linux 降级为路径行；不在播放面里再判
                // dart:io Platform。
                host: store.capabilities.platform,
              ),
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
          child: Row(
            children: [
              Icon(Icons.movie_outlined, size: 14, color: p.ink4),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  path,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11,
                    color: p.ink3,
                    fontFamily: 'monospace',
                  ),
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
            ],
          ),
        ),
      ],
    );
  }

  /// 生成项目当前的展示标题（读盘成功用项目标题，未读出来用项目名兜底）。
  String _projectTitle() {
    final project = _project;
    if (project != null && project.title.isNotEmpty) return project.title;
    final name = _projectName;
    if (name == null || name.isEmpty) return '视频工作台';
    return name;
  }

  Widget _deleteProjectButton(BuildContext context) {
    return TextButton.icon(
      key: const ValueKey('video-project-delete'),
      onPressed: _deleteProject,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      icon: const Icon(Icons.delete_outline, size: 15),
      label: const Text('删除项目', style: TextStyle(fontSize: 11)),
    );
  }

  /// 项目读取中：给一个「正在打开」而不是空白面板。
  Widget _projectLoadingPane(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('video-project-loading'),
      decoration: BoxDecoration(
        color: p.panel2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hourglass_empty, size: 32, color: p.ink4),
          const SizedBox(height: 10),
          Text('正在打开生成项目…', style: TextStyle(fontSize: 12, color: p.ink2)),
        ],
      ),
    );
  }

  /// 项目读失败（规范/时间线被手改坏、目录被删）：
  /// 可行动人话 + 重试/回退按钮 + 折叠的「技术详情」（原始诊断只在这里）。
  Widget _projectFailurePane(
    BuildContext context,
    VideoProjectFailure failure,
  ) {
    final p = context.palette;
    return Container(
      key: const ValueKey('video-project-error'),
      decoration: BoxDecoration(
        color: p.panel2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 38, color: p.ink4),
            const SizedBox(height: 10),
            Text(
              '这个生成项目打不开',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              failure.message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: p.ink3, height: 1.5),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  key: const ValueKey('video-project-retry'),
                  onPressed: _retryProject,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: const Text('重新读取', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  key: const ValueKey('video-project-use-sample'),
                  onPressed: _useSampleFromProjectFailure,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: const Text('用内置示例', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Material 包一层：ExpansionTile 的 ListTile 直接在带底色的
            // DecoratedBox 里会触发 Flutter 的「ink 不可见」调试断言。
            Material(
              type: MaterialType.transparency,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: _TechnicalDetails(
                  key: const ValueKey('video-project-error-details'),
                  text: failure.technical,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 主区：选中的文档直接可播；没有文档时是空态。
  /// 导演台选镜头：树/时间线/检查器同步，并把只读播放头落到镜头起点。
  void _selectShot(VideoShotItem shot) {
    setState(() {
      _selectedShotIndex = shot.index;
      _playheadSeconds = shot.start;
      _previewPlaying = false;
    });
  }

  Widget _previewPane(BuildContext context) {
    final p = context.palette;
    if (_projectName != null) {
      final failure = _projectFailure;
      if (failure != null) return _projectFailurePane(context, failure);
      if (_projectBusy) return _projectLoadingPane(context);
    }
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_outlined, size: 38, color: p.ink4),
            const SizedBox(height: 10),
            Text(
              '还没有视频',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              problem.isEmpty ? '选一个例子，点播放就能看到代码动画' : problem,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: p.ink3, height: 1.5),
            ),
          ],
        ),
      );
    }
    // 导演台：选中镜头时把预览切到该镜头起点（新实例 = 暂停在新位置，
    // 旧计时器彻底停掉）；未选中镜头则从片头开始。
    double selectedStart = 0;
    final selectedIndex = _selectedShotIndex;
    if (selectedIndex != null) {
      for (final shot in videoShotsFromTimeline(doc.timeline)) {
        if (shot.index == selectedIndex) selectedStart = shot.start;
      }
    }
    return VideoAnimationSurface(
      key: ValueKey('video-animation-${identityHashCode(doc)}-$selectedIndex'),
      document: doc,
      fps: _fps,
      initialTime: selectedStart,
      onFrame: (seconds, _) {
        if (mounted) setState(() => _playheadSeconds = seconds);
      },
      onPlayingChanged: (playing) {
        if (mounted) setState(() => _previewPlaying = playing);
      },
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  '$_value 帧/秒',
                  style: TextStyle(fontSize: 12, color: p.ink2),
                ),
                const Spacer(),
                Text('1–30', style: TextStyle(fontSize: 10, color: p.ink4)),
              ],
            ),
            Slider(
              key: const ValueKey('video-fps-slider'),
              value: _value.toDouble(),
              min: 1,
              max: 30,
              divisions: 29,
              label: '$_value',
              activeColor: p.accent,
              onChanged: (value) =>
                  setState(() => _value = value.round().clamp(1, 30)),
            ),
            Text(
              '越高画面越连贯；改动只影响播放，不改脚本本身。',
              style: TextStyle(fontSize: 10, color: p.ink4),
            ),
          ],
        ),
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
    final statusLabel = review == null
        ? '待检查'
        : (ok ? (notes.isEmpty ? '通过' : '有问题') : '未通过');
    final color = review == null
        ? p.ink4
        : (ok ? (notes.isEmpty ? p.accent : p.warn) : p.danger);
    return Material(
      key: const ValueKey('video-review-sheet'),
      color: p.bgElevated,
      clipBehavior: Clip.antiAlias,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.rule_outlined, size: 16, color: color),
                  const SizedBox(width: 6),
                  Text(
                    '规范对照',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: color.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                review?.summary ?? '还没有对照结果',
                style: TextStyle(fontSize: 11, color: p.ink3),
              ),
              if (!hasDocument) ...[
                const SizedBox(height: 8),
                Text(
                  '选一个例子，点播放就能看到代码动画',
                  style: TextStyle(fontSize: 11, color: p.ink4),
                ),
              ],
              if (problems.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '需要修正',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: p.danger,
                  ),
                ),
                for (final problem in problems)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline, size: 13, color: p.danger),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            problem,
                            style: TextStyle(
                              fontSize: 11,
                              color: p.ink2,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '值得留意',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: p.warn,
                  ),
                ),
                for (final note in notes)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 13, color: p.warn),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            note,
                            style: TextStyle(
                              fontSize: 11,
                              color: p.ink2,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              if (review != null && review.technical.isNotEmpty) ...[
                const SizedBox(height: 8),
                _TechnicalDetails(text: review.technical.join('\n')),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
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
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 折叠的「技术详情」：原始诊断只在这里出现，默认不展开。
class _TechnicalDetails extends StatelessWidget {
  const _TechnicalDetails({super.key, required this.text});

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
        title: Text(
          '技术详情',
          style: TextStyle(
            fontSize: 11,
            color: p.ink4,
            fontWeight: FontWeight.w600,
          ),
        ),
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
              style: TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                color: p.ink4,
                height: 1.4,
              ),
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
  late final TextEditingController _timeline = TextEditingController(
    text: widget.timeline,
  );
  late final TextEditingController _spec = TextEditingController(
    text: widget.spec,
  );

  @override
  void dispose() {
    _timeline.dispose();
    _spec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextStyle(
      fontSize: 11,
      fontFamily: 'monospace',
      color: p.ink2,
      height: 1.5,
    );
    return AlertDialog(
      title: const Text('编辑脚本', style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 680,
        height: 460,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 560;
            final timelineField = _field(context, '时间线脚本', _timeline, style);
            final specField = _field(context, '规范', _spec, style);
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: timelineField),
                  const SizedBox(width: 12),
                  Expanded(child: specField),
                ],
              );
            }
            return Column(
              children: [
                Expanded(child: timelineField),
                const SizedBox(height: 10),
                Expanded(child: specField),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context)
                  .pop(_ScriptDraft(_timeline.text, _spec.text)),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: p.ink3,
          ),
        ),
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
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 示例选择器的取值：动效合成短片下标（矢量动画示例直接用 int 下标）。
class _ClipPick {
  const _ClipPick(this.index);

  final int index;
}

/// 示例选择器的取值：生成项目名（用名字而不是下标——列表刷新后下标会漂）。
class _ProjectPick {
  const _ProjectPick(this.name);

  final String name;
}

String _clipStyleLabel(String style) => switch (style) {
  'hand' => '手绘',
  'motion' => '动效排版',
  'ui' => '界面演示',
  'data' => '数据',
  _ => '动效合成',
};

/// 动效合成的只读对照卡：title / subtitle / tags / 时长 / 风格。
///
/// 短片是**成品合成**（画面在 HTML 里），这里没有脚本与规范可编辑，
/// 所以只把清单里的事实摊开给用户对照，不提供任何写入口。
class _ClipReviewSheet extends StatelessWidget {
  const _ClipReviewSheet({required this.clip});

  final VideoClipInfo clip;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      key: const ValueKey('video-clip-review-sheet'),
      color: p.bgElevated,
      clipBehavior: Clip.antiAlias,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.rule_outlined, size: 16, color: p.accent),
                  const SizedBox(width: 6),
                  Text(
                    '规格对照',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: p.accent.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Text(
                      '只读',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: p.accent,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                clip.title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                ),
              ),
              if (clip.subtitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  clip.subtitle,
                  style: TextStyle(fontSize: 11, color: p.ink3, height: 1.5),
                ),
              ],
              if (clip.tags.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in clip.tags)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: p.panel2,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: p.line),
                        ),
                        child: Text(
                          '#$tag',
                          style: TextStyle(fontSize: 10, color: p.ink3),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.schedule, size: 13, color: p.ink4),
                  const SizedBox(width: 6),
                  Text(
                    '时长 ${formatVideoTime(clip.duration)}',
                    style: TextStyle(fontSize: 11, color: p.ink3),
                  ),
                  const SizedBox(width: 14),
                  Icon(Icons.brush_outlined, size: 13, color: p.ink4),
                  const SizedBox(width: 6),
                  Text(
                    _clipStyleLabel(clip.style),
                    style: TextStyle(fontSize: 11, color: p.ink3),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '这支短片是成品合成，画面与节奏由短片自身决定；这里只做只读对照。',
                style: TextStyle(fontSize: 11, color: p.ink3, height: 1.5),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.play_circle_outline, size: 12, color: p.ink4),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'HTML/CSS/JS 动效合成，应用内实时播放，暂不导出成片',
                      style: TextStyle(fontSize: 10, color: p.ink4),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
