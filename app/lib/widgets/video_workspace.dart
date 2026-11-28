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
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/capability.dart';
import '../core/inspect/check_field.dart';
import '../core/store.dart';
import '../core/theme.dart';
import '../core/workbench_docs.dart';
import '../core/workbench_layout.dart';
import '../core/toast_service.dart';
import '../core/video_clip.dart';
import '../core/video/video_screenplay.dart';
import '../core/video/video_short_evidence.dart';
import '../core/video/video_style_pack.dart';
import '../core/video/video_short_project.dart';
import '../core/video_project.dart';
import '../core/video_service.dart';
import 'aqua.dart';
import 'video_animation_surface.dart';
import 'video_clip_surface.dart';
import 'video_workbench_panels.dart';
import 'video_player_surface.dart';
import 'video_short_preview_surface.dart';
import 'workbench_views.dart';

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
    this.shortProjectStore,
    this.shortPreviewFactory,
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

  /// 测试注入：引擎短片项目库（生产用 [VideoShortProjectStore.instance]）。
  final VideoShortProjectStore? shortProjectStore;

  /// 测试注入：不构造真 WebView 的短片预览控制器工厂（生产为 null）。
  final VideoShortPreviewController Function(
    VideoScreenplay screenplay,
    VideoStylePack? style,
  )?
  shortPreviewFactory;

  @override
  State<VideoWorkspace> createState() => _VideoWorkspaceState();
}

/// 艺术架「打开」直载：切视图前设置**某个产物的 mp4 绝对路径**，本工作台
/// initState 消费后清空（与 threeLoadOnOpen 同构的跨实例通道）。
String? videoLoadOnOpen;

/// 四栏目数据装配结果：随项目读盘一次读出，切栏目不再读盘。
typedef _VideoProjectColumns = ({
  String? docs,
  List<WorkbenchSourceFile> sources,
  Object? videoMeta,
});

class _VideoWorkspaceState extends State<VideoWorkspace> {
  int _sampleIdx = 0;
  int _fps = 10;
  VideoDocument? _doc;

  /// 导演台镜头表缓存：文档实例不变就只投影一次；播放头每帧回调触发的
  /// 重建不再重算整条镜头树（[videoShotsFromTimeline] 不便宜）。
  List<VideoShotItem> _shots = const <VideoShotItem>[];
  VideoDocument? _shotsDoc;
  VideoReviewResult? _review;
  // UI-3：导演台当前选中镜头（只读检查器/时间线联动；不写事实源）。
  int? _selectedShotIndex;
  // 导演台共享播放头（由预览面回调；时间线只读呈现）。
  double _playheadSeconds = 0;
  bool _previewPlaying = false;
  final VideoAnimationController _previewController =
      VideoAnimationController();

  // ---- 引擎短片（nan.screenplay/1）——与 v1 生成项目互斥的第二种呈现面 ----
  /// 当前打开的引擎短片项目名（null = 没打开；打开时呈现效果栏目换成短片预览）。
  String? _shortProjectName;
  VideoShortProjectSnapshot? _shortSnapshot;
  VideoShortPreviewController? _shortPreview;
  bool _shortBusy = false;
  String _shortFailure = '';

  /// 当前短片风格包（null = 内置默认；存进项目 `style.json`）。
  VideoStylePack? _shortStyle;

  /// 短片抓帧运行器（注册进 AppStore 供 `video_short_render_frames` 用）；
  /// 只对当前打开的项目有效，关闭/卸载即注销。
  VideoShortCaptureRunner? _shortCaptureRunner;

  /// 通用检查器控制器（导演台选中镜头 → 右侧「检查」tab 的可编辑属性表）。
  ///
  /// 写回走工作台自己的保存链路 [_saveShotTimeline]（先按项目规范重新校验，
  /// 再原子替换 `timeline.json` / `video.json`，最后重新读盘刷新）；控制器
  /// 不持有项目事实源、不直接写盘。生命周期：首帧后注册到 store，卸载时只
  /// 清自己的注册（见 [_clearCheckControllerOnDispose]）。
  late final _VideoCheckController _checkController;

  /// 检查器写回串行闸：一次只跑一条保存链路，避免两次编辑读到同一份旧时间线
  /// 各自落盘覆盖彼此。
  Future<bool>? _checkSaveQueue;

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

  // ---- 四栏目（呈现效果 / 文档 / 规范 / 源码） --------------------------

  /// 当前栏目。用户裁决 2026-11-27：所有工作台内容区固定四栏目；框架在
  /// `widgets/workbench_views.dart`，本工作台只做数据装配，「呈现效果」=
  /// 原有导演台/预览面（行为不变）。
  WorkbenchColumn _column = WorkbenchColumn.present;

  /// 文档栏数据（`docs.md` 优先，其次 `brief.md`；null = 没有文档）。
  String? _docsMarkdown;

  /// 文档生成中：真时文档栏按钮禁用/转圈；结束（成功或失败）都复位。
  bool _docsGenerating = false;

  /// 源码栏数据（项目目录里的 timeline/规范/元数据文件；只读文本树）。
  List<WorkbenchSourceFile> _sourceFiles = const <WorkbenchSourceFile>[];

  /// `video.json` 的原始对象（规范栏里与 spec.json 并排展示；读不出时用
  /// 快照里的标题/片长/帧率兜底，不编造来源字段）。
  Object? _videoMetaJson;

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

  /// 动效合成的播放位置（秒）：短片 WebView 归播放面所有，切走栏目会卸载
  /// 播放面；回到呈现效果时按这个位置载入，不回到片头（也不假装还在播）。
  double _clipResumeSeconds = 0;

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
    // 通用检查器：导演台选中镜头 → 属性表；写回走本工作台的保存链路。
    _checkController = _VideoCheckController(
      projectOf: () => _project,
      selectedShotIndexOf: () => _selectedShotIndex,
      save: _saveShotTimeline,
      onReject: _rejectCheckEdit,
    );

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

