// A2UI 渲染底座（S0，docs/plan-chat-stream-shell.md §1/§5）。
//
// 本文件是 a2ui 系列包的唯一封装边界：a2ui_flutter / a2ui_agent / a2ui_core
// 的 import 只允许出现在这里，后续升级（0.3.x → 新版）只改本文件。
// 不绑 Firebase：传输层是可注入的 [A2uiTransport]，默认实现
// [aiSdkStreamTextTransport] 接 ai_sdk_dart 的 streamText textStream。
//
// 两条路径共用同一块 surface 宿主（MessageProcessor + A2uiSurface）：
// - `A2uiCard`（流式）：用户指令 → a2ui_agent 的 A2uiGenerator 出系统提示
//   （promptSnippet）→ transport 灌 chunk → openContinuingStream 流解析 →
//   文本与 A2UI 消息边到边渲（文本 Markdown、surface 原生组件）。
// - `A2uiCard.messages`（静态）：surface 消息 JSON（createSurface 等信封
//   序列）直灌 MessageProcessor——.nonapp 载荷、离线打开与 widget 测试
//   走同一条渲染路径。
//
// 回流（outbound）：surface 的用户动作经 onAction 透出（A2uiRendererAction），
// renderer→agent 的 RPC 消息（callAgentFunction 等）经 onOutbound 透出。
// 0.3.0 的 MessageProcessor 尚无统一 `unifiedOutbound` 形参（官方示例超前于
// 已发布 API），这里以 onAction + outboundListener 双通道等价透出——升级到
// 带 unifiedOutbound 的版本时只改本文件的这一处接线。
//
// 运行语义：指令在 mount 时跑一次（run-once-per-mount）——聊天流里每条
// 指令一张新卡（宿主侧自带唯一 key）；同卡指令变化不重跑，S1 按此组装。
//
// openUrl 是显式回调（官方明示 agent 消息是不可信输入）：宿主要放行外链时
// 传 url_launcher 的 launchUrl（如 `(uri) => launchUrl(uri)`），不传即禁用
// （openUrl 调用报 EXECUTION_ERROR，不会逃出本卡）。
//
// 主题：卡片 chrome 与流式文本取 AppTheme 的 NonPalette（context.palette）；
// A2uiSurface 的 Material 组件继承外层 AppTheme（main.dart 已在 MaterialApp
// 挂 AppTheme.build）——basic 目录仅在 surface 消息显式声明 primaryColor 时
// 才覆盖主题色（a2ui_flutter BasicTheme 官方语义，agent 有意为之时不拦）。
import 'dart:async';

import 'package:a2ui_agent/a2ui_agent.dart';
import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:a2ui_flutter/basic_catalog.dart';
import 'package:ai_sdk_dart/ai_sdk_dart.dart'
    show CancellationToken, TimeoutConfiguration, streamText;
import 'package:ai_sdk_openai/ai_sdk_openai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../core/theme.dart';

/// 打开外链的回调（a2ui_core 的 OpenUrlCallback 别名）。
///
/// 传 url_launcher 的 `launchUrl` 即启用，传 null 即禁用。
typedef A2uiOpenUrlCallback = FutureOr<void> Function(Uri url);

/// 一次 A2UI 生成的传输请求：系统提示（promptSnippet 拼宿主前置）+ 用户指令。
class A2uiRunRequest {
  const A2uiRunRequest({
    required this.system,
    required this.prompt,
    this.abortSignal,
  });

  /// 完整系统提示（宿主前置 + a2ui_agent 的 promptSnippet）。
  final String system;

  /// 用户指令。
  final String prompt;

  /// 取消令牌（卡片 dispose / 取消时置位）。可忽略，但尊重它是礼貌。
  final CancellationToken? abortSignal;
}

/// 流式传输抽象：返回 LLM 的文本增量流。
///
/// 默认实现见 [aiSdkStreamTextTransport]；换后端（Anthropic 兼容网关、桌面
/// ACP agent）即换这个参数，卡片本体不感知传输细节。
typedef A2uiTransport =
    Future<Stream<String>> Function(A2uiRunRequest request);

/// 默认传输：ai_sdk_dart `streamText` 的 textStream。
///
/// OpenAI 兼容协议（ai_sdk_openai 的 OpenAIProvider），与 store/mobile_agent
/// 现有链路同源；provider 在流结束/出错/被取消时释放。
A2uiTransport aiSdkStreamTextTransport({
  required String apiKey,
  required String baseUrl,
  required String model,
  Duration? timeout,
}) {
  return (request) async {
    final provider = OpenAIProvider(apiKey: apiKey, baseUrl: baseUrl);
    try {
      final result = await streamText(
        model: provider.call(model),
        system: request.system,
        prompt: request.prompt,
        abortSignal: request.abortSignal,
        timeout: timeout == null ? null : TimeoutConfiguration(total: timeout),
      );
      // async* 包一层：消费侧停止监听/流出错/自然结束时都释放 provider。
      Stream<String> relay() async* {
        try {
          await for (final chunk in result.textStream) {
            yield chunk;
          }
        } finally {
          provider.dispose();
        }
      }

      return relay();
    } on Object {
      provider.dispose();
      rethrow;
    }
  };
}

