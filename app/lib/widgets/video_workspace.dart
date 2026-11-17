import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/api_shelf.dart';
import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'video_player_surface.dart';

/// 轨道 B 客户端面：视频工作台（无声版，用户裁决音轨/旁白暂不做）。
/// 加载标杆示例（或粘贴 timeline）→ 环②机械对照 → 后台渲染（job 轮询）
/// → 帧序列预览 + mp4 路径。渲染引擎是独立插件 plugins/video-engine/
/// （服务器端点只是调用方，引擎零服务器依赖）。
class VideoWorkspace extends StatefulWidget {
  const VideoWorkspace({super.key});

  @override
  State<VideoWorkspace> createState() => _VideoWorkspaceState();
}

/// 艺术架「打开」直载：切视图前设置**某个产物的 mp4 绝对路径**，本工作台
/// initState 消费后清空（与 threeLoadOnOpen 同构的跨实例通道）。与
/// hotAppLoadOnOpen 的取值域不同——热应用传应用名，这里传文件路径。
String? videoLoadOnOpen;

class _SampleDef {
  const _SampleDef(this.label, this.timelineAsset, this.specAsset);
  final String label;
  final String timelineAsset;
  final String specAsset;
}

const _samples = [
  _SampleDef('物理 · 斜面摩擦力（真实性门面）', 'physics-friction/timeline.json', 'physics-friction/spec.json'),
  _SampleDef('生物 · 细胞有丝分裂', 'bio-mitosis/timeline.json', 'bio-mitosis/spec.json'),
  _SampleDef('艺术 · 沙雕简笔小人', 'art-sketch/timeline.json', 'art-sketch/screenplay.json'),
];

class _VideoWorkspaceState extends State<VideoWorkspace> {
  int _sampleIdx = 0;
  double _fps = 10;
  bool _busy = false;
  String? _job;
  Timer? _poll;
  Map<String, dynamic>? _jobState;
  String _reviewOutput = '';
  int _previewCount = 0;

  /// 产物模式：艺术架点开的某个 mp4（非 null 即整个工作台切到播放面）。
  /// null = 默认渲染台（示例/渲染/帧预览，文案与布局保持原样）。
  String? _artifactPath;

  /// job 轮询连续失败上限：1.2s × 25 ≈ 30s（ask 给出的放弃窗口）。网络抖动
  /// 期间保留轮询，但服务器中途永久下线（移动端连桌面断网）必须放弃并复位
  /// ——否则 _busy 永真、「加载示例/渲染」永久禁点（工作台死端）。
  static const int _pollMaxFails = 25;
  int _pollFails = 0;

  /// 环② review 结论（ok/exit 解析）：null=未知/未评审/请求失败（不拦渲染，
  /// 环①硬门在 render 内 fail-closed 兜底）；false=FAIL（禁用渲染按钮）。
  bool? _reviewOk;

