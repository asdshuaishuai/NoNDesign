import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/mediapipe_service.dart';
import '../core/theme.dart';
import '../core/toast_service.dart';
import 'common.dart';

/// 设置里的「本地语义模型」卡：下载、删除、校验与平台支持。
///
/// 纪律（docs/plan-flutter-3.50-adoption.md N6/M1 的用户面）：
/// - **绝不自动下载**：约 388 MB 的模型只由用户点「下载」触发；
/// - 官方只公布近似大小，进度条按不确定态呈现，不画假百分比；
/// - 下载完成后由服务层校验文件完整性，校验失败即删除并提示重试；
/// - 平台不支持时按钮禁用并说明原因，不假装可以下载。
///
/// 服务与提示都可注入（测试不联网、不碰真实模型目录）。
class MediaPipeModelCard extends StatefulWidget {
  const MediaPipeModelCard({
    super.key,
    this.service,
    this.model = MediaPipeModels.universalEmbedder,
    this.sizeLabel = '约 388 MB',
    this.toasts,
  });

  /// 模型服务（默认进程内共享实例）。
  final MediaPipeService? service;

  /// 注册表条目（测试可注入自造条目与临时目录）。
  final MediaPipeModelDescriptor model;

  /// 大小文案（官方只给近似值；测试可覆盖）。
  final String sizeLabel;

  /// 通知出口（默认全局实例）。
  final ToastService? toasts;

  @override
  State<MediaPipeModelCard> createState() => _MediaPipeModelCardState();
}

class _MediaPipeModelCardState extends State<MediaPipeModelCard> {
  late final MediaPipeService _service = widget.service ?? MediaPipeService.shared;
  MediaPipeAvailability? _availability;
  bool _probing = true;
  bool _downloading = false;
  bool _deleting = false;
  int _received = 0;
  String? _error;

  ToastService get _toasts => widget.toasts ?? ToastService.instance;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    MediaPipeAvailability availability;
    try {
      availability = await _service.probe(widget.model);
    } catch (_) {
      availability = MediaPipeAvailability(
        status: MediaPipeStatus.modelUnavailable,
        platform: 'unknown',
        modelId: widget.model.id,
      );
    }
    if (!mounted) return;
    setState(() {
      _availability = availability;
      _probing = false;
    });
  }

  /// 错误码 → 人话（原始错误只留在日志，不占屏幕）。
  String _friendly(MediaPipeModelException e) {
    switch (e.code) {
      case 'sha256_mismatch':
        return '模型文件校验失败，已删除，请重试';
      case 'download_failed':
        return '模型下载失败，请检查网络后重试';
      case 'model_unpinned':
        return '这个模型暂不可下载，请稍后再试';
      default:
        return '模型没有准备好，请重试';
    }
  }

  Future<void> _download() async {
    if (_downloading || _deleting) return;
    setState(() {
      _downloading = true;
      _error = null;
      _received = 0;
    });
    try {
      await _service.ensureModel(widget.model, onProgress: (received, total) {
        if (!mounted) return;
        setState(() => _received = received);
      });
      if (!mounted) return;
      setState(() => _downloading = false);
      _toasts.success('本地语义模型已就绪');
      await _refresh();
    } on MediaPipeModelException catch (e) {
      debugPrint('[mediapipe] download failed: ${e.code} ${e.message}');
      if (!mounted) return;
      final message = _friendly(e);
      setState(() {
        _downloading = false;
        _error = message;
      });
      _toasts.error(message);
      await _refresh();
    } catch (e) {
      debugPrint('[mediapipe] download failed: $e');
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = '模型下载失败，请检查网络后重试';
      });
      _toasts.error('模型下载失败，请检查网络后重试');
    }
  }

  Future<void> _delete() async {
    if (_downloading || _deleting) return;
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      final file = File(_service.modelPathFor(widget.model));
      if (await file.exists()) await file.delete();
      _toasts.info('已删除本地模型');
    } catch (e) {
      debugPrint('[mediapipe] delete failed: $e');
      if (mounted) setState(() => _error = '删除没有完成，请重试');
    } finally {
      if (mounted) {
        setState(() => _deleting = false);
        await _refresh();
      }
    }
  }

  String get _sizeText {
    final received = _received;
    if (received <= 0) return '';
    final mb = received / (1024 * 1024);
    return mb >= 1 ? '已接收 ${mb.toStringAsFixed(1)} MB' : '已接收 ${(received / 1024).round()} KB';
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final availability = _availability;
    final supported = availability?.supported ?? true;
    final ready = availability?.available ?? false;
    final statusLabel = _probing
        ? '检查中'
        : ready
            ? '已就绪'
            : !supported
                ? '当前设备不支持'
                : '未下载';
    final statusColor = ready ? p.success : (!supported ? p.warn : p.ink4);

    return Container(
      key: const ValueKey('mediapipe-model-card'),
      padding: const EdgeInsets.all(NonSpace.md),
      decoration: BoxDecoration(
        color: p.panel2.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 16, color: p.accent),
              const SizedBox(width: NonSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('本地语义模型',
                        style: TextStyle(fontSize: NonType.body, fontWeight: FontWeight.w600, color: p.ink)),
                    const SizedBox(height: NonSpace.xxs),
                    Text('用于作品与应用的本机语义检索；模型不随安装包分发。',
                        style: TextStyle(fontSize: NonType.micro, height: NonType.lineBody, color: p.ink3)),
                  ],
                ),
              ),
              Pill(label: statusLabel, color: statusColor),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text('大小 ${widget.sizeLabel} · 下载后自动校验文件完整性',
                    style: TextStyle(fontSize: NonType.micro, color: p.ink4)),
              ),
              if (supported)
                TextButton.icon(
                  key: const ValueKey('mediapipe-download'),
                  onPressed: _probing || _downloading || _deleting ? null : _download,
                  icon: Icon(ready ? Icons.refresh : Icons.download_outlined, size: 14),
                  label: Text(ready ? '重新下载' : '下载', style: const TextStyle(fontSize: NonType.caption)),
                ),
              if (ready)
                TextButton.icon(
                  key: const ValueKey('mediapipe-delete'),
                  onPressed: _deleting || _downloading ? null : _delete,
                  icon: const Icon(Icons.delete_outline, size: 14),
                  label: const Text('删除', style: TextStyle(fontSize: NonType.caption)),
                ),
            ],
          ),
          if (_downloading) ...[
            const SizedBox(height: 6),
            // 官方只给近似大小：不确定态进度条，不显示假百分比。
            ClipRRect(
              key: const ValueKey('mediapipe-progress'),
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: null,
                minHeight: 4,
                backgroundColor: p.panel3,
                valueColor: AlwaysStoppedAnimation<Color>(p.accent),
              ),
            ),
            const SizedBox(height: NonSpace.xs),
            Text(
              [if (_sizeText.isNotEmpty) _sizeText, '正在下载…'].join(' · '),
              style: TextStyle(fontSize: NonType.micro, color: p.ink4),
            ),
          ],
          if (!supported && availability != null) ...[
            const SizedBox(height: 6),
            Text('当前设备不在官方支持范围内，本地语义检索会保持关闭。',
                style: TextStyle(fontSize: NonType.micro, height: NonType.lineBody, color: p.warn)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: p.warn.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: p.warn.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_error!, style: TextStyle(fontSize: NonType.micro, color: p.warn)),
                  ),
                  if (supported)
                    TextButton(
                      onPressed: _downloading ? null : _download,
                      child: const Text('重试', style: TextStyle(fontSize: NonType.caption)),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