/// A2UI 卡片：聊天流里的原生富交互层（表单/输入/滑杆 + DataModel 绑定 +
/// 动作回流），S0 的渲染底座。
class A2uiCard extends StatefulWidget {
  /// 流式路径：一条用户指令，边流边渲（指令为空即不跑，仅渲宿主回调）。
  const A2uiCard({
    super.key,
    required this.instruction,
    required this.transport,
    this.systemPreamble,
    this.locale = 'zh-CN',
    this.openUrl,
    this.onAction,
    this.onOutbound,
    this.onError,
    this.onTextChunk,
    this.offlineOnly = false,
  }) : messages = null;

  /// 静态路径：surface 消息 JSON 直灌（.nonapp 载荷 / 离线打开 / 测试）。
  ///
  /// [messages] 每项是一个已解码的信封 map（如
  /// `{'version': '1.0', 'createSurface': {...}}`），与 A2UI 协议同形。
  const A2uiCard.messages({
    super.key,
    required List<Object?> this.messages,
    this.locale = 'zh-CN',
    this.openUrl,
    this.onAction,
    this.onOutbound,
    this.onError,
    this.offlineOnly = false,
  }) : instruction = null,
       transport = null,
       systemPreamble = null,
       onTextChunk = null;

  /// 流式路径用的推理格式：Direct JSON（`<a2ui-json>` 块，text/label 渐进
  /// 显示，与官方 chat 示例同选型）。测试用它构造同源夹具。
  static const InferenceFormatFactory format = DirectJsonFormatFactory(
    progressiveKeys: {'text', 'label'},
  );

  /// 宿主未给前置时的默认角色说明（拼在 promptSnippet 之前）。
  static const String defaultPreamble =
      '你是 NaN 聊天流中的设计助手。回答用一两句话；表单、清单、卡片、'
      '参数选择这类数据交互界面用 A2UI surface 呈现。每个新 surface 用新的 '
      'surfaceId；带输入控件的 surface 设 "sendDataModel": true，把输入绑定'
      '到数据模型路径，提交按钮的事件在 context 里带回这些路径的值。';

  /// 流式路径的用户指令；静态路径为 null。
  final String? instruction;

  /// 静态路径的原始消息 JSON；流式路径为 null。
  final List<Object?>? messages;

  /// 流式传输（流式路径必需）。
  final A2uiTransport? transport;

  /// 宿主角色前置，缺省用 [defaultPreamble]。
  final String? systemPreamble;

  /// basic 目录的格式化 locale（日期/货币等），未知值回退 en-US。
  final String locale;

  /// 外链放行回调；null 即禁用（openUrl 调用报 EXECUTION_ERROR）。
  final A2uiOpenUrlCallback? openUrl;

  /// `.nonapp` 等不可信载荷：媒体组件只渲染 data: 内容，绝不发起网络请求。
  ///
  /// 静态门（[assertSurfaceRenderable]）已经拒绝外链与动态拼接，但图/视频
  /// 的 URL 也可能来自 data model；这一层在渲染时再做一次兜底，即使门被
  /// 绕过也不会触发 `Image.network` / 网络播放器。
  final bool offlineOnly;

  /// 动作回流：surface 上的用户事件动作（name/context/surfaceId）。
  final void Function(A2uiRendererAction action)? onAction;

  /// renderer→agent 消息回流（callAgentFunction / functionResponse 等）。
  final void Function(RendererToAgentMessage message)? onOutbound;

  /// 错误回流：运行失败、解析拒绝与 surface 上报的错误。
  final void Function(Object error)? onError;

  /// 流式文本增量（TextPart，可选观察）。
  final void Function(String delta)? onTextChunk;

  @override
  State<A2uiCard> createState() => _A2uiCardState();
}