  AppStore get store => context.read<AppStore>();

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
    // 视图切换即 dispose：示例下标与在飞 job 从设置恢复，回来接回轮询
    // （旧实现切走就永久丢失渲染进度）。
    final s = store.settings;
    _sampleIdx = s.videoSampleIdx.clamp(0, _samples.length - 1);
    if (s.videoJob.isNotEmpty) {
      _job = s.videoJob;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (store.api == null) {
          // 离线恢复的 job 无处查询：直接清掉，不建永久空转轮询。
          setState(() => _busy = false);
          store.setVideoState(job: '');
          return;
        }
        setState(() => _busy = true);
        _pollOnce();
        _poll?.cancel();
        _poll = Timer.periodic(const Duration(milliseconds: 1200), (_) => _pollOnce());
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// 从服务器仓库读示例（示例文件随仓库分发；通过 /video/review 的
  /// cwd 无关性不适用——直接用静态内嵌会双份维护。改走服务器端点
  /// /video/sample 读文件最省事，见 main.py）。
  Future<void> _loadSample() async {
    final api = store.api;
    if (api == null) return;
    final s = _samples[_sampleIdx];
    setState(() => _busy = true);
    try {
      final res = await api.getJson('/video/sample?timeline=${Uri.encodeQueryComponent(s.timelineAsset)}&spec=${Uri.encodeQueryComponent(s.specAsset)}');
      if (res['ok'] == true) {
        if (!mounted) return;
        setState(() {
          _tl = (res['timeline'] as Map).cast<String, dynamic>();
          _spec = (res['spec'] as Map?)?.cast<String, dynamic>();
          _reviewOutput = '';
          _reviewOk = null; // 新示例待重新评审，渲染门随之重开
          _jobState = null;
          _job = null;
          _previewCount = 0;
        });
        store.setVideoState(job: '');
        _runReview();
      } else {
        _toast('加载失败', '${res['detail']}');
      }
    } catch (e) {
      _toast('加载失败', '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic>? _tl;
  Map<String, dynamic>? _spec;

  void _runReview() async {
    final api = store.api;
    if (api == null || _tl == null) return;
    try {
      final res = await api.postJson('/video/review', {'timeline': _tl, 'spec': _spec});
      if (!mounted) return;
      // ok/exit 双判（server 返回 {ok: exit==0, exit, output}）：FAIL 必须
      // 当场禁用渲染按钮并就近亮出原因，而不是等用户点了渲染、被 render.py
      // 独立硬门拒掉后才看到「渲染失败」（反馈滞后一拍）。
      final exitCode = res['exit'];
      final ok = res['ok'] == true && (exitCode is! num || exitCode.toInt() == 0);
      setState(() {
        _reviewOutput = (res['output'] ?? '').toString();
        _reviewOk = ok;
      });
    } catch (e) {
      if (!mounted) return;
      // 评审请求失败 ≠ 评审 FAIL：不拦渲染（render 内环①硬门兜底）。
      setState(() {
        _reviewOutput = '环②请求失败：$e';
        _reviewOk = null;
      });
    }
  }

  /// 环② FAIL 的就近原因：优先抽 ✗ / REJECTED 行（机械对照的具体拒绝项，
  /// review.py 的输出形态），抽不到退回全文。
  String get _reviewFailReason {
    final lines = _reviewOutput
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.contains('✗') || l.startsWith('REJECTED'))
        .toList();
    if (lines.isEmpty) return _reviewOutput.trim();
    return lines.join('\n');
  }

  void _render() async {
    final api = store.api;
    if (api == null || _tl == null) return;
    setState(() => _busy = true);
    try {
      final res = await api.postJson('/video/render', {'timeline': _tl, 'spec': _spec, 'fps': _fps.round()});
      if (!mounted) return; // 在飞期间切走视图：dispose 已取消旧定时器，不得再建新轮询
      if (res['ok'] == true) {
        _job = res['job'] as String?;
        if (_job != null) store.setVideoState(job: _job); // 视图切走可接回轮询
        _pollFails = 0; // 新任务重新计数（上一任务的失败计数不复用）
        _poll?.cancel();
        _poll = Timer.periodic(const Duration(milliseconds: 1200), (_) => _pollOnce());
      } else {
        _toast('渲染任务创建失败', '${res['detail']}');
        if (mounted) setState(() => _busy = false);
      }
    } catch (e) {
      _toast('渲染任务创建失败', '$e');
      if (mounted) setState(() => _busy = false);
    }
  }

  void _pollOnce() async {
    final api = store.api;
    if (api == null) {
      // 离线/未连接：不留下永久转圈（恢复的 job 只在有服务器时能接回）。
      if (mounted && _busy) setState(() => _busy = false);
      return;
    }
    final job = _job;
    if (job == null) return;
    try {
      final res = await api.getJson('/video/render/status?job=$job');
      _pollFails = 0; // 任何成功响应（含失效/终态信封）都清零连续失败计数
      if (!mounted || _job != job) return; // 旧回调/已清 job：丢弃迟到结果
      // 未知 job（服务器随 App 重启，任务只在进程内存里 → 404）或任何
      // 非 ok 响应都视为终态：否则每 1.2s 轮询一个永远不存在的 job，
      // _busy 永不清、『加载示例/渲染』永久禁点（工作台死端）。
      if (res['ok'] != true || res['status'] == 404) {
        _poll?.cancel();
        setState(() {
          _job = null;
          _jobState = null;
          _busy = false;
          _previewCount = 0;
        });
        store.setVideoState(job: ''); // 清持久化的失效 job
        _toast('渲染任务已失效', '服务器重启后旧任务不再存在，请重新渲染。');
        return;
      }
      setState(() => _jobState = res);
      if (res['status'] == 'done' || res['status'] == 'failed') {
        _poll?.cancel();
        setState(() {
          _job = null;
          _busy = false;
          _previewCount = (res['frames'] as num?)?.toInt() ?? 0;
        });
        store.setVideoState(job: ''); // 终态不再持久化在飞 job
        if (res['status'] == 'done') {
          _toast('渲染完成（$_previewCount 帧）', '${res['mp4']}');
        } else {
          _toast('渲染失败', (res['log'] ?? '').toString().split('\n').last);
        }
      }
    } catch (_) {
      // 网络抖动不视为终态：保留轮询，服务器恢复后可继续；但只容忍有限
      // 次——连续失败达上限（≈30s）即放弃并复位，服务器永久下线时不得把
      // _busy 永真、「加载示例/渲染」永久禁点（工作台死端）。
      _pollFails++;
      if (_pollFails < _pollMaxFails) return;
      _pollFails = 0;
      _poll?.cancel();
      if (!mounted) return; // dispose 已取消定时器；回来时 initState 重新接回
      setState(() {
        _job = null;
        _jobState = null;
        _busy = false;
        _previewCount = 0;
      });
      store.setVideoState(job: ''); // 失联任务不再持久化为在飞 job
      _toast('渲染任务失联', '连续约 30s 连不上服务器，已停止轮询；恢复连接后请重新渲染。');
    }
  }

  void _toast(String title, String detail) {
    // 失败原因必须可见（此前 detail 形参被丢弃）。
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        if (detail.trim().isNotEmpty)
          Text(detail.trim(), style: const TextStyle(fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
      ]),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final artifact = _artifactPath;
    return Column(
      children: [
        Container(
          height: 46,
          decoration: BoxDecoration(color: p.bgElevated, border: Border(bottom: BorderSide(color: p.line))),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          // 窄屏断点：副标题（长串技术管线）隐藏、返回钮压缩，标题省略号；
          // 390 宽曾溢出 241px。
          child: LayoutBuilder(builder: (context, constraints) {
            final narrow = constraints.maxWidth < 700;
            return Row(children: [
            // 插件视图全屏接管的可见出口（镜像 PlayView 的返回画布）。
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
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink)),
            ),
            if (artifact != null)
              // 产物模式是工作台内部的一次导航，不占用全屏视图的返回键。
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
              Text('无声版 · timeline → 逐帧 SVG → resvg → ffmpeg',
                  style: TextStyle(fontSize: 11, color: p.ink4)),
            const Spacer(),
            if (_busy) SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: p.accent)),
          ]);
          }),
        ),
        Expanded(
          child: artifact != null ? _artifactPane(context, artifact) : LayoutBuilder(builder: (context, constraints) {
            // 手机窄屏：300px 固定配置列会把帧预览压到 ~100px（无溢出但不可用）。
            // 窄屏改单列滚动：配置在上、预览固定高度在下。
            final narrow = constraints.maxWidth < 700;
            if (narrow) {
              return SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _configColumn(context, narrow: true),
                    const SizedBox(height: 8),
                    SizedBox(height: 280, child: _previewPane(context)),
                  ],
                ),
              );
            }
            return Row(children: [
              SizedBox(width: 300, child: _configColumn(context, narrow: false)),
              Expanded(child: _previewPane(context)),
            ]);
          }),
        ),
      ],
    );
  }

  /// 产物模式：播放面 + 信息行（路径 / 复制 / 桌面端在文件夹中显示）。
  /// 这是「视频真能播」的客户端落点——WebView 载入 /video/mp4（有服务器）
  /// 或 file://（离线），不再只是把路径塞进 SnackBar。
  Widget _artifactPane(BuildContext context, String path) {
    final p = context.palette;
    return Column(children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: VideoPlayerSurface(path: path, baseUrl: store.api?.baseUrl),
          ),
        ),
      ),
      Container(
        width: double.infinity,
        decoration: BoxDecoration(
            color: p.bgElevated, border: Border(top: BorderSide(color: p.line))),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          Icon(Icons.movie_outlined, size: 14, color: p.ink4),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(path,
                maxLines: 1,
                style: TextStyle(fontSize: 11, color: p.ink3, fontFamily: 'monospace')),
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
          if (revealSupported)
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

  static String _artifactName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    // 产物固定是 <job>/frames.mp4：父目录名才是「第几个渲染」，帧名没有信息量。
    return parts.length >= 2 ? parts[parts.length - 2] : path;
  }

  Future<void> _copyArtifactPath() async {
    final path = _artifactPath;
    if (path == null) return;
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制路径')));
  }

  Future<void> _revealArtifact() async {
    final path = _artifactPath;
    if (path == null) return;
    final ok = await revealInFolder(path);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法在文件夹中显示')));
  }

  /// 配置列（宽屏固定 300 / 窄屏整宽纵向排列）。
  Widget _configColumn(BuildContext context, {required bool narrow}) {
    final p = context.palette;
    final total = _tl == null
        ? 0.0
        : ((_tl!['scenes'] as List?)?.fold<double>(0, (a, s) => a + ((s['duration'] as num?)?.toDouble() ?? 0)) ?? 0);
    final reviewBox = Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(8)),
      child: SingleChildScrollView(
        child: SelectableText(_reviewOutput,
            style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: p.ink3, height: 1.5)),
      ),
    );
    return Container(
      width: narrow ? double.infinity : 300,
      decoration: BoxDecoration(
        border: narrow ? null : Border(right: BorderSide(color: p.line)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: narrow ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('标杆示例', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.ink2)),
          const SizedBox(height: 8),
          for (var i = 0; i < _samples.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                onTap: () {
                  setState(() => _sampleIdx = i);
                  store.setVideoState(sampleIdx: i);
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: i == _sampleIdx ? p.accentSoft : p.panel2,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: i == _sampleIdx ? p.accent : p.line),
                  ),
                  child: Text(_samples[i].label, style: TextStyle(fontSize: 12, color: i == _sampleIdx ? p.accent : p.ink2)),
                ),
              ),
            ),
          const SizedBox(height: 10),
          Row(children: [
            Text('fps ${_fps.round()}', style: TextStyle(fontSize: 12, color: p.ink2)),
            Expanded(
              child: Slider(
                value: _fps,
                min: 6, max: 30, divisions: 12,
                label: '${_fps.round()}',
                activeColor: p.accent,
                onChanged: (v) => setState(() => _fps = v),
              ),
            ),
          ]),
          Text('片长 ${total.toStringAsFixed(1)}s · 冒烟预览降帧（成片再 30fps 全量）',
              style: TextStyle(fontSize: 10, color: p.ink4)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _loadSample,
            icon: const Icon(Icons.upload_file, size: 15),
            label: const Text('加载示例'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            // 环② FAIL 时禁渲染：失败原因当场就近可见，不滞后到 render.py
            // 独立硬门的「渲染失败」toast。
            onPressed: _busy || _tl == null || _reviewOk == false ? null : _render,
            icon: const Icon(Icons.play_circle_outlined, size: 15),
            label: const Text('渲染（后台）'),
          ),
          if (_reviewOk == false) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: p.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: p.danger.withValues(alpha: 0.6)),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.block_outlined, size: 14, color: p.danger),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_reviewFailReason,
                      style: TextStyle(fontSize: 11, color: p.danger, height: 1.4),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
          ],
          const SizedBox(height: 14),
          if (_reviewOutput.isNotEmpty) ...[
            Row(children: [
              Icon(Icons.rule_outlined, size: 14, color: p.ink3),
              const SizedBox(width: 5),
              Text('环② spec 对照', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: p.ink2)),
            ]),
            const SizedBox(height: 6),
            if (narrow) SizedBox(height: 160, child: reviewBox) else Expanded(child: reviewBox),
          ],
        ],
      ),
    );
  }

  /// 帧预览（加载前是空态提示）。
  Widget _previewPane(BuildContext context) {
    final p = context.palette;
    final status = _jobState?['status']?.toString();
    return _previewCount > 0
        ? _FrameStrip(
            baseUrl: store.api?.baseUrl ?? '',
            count: _previewCount,
            jobDir: _jobState?['dir']?.toString() ?? '')
        : Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.movie_outlined, size: 42, color: p.ink4),
              const SizedBox(height: 12),
              Text(status == 'running' ? '渲染中…（逐帧确定性光栅化）' : '加载示例后点「渲染」',
                  style: TextStyle(fontSize: 12, color: p.ink3)),
            ]),
          );
  }
}

/// 帧条带预览：经 /video/frame 逐帧取图（path 限定 job 目录内，防穿越）。
class _FrameStrip extends StatelessWidget {
  const _FrameStrip({required this.baseUrl, required this.count, required this.jobDir});
  final String baseUrl;
  final int count;
  final String jobDir;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final shown = count < 24 ? count : 24;
    return Column(children: [
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(14),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4, crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 16 / 9),
          itemCount: shown,
          itemBuilder: (ctx, i) {
            final n = count <= 24 ? i : (i * (count - 1) / 23).round();
            return Container(
              decoration: BoxDecoration(border: Border.all(color: p.line), borderRadius: BorderRadius.circular(6)),
              clipBehavior: Clip.antiAlias,
              child: Image.network(
                '$baseUrl/video/frame?path=${Uri.encodeQueryComponent(jobDir)}&n=$n',
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
        child: Text('显示 $shown/$count 帧（均匀抽样）', style: TextStyle(fontSize: 11, color: p.ink4)),
      ),
    ]);
  }
}
