/// 视频工作区（批次 08：全本地）。
///
/// 一次完整的视频制作只有四步，全部在本机完成：
///
///  1. **选脚本**：内置标杆示例，或在「编辑脚本」里粘贴自己的时间线脚本与规范；
///  2. **规范对照**：规范硬门 + 算式符号闭包 + 节拍覆盖，失败原因当场列在
///     按钮旁边（不是等点了渲染才报错）；
///  3. **渲染**：桌面调本机渲染组件出逐帧画面并编码成片；手机/平板不渲染，
///     点渲染会明确告诉你「只在电脑上可用」，而不是点了没反应；
///  4. **播放**：成片与艺术架里的既有视频都能在工作台内播放。
///
/// 数据面全部在 [VideoService]（纯 Dart）：校验、逐帧画面、对照检查、渲染
/// 任务与进度都在进程内，不经过任何端口或内部路由。界面只做三件事：把状态
/// 画出来、把用户动作翻译成一次服务调用、把失败翻成一句人话（原始诊断进
/// 折叠的「技术详情」）。
///
/// 平台矩阵的唯一判据是 [PlatformCapabilities]（能力中心）：
///  * 渲染 = 桌面三平台（[PlatformCapabilities.supportsVideoRender]）；
///  * 「在文件夹中显示」= 桌面三平台（[PlatformCapabilities.supportsRevealInFolder]）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/capability.dart';
import '../core/keys.dart';
import '../core/platform_capabilities.dart';
import '../core/store.dart';
import '../core/theme.dart';
import '../core/toast_service.dart';
import '../core/video_service.dart';
import 'video_player_surface.dart';

/// 视频工作区。
class VideoWorkspace extends StatefulWidget {
  const VideoWorkspace({super.key, this.service});

  /// 测试注入（生产用 [VideoService.instance]，任务与产物活过视图切换）。
  final VideoService? service;

  @override
  State<VideoWorkspace> createState() => _VideoWorkspaceState();
}

/// 艺术架「打开」直载：切视图前设置**某个产物的 mp4 绝对路径**，本工作台
/// initState 消费后清空（与 threeLoadOnOpen 同构的跨实例通道）。
String? videoLoadOnOpen;

class _VideoWorkspaceState extends State<VideoWorkspace> {
  static const int _pollMillis = 350;

  int _sampleIdx = 0;
  double _fps = 10;
  bool _busy = false;
  VideoDocument? _doc;
  VideoReviewResult? _review;
  String? _jobId;
  VideoRenderJob? _job;
  Timer? _poll;

  /// 产物模式：艺术架点开的某个 mp4（非 null 即整个工作台切到播放面）。
  String? _artifactPath;

  /// 渲染启动失败 / 任务失败的人话与原始诊断（诊断只进折叠详情）。
  String _renderError = '';
  String _renderTechnical = '';

  /// 脚本编辑器最近一次输入（切示例后仍保留，方便改回去）。
  String _scriptTimeline = '';
  String _scriptSpec = '';

  AppStore get store => context.read<AppStore>();
  VideoService get _service => widget.service ?? VideoService.instance;
  ToastService get _toasts => store.toasts;
  PlatformCapabilities get _host => store.capabilities.platform;

  @override
  void initState() {
    super.initState();
    // 艺术架产物直载优先于一切恢复路径：用户点开的是某个产物，不是
    // 「上次渲染态」。消费即清（跨实例通道）。
    final pendingArtifact = videoLoadOnOpen;
    videoLoadOnOpen = null;
    if (pendingArtifact != null && pendingArtifact.isNotEmpty) {
      _artifactPath = pendingArtifact;
      return;
    }

    final settings = store.settings;
    _sampleIdx = settings.videoSampleIdx.clamp(0, _service.samples.length - 1);
    _applySample(_sampleIdx);

    // 视图切换即 dispose：在飞任务从共享服务接回轮询（任务活在进程里，
    // 不随视图销毁）。进程重启后旧任务号查无此项——清掉并轻提示。
    final restoredId = settings.videoJob;
    if (restoredId.isNotEmpty) {
      final snapshot = _service.job(restoredId);
      if (snapshot == null) {
        // initState 里不能同步改 store（notifyListeners 会撞 build），
        // 放到首帧之后：清持久化 + 轻提示，不空转轮询。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          store.setVideoState(job: '');
          _toasts.info('上次的渲染任务已经不在了', '重新渲染一次就好。');
        });
      } else {
        _jobId = restoredId;
        _job = snapshot;
        if (snapshot.isRunning) _startPolling();
        if (snapshot.isFailed) {
          _renderError = videoFailureMessage(snapshot.failureCode);
          _renderTechnical = snapshot.log;
        }
      }
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------------ 脚本