    // 检查控制器等首帧后再注册：setCheckController 会 notifyListeners，构建期
    // 通知会标脏祖先。产物播放模式在 initState 早退，没有镜头可选，不注册。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _appStore?.setCheckController(_checkController);
    });
  }

  @override
  void dispose() {
    // 切视图即销毁工作台：store 监听与注入的播放源都不能留下。
    _appStore?.removeListener(_onStoreChanged);
    // 清空检查控制器注册（只清自己的；控制器不 dispose——右侧面板可能还在
    // 移除监听，ChangeNotifier dispose 后再 removeListener 会断言失败）。
    _clearCheckControllerOnDispose();
    _appStore = null;
    _releaseClipPlayback();
    _unregisterShortCapture();
    _shortPreview?.dispose();
    _shortPreview = null;
    _previewController.dispose();
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
      // 切项目 = 切镜头表：旧项目的选中镜头不能带过来。
      _selectedShotIndex = null;
      // 切项目 = 切内容：四栏目回到呈现效果，旧项目的文档/源码不能带过来。
      _column = WorkbenchColumn.present;
      _docsMarkdown = null;
      _docsGenerating = false;
      _sourceFiles = const <WorkbenchSourceFile>[];
      _videoMetaJson = null;
    });
    _checkController.notifySelectionChanged();
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
      // 四栏目数据与项目读盘同一拍装配：文档/源码/元数据都在项目目录里，
      // 读一次缓存；切栏目不再读盘，也不伪造内容。
      final _VideoProjectColumns columns = _readProjectColumns(snapshot);
      setState(() {
        _project = snapshot;
        _docsMarkdown = columns.docs;
        _sourceFiles = columns.sources;
        _videoMetaJson = columns.videoMeta;
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
      // 新时间线就位 → 检查器重取当前镜头的属性值。
      _checkController.notifySelectionChanged();
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
      _selectedShotIndex = null;
      _project = null;
      _projectFailure = failure;
      _projectBusy = false;
      _doc = null;
      // 坏项目：栏目条常显，但呈现效果要露在用户眼前（错误面不是空态）；
      // 其余栏目如实空态，不拿上一个项目的说明冒充这个项目。
      _column = WorkbenchColumn.present;
      _docsMarkdown = null;
      _docsGenerating = false;
      _sourceFiles = const <WorkbenchSourceFile>[];
      _videoMetaJson = null;
      _review = VideoReviewResult(
        ok: false,
        totalSeconds: 0,
        problems: <String>[failure.message],
        notes: const <String>[],
        technical: <String>[failure.technical],
      );
    });
    _checkController.notifySelectionChanged();
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
    // 没有生成项目 = 检查器没有可编辑镜头（内置示例只读）。
    _selectedShotIndex = null;
    // 内容切走（示例/动效合成）：四栏目回到呈现效果，项目数据不能留在栏目里。
    _column = WorkbenchColumn.present;
    _docsMarkdown = null;
    _docsGenerating = false;
    _sourceFiles = const <WorkbenchSourceFile>[];
    _videoMetaJson = null;
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
    _checkController.notifySelectionChanged();
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

  // ------------------------------------------------------------ 检查器写回

  /// 检查器非法值/保存失败的人话提示（上屏；原始诊断不进用户文案）。
  void _rejectCheckEdit(String message) {
    if (!mounted) return;
    _toasts.warn(message);
  }

  /// 卸载时清空检查控制器注册：只清自己的（别的工作台可能已经接管）。
  ///
  /// dispose 常发生在构建期（视图切换），notifyListeners 会标脏祖先，因此推到
  /// 帧末并先判身份。控制器不 dispose——右侧面板可能还在移除监听，
  /// ChangeNotifier dispose 后再 removeListener 会断言失败。
  void _clearCheckControllerOnDispose() {
    final AppStore? appStore = _appStore;
    final _VideoCheckController controller = _checkController;
    if (appStore == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (appStore.checkController == controller) {
        appStore.setCheckController(null);
      }
    });
  }

  /// 检查器写回串行化：前一条保存链路跑完再跑下一条（两次编辑不能各自读到
  /// 同一份旧时间线、互相覆盖）。
  Future<bool> _saveShotTimeline(Map<String, dynamic> timeline) {
    final Future<bool> previous = _checkSaveQueue ?? Future<bool>.value(true);
    final Future<bool> result = previous.then(
      (_) => _persistShotTimeline(timeline),
    );
    _checkSaveQueue = result;
    unawaited(
      result.whenComplete(() {
        if (identical(_checkSaveQueue, result)) _checkSaveQueue = null;
      }),
    );
    return result;
  }

  /// 把检查器编辑结果写回项目：先按项目规范重新校验
  ///（[VideoDocument.build] 预编译全量算式），再原子替换 `timeline.json` /
  /// `video.json`，最后重新读盘刷新播放面与镜头表。
  ///
  /// 返回值 = 本次编辑是否「落盘且刷新成功」；控制器靠它区分成功与拒绝，
  /// 失败时绝不伪造成功。
  Future<bool> _persistShotTimeline(Map<String, dynamic> timeline) async {
    final VideoProjectSnapshot? project = _project;
    final String? name = _projectName;
    if (!mounted || project == null || name == null) return false;
    final VideoDocument document;
    try {
      document = VideoDocument.build(
        timeline: timeline,
        spec: project.spec,
        baseDir: Directory(project.dir),
      );
    } on VideoRejected catch (error) {
      _rejectCheckEdit(videoFailureMessage(error));
      return false;
    } catch (_) {
      _rejectCheckEdit('这次修改没有通过校验，项目文件保持不变。');
      return false;
    }
    try {
      _writeProjectTimeline(
        dir: project.dir,
        timeline: timeline,
        document: document,
        title: project.title,
      );
    } catch (_) {
      _rejectCheckEdit('项目文件没能写入，请重试。');
      return false;
    }
    await _loadProject(name);
    if (!mounted) return false;
    final bool saved = _project != null && _projectFailure == null;
    if (saved) _checkController.notifySelectionChanged();
    return saved;
  }

  /// 原子替换项目的事实源：`timeline.json` + `video.json`（元数据片长/帧率）。
  ///
  /// 两份先写同目录临时文件并 flush，再逐个改名替换；只动这两个文件，
  /// `docs.md` / 规范文件 / 其它源码一律不碰。改名失败时目标文件保持旧内容
  ///（Windows 目标在场时先删再改名）。
  void _writeProjectTimeline({
    required String dir,
    required Map<String, dynamic> timeline,
    required VideoDocument document,
    required String title,
  }) {
    const JsonEncoder encoder = JsonEncoder.withIndent('  ');
    final String timelineText = '${encoder.convert(timeline)}\n';
    final Map<String, dynamic> meta = <String, dynamic>{};
    final File metaFile = File('$dir/video.json');
    if (metaFile.existsSync()) {
      try {
        final Object? decoded = jsonDecode(metaFile.readAsStringSync());
        if (decoded is Map) meta.addAll(Map<String, dynamic>.from(decoded));
      } catch (_) {
        // 元数据坏了不阻塞编辑：重建一份最小元数据（标题/片长/帧率）。
      }
    }
    if ('${meta['title'] ?? ''}'.trim().isEmpty) meta['title'] = title;
    meta['seconds'] = document.totalSeconds;
    meta['fps'] = document.fps;
    final String metaText = '${encoder.convert(meta)}\n';
    final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
    final File timelineTmp = File('$dir/.timeline.json.$stamp.tmp');
    final File metaTmp = File('$dir/.video.json.$stamp.tmp');
    try {
      _writeFlushed(timelineTmp, timelineText);
      _writeFlushed(metaTmp, metaText);
      _replaceWithTmp(timelineTmp, File('$dir/timeline.json'));
      _replaceWithTmp(metaTmp, metaFile);
    } finally {
      _deleteQuietlyFile(timelineTmp);
      _deleteQuietlyFile(metaTmp);
    }
  }

  /// 临时文件写入并 flush：没 flush 的改名在掉电/崩溃时会变成半截文件。
  static void _writeFlushed(File file, String text) {
    final RandomAccessFile handle = file.openSync(mode: FileMode.writeOnly);
    try {
      handle.writeStringSync(text);
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
  }

  /// 原子替换：先 rename；Windows 目标在场时 rename 可能失败，先删目标再改名。
  static void _replaceWithTmp(File tmp, File target) {
    try {
      tmp.renameSync(target.path);
    } on FileSystemException {
      if (target.existsSync()) target.deleteSync();
      tmp.renameSync(target.path);
    }
  }

  /// 清掉残留临时文件；清理失败不能盖掉原始错误。
  static void _deleteQuietlyFile(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// 删除当前生成项目（确认后删目录、清设置、回退到内置示例）。
  Future<void> _deleteProject() async {
    final name = _projectName;
    if (name == null) return;
    final title = _project?.title.isNotEmpty == true ? _project!.title : name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(
          '删除生成项目',
          style: TextStyle(fontSize: NonType.subtitle),
        ),
        content: Text(
          '「$title」会从磁盘上删除，删掉后不能恢复。',
          style: TextStyle(fontSize: NonType.body, height: NonType.lineBody),
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
    _checkController.notifySelectionChanged();
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
    _checkController.notifySelectionChanged();
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
    _clipResumeSeconds = 0;
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
      case 'short':
        // 引擎短片是第二种呈现面；打开入口固定在「更多」里，不依赖空态。
        if (mounted) await _pickShortProject(context);
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
    // 产物播放（艺术架点开的既有 mp4）是「播既有产物」的直达入口，不是项目
    // 创作面：没有文档/规范/源码可展示，保留原布局、不套四栏目，也不因切栏目
    // 重建播放 WebView（那会打断正在看的成片）。
    if (artifact != null) {
      return Column(
        children: [
          _header(context, artifact: artifact),
          Expanded(child: _artifactPane(context, artifact)),
        ],
      );
    }
    // 四栏目（用户裁决 2026-11-27）：顶部固定栏目条 + 内容区。呈现效果 =
    // 原有导演台/播放面（行为不变）；切到文档/规范/源码时不构建呈现面子树，
    // 也不触碰播放面控制器。
    return Column(
      children: [
        _header(context, artifact: null),
        Expanded(
          child: WorkbenchColumns(
            column: _column,
            onColumnChanged: _onColumnChanged,
            data: _columnData(),
            // 文档栏目动作：按项目事实源确定性生成 docs.md；内置示例/产物/坏项目
            // 没有磁盘事实源 → 不提供入口（null），生成中按钮禁用/转圈。
            onGenerateDocs: _docsGenerateAction,
            docsGenerating: _docsGenerating,
            present: Builder(
              builder: (BuildContext context) => _authoringBody(context),
            ),
          ),
        ),
      ],
    );
  }

  /// 栏目切换：离开呈现效果时记下动效合成的播放位置，回来按它重新载入。
  void _onColumnChanged(WorkbenchColumn column) {
    if (_column == column) return;
    setState(() {
      if (column != WorkbenchColumn.present) {
        final VideoClipPlayback? playback = _clipPlayback;
        if (_clip != null && playback != null) {
          _clipResumeSeconds = playback.t;
        }
        // 短片播放源归播放面所有；离开呈现效果会卸载播放面，这里先摘掉
        // 运输条引用，回来由播放面重新回调（不等一个已被释放的播放源）。
        _clipPlayback = null;
      } else {
        // 注入的播放源（测试/外托管）不随播放面销毁：回来直接接回运输条。
        final VideoClipPlayback? injected = _injectedClipPlayback;
        if (_clip != null && injected != null) _clipPlayback = injected;
      }
      _column = column;
    });
  }

  /// 四栏目数据袋：只读装配；没有项目就是可行动空态，不伪造内容。
  WorkbenchColumnData _columnData() {
    final VideoProjectSnapshot? project = _project;
    if (project == null) return const WorkbenchColumnData();
    final Object meta =
        _videoMetaJson ??
        <String, Object?>{
          'title': project.title,
          'seconds': project.document.totalSeconds,
          'fps': project.document.fps,
        };
    final Object? scenes = project.timeline['scenes'];
    final int shots = scenes is List ? scenes.length : 0;
    return WorkbenchColumnData(
      docsMarkdown: _docsMarkdown,
      // 规范栏：把项目里的机器可读事实源按文件名并排展示——video.json
      // （元数据：标题/片长/帧率）与 timeline 指向的规范文件（剧本科普）。
      specJson: <String, Object?>{
        'video.json': meta,
        _specFileName(project.timeline): project.spec,
      },
      specSummary:
          '$shots 个镜头 · 时长 ${formatVideoTime(project.document.totalSeconds)} · '
          '${project.document.fps} fps',
      sourceFiles: _sourceFiles,
    );
  }

  /// 规范文件名（与 [VideoProjectStore] 的解析规则一致：同目录普通文件名；
  /// 坏引用退回 `spec.json`）。
  static String _specFileName(Map<String, dynamic> timeline) {
    final Object? ref = timeline['spec'];
    if (ref is String) {
      final String name = ref.trim();
      if (name.isNotEmpty && !name.contains('/') && !name.contains('\\')) {
        return name;
      }
    }
    return 'spec.json';
  }

  // -- 生成文档（文档栏的「生成/重新生成」动作） ----------------------------
  //
  // 生成物 = 项目事实源的确定性投影（`core/workbench_docs.dart`，不调模型）：
  // 视频的摘要 = 标题（video.json）/ 总时长与帧率 / 镜头表（时长 + 分镜说明）。
  // 只读项目快照与磁盘，不写 timeline/spec/video.json；写盘失败不破坏既有文档。
  // 只有生成项目有磁盘事实源；内置示例/动效合成/产物播放都没有可写的项目目录，
  // 不提供入口（文档栏只给可行动空态）。

  /// 「生成文档」动作：没有生成项目或坏项目（读不出快照）时为 null。
  VoidCallback? get _docsGenerateAction {
    if (_project == null || _projectName == null) return null;
    return () => unawaited(_generateDocs());
  }

  /// 生成/重新生成文档：原子写 `docs.md`（overwrite: true）→ 同步重读刷新
  /// 文档栏。生成中 [_docsGenerating] 为真（按钮禁用/转圈），无论成功失败都复位。
  Future<void> _generateDocs() async {
    if (_docsGenerating) return;
    final VideoProjectSnapshot? project = _project;
    final String? name = _projectName;
    if (!mounted || project == null || name == null) return;
    setState(() => _docsGenerating = true);
    final Directory projectDir = Directory(project.dir);
    String? docs;
    bool failed = false;
    try {
      final File? written = await writeWorkbenchDoc(
        projectDir: projectDir,
        kind: 'video',
        name: name,
        title: project.title,
        summary: _docsSummaryOf(project),
        overwrite: true,
      );
      if (written == null) {
        failed = true;
      } else {
        // 重读刚写出的 docs.md（与栏目同一读盘口径：同步读，widget 测试下
        // 不需要额外等一次真实异步 IO）。
        docs = _readProjectDocs(projectDir.path);
        if (docs == null) failed = true;
      }
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      _docsGenerating = false;
      if (!failed && _projectName == name) _docsMarkdown = docs;
    });
    // 生成期间切了项目：这次结果只属于原项目，提示不能落到新项目上。
    if (_projectName != name) return;
    if (failed) {
      _toasts.warn('文档没能写入，请重试');
      return;
    }
    _toasts.success('文档已生成');
  }

  /// 文档生成器要的人话摘要（只读快照/磁盘事实源，字段按 workbench_docs 契约
  /// 命名）。总时长/帧率取已校验文档（与播放面同一份编译结果）。
  Map<String, Object?> _docsSummaryOf(VideoProjectSnapshot project) {
    return <String, Object?>{
      'title': project.title,
      'totalSeconds': project.document.totalSeconds,
      'fps': project.document.fps,
      'shots': _docsShotsOf(project),
    };
  }

  /// 镜头表：一幕一行。时长取时间线场景（结构化事实源）；文本取规范
  /// `storyboard` 同序号的说明——幕数与说明数一致时才配对，避免张冠李戴；
  /// 对不上/没有分镜说明时如实留空（生成器渲染「未记录」，不编造）。
  List<Object?> _docsShotsOf(VideoProjectSnapshot project) {
    final Object? scenes = project.timeline['scenes'];
    if (scenes is! List) return const <Object?>[];
    final Object? rawStoryboard = project.spec['storyboard'];
    final List<Object?> storyboard = rawStoryboard is List
        ? rawStoryboard.cast<Object?>()
        : const <Object?>[];
    final bool paired = storyboard.length == scenes.length;
    return <Object?>[
      for (int i = 0; i < scenes.length; i++)
        <String, Object?>{
          'duration': scenes[i] is Map ? (scenes[i] as Map)['duration'] : null,
          'text': paired && storyboard[i] is Map
              ? (storyboard[i] as Map)['note']
              : null,
        },
    ];
  }

  /// 四栏目数据装配：文档/源码/元数据都在项目目录里，读盘一次缓存。
  ///
  /// 源码只收项目事实源（timeline.json / 规范文件 / video.json），不含
  /// artifacts 与任何缓存；单个文件读不出来就不列（不显示半截伪造内容）。
  _VideoProjectColumns _readProjectColumns(VideoProjectSnapshot project) {
    final String dir = project.dir;
    final String specName = _specFileName(project.timeline);
    final List<WorkbenchSourceFile> sources = <WorkbenchSourceFile>[];
    for (final String name in <String>[
      'timeline.json',
      specName,
      'video.json',
    ]) {
      if (sources.any((WorkbenchSourceFile file) => file.path == name)) {
        continue;
      }
      final String? text = _readProjectText('$dir/$name');
      if (text != null) {
        sources.add(WorkbenchSourceFile(path: name, content: text));
      }
    }
    return (
      docs: _readProjectDocs(dir),
      sources: sources,
      videoMeta: _readProjectJson('$dir/video.json'),
    );
  }

  /// 项目内人读文档：`docs.md` 优先，其次 `brief.md`；空文件按没有文档。
  String? _readProjectDocs(String dir) {
    for (final String name in const <String>['docs.md', 'brief.md']) {
      final String? text = _readProjectText('$dir/$name');
      if (text != null) return text;
    }
    return null;
  }

  /// 读项目目录内一个文本文件；缺失/读失败/空白一律 null。
  String? _readProjectText(String path) {
    final File file = File(path);
    if (!file.existsSync()) return null;
    try {
      final String text = file.readAsStringSync();
      return text.trim().isEmpty ? null : text;
    } on FileSystemException {
      return null;
    }
  }

  /// 读项目目录内一个 JSON 对象；缺失/坏格式/根不是对象一律 null。
  Object? _readProjectJson(String path) {
    final String? text = _readProjectText(path);
    if (text == null) return null;
    try {
      final Object? decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// 导演台镜头表：按文档实例缓存（时间线不变就不重新投影）。
  List<VideoShotItem> _shotsFor(VideoDocument doc) {
    if (!identical(_shotsDoc, doc)) {
      _shotsDoc = doc;
      _shots = videoShotsFromTimeline(doc.timeline);
    }
    return _shots;
  }

  /// 一块播放面铺满主区 + 底部一行不抢画面的提示。
  ///
  /// 矢量动画与动效合成共用同一块留边：主区 14 边距，播放面自己圆角；
  /// 动效合成在播放面下方多一条运输条（它不抢画面，只是控制条）。
  // ---------------------------------------------------------- 引擎短片

  VideoShortProjectStore get _shortStore =>
      widget.shortProjectStore ?? VideoShortProjectStore.instance;

  /// 注册短片抓帧运行器：只认当前打开的项目名（别拿别的项目冒充取证源）。
  void _registerShortCapture(String name, VideoShortPreviewController preview) {
    final AppStore? appStore = _appStore;
    _unregisterShortCapture();
    if (appStore == null) return;
    Future<List<VideoShortFrameEvidence>> runner(
      String project,
      List<int> frames,
    ) async {
      if (project != name) {
        throw VideoShortEvidenceError(
          videoShortCaptureUnavailableCode,
          '抓帧需要先在视频工作台打开这个引擎短片',
          'open=$name requested=$project',
        );
      }
      return preview.captureFrames(frames);
    }

    _shortCaptureRunner = runner;
    appStore.registerVideoShortCaptureRunner(runner);
  }

  /// 注销抓帧运行器（只注销自己注册的那个）。
  void _unregisterShortCapture() {
    final AppStore? appStore = _appStore;
    final VideoShortCaptureRunner? runner = _shortCaptureRunner;
    _shortCaptureRunner = null;
    if (appStore != null && runner != null) {
      appStore.unregisterVideoShortCaptureRunner(runner);
    }
  }

  /// 打开引擎短片项目：读盘 → 校验 → 建预览控制器 → 起播（与 v1 项目互斥）。
  Future<void> _openShortProject(String name) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty || _shortBusy) return;
    setState(() {
      _shortBusy = true;
      _shortFailure = '';
      _shortProjectName = trimmed;
    });
    VideoShortProjectSnapshot snapshot;
    try {
      snapshot = await _shortStore.read(trimmed);
    } on VideoShortProjectFailure catch (error) {
      if (!mounted) return;
      setState(() {
        _shortBusy = false;
        _shortFailure = videoShortProjectFailureMessage(error.code);
      });
      return;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _shortBusy = false;
        _shortFailure = '引擎短片项目打不开，可以重试';
      });
      return;
    }
    if (!mounted) return;
    final VideoScreenplay? screenplay = snapshot.verification.verified
        ? snapshot.verification.screenplay
        : null;
    if (screenplay == null) {
      setState(() {
        _shortBusy = false;
        _shortFailure = '剧本没有通过校验，先在「规范」栏目改好再打开';
      });
      return;
    }
    // 风格包：读不到/坏了不拦打开（回默认风格），但如实记进失败行。
    VideoStylePack? style;
    String styleNote = '';
    try {
      style = await _shortStore.readStyle(trimmed);
    } on VideoShortProjectFailure catch (error) {
      styleNote = '风格包不可用：${videoShortProjectFailureMessage(error.code)}';
    }
    if (!mounted) return;
    _shortPreview?.dispose();
    final VideoShortPreviewController preview =
        widget.shortPreviewFactory?.call(screenplay, style) ??
        VideoShortWebPreview(screenplay: screenplay, stylePack: style);
    setState(() {
      _shortSnapshot = snapshot;
      _shortPreview = preview;
      _shortBusy = false;
      _shortStyle = style;
      if (styleNote.isNotEmpty) _shortFailure = '';
    });
    _registerShortCapture(trimmed, preview);
    unawaited(preview.start());
  }

  /// 切换短片风格包：存进项目 `style.json`，再用新风格重建预览面。
  Future<void> _applyShortStyle(VideoStylePack? style) async {
    final String? name = _shortProjectName;
    final VideoShortProjectSnapshot? snapshot = _shortSnapshot;
    if (name == null || snapshot == null || _shortBusy) return;
    final VideoScreenplay? screenplay = snapshot.verification.screenplay;
    if (screenplay == null) return;
    setState(() => _shortBusy = true);
    if (style != null) {
      try {
        final VideoStylePackVerification saved = await _shortStore.saveStyle(
          name,
          style.raw,
        );
        if (!saved.verified) {
          if (!mounted) return;
          setState(() {
            _shortBusy = false;
            _shortFailure = '风格包没有通过校验';
          });
          return;
        }
      } on VideoShortProjectFailure catch (error) {
        if (!mounted) return;
        setState(() {
          _shortBusy = false;
          _shortFailure = videoShortProjectFailureMessage(error.code);
        });
        return;
      }
    }
    if (!mounted) return;
    // 重建预览面：风格是页面组装期输入，改了必须重挂（不是运行时改色）。
    _unregisterShortCapture();
    final VideoShortPreviewController? previous = _shortPreview;
    _shortPreview = null;
    previous?.dispose();
    final VideoShortPreviewController preview =
        widget.shortPreviewFactory?.call(screenplay, style) ??
        VideoShortWebPreview(screenplay: screenplay, stylePack: style);
    setState(() {
      _shortStyle = style;
      _shortPreview = preview;
      _shortBusy = false;
      _shortFailure = '';
    });
    _registerShortCapture(name, preview);
    unawaited(preview.start());
  }

  /// 关闭引擎短片：释放预览控制器（WebView 随之卸载），回到 v1 空态。
  void _closeShortProject() {
    _unregisterShortCapture();
    final VideoShortPreviewController? preview = _shortPreview;
    _shortPreview = null;
    // 先清状态再释放控制器：dispose 会触发监听者重建，若先 dispose 后 setState，
    // 期间任何异常都会把「回到 v1 呈现面」这一步吞掉（真机/测试都出现过）。
    if (mounted) {
      setState(() {
        _shortProjectName = null;
        _shortSnapshot = null;
        _shortStyle = null;
        _shortFailure = '';
      });
    }
    preview?.dispose();
  }

  /// 选一个引擎短片项目打开（列不出来的坏项目如实标出、不静默隐藏）。
  Future<void> _pickShortProject(BuildContext context) async {
    List<VideoShortProjectEntry> entries;
    try {
      entries = await _shortStore.list();
    } catch (_) {
      entries = const <VideoShortProjectEntry>[];
    }
    if (!mounted) return;
    if (entries.isEmpty) {
      _toasts.warn('还没有引擎短片项目', '可以让 NaN 用 video_short_create 建一个。');
      return;
    }
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('打开引擎短片'),
        content: SizedBox(
          width: 360,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: entries.length,
            itemBuilder: (BuildContext context, int index) {
              final VideoShortProjectEntry entry = entries[index];
              final String detail = entry.corrupt
                  ? '剧本损坏'
                  : '${entry.shots} 镜头 · ${entry.frames} 帧'
                      '${entry.verified ? '' : ' · 未通过校验'}';
              return ListTile(
                title: Text(entry.name),
                subtitle: Text(detail),
                enabled: !entry.corrupt,
                onTap: () => Navigator.of(dialogContext).pop(entry.name),
              );
            },
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await _openShortProject(picked);
  }

  /// 呈现效果栏目里的短片面（项目名 + 关闭 + 预览面/失败面）。
  Widget _shortAuthoringBody(BuildContext context) {
    final p = context.palette;
    final VideoShortPreviewController? preview = _shortPreview;
    return Column(
      key: const ValueKey('video-short-authoring'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NonSpace.lg,
            NonSpace.sm,
            NonSpace.sm,
            NonSpace.xs,
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.auto_awesome_motion_outlined, size: 14, color: p.ink4),
              const SizedBox(width: NonSpace.sm),
              Flexible(
                child: Text(
                  '引擎短片 · ${_shortProjectName ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NonType.bodyStrong,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
              ),
              const Spacer(),
              if (_shortSnapshot?.screenplay != null)
                Text(
                  '${_shortSnapshot!.screenplay!.width}×'
                  '${_shortSnapshot!.screenplay!.height} · '
                  '${_shortSnapshot!.screenplay!.totalFrames} 帧',
                  style: TextStyle(fontSize: NonType.micro, color: p.ink4),
                ),
              // 风格包选择（内置预设）：改了就存进项目并重建预览面。
              PopupMenuButton<String>(
                key: const ValueKey('video-short-style'),
                tooltip: '风格包',
                initialValue: _shortStyle?.id ?? 'default_dark',
                onSelected: (String id) {
                  unawaited(_applyShortStyle(videoStylePackPreset(id)));
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  for (final String id in videoStylePackPresets.keys)
                    PopupMenuItem<String>(
                      value: id,
                      height: 38,
                      child: Text(
                        videoStylePackLabel(id),
                        style: TextStyle(
                          fontSize: NonType.body,
                          color: p.ink2,
                        ),
                      ),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NonSpace.sm,
                    vertical: NonSpace.xxs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.palette_outlined, size: 14, color: p.ink3),
                      const SizedBox(width: NonSpace.xxs),
                      Text(
                        videoStylePackLabel(
                          _shortStyle?.id ?? 'default_dark',
                        ),
                        style: TextStyle(
                          fontSize: NonType.caption,
                          color: p.ink2,
                        ),
                      ),
                      Icon(Icons.arrow_drop_down, size: 16, color: p.ink4),
                    ],
                  ),
                ),
              ),
              // 紧凑图标按钮：窄屏工具条也要放得下（文字按钮会溢出把按钮挤出屏幕）。
              IconButton(
                key: const ValueKey('video-short-open-another'),
                onPressed: () => _pickShortProject(context),
                tooltip: '换一个',
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 30,
                  minHeight: 30,
                ),
                icon: const Icon(Icons.swap_horiz),
              ),
              IconButton(
                key: const ValueKey('video-short-close'),
                onPressed: _closeShortProject,
                tooltip: '关闭',
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 30,
                  minHeight: 30,
                ),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              NonSpace.lg,
              NonSpace.xs,
              NonSpace.lg,
              NonSpace.lg,
            ),
            child: _shortBusy
                ? Center(
                    child: Text(
                      '正在打开…',
                      style: TextStyle(fontSize: NonType.body, color: p.ink4),
                    ),
                  )
                : _shortFailure.isNotEmpty
                ? Center(
                    child: Text(
                      _shortFailure,
                      key: const ValueKey('video-short-open-failure'),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: NonType.body, color: p.warn),
                    ),
                  )
                : preview == null
                ? const SizedBox.shrink()
                : VideoShortPreviewSurface(preview: preview),
          ),
        ),
      ],
    );
  }

  Widget _authoringBody(BuildContext context) {
    // 引擎短片是第二种呈现面：打开时直接替换整个呈现效果栏目。
    if (_shortProjectName != null) return _shortAuthoringBody(context);
    final clip = _clip;
    if (clip != null) return _clipAuthoringBody(context, clip);
    final doc = _doc;
    if (doc == null) {
      return Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                NonSpace.lg,
                NonSpace.lg,
                NonSpace.lg,
                NonSpace.sm,
              ),
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
          // 用工作台自己的约束高度（不是整窗高度）：嵌入壳/画中画同样正确。
          width: constraints.maxWidth,
          height: constraints.maxHeight,
        );
        final shots = _shotsFor(doc);
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
          // 宽屏（右栏常驻）时右侧共享窄栏的「检查」tab 才是编辑入口；内容区
          // 这块检查器降级为只读摘要，避免同一属性两处可编辑却不同步。
          readOnly: layout.right == PanelPolicy.docked,
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
                      padding: const EdgeInsets.fromLTRB(
                        NonSpace.md,
                        NonSpace.md,
                        NonSpace.md,
                        NonSpace.sm,
                      ),
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
                controller: _previewController,
                // 底栏高度来自视频工作台规格（WorkbenchLayout），不再写死 92。
                height: layout.bottomBarHeight,
              ),
            if (layout.isPhone) _playerHint(context),
          ],
        );
        return director;
      },
    );
  }

  Widget _playerHint(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      NonSpace.lg,
      0,
      NonSpace.lg,
      NonSpace.sm,
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.play_circle_outline, size: 12, color: context.palette.ink4),
        const SizedBox(width: NonSpace.sm),
        Flexible(
          child: Text(
            '代码动画直接播放，暂不导出成片',
            key: const ValueKey('video-player-hint'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NonType.micro,
              color: context.palette.ink4,
            ),
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
            padding: const EdgeInsets.fromLTRB(
              NonSpace.lg,
              NonSpace.lg,
              NonSpace.lg,
              NonSpace.sm,
            ),
            child: VideoClipSurface(
              // 换短片即换实例：旧 WebView/计时器随旧播放面释放。
              key: ObjectKey(clip),
              clip: clip,
              host: store.capabilities.platform,
              playback: _injectedClipPlayback,
              // 从其它栏目切回呈现效果时按离开时的位置载入（不回到片头，
              // 也不假装还在播——页面以暂停态打开）。
              initialTime: _clipResumeSeconds > 0 ? _clipResumeSeconds : null,
              onPlaybackChanged: _onClipPlayback,
            ),
          ),
        ),
        if (playback != null)
          VideoClipTransport(
            playback: playback,
            padding: const EdgeInsets.fromLTRB(
              NonSpace.lg,
              0,
              NonSpace.lg,
              NonSpace.sm,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NonSpace.lg,
            0,
            NonSpace.lg,
            NonSpace.sm,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.play_circle_outline,
                size: 12,
                color: context.palette.ink4,
              ),
              const SizedBox(width: NonSpace.sm),
              Flexible(
                child: Text(
                  'HTML/CSS/JS 动效合成，应用内实时播放，暂不导出成片',
                  key: const ValueKey('video-clip-hint'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NonType.micro,
                    color: context.palette.ink4,
                  ),
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
    // 浅色（Aqua）：工具条白面 + 发丝线 + 深色软阴影（静态装饰，不影响布局测量）；
    // 深色保持原底。
    final bool aqua = isAquaTheme(context);
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: aqua ? p.panel : p.bgElevated,
        border: Border(bottom: BorderSide(color: p.line)),
        boxShadow: aqua
            ? <BoxShadow>[
                BoxShadow(
                  color: p.line,
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      // 窄屏（320 手机/画中画）工具条内容多：水平内边距压到 sm，
      // 保证 1.1x 字号缩放下也不横向溢出。
      padding: const EdgeInsets.symmetric(horizontal: NonSpace.sm),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final labels = width >= 760;
          final showTitle = width >= 560;
          return Row(
            children: [
              if (isAquaTheme(context))
                // 浅色（Aqua）：裸 IconButton 换 AquaToolIcon 白面圆钮；槽位
                // 固定 40（与 IconButton 实测同尺寸），工具条测量尺寸不变。
                SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: AquaToolIcon(
                      icon: Icons.arrow_back,
                      tooltip: '返回主页',
                      size: 28,
                      onTap: () => store.setView('home'),
                    ),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 18),
                  tooltip: '返回主页',
                  color: p.ink2,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  // 视频是独立工作区：返回的是主页（模块入口），不是某个设计项目
                  // 的画布——工作区之间不互相挂靠。
                  onPressed: () => store.setView('home'),
                ),
              if (artifact != null) ...[
                const SizedBox(width: NonSpace.xxs),
                Icon(Icons.movie_outlined, size: 17, color: p.accent),
                const SizedBox(width: NonSpace.sm),
                Flexible(
                  child: Text(
                    '视频产物 · ${_artifactName(artifact)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: NonType.bodyStrong,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                ),
                const SizedBox(width: NonSpace.sm),
                TextButton(
                  onPressed: _leaveArtifact,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(
                      horizontal: NonSpace.sm,
                    ),
                  ),
                  child: const Text(
                    '返回创作台',
                    style: TextStyle(fontSize: NonType.caption),
                  ),
                ),
                const Spacer(),
              ] else if (_clip != null) ...[
                // 动效合成：成品短片没有脚本可编辑，工具条只留返回主页 /
                // 规格对照（只读卡）/ 加示例。
                if (width >= 520) ...[
                  const SizedBox(width: NonSpace.xxs),
                  Icon(Icons.movie_outlined, size: 17, color: p.accent),
                  const SizedBox(width: NonSpace.sm),
                ],
                if (showTitle)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      '视频工作台',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: NonType.bodyStrong,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                  ),
                if (labels)
                  const Spacer()
                else
                  const SizedBox(width: NonSpace.sm),
                if (labels) ...[
                  _samplePicker(context, maxWidth: 260),
                  const SizedBox(width: NonSpace.sm),
                  _clipReviewChip(context, showLabel: true),
                  const SizedBox(width: NonSpace.xs),
                  _addClipSampleButton(context),
                ] else ...[
                  Flexible(
                    child: _samplePicker(
                      context,
                      maxWidth: width < 420 ? 120 : 150,
                    ),
                  ),
                  const SizedBox(width: NonSpace.xxs),
                  _clipReviewChip(context, showLabel: false),
                  const SizedBox(width: NonSpace.xxs),
                  _addClipSampleButton(context),
                ],
              ] else ...[
                if (width >= 520) ...[
                  const SizedBox(width: NonSpace.xxs),
                  Icon(
                    _projectName != null
                        ? Icons.video_library_outlined
                        : Icons.movie_outlined,
                    size: 17,
                    color: p.accent,
                  ),
                  const SizedBox(width: NonSpace.sm),
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
                        fontSize: NonType.bodyStrong,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                  ),
                if (labels)
                  const Spacer()
                else
                  const SizedBox(width: NonSpace.sm),
                if (labels) ...[
                  _samplePicker(context, maxWidth: 240),
                  const SizedBox(width: NonSpace.sm),
                  _fpsControl(context),
                  const SizedBox(width: NonSpace.xs),
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: NonSpace.sm,
                        ),
                      ),
                      icon: const Icon(Icons.edit_note_outlined, size: 16),
                      label: const Text(
                        '编辑脚本',
                        style: TextStyle(fontSize: NonType.caption),
                      ),
                    ),
                  const SizedBox(width: NonSpace.xs),
                  _reviewChip(context, showLabel: true),
                  const SizedBox(width: NonSpace.xs),
                  // 引擎短片入口（宽屏分支）：与窄屏「更多」菜单里的同一动作。
                  IconButton(
                    key: const ValueKey('video-short-open-wide'),
                    tooltip: '打开引擎短片',
                    iconSize: 18,
                    padding: EdgeInsets.zero,
                    color: p.ink2,
                    icon: const Icon(
                      Icons.auto_awesome_motion_outlined,
                      size: 18,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: () => _pickShortProject(context),
                  ),
                  if (_projectName == null) _loadSampleButton(context),
                ] else ...[
                  Flexible(
                    child: _samplePicker(
                      context,
                      maxWidth: width < 420 ? 110 : 140,
                    ),
                  ),
                  const SizedBox(width: NonSpace.xxs),
                  _reviewChip(context, showLabel: false),
                  if (_projectName == null) _loadSampleButton(context),
                  const SizedBox(width: NonSpace.xxs),
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
                          style: TextStyle(
                            fontSize: NonType.body,
                            color: p.ink2,
                          ),
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'short',
                        height: 40,
                        child: Text(
                          '打开引擎短片…',
                          style: TextStyle(
                            fontSize: NonType.body,
                            color: p.ink2,
                          ),
                        ),
                      ),
                      if (_projectName != null)
                        PopupMenuItem<String>(
                          value: 'delete',
                          height: 40,
                          child: Text(
                            '删除项目',
                            style: TextStyle(
                              fontSize: NonType.body,
                              color: p.ink2,
                            ),
                          ),
                        )
                      else
                        PopupMenuItem<String>(
                          value: 'script',
                          height: 40,
                          child: Text(
                            '编辑脚本',
                            style: TextStyle(
                              fontSize: NonType.body,
                              color: p.ink2,
                            ),
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
        borderRadius: BorderRadius.circular(NonRadius.md),
        side: BorderSide(color: p.line),
      ),
      itemBuilder: (context) => <PopupMenuEntry<Object>>[
        // 生成项目放最上面：它是用户自己产出的内容，不是标杆示例。
        PopupMenuItem<Object>(
          enabled: false,
          height: 26,
          child: Text(
            '生成项目',
            style: TextStyle(fontSize: NonType.micro, color: p.ink4),
          ),
        ),
        if (_projectsLoading)
          PopupMenuItem<Object>(
            enabled: false,
            height: 34,
            child: Text(
              '载入中…',
              style: TextStyle(fontSize: NonType.caption, color: p.ink4),
            ),
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
                style: TextStyle(
                  fontSize: NonType.micro,
                  color: p.ink4,
                  height: NonType.lineCaption,
                ),
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
                      fontSize: NonType.body,
                      color: clip == null && _projectName == entry.name
                          ? p.accent
                          : p.ink2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: NonSpace.xs),
                  Text(
                    entry.corrupt
                        ? '打不开 · 文件可能被改动'
                        : '片长 ${formatVideoTime(entry.seconds)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: NonType.micro, color: p.ink4),
                  ),
                ],
              ),
            ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          enabled: false,
          height: 26,
          child: Text(
            '矢量动画',
            style: TextStyle(fontSize: NonType.micro, color: p.ink4),
          ),
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
                    fontSize: NonType.body,
                    color:
                        clip == null && _projectName == null && i == _sampleIdx
                        ? p.accent
                        : p.ink2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: NonSpace.xs),
                Text(
                  samples[i].note,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: NonType.micro, color: p.ink4),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          enabled: false,
          height: 26,
          child: Text(
            '动效合成',
            style: TextStyle(fontSize: NonType.micro, color: p.ink4),
          ),
        ),
        if (_clipsLoading)
          PopupMenuItem<Object>(
            enabled: false,
            height: 34,
            child: Text(
              '载入中…',
              style: TextStyle(fontSize: NonType.caption, color: p.ink4),
            ),
          )
        else if (_clips.isEmpty)
          PopupMenuItem<Object>(
            enabled: false,
            height: 40,
            child: Text(
              _clipsError.isEmpty ? '暂无动效合成示例' : _clipsError,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: NonType.micro, color: p.ink4),
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
                      fontSize: NonType.body,
                      color: clip?.id == _clips[i].id ? p.accent : p.ink2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: NonSpace.xs),
                  Text(
                    _clips[i].subtitle.isEmpty
                        ? _clips[i].file
                        : _clips[i].subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: NonType.micro, color: p.ink4),
                  ),
                ],
              ),
            ),
      ],
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: NonSpace.sm),
          decoration: BoxDecoration(
            color: p.panel2,
            borderRadius: BorderRadius.circular(NonRadius.md),
            border: Border.all(color: p.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                clip != null
                    ? '动效合成'
                    : (_projectName != null ? '生成项目' : '标杆示例'),
                style: TextStyle(fontSize: NonType.micro, color: p.ink4),
              ),
              const SizedBox(width: NonSpace.sm),
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
                  style: TextStyle(fontSize: NonType.caption, color: p.ink2),
                ),
              ),
              const SizedBox(width: NonSpace.xxs),
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
        padding: const EdgeInsets.symmetric(horizontal: NonSpace.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.speed_outlined, size: 14, color: p.ink3),
          const SizedBox(width: NonSpace.xs),
          Text(
            '帧率 $_fps',
            style: TextStyle(fontSize: NonType.caption, color: p.ink2),
          ),
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
      borderRadius: BorderRadius.circular(NonRadius.lg),
      child: Container(
        height: 28,
        padding: EdgeInsets.symmetric(
          horizontal: showLabel ? NonSpace.md : NonSpace.xs,
        ),
        decoration: BoxDecoration(
          color: status.color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(NonRadius.lg),
          border: Border.all(color: status.color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(status.icon, size: 13, color: status.color),
            if (showLabel) ...[
              const SizedBox(width: NonSpace.xs),
              Text(
                '规范对照',
                style: TextStyle(fontSize: NonType.caption, color: p.ink2),
              ),
            ],
            const SizedBox(width: NonSpace.xs),
            Text(
              status.label,
              style: TextStyle(
                fontSize: NonType.caption,
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
        padding: const EdgeInsets.symmetric(horizontal: NonSpace.xs),
      ),
      child: const Text('加载示例', style: TextStyle(fontSize: NonType.caption)),
    );
  }

  /// 动效合成的「规格对照」：只读卡（subtitle + tags），没有脚本可对照。
  Widget _clipReviewChip(BuildContext context, {required bool showLabel}) {
    final p = context.palette;
    return InkWell(
      key: const ValueKey('video-clip-review-chip'),
      onTap: _showClipReviewSheet,
      borderRadius: BorderRadius.circular(NonRadius.lg),
      child: Container(
        height: 28,
        padding: EdgeInsets.symmetric(
          horizontal: showLabel ? NonSpace.md : NonSpace.xs,
        ),
        decoration: BoxDecoration(
          color: p.accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(NonRadius.lg),
          border: Border.all(color: p.accent.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.rule_outlined, size: 13, color: p.accent),
            if (showLabel) ...[
              const SizedBox(width: NonSpace.xs),
              Text(
                '规格对照',
                style: TextStyle(fontSize: NonType.caption, color: p.ink2),
              ),
              const SizedBox(width: NonSpace.xs),
              Text(
                '只读',
                style: TextStyle(
                  fontSize: NonType.caption,
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
        padding: const EdgeInsets.symmetric(horizontal: NonSpace.xs),
      ),
      child: const Text('加示例', style: TextStyle(fontSize: NonType.caption)),
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
            padding: const EdgeInsets.all(NonSpace.lg),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(NonRadius.md),
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
          padding: const EdgeInsets.symmetric(
            horizontal: NonSpace.md,
            vertical: NonSpace.sm,
          ),
          child: Row(
            children: [
              Icon(Icons.movie_outlined, size: 14, color: p.ink4),
              const SizedBox(width: NonSpace.sm),
              Expanded(
                child: SelectableText(
                  path,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: NonType.caption,
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
                  padding: const EdgeInsets.symmetric(horizontal: NonSpace.sm),
                ),
                icon: const Icon(Icons.copy_all_outlined, size: 14),
                label: const Text(
                  '复制路径',
                  style: TextStyle(fontSize: NonType.caption),
                ),
              ),
              if (host.supportsRevealInFolder)
                TextButton.icon(
                  onPressed: _revealArtifact,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(
                      horizontal: NonSpace.sm,
                    ),
                  ),
                  icon: const Icon(Icons.folder_open_outlined, size: 14),
                  label: const Text(
                    '在文件夹中显示',
                    style: TextStyle(fontSize: NonType.caption),
                  ),
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
        padding: const EdgeInsets.symmetric(horizontal: NonSpace.sm),
      ),
      icon: const Icon(Icons.delete_outline, size: 15),
      label: const Text('删除项目', style: TextStyle(fontSize: NonType.caption)),
    );
  }

  /// 项目读取中：给一个「正在打开」而不是空白面板。
  Widget _projectLoadingPane(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('video-project-loading'),
      decoration: BoxDecoration(
        color: p.panel2,
        borderRadius: BorderRadius.circular(NonRadius.md),
        border: Border.all(color: p.line),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(NonSpace.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hourglass_empty, size: 32, color: p.ink4),
          const SizedBox(height: NonSpace.md),
          Text(
            '正在打开生成项目…',
            style: TextStyle(fontSize: NonType.body, color: p.ink2),
          ),
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
        borderRadius: BorderRadius.circular(NonRadius.md),
        border: Border.all(color: p.line),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(NonSpace.xl),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 38, color: p.ink4),
            const SizedBox(height: NonSpace.md),
            Text(
              '这个生成项目打不开',
              style: TextStyle(
                fontSize: NonType.bodyStrong,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
            const SizedBox(height: NonSpace.sm),
            Text(
              failure.message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: NonType.caption,
                color: p.ink3,
                height: NonType.lineBody,
              ),
            ),
            const SizedBox(height: NonSpace.md),
            Wrap(
              spacing: NonSpace.sm,
              runSpacing: NonSpace.sm,
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  key: const ValueKey('video-project-retry'),
                  onPressed: _retryProject,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(
                      horizontal: NonSpace.lg,
                    ),
                  ),
                  child: const Text(
                    '重新读取',
                    style: TextStyle(fontSize: NonType.body),
                  ),
                ),
                TextButton(
                  key: const ValueKey('video-project-use-sample'),
                  onPressed: _useSampleFromProjectFailure,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(
                      horizontal: NonSpace.md,
                    ),
                  ),
                  child: const Text(
                    '用内置示例',
                    style: TextStyle(fontSize: NonType.body),
                  ),
                ),
              ],
            ),
            const SizedBox(height: NonSpace.sm),
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
    _checkController.notifySelectionChanged();
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
          borderRadius: BorderRadius.circular(NonRadius.md),
          border: Border.all(color: p.line),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(NonSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_outlined, size: 38, color: p.ink4),
            const SizedBox(height: NonSpace.md),
            Text(
              '还没有视频',
              style: TextStyle(
                fontSize: NonType.bodyStrong,
                fontWeight: FontWeight.w600,
                color: p.ink2,
              ),
            ),
            const SizedBox(height: NonSpace.sm),
            Text(
              problem.isEmpty ? '选一个例子，点播放就能看到代码动画' : problem,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: NonType.caption,
                color: p.ink3,
                height: NonType.lineBody,
              ),
            ),
            const SizedBox(height: NonSpace.md),
            // 引擎短片（nan.screenplay/1）是第二种呈现面，与 v1 生成项目互斥。
            OutlinedButton.icon(
              key: const ValueKey('video-short-open-picker'),
              onPressed: () => _pickShortProject(context),
              icon: const Icon(Icons.auto_awesome_motion_outlined, size: 15),
              label: const Text(
                '打开引擎短片…',
                style: TextStyle(fontSize: NonType.body),
              ),
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
      controller: _previewController,
    );
  }
}

/// 视频工作台接入通用检查器：把导演台选中镜头映射成一份 [CheckSheet]。
///
/// 字段只映射 `timeline.scenes[i]` 里**真实存在且可写**的键：时长 duration、
/// 文本 title（导演台镜头树的展示名来源）/ 背景色 background。起始时间是前面
/// 镜头时长累加出来的派生值（只读），元素清单只读；契约里没有音量字段，
/// 所以不造音量。
///
/// 写回**不在这里**：控制器只归一化值并交给工作台保存链路
///（[_VideoWorkspaceState._saveShotTimeline]：重新校验 → 原子落盘 → 重读刷新）。
/// 控制器不持有项目事实源，也不直接写盘。
class _VideoCheckController extends WorkbenchCheckController {
  _VideoCheckController({
    required this.projectOf,
    required this.selectedShotIndexOf,
    required this.save,
    required this.onReject,
  });

  /// 当前生成项目：每次取表都重新读（保存后工作台刷新即看到新值）。
  /// null = 没有生成项目（内置示例/产物），检查器给空态。
  final VideoProjectSnapshot? Function() projectOf;

  /// 导演台当前选中镜头下标；null = 没有选中。
  final int? Function() selectedShotIndexOf;

  /// 工作台保存链路（返回是否真的落盘并刷新成功）。
  final Future<bool> Function(Map<String, dynamic> timeline) save;

  /// 非法值的人话提示（上屏由工作台负责；控制器不写盘）。
  final void Function(String message) onReject;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifySelectionChanged() {
    if (!_disposed) super.notifySelectionChanged();
  }

  static final RegExp _hexPattern = RegExp(r'^#([0-9a-fA-F]{6})$');

  static String _text(Object? value) => (value ?? '').toString();

  /// `#RRGGBB` → ARGB int（检查器颜色控件的值形状）；坏值用中性灰占位，
  /// 不伪装成项目里的真实颜色。
  static int _colorOf(Object? raw) {
    final RegExpMatch? match = _hexPattern.firstMatch(_text(raw).trim());
    if (match == null) return 0xFF888888;
    return 0xFF000000 | int.parse(match.group(1)!, radix: 16);
  }

  /// 场景的项目 id：契约没有强制场景 id，真实存在就用；否则退回镜头文本 /
  /// 序号（与导演台镜头树的展示口径一致）。
  static String _sceneId(Map<String, Object?> scene, int index) {
    final String id = _text(scene['id']).trim();
    if (id.isNotEmpty) return id;
    for (final String key in const <String>['title', 'name', 'caption']) {
      final String text = _text(scene[key]).trim();
      if (text.isNotEmpty) return text;
    }
    return '${index + 1}';
  }

  /// 选中镜头在原始 `scenes[]` 里的位置：投影会跳过非对象，这里按同一套规则
  /// 数到第 index 个合法场景，写回时不改坏其它条目。
  static int _rawSceneIndexOf(Map<String, dynamic> timeline, int index) {
    final Object? scenes = timeline['scenes'];
    if (scenes is! List) return -1;
    int seen = 0;
    for (int i = 0; i < scenes.length; i++) {
      if (scenes[i] is! Map) continue;
      if (seen == index) return i;
      seen += 1;
    }
    return -1;
  }

  @override
  CheckSheet? get sheet {
    final VideoProjectSnapshot? project = projectOf();
    if (project == null) return null; // 无生成项目：检查器显示空态
    final List<VideoShotItem> shots = videoShotsFromTimeline(project.timeline);
    final int? index = selectedShotIndexOf();
    if (index == null || index < 0 || index >= shots.length) return null;
    final VideoShotItem shot = shots[index];
    final int fps = project.document.fps > 0 ? project.document.fps : 30;
    final Map<String, Object?> rawScene = shot.data;
    final String label = _text(
      rawScene['title'] ?? rawScene['name'] ?? rawScene['caption'],
    ).trim();
    return CheckSheet(
      title: '镜头「${_sceneId(shot.data, shot.index)}」',
      kindLabel: '镜头',
      subtitle: '来自 timeline.json',
      fields: <CheckField>[
        CheckField(
          key: 'start',
          label: '起始时间',
          kind: CheckFieldKind.number,
          value: shot.start,
          unit: '秒',
          enabled: false,
          hint: '由前面镜头时长累加',
        ),
        CheckField(
          key: 'duration',
          label: '时长',
          kind: CheckFieldKind.number,
          value: shot.duration,
          unit: '秒',
          min: 1.0 / fps,
          hint: '至少一帧',
        ),
        CheckField(
          key: 'label',
          label: '文本',
          kind: CheckFieldKind.text,
          value: label,
          hint: '镜头标题；留空按序号显示',
        ),
        CheckField(
          key: 'background',
          label: '背景色',
          kind: CheckFieldKind.color,
          value: _colorOf(
            rawScene['background'] ?? project.timeline['background'],
          ),
          hint: '#RRGGBB',
        ),
        CheckField(
          key: 'elements',
          label: '元素',
          kind: CheckFieldKind.readOnly,
          value: '${shot.elementCount}',
          hint: '只读：元素内容在脚本里编辑',
        ),
      ],
    );
  }

  @override
  Future<bool> update(String key, Object? value) async {
    if (_disposed) return false;
    final VideoProjectSnapshot? project = projectOf();
    if (project == null) return false;
    final int? index = selectedShotIndexOf();
    if (index == null || index < 0) return false;
    final int rawIndex = _rawSceneIndexOf(project.timeline, index);
    if (rawIndex < 0) return false;
    final int fps = project.document.fps > 0 ? project.document.fps : 30;
    Object? normalized;
    switch (key) {
      case 'duration':
        if (value is! num || !value.isFinite) {
          onReject('镜头时长要填一个数字');
          return false;
        }
        final double next = value.toDouble();
        if (next <= 0 || next < 1.0 / fps) {
          onReject('镜头时长至少一帧，改大一点再试');
          return false;
        }
        normalized = next;
      case 'label':
        if (value is! String) {
          onReject('镜头文本要填一段文字');
          return false;
        }
        normalized = value.trim();
      case 'background':
        // 通用检查器的颜色控件给 ARGB int；也接受已经是 #RRGGBB 的文本。
        if (value is int) {
          normalized =
              '#${(value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
        } else if (value is String && _hexPattern.hasMatch(value.trim())) {
          normalized = value.trim();
        } else {
          onReject('背景色要用 #RRGGBB 形式');
          return false;
        }
      default:
        return false;
    }
    // 只改选中的那个场景、只带改动的键；元素/转场等其它字段原样保留。
    final Map<String, dynamic> nextTimeline = Map<String, dynamic>.from(
      project.timeline,
    );
    final Object? rawScenes = nextTimeline['scenes'];
    if (rawScenes is! List) return false;
    final List<dynamic> scenes = List<dynamic>.from(rawScenes);
    final Map<String, dynamic> scene = Map<String, dynamic>.from(
      scenes[rawIndex] as Map,
    );
    // 文本统一写 title（导演台镜头树的展示名优先读 title/name/caption）。
    scene[key == 'label' ? 'title' : key] = normalized;
    scenes[rawIndex] = scene;
    nextTimeline['scenes'] = scenes;
    final bool saved = await save(nextTimeline);
    if (!saved || _disposed) return saved;
    // 保存成功 → 工作台已重读刷新；通知检查面板重取当前值。
    notifyListeners();
    return true;
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
      title: const Text('播放帧率', style: TextStyle(fontSize: NonType.subtitle)),
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
                  style: TextStyle(fontSize: NonType.body, color: p.ink2),
                ),
                const Spacer(),
                Text(
                  '1–30',
                  style: TextStyle(fontSize: NonType.micro, color: p.ink4),
                ),
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
              style: TextStyle(fontSize: NonType.micro, color: p.ink4),
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
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(NonRadius.lg),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            NonSpace.lg,
            NonSpace.lg,
            NonSpace.lg,
            NonSpace.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.rule_outlined, size: 16, color: color),
                  const SizedBox(width: NonSpace.sm),
                  Text(
                    '规范对照',
                    style: TextStyle(
                      fontSize: NonType.bodyStrong,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NonSpace.sm,
                      vertical: NonSpace.xs,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(NonRadius.lg),
                      border: Border.all(color: color.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: NonType.caption,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: NonSpace.sm),
              Text(
                review?.summary ?? '还没有对照结果',
                style: TextStyle(fontSize: NonType.caption, color: p.ink3),
              ),
              if (!hasDocument) ...[
                const SizedBox(height: NonSpace.sm),
                Text(
                  '选一个例子，点播放就能看到代码动画',
                  style: TextStyle(fontSize: NonType.caption, color: p.ink4),
                ),
              ],
              if (problems.isNotEmpty) ...[
                const SizedBox(height: NonSpace.md),
                Text(
                  '需要修正',
                  style: TextStyle(
                    fontSize: NonType.caption,
                    fontWeight: FontWeight.w700,
                    color: p.danger,
                  ),
                ),
                for (final problem in problems)
                  Padding(
                    padding: const EdgeInsets.only(top: NonSpace.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline, size: 13, color: p.danger),
                        const SizedBox(width: NonSpace.sm),
                        Expanded(
                          child: Text(
                            problem,
                            style: TextStyle(
                              fontSize: NonType.caption,
                              color: p.ink2,
                              height: NonType.lineBody,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              if (notes.isNotEmpty) ...[
                const SizedBox(height: NonSpace.md),
                Text(
                  '值得留意',
                  style: TextStyle(
                    fontSize: NonType.caption,
                    fontWeight: FontWeight.w700,
                    color: p.warn,
                  ),
                ),
                for (final note in notes)
                  Padding(
                    padding: const EdgeInsets.only(top: NonSpace.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 13, color: p.warn),
                        const SizedBox(width: NonSpace.sm),
                        Expanded(
                          child: Text(
                            note,
                            style: TextStyle(
                              fontSize: NonType.caption,
                              color: p.ink2,
                              height: NonType.lineBody,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              if (review != null && review.technical.isNotEmpty) ...[
                const SizedBox(height: NonSpace.sm),
                _TechnicalDetails(text: review.technical.join('\n')),
              ],
              const SizedBox(height: NonSpace.md),
              Row(
                children: [
                  Icon(Icons.play_circle_outline, size: 12, color: p.ink4),
                  const SizedBox(width: NonSpace.sm),
                  Expanded(
                    child: Text(
                      '代码动画直接播放，暂不导出成片',
                      style: TextStyle(fontSize: NonType.micro, color: p.ink4),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onEditScript,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(
                        horizontal: NonSpace.sm,
                      ),
                    ),
                    icon: const Icon(Icons.edit_note_outlined, size: 15),
                    label: const Text(
                      '编辑脚本',
                      style: TextStyle(fontSize: NonType.caption),
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
        childrenPadding: const EdgeInsets.only(bottom: NonSpace.sm),
        dense: true,
        title: Text(
          '技术详情',
          style: TextStyle(
            fontSize: NonType.caption,
            color: p.ink4,
            fontWeight: FontWeight.w600,
          ),
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(NonSpace.sm),
            decoration: BoxDecoration(
              color: p.panel2,
              borderRadius: BorderRadius.circular(NonRadius.sm),
            ),
            child: SelectableText(
              text,
              style: TextStyle(
                fontSize: NonType.micro,
                fontFamily: 'monospace',
                color: p.ink4,
                height: NonType.lineCaption,
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
      fontSize: NonType.caption,
      fontFamily: 'monospace',
      color: p.ink2,
      height: NonType.lineBody,
    );
    return AlertDialog(
      title: const Text('编辑脚本', style: TextStyle(fontSize: NonType.subtitle)),
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
                  const SizedBox(width: NonSpace.md),
                  Expanded(child: specField),
                ],
              );
            }
            return Column(
              children: [
                Expanded(child: timelineField),
                const SizedBox(height: NonSpace.md),
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
            fontSize: NonType.caption,
            fontWeight: FontWeight.w600,
            color: p.ink3,
          ),
        ),
        const SizedBox(height: NonSpace.sm),
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
              contentPadding: const EdgeInsets.all(NonSpace.md),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(NonRadius.md),
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
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(NonRadius.lg),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            NonSpace.lg,
            NonSpace.lg,
            NonSpace.lg,
            NonSpace.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.rule_outlined, size: 16, color: p.accent),
                  const SizedBox(width: NonSpace.sm),
                  Text(
                    '规格对照',
                    style: TextStyle(
                      fontSize: NonType.bodyStrong,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NonSpace.sm,
                      vertical: NonSpace.xs,
                    ),
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(NonRadius.lg),
                      border: Border.all(
                        color: p.accent.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Text(
                      '只读',
                      style: TextStyle(
                        fontSize: NonType.caption,
                        fontWeight: FontWeight.w600,
                        color: p.accent,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: NonSpace.md),
              Text(
                clip.title,
                style: TextStyle(
                  fontSize: NonType.bodyStrong,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                ),
              ),
              if (clip.subtitle.isNotEmpty) ...[
                const SizedBox(height: NonSpace.xs),
                Text(
                  clip.subtitle,
                  style: TextStyle(
                    fontSize: NonType.caption,
                    color: p.ink3,
                    height: NonType.lineBody,
                  ),
                ),
              ],
              if (clip.tags.isNotEmpty) ...[
                const SizedBox(height: NonSpace.md),
                Wrap(
                  spacing: NonSpace.sm,
                  runSpacing: NonSpace.sm,
                  children: [
                    for (final tag in clip.tags)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: NonSpace.sm,
                          vertical: NonSpace.xs,
                        ),
                        decoration: BoxDecoration(
                          color: p.panel2,
                          borderRadius: BorderRadius.circular(NonRadius.lg),
                          border: Border.all(color: p.line),
                        ),
                        child: Text(
                          '#$tag',
                          style: TextStyle(
                            fontSize: NonType.micro,
                            color: p.ink3,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: NonSpace.md),
              Row(
                children: [
                  Icon(Icons.schedule, size: 13, color: p.ink4),
                  const SizedBox(width: NonSpace.sm),
                  Text(
                    '时长 ${formatVideoTime(clip.duration)}',
                    style: TextStyle(fontSize: NonType.caption, color: p.ink3),
                  ),
                  const SizedBox(width: 14),
                  Icon(Icons.brush_outlined, size: 13, color: p.ink4),
                  const SizedBox(width: NonSpace.sm),
                  Text(
                    _clipStyleLabel(clip.style),
                    style: TextStyle(fontSize: NonType.caption, color: p.ink3),
                  ),
                ],
              ),
              const SizedBox(height: NonSpace.md),
              Text(
                '这支短片是成品合成，画面与节奏由短片自身决定；这里只做只读对照。',
                style: TextStyle(
                  fontSize: NonType.caption,
                  color: p.ink3,
                  height: NonType.lineBody,
                ),
              ),
              const SizedBox(height: NonSpace.md),
              Row(
                children: [
                  Icon(Icons.play_circle_outline, size: 12, color: p.ink4),
                  const SizedBox(width: NonSpace.sm),
                  Expanded(
                    child: Text(
                      'HTML/CSS/JS 动效合成，应用内实时播放，暂不导出成片',
                      style: TextStyle(fontSize: NonType.micro, color: p.ink4),
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
