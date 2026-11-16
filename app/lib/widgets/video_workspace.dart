import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';

/// 轨道 B 客户端面：视频工作台（无声版，用户裁决音轨/旁白暂不做）。
/// 加载标杆示例（或粘贴 timeline）→ 环②机械对照 → 后台渲染（job 轮询）
/// → 帧序列预览 + mp4 路径。渲染引擎是独立插件 plugins/video-engine/
/// （服务器端点只是调用方，引擎零服务器依赖）。
class VideoWorkspace extends StatefulWidget {
  const VideoWorkspace({super.key});

  @override
  State<VideoWorkspace> createState() => _VideoWorkspaceState();
}

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

  AppStore get store => context.read<AppStore>();

  @override
  void initState() {
    super.initState();
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
      setState(() => _reviewOutput = (res['output'] ?? '').toString());
    } catch (e) {
      if (!mounted) return;
      setState(() => _reviewOutput = '环②请求失败：$e');
    }
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
      // 网络抖动不视为终态：保留轮询，服务器恢复后可继续。
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
              constraints: BoxConstraints(maxWidth: narrow ? 110 : 400),
              child: Text('视频工作台',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: p.ink)),
            ),
            const SizedBox(width: 14),
            if (!narrow)
              Text('无声版 · timeline → 逐帧 SVG → resvg → ffmpeg',
                  style: TextStyle(fontSize: 11, color: p.ink4)),
            const Spacer(),
            if (_busy) SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.8, color: p.accent)),
          ]);
          }),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
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
            onPressed: _busy || _tl == null ? null : _render,
            icon: const Icon(Icons.play_circle_outlined, size: 15),
            label: const Text('渲染（后台）'),
          ),
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
                errorBuilder: (_, __, ___) => Center(child: Icon(Icons.broken_image_outlined, size: 18, color: p.ink4)),
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