  void _applySample(int index) {
    try {
      final doc = _service.loadSample(index);
      _doc = doc;
      _scriptTimeline = const JsonEncoder.withIndent('  ').convert(doc.timeline);
      _scriptSpec = const JsonEncoder.withIndent('  ').convert(doc.spec.raw);
      _review = _service.review(timeline: doc.timeline, spec: doc.spec.raw);
      _renderError = '';
      _renderTechnical = '';
      _jobId = null;
      _job = null;
      _poll?.cancel();
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
    store.setVideoState(sampleIdx: index, job: '');
  }

  void _reloadSelectedSample() {
    setState(() => _applySample(_sampleIdx));
    store.setVideoState(job: '');
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
        _review = _service.review(timeline: doc.timeline, spec: doc.spec.raw);
        _renderError = '';
        _renderTechnical = '';
        _jobId = null;
        _job = null;
        _poll?.cancel();
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
    store.setVideoState(job: '');
  }

  // ------------------------------------------------------------------ 渲染

  bool get _running => _job?.isRunning ?? false;

  Future<void> _render() async {
    if (!_host.supportsVideoRender) {
      _toasts.warn(
        store.capabilities.message(CapabilityId.videoRender),
        '手机上可以编辑脚本、做对照检查，并播放已有的视频。',
      );
      return;
    }
    final doc = _doc;
    if (doc == null) return;
    setState(() {
      _busy = true;
      _renderError = '';
      _renderTechnical = '';
    });
    try {
      final job = await _service.startRender(doc, fps: _fps.round());
      if (!mounted) return;
      setState(() {
        _jobId = job.id;
        _job = job;
        _busy = false;
      });
      store.setVideoState(job: job.id);
      _startPolling();
    } on VideoRejected catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _renderError = videoFailureMessage(error);
        _renderTechnical = error.technical;
      });
      _toasts.error(videoFailureMessage(error));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _renderError = videoFailureMessage(null);
        _renderTechnical = '$error';
      });
      _toasts.error(videoFailureMessage(null));
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: _pollMillis), (_) => _pollOnce());
  }

  void _pollOnce() {
    final id = _jobId;
    if (id == null) return;
    final snapshot = _service.job(id);
    if (!mounted) return;
    if (snapshot == null) {
      // 任务不在了（进程重启 / 服务被替换）：停轮询、清持久化，不空转。
      _poll?.cancel();
      setState(() {
        _jobId = null;
        _job = null;
      });
      store.setVideoState(job: '');
      _toasts.info('渲染任务已经不在了', '重新渲染一次就好。');
      return;
    }
    setState(() => _job = snapshot);
    if (snapshot.isRunning) return;
    _poll?.cancel();
    store.setVideoState(job: '');
    if (snapshot.isDone) {
      _toasts.success(
        '渲染完成（${snapshot.totalFrames} 帧）',
        '成片已经放进艺术架，可以在工作台里播放。',
      );
    } else if (snapshot.isFailed) {
      setState(() {
        _renderError = videoFailureMessage(snapshot.failureCode);
        _renderTechnical = snapshot.log;
      });
      _toasts.error(videoFailureMessage(snapshot.failureCode));
    }
  }

  // ------------------------------------------------------------------ 播放面

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
    // 产物固定是 <job>/frames.mp4：父目录名才是「第几个渲染」，帧名没有信息量。
    return parts.length >= 2 ? parts[parts.length - 2] : path;
  }

  // ------------------------------------------------------------------ 界面

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final artifact = _artifactPath;
    return Column(
      children: [
        Container(
          height: 46,
          decoration: BoxDecoration(
            color: p.bgElevated,
            border: Border(bottom: BorderSide(color: p.line)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          // 窄屏断点：副标题隐藏、标题省略号；390 宽曾溢出 241px。
          child: LayoutBuilder(builder: (context, constraints) {
            final narrow = constraints.maxWidth < 700;
            return Row(children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 18),
                tooltip: '返回设计 ${modCombo('⌘1')}',
                color: p.ink2,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: () => store.setView('design'),
              ),
              const SizedBox(width: 4),
              Icon(Icons.movie_outlined, size: 17, color: p.accent),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: narrow ? 150 : 400),
                child: Text(
                  artifact != null ? '视频产物 · ${_artifactName(artifact)}' : '视频工作台',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink),
                ),
              ),
              if (artifact != null)
                TextButton(
                  onPressed: () => setState(() => _artifactPath = null),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('返回渲染台', style: TextStyle(fontSize: 11)),
                ),
              const SizedBox(width: 14),
              if (!narrow && artifact == null)
                Text('无声视频 · 本机渲染 + 规范对照',
                    style: TextStyle(fontSize: 11, color: p.ink4)),
              const Spacer(),
              if (_running || _busy)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.8, color: p.accent),
                ),
            ]);
          }),
        ),
        Expanded(
          child: artifact != null
              ? _artifactPane(context, artifact)
              : LayoutBuilder(builder: (context, constraints) {
                  // 窄屏：单列滚动（固定 300px 配置列会把预览压到不可用）。
                  final narrow = constraints.maxWidth < 700;
                  if (narrow) {
                    return SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _configColumn(context, narrow: true),
                          const SizedBox(height: 8),
                          SizedBox(height: 300, child: _previewPane(context)),
                        ],
                      ),
                    );
                  }
                  return Row(children: [
                    SizedBox(width: 320, child: _configColumn(context, narrow: false)),
                    Expanded(child: _previewPane(context)),
                  ]);
                }),
        ),
      ],
    );
  }

  /// 产物模式：播放面 + 信息行（路径 / 复制 / 桌面端在文件夹中显示）。
  Widget _artifactPane(BuildContext context, String path) {
    final p = context.palette;
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
          if (_host.supportsRevealInFolder)
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

  /// 配置列（宽屏固定 320 / 窄屏整宽，内部整体滚动）。
  Widget _configColumn(BuildContext context, {required bool narrow}) {
    final p = context.palette;
    final doc = _doc;
    final review = _review;
    final reviewOk = review?.ok ?? false;
    final canRender = doc != null && reviewOk && !_busy && !_running;

    return Container(
      width: narrow ? double.infinity : 320,
      decoration: BoxDecoration(
        border: narrow ? null : Border(right: BorderSide(color: p.line)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('标杆示例',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.ink2)),
            const SizedBox(height: 8),
            for (var i = 0; i < _service.samples.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  onTap: _busy || _running ? null : () => _selectSample(i),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: i == _sampleIdx ? p.accentSoft : p.panel2,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: i == _sampleIdx ? p.accent : p.line),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        _service.samples[i].label,
                        style: TextStyle(
                          fontSize: 12,
                          color: i == _sampleIdx ? p.accent : p.ink2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _service.samples[i].note,
                        style: TextStyle(fontSize: 10, color: p.ink4),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ]),
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Text('脚本',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.ink2)),
              ),
              TextButton.icon(
                onPressed: _busy || _running ? null : _editScript,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: const Icon(Icons.edit_note_outlined, size: 16),
                label: const Text('编辑脚本', style: TextStyle(fontSize: 11)),
              ),
            ]),
            if (doc != null)
              Text(
                '${doc.spec.kind == VideoSpecKind.science ? '科学说明' : '剧本'} · '
                '${doc.width}×${doc.height} · 片长 ${doc.totalSeconds.toStringAsFixed(1)} 秒',
                style: TextStyle(fontSize: 10, color: p.ink4),
              ),
            const SizedBox(height: 6),
            Row(children: [
              Text('帧率 ${_fps.round()}', style: TextStyle(fontSize: 12, color: p.ink2)),
              Expanded(
                child: Slider(
                  value: _fps,
                  min: 6,
                  max: 30,
                  divisions: 12,
                  label: '${_fps.round()}',
                  activeColor: p.accent,
                  onChanged: _busy || _running ? null : (value) => setState(() => _fps = value),
                ),
              ),
            ]),
            Text('预览用较低帧率更快出片，成片可用 30 帧/秒',
                style: TextStyle(fontSize: 10, color: p.ink4)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy || _running ? null : _reloadSelectedSample,
              icon: const Icon(Icons.upload_file, size: 15),
              label: const Text('加载示例'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              // 对照不通过时禁渲染：原因当场就近可见，不滞后到渲染失败。
              onPressed: canRender ? _render : null,
              icon: const Icon(Icons.play_circle_outlined, size: 15),
              label: const Text('渲染（后台）'),
            ),
            if (!_host.supportsVideoRender) ...[
              const SizedBox(height: 8),
              _NoticeBox(
                icon: Icons.computer_outlined,
                color: p.ink3,
                title: store.capabilities.message(CapabilityId.videoRender),
                body: '手机上可以编辑脚本、做对照检查，并播放已有的视频。',
              ),
            ],
            if (review != null && !review.ok) ...[
              const SizedBox(height: 8),
              _NoticeBox(
                icon: Icons.block_outlined,
                color: p.danger,
                title: review.problems.isEmpty ? review.summary : review.problems.first,
                body: review.problems.length > 1
                    ? review.problems.skip(1).join('\n')
                    : null,
              ),
            ],
            if (_renderError.isNotEmpty) ...[
              const SizedBox(height: 8),
              _NoticeBox(
                icon: Icons.error_outline,
                color: p.danger,
                title: _renderError,
                body: null,
              ),
            ],
            if (review != null) ...[
              const SizedBox(height: 14),
              Row(children: [
                Icon(Icons.rule_outlined, size: 14, color: review.ok ? p.accent : p.danger),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '规范对照',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.ink2),
                  ),
                ),
                Text(
                  review.ok ? '通过' : '待修正',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: review.ok ? p.accent : p.danger,
                  ),
                ),
              ]),
              const SizedBox(height: 2),
              Text(review.summary, style: TextStyle(fontSize: 10, color: p.ink4)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: p.panel2,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  review.output,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: p.ink3,
                    height: 1.5,
                  ),
                ),
              ),
              if (review.technical.isNotEmpty || _renderTechnical.isNotEmpty)
                _TechnicalDetails(
                  text: <String>[
                    ...review.technical,
                    if (_renderTechnical.isNotEmpty) _renderTechnical,
                  ].join('\n'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 预览面：渲染进度 / 帧条带 / 空态。
  Widget _previewPane(BuildContext context) {
    final p = context.palette;
    final job = _job;
    if (job != null && job.isRunning) {
      final total = job.totalFrames <= 0 ? 1 : job.totalFrames;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 320,
              child: LinearProgressIndicator(
                value: job.frames / total,
                minHeight: 4,
                color: p.accent,
                backgroundColor: p.panel2,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '渲染中…（第 ${job.frames}/${job.totalFrames} 帧）',
              style: TextStyle(fontSize: 12, color: p.ink3),
            ),
            const SizedBox(height: 6),
            Text(
              '在后台进行，可以切到别的视图再回来。',
              style: TextStyle(fontSize: 10, color: p.ink4),
            ),
          ]),
        ),
      );
    }
    if (job != null && job.frames > 0 && job.directory != null) {
      return _FrameStrip(
        directory: job.directory!,
        count: job.frames,
        mp4Path: job.mp4Path,
        onPlay: job.mp4Path == null
            ? null
            : () => setState(() => _artifactPath = job.mp4Path),
      );
    }
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.movie_outlined, size: 42, color: p.ink4),
        const SizedBox(height: 12),
        Text(
          _doc == null
              ? '还没有视频'
              : _host.supportsVideoRender
                  ? '点「渲染（后台）」开始出片'
                  : '手机上不能出片，可以从艺术架打开已有的视频',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: p.ink3),
        ),
        if (_doc != null && _host.supportsVideoRender) ...[
          const SizedBox(height: 6),
          Text(
            '预计 ${_doc!.frameCount(_fps.round())} 帧 · '
            '${_doc!.totalSeconds.toStringAsFixed(1)} 秒',
            style: TextStyle(fontSize: 10, color: p.ink4),
          ),
        ],
      ]),
    );
  }
}