class _A2uiCardState extends State<A2uiCard> {
  MessageProcessor<ComponentImplementation>? _processor;
  CatalogImplementation? _catalog;
  final List<SurfaceModel<ComponentImplementation>> _surfaces = [];
  final List<Subscription> _surfaceSubscriptions = [];
  final Set<String> _reportedErrors = {};
  RendererState? _agentState;
  CancellationToken? _token;
  String _text = '';
  String? _error;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _catalog = _catalogFor(
      locale: widget.locale,
      openUrl: widget.openUrl,
      offlineOnly: widget.offlineOnly,
    );
    final processor = MessageProcessor<ComponentImplementation>(
      catalogs: [_catalog!],
      defaultVersion: A2uiProtocolVersion.v1_0,
      // relaxed：流式到达的半截 surface 不该被整树检查卡死（官方 chat 示例
      // 同选型）；schema 与重复 id 检查仍然生效。
      validationConfig: ValidationConfig.relaxed,
      onAction: (action) => widget.onAction?.call(action),
      outboundListener: (message) => widget.onOutbound?.call(message),
    );
    processor.model.onSurfaceCreated.subscribe(_addSurface);
    processor.model.onSurfaceDeleted.subscribe(_removeSurface);
    _processor = processor;
    if (widget.messages != null) {
      // 静态路径：initState 里同步入列（订阅已就位，onSurfaceCreated 会在
      // 首次 build 前把 surface 收进 _surfaces——官方 README 同模式）。
      // **不可信输入**：.nonapp 的 surface.json 来自外部文件，结构门只能
      // 挡住 known-bad 形状；processMessages 对 schema 错会抛
      // A2uiValidationError（同步抛在 initState 里 = 打开坏包炸整页）。
      // 这里降级为卡内错误行 + onError 回流，异常绝不冒泡。
      try {
        processor.processMessages(widget.messages);
      } on Object catch (error) {
        _error = 'surface 消息无效：$error';
        widget.onError?.call(error);
      }
    } else if (widget.instruction != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  void _addSurface(SurfaceModel<ComponentImplementation> surface) {
    _surfaceSubscriptions.add(
      surface.onError.subscribe(_reportSurfaceError),
    );
    if (mounted) {
      setState(() => _surfaces.add(surface));
    } else {
      _surfaces.add(surface);
    }
  }

  void _removeSurface(String surfaceId) {
    if (!mounted) return;
    setState(() => _surfaces.removeWhere((s) => s.id == surfaceId));
  }

  void _reportSurfaceError(A2uiRendererError error) {
    final key = 'surface:${error.surfaceId}:${error.code}:${error.message}';
    if (!_reportedErrors.add(key)) return;
    widget.onError?.call(error);
    if (mounted) {
      setState(() => _error = '${error.code} on "${error.surfaceId}"');
    }
  }

  String _systemPrompt(String snippet) =>
      '${widget.systemPreamble ?? A2uiCard.defaultPreamble}\n$snippet';

  Future<void> _run() async {
    if (!mounted || widget.instruction == null || widget.transport == null) {
      return;
    }
    final token = _token = CancellationToken();
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      // agent 侧：目录协商（我们自己的渲染器声明 v1.0 basic 目录）→
      // promptSnippet 出系统提示 → 流解析器开流。
      final agent = A2uiGenerator(
        catalogs: [CatalogConfig(_catalog!)],
        inferenceFormatFactory: A2uiCard.format,
      ).createProcessor(
        A2uiRendererCapabilities.forCatalogIds(
          [BasicCatalog.v1_0Id],
          version: A2uiProtocolVersion.v1_0,
        ),
      );
      // 会话级 renderer state：同卡增量指令续写时，后一轮校验建立在
      // 前一轮的 surface 之上。
      _agentState ??= agent.createState();
      final stream = agent.openContinuingStream(state: _agentState);
      final chunks = await widget.transport!(
        A2uiRunRequest(
          system: _systemPrompt(agent.promptSnippet),
          prompt: widget.instruction!,
          abortSignal: token,
        ),
      );
      await for (final chunk in chunks) {
        if (!mounted || token.isCancelled) break;
        _read(stream.feed(chunk));
      }
      if (mounted && !token.isCancelled) {
        _read(stream.close());
      }
    } on Object catch (error) {
      if (mounted && !token.isCancelled) {
        _reportedErrors.add('run:$error');
        widget.onError?.call(error);
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  /// 一批流解析产物：文本进 Markdown 行，A2UI 消息灌渲染处理器，
  /// 被跳过的坏块（openContinuingStream 的 ErrorPart）落错误行不中断。
  void _read(List<StreamPart> parts) {
    for (final part in parts) {
      switch (part) {
        case TextPart(:final text):
          widget.onTextChunk?.call(text);
          if (mounted) {
            setState(() => _text += text);
          } else {
            _text += text;
          }
        case A2uiPart(:final a2ui):
          _processor!.processMessages(AgentToRendererMessagePayload(a2ui));
        case ErrorPart(:final error):
          final key = 'block:${error.message}';
          if (_reportedErrors.add(key)) {
            widget.onError?.call(error);
            if (mounted) {
              setState(() => _error = error.message);
            }
          }
      }
    }
  }

  @override
  void dispose() {
    _token?.cancel();
    for (final subscription in _surfaceSubscriptions) {
      subscription.unsubscribe();
    }
    _surfaceSubscriptions.clear();
    _processor?.dispose();
    _agentState?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Material(
      color: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: palette.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_text.isNotEmpty)
              MarkdownBody(
                data: _text,
                styleSheet: MarkdownStyleSheet.fromTheme(
                  Theme.of(context),
                ).copyWith(
                  p: TextStyle(fontSize: 12, color: palette.ink2, height: 1.45),
                ),
              ),
            for (final surface in _surfaces) ...[
              if (_text.isNotEmpty) const SizedBox(height: 10),
              // Material 组件继承外层 AppTheme（context.palette 派生的
              // colorScheme）；surface 消息显式声明 primaryColor 时由
              // a2ui_flutter 的 BasicTheme 官方语义接管。
              A2uiSurface(surface: surface),
            ],
            if (_running && _text.isEmpty && _surfaces.isEmpty) ...[
              Row(
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: palette.accent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '生成中…',
                    style: TextStyle(fontSize: 11, color: palette.ink3),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 11, color: palette.danger),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 离线载荷的 basic 目录：媒体组件换成不发起网络请求的本地实现。
///
/// 仍复用官方 [`basicCatalog`] 的 schema/functions（协议面不变），只替换
/// Image / Video / AudioPlayer 三个会走网络的 builder。
CatalogImplementation _catalogFor({
  required String locale,
  A2uiOpenUrlCallback? openUrl,
  required bool offlineOnly,
}) {
  final base = basicCatalog(locale: locale, openUrl: openUrl);
  if (!offlineOnly) return base;
  return base.copyWith(components: [
    for (final component in base.components.values)
      if (component.name == 'Image')
        _replaceComponent(component, _offlineImageBuilder)
      else if (component.name == 'Video' || component.name == 'AudioPlayer')
        _replaceComponent(component, _offlineMediaBuilder)
      else
        component,
  ]);
}

ComponentImplementation _replaceComponent(
  ComponentImplementation base,
  Widget Function(
    BuildContext,
    ComponentNode<ComponentImplementation>,
    ComponentProps,
    ChildWidgetBuilder,
  ) builder,
) =>
    ComponentImplementation(
      name: base.name,
      schema: base.schema,
      allowedParents: base.allowedParents,
      allowedChildren: base.allowedChildren,
      builder: builder,
    );

Widget _offlineImageBuilder(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) {
  final url = (props.string('url') ?? '').trim();
  final description = props.string('description') ?? '';
  final broken = description.isEmpty
      ? const Icon(Icons.broken_image)
      : Semantics(image: true, label: description, child: const Icon(Icons.broken_image));
  Widget image = broken;
  if (url.startsWith('data:')) {
    final bytes = Uri.tryParse(url)?.data?.contentAsBytes();
    if (bytes != null && bytes.isNotEmpty) {
      image = Image.memory(
        bytes,
        fit: BoxFit.fill,
        semanticLabel: description.isEmpty ? null : description,
        excludeFromSemantics: description.isEmpty,
        errorBuilder: (context, error, stackTrace) => broken,
      );
    }
  }
  return switch (props.string('variant')) {
    'icon' => Align(
        alignment: AlignmentDirectional.topStart,
        widthFactor: 1,
        heightFactor: 1,
        child: SizedBox.square(dimension: 24, child: image),
      ),
    'avatar' => Align(
        alignment: AlignmentDirectional.topStart,
        widthFactor: 1,
        heightFactor: 1,
        child: SizedBox.square(dimension: 40, child: ClipOval(child: image)),
      ),
    'smallFeature' => Align(
        alignment: AlignmentDirectional.topStart,
        widthFactor: 1,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 100),
          child: image,
        ),
      ),
    'largeFeature' => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 400),
        child: image,
      ),
    'header' => SizedBox(height: 200, child: image),
    _ => image,
  };
}

/// 离线载荷的音视频占位：不创建播放器、不解析网络地址。
Widget _offlineMediaBuilder(
  BuildContext context,
  ComponentNode<ComponentImplementation> node,
  ComponentProps props,
  ChildWidgetBuilder buildChild,
) {
  final description =
      (props.string('description') ?? props.string('label') ?? '').trim();
  return Container(
    constraints: const BoxConstraints(maxWidth: 300),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.movie_outlined, size: 18),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            description.isEmpty ? '本地预览不播放外部媒体' : description,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    ),
  );
}