/// 帧条带预览：均匀抽 24 帧直接读本机文件（不再经任何服务端取图）。
class _FrameStrip extends StatelessWidget {
  const _FrameStrip({
    required this.directory,
    required this.count,
    this.mp4Path,
    this.onPlay,
  });

  final String directory;
  final int count;
  final String? mp4Path;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final shown = count < 24 ? count : 24;
    return Column(children: [
      if (mp4Path != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
          child: Row(children: [
            Expanded(
              child: Text(
                '成片已就绪',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink2),
              ),
            ),
            TextButton.icon(
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow_outlined, size: 16),
              label: const Text('播放成片', style: TextStyle(fontSize: 11)),
            ),
          ]),
        ),
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(14),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 16 / 9,
          ),
          itemCount: shown,
          itemBuilder: (context, index) {
            final frame = count <= 24 ? index : (index * (count - 1) / 23).round();
            final file = File('$directory/frame_${frame.toString().padLeft(5, '0')}.png');
            return Container(
              decoration: BoxDecoration(
                border: Border.all(color: p.line),
                borderRadius: BorderRadius.circular(6),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.file(
                file,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    Center(child: Icon(Icons.broken_image_outlined, size: 18, color: p.ink4)),
              ),
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(10),
        child: Text('显示 $shown/$count 帧（均匀抽样）',
            style: TextStyle(fontSize: 11, color: p.ink4)),
      ),
    ]);
  }
}

/// 一行的提示条（图标 + 一句主句 + 可选补充）。
class _NoticeBox extends StatelessWidget {
  const _NoticeBox({
    required this.icon,
    required this.color,
    required this.title,
    this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 11, color: color, height: 1.4)),
            if (body != null && body!.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(body!, style: TextStyle(fontSize: 10, color: p.ink3, height: 1.4)),
            ],
          ]),
        ),
      ]),
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
