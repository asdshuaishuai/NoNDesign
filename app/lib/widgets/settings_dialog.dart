import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:provider/provider.dart';

import '../core/layout.dart';
import '../core/mediapipe_service.dart';
import '../core/models.dart';
import '../core/keys.dart';
import '../core/platform_capabilities.dart';
import '../core/remote_desktop_client.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';
import 'mediapipe_model_card.dart';

Future<void> showSettingsDialog(BuildContext context, {MediaPipeService? mediaPipeService}) async {
  await showNonDialog<void>(
    context: context,
    builder: (context) => _SettingsDialog(mediaPipeService: mediaPipeService),
  );
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({this.mediaPipeService});

  /// 本地语义模型服务（测试注入临时目录；默认进程内共享实例）。
  final MediaPipeService? mediaPipeService;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  String _tab = 'models';
  // 手机端独立布局：null = 分组根页；否则为下钻的分组 id。
  // 与 _tab 分开：桌面/平板保持既有三档导航，手机走「列表 → 详情」。
  String? _mobileSection;
  bool _keyVisible = false;
  String _query = '';
  late final TextEditingController _keyController;
  late final TextEditingController _baseController;
  late final TextEditingController _remoteUrlController;
  late final TextEditingController _remoteTokenController;
  List<AcpAgentInfo> _acpAgents = const [];
  // 外部智能体探测失败的人话原因；null = 正常或未探测。
  String? _acpError;
  // 「检测连接」内联状态：检测中 / 已连接 / 失败原因。
  bool _remoteTesting = false;
  bool _remoteConnected = false;
  String? _remoteMessage;
  // 步数输入控制器：initState 赋值（字段初始化器访问不到局部 store）。
  late final TextEditingController _stepsController;
  final TextEditingController _customModelController = TextEditingController();
  // 自定义端点开关：开 = baseUrl 可编辑（兼容网关 / 中转）；关 = 内置只读。
  // 初值由「当前端点 ≠ 内置」派生（initState 尾部，2026-11-19 移动适配）。
  bool _customEndpoint = false;
  final _stepsFocus = FocusNode();
  bool _stepsSavedFlash = false;

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    _keyController = TextEditingController(text: store.settings.apiKey);
    // 内置服务商的端点来自模型快照：设置页打开时就填入，避免「先切一次
    // 服务商才看到端点」的空态。端点本身只读（内置不可改）。
    //
    // 只回填内存、不落盘：打开设置不应产生一次隐式保存（此前 initState
    // 的微任务落盘让首次显式保存变成第二次写盘）。首次显式保存/切服务商
    // 时才写盘；旧自定义端点保持原值，由「旧自定义端点」提示显式重置。
    final fallback = _endpointForProvider(store, store.settings.providerId);
    final base = store.settings.baseUrl.isNotEmpty ? store.settings.baseUrl : fallback;
    if (store.settings.baseUrl.isEmpty && fallback.isNotEmpty) {
      store.settings.baseUrl = fallback;
    }
    _baseController = TextEditingController(text: base);
    _remoteUrlController = TextEditingController(text: store.settings.serverUrl);
    _remoteTokenController = TextEditingController(text: store.serverToken);
    _remoteConnected = store.remoteStatus.connected;
    _remoteMessage = store.remoteStatus.connected ? store.remoteStatus.message : null;
    _stepsController = TextEditingController(text: store.settings.maxSteps.toString());
    _stepsFocus.addListener(() { if (mounted) setState(() {}); });
    _customEndpoint = _hasLegacyEndpoint(store);
    _loadAcpAgents();
  }

  /// 自定义端点开关切换：开 = 当前值保持可编辑；关 = 恢复内置端点并落盘。
  Future<void> _setCustomEndpoint(bool value, AppStore store) async {
    setState(() => _customEndpoint = value);
    if (!value) {
      final builtin = _endpointForProvider(store, store.settings.providerId);
      if (builtin.isNotEmpty) {
        store.settings.baseUrl = builtin;
        _baseController.text = builtin;
      }
    }
    await store.saveSettings();
    if (mounted) setState(() {});
  }

  /// 显式保存按钮（用户点名）：把步数输入框的当前值提交并给出 ✓ 反馈。
  Future<void> _saveSteps() async {
    final store = context.read<AppStore>();
    store.settings.maxSteps =
        (int.tryParse(_stepsController.text) ?? store.settings.maxSteps).clamp(4, 600);
    await store.saveSettings();
    // 双写盘（SharedPreferences + settings.json）在飞期间弹窗可能已被
    // 关闭（窄窗口）——await 之后先验 mounted，防 setState-after-dispose。
    if (!mounted) return;
    setState(() => _stepsSavedFlash = true);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _stepsSavedFlash = false);
    });
  }

  Future<void> _loadAcpAgents() async {
    final api = context.read<AppStore>().api;
    if (api == null) {
      if (mounted) setState(() => _acpError = '现在还不能检测外部智能体，请稍后重试');
      return;
    }
    try {
      final agents = await api.acpAgents(probe: true).timeout(const Duration(seconds: 50));
      if (mounted) {
        setState(() {
          _acpAgents = agents;
          _acpError = null;
        });
      }
    } catch (e) {
      // 失败显性呈现（_acp 顶部错误行 + 重试），不静默吞掉——原始错误只进日志。
      debugPrint('[settings] external agent probe failed: $e');
      if (mounted) setState(() => _acpError = '检测没有完成，请稍后重试');
    }
  }

  @override
  void dispose() {
    _keyController.dispose();
    _baseController.dispose();
    _remoteUrlController.dispose();
    _remoteTokenController.dispose();
    _stepsController.dispose();
    _stepsFocus.dispose();
    _customModelController.dispose();
    super.dispose();
  }

  String _endpointForProvider(AppStore store, String providerId) {
    final api = (store.registry.provider(providerId)?['api'] ?? '').toString().trim();
    return api.isNotEmpty ? api : builtInBaseUrlFor(providerId);
  }

  static String _trimEndpoint(String value) =>
      value.trim().replaceAll(RegExp(r'/+$'), '');

  /// 当前端点是否与内置端点不同（旧自定义端点：显式提示 + 可重置，不静默锁死）。
  bool _hasLegacyEndpoint(AppStore store) {
    final actual = _trimEndpoint(store.settings.baseUrl);
    if (actual.isEmpty) return false;
    final builtIn = _trimEndpoint(_endpointForProvider(store, store.settings.providerId));
    return builtIn.isEmpty || actual != builtIn;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    final size = MediaQuery.sizeOf(context);
    // 三档布局：手机/矮窗全屏 + 顶部导航；iPad 竖屏全屏但内容限宽；
    // iPad 横屏/桌面居中对话框 + 左侧导航（两种朝向不共用同一套堆叠）。
    final phone = size.width < 700;
    final short = size.height < 560;
    final padPortrait = !phone && !short && size.width < 1100 && size.height >= size.width;
    final fullScreen = phone || short || padPortrait;
    // 手机（含横屏矮窗）走独立移动端布局：分组列表 → 下钻详情。
    // 不再沿用「顶部横向 tab + 桌面向量表单」——2026-11-17 用户实测反馈
    // 两列输入在 390 宽挤成一条、字号 11 不可读、下半屏空白。
    final phoneLayout = phone || (size.height < 460 && size.width < 960);
    if (phoneLayout) {
      // 系统返回（Android back / 预测性返回）先回分组根页，再按一次才关
      // 设置：此前普通路由被直接 pop，下钻详情页没有栈内退路（review
      // settings-2）。
      return PopScope<Object?>(
        canPop: _mobileSection == null,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (_mobileSection != null) setState(() => _mobileSection = null);
        },
        child: _mobileFrame(context, store),
      );
    }
    final dialogWidth = (size.width - 48).clamp(320.0, size.width < 1100 ? 920.0 : 860.0).toDouble();
    final dialogHeight = (size.height - 48).clamp(420.0, 640.0).toDouble();
    final railWidth = size.width < 1100 ? 200.0 : 176.0;
    // 外部智能体需要本机进程能力：移动端入口整体隐藏（iOS 不能拉起任意
    // 进程、Android 不能执行 PATH 上的 CLI），只保留内置智能体。
    final mobile = Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.android;
    final navItems = <(String, IconData, String)>[
      ('models', Icons.memory, '模型与端点'),
      ('agent', Icons.smart_toy_outlined, '智能体'),
      ('appearance', Icons.palette_outlined, '外观与交互'),
      if (!mobile) ('acp', Icons.hub_outlined, '外部智能体'),
      ('about', Icons.info_outline, '关于'),
    ];
    final content = Padding(
      padding: EdgeInsets.all(phone ? 14 : (padPortrait ? 20 : 18)),
      child: switch (_tab) {
        'appearance' => _appearance(context, store),
        'agent' => _agent(context, store),
        'acp' => mobile ? _models(context, store) : _acp(context, store),
        'about' => _about(context, store),
        _ => _models(context, store),
      },
    );
    final topNav = Container(
      key: const ValueKey('settings-topnav'),
      width: double.infinity,
      height: phone ? 46 : 50,
      decoration: BoxDecoration(
        color: p.panel2.withValues(alpha: 0.3),
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          for (final item in navItems) _nav(context, item.$1, item.$2, item.$3, compact: true),
        ]),
      ),
    );
    return Dialog(
      insetPadding: fullScreen ? EdgeInsets.zero : const EdgeInsets.all(24),
      backgroundColor: p.panel,
      shape: fullScreen
          ? const RoundedRectangleBorder()
          : RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16), side: BorderSide(color: p.lineStrong)),
      child: SizedBox(
        width: fullScreen ? double.infinity : dialogWidth,
        height: fullScreen ? double.infinity : dialogHeight,
        child: SafeArea(
          child: Column(
            children: [
              Container(
                height: 54,
                padding: EdgeInsets.symmetric(horizontal: phone ? 14 : 18),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
                child: Row(
                  children: [
                    Text('设置', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink)),
                    if (!phone) ...[
                      const SizedBox(width: 8),
                      Text('模型与端点、智能体、外观设置', style: TextStyle(fontSize: 11, color: p.ink3)),
                    ],
                    const Spacer(),
                    // 触屏（iPad/手机）关闭按钮命中区 44：视觉尺寸不变，
                    // IconAction 的 InkWell 盒子按 hitSize 放大（review
                    // settings-1；桌面临界值是 26）。
                    IconAction(
                      icon: Icons.close,
                      tooltip: '关闭',
                      size: 26,
                      hitSize: mobile ? 44 : null,
                      onTap: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              if (fullScreen) topNav,
              Expanded(
                child: fullScreen
                    ? Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: padPortrait ? 820 : double.infinity),
                          child: content,
                        ),
                      )
                    : Row(
                        children: [
                          Container(
                            key: const ValueKey('settings-rail'),
                            width: railWidth,
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: p.panel2.withValues(alpha: 0.3),
                              border: Border(right: BorderSide(color: p.line)),
                            ),
                            child: Column(
                              children: [
                                for (final item in navItems) _nav(context, item.$1, item.$2, item.$3),
                              ],
                            ),
                          ),
                          Expanded(child: content),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _nav(BuildContext context, String id, IconData icon, String label, {bool compact = false}) {
    final p = context.palette;
    final active = _tab == id;
    // 触屏（iOS/Android，含 iPad 两朝向）最小触控目标 44：顶部 tab 与
    // 侧栏项同规；桌面维持 32/34 的紧凑密度（review settings-1）。
    final touch = Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.android;
    return InkWell(
      key: ValueKey('settings-nav-$id'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _tab = id),
      child: Container(
        height: touch ? 44 : (compact ? 32 : 34),
        margin: compact ? const EdgeInsets.only(right: 4) : const EdgeInsets.only(bottom: 2),
        padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 9),
        decoration: BoxDecoration(
          color: active ? p.panel : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: active ? p.accent : p.ink4),
            const SizedBox(width: 7),
            Text(label,
                maxLines: 1,
                style: TextStyle(fontSize: 12, color: active ? p.ink : p.ink3)),
          ],
        ),
      ),
    );
  }

  Widget _models(BuildContext context, AppStore store) {
    final p = context.palette;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _labeled(context, '服务商',
              KeyedSubtree(key: const ValueKey('settings-provider'), child: _providerDropdown(context, store))),
          const SizedBox(height: 10),
          // 模型行紧贴服务商下方：点按打开底部选择面板（搜索/更新/勾选）。
          _labeled(context, '模型', _modelRow(context, store, keyName: 'settings-model-row')),
          const SizedBox(height: 10),
          // 端点：默认内置只读；打开「自定义端点」后可编辑（兼容网关 / 中转）。
          // 自定义态由「当前端点 ≠ 内置」派生（旧自定义端点自动落在自定义态）。
          _labeled(context, '端点', Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('settings-endpoint'),
                controller: _baseController,
                readOnly: !_customEndpoint,
                style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'Menlo',
                    color: _customEndpoint ? p.ink : p.ink2),
                decoration: InputDecoration(
                  hintText: _customEndpoint
                      ? 'https://your-gateway.example/v1'
                      : '内置端点',
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
                  suffixIcon: _customEndpoint
                      ? IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(Icons.restart_alt, size: 14, color: p.ink4),
                          tooltip: '恢复内置端点',
                          onPressed: () => _setCustomEndpoint(false, store),
                        )
                      : Icon(Icons.lock_outline, size: 13, color: p.ink4),
                ),
                onChanged: (v) => store.settings.baseUrl = _trimEndpoint(v),
                onSubmitted: (v) async {
                  store.settings.baseUrl = _trimEndpoint(v);
                  await store.saveSettings();
                },
                onTapOutside: (_) async {
                  store.settings.baseUrl = _trimEndpoint(_baseController.text);
                  await store.saveSettings();
                },
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _customEndpoint
                          ? '自定义端点已生效（兼容网关 / 中转）；点 🔄 恢复内置端点'
                          : '端点为内置只读；打开自定义端点可接入兼容网关 / 中转',
                      style: TextStyle(fontSize: 11, color: p.ink3),
                    ),
                  ),
                  Text('自定义端点',
                      style: TextStyle(fontSize: 11, color: p.ink3)),
                  const SizedBox(width: 4),
                  Switch.adaptive(
                    key: const ValueKey('settings-endpoint-custom'),
                    value: _customEndpoint,
                    activeColor: p.accent,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) => _setCustomEndpoint(v, store),
                  ),
                ],
              ),
            ],
          )),
          if (_customEndpoint)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '自定义端点请自行保证与所选模型的服务协议兼容。',
                style: TextStyle(fontSize: 11, height: 1.4, color: p.ink4),
              ),
            ),
          const SizedBox(height: 12),
          _labeled(context, 'API Key（只存本机）', TextField(
            controller: _keyController,
            obscureText: false,
            style: TextStyle(fontSize: 11, fontFamily: 'Menlo', color: p.ink2),
            decoration: const InputDecoration(hintText: 'sk-…'),
            onSubmitted: (v) async {
              store.settings.apiKey = v.trim();
              await store.saveSettings();
            },
            onTapOutside: (_) async {
              store.settings.apiKey = _keyController.text.trim();
              await store.saveSettings();
            },
          )),
          const SizedBox(height: 14),
          MediaPipeModelCard(service: widget.mediaPipeService),
          const SizedBox(height: 12),
          if (store.model != null)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: p.panel2.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(10)),
              // 两行基线对齐：行1 标题+context，行2 思考等级 chips 与
              // 「步数+保存」同行——右列不再上下孤立（用户红框反馈）。
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(Icons.auto_awesome, size: 13, color: p.accent),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(store.model!.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text('思考等级', style: TextStyle(fontSize: 10, color: p.ink3)),
                      const SizedBox(width: 6),
                      for (final level in _levels(store.model!))
                        Padding(
                          padding: const EdgeInsets.only(right: 3),
                          child: InkWell(
                            onTap: () async {
                              store.settings.thinkingLevel = level;
                              await store.saveSettings();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                              decoration: BoxDecoration(
                                color: store.settings.thinkingLevel == level ? p.accent : p.panel3,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(level,
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: store.settings.thinkingLevel == level ? Colors.white : p.ink3)),
                            ),
                          ),
                        ),
                      const Spacer(),
                      Text('${formatTokens(store.model!.context)} 上下文',
                          style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                      const SizedBox(width: 10),
                      Text('步数', style: TextStyle(fontSize: 10, color: p.ink3)),
                      const SizedBox(width: 4),
                      // 与保存按钮/chips 同高 24：TextFormField 默认非 dense
                      // 的最小高度 + 聚焦 2px 粗描边会高出一截（用户截图实证）
                      // ——实体容器自绘聚焦态，三件套视觉统一。
                      Container(
                        width: 54,
                        height: 24,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _stepsFocus.hasFocus ? p.bgElevated : p.panel3,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              width: _stepsFocus.hasFocus ? 1.2 : 1,
                              color: _stepsFocus.hasFocus
                                  ? p.accent.withValues(alpha: 0.55)
                                  : p.line),
                        ),
                        child: TextField(
                          controller: _stepsController,
                          focusNode: _stepsFocus,
                          textAlign: TextAlign.center,
                          textAlignVertical: TextAlignVertical.center,
                          style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink),
                          decoration: const InputDecoration(
                            isCollapsed: true,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onChanged: (v) async {
                            final n = int.tryParse(v);
                            if (n == null) return;
                            store.settings.maxSteps = n.clamp(4, 600);
                            await store.saveSettings();
                          },
                          onSubmitted: (_) => _saveSteps(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // 显式保存（用户点名「不然感觉没生效」）：点击提交
                      // 输入框当前值，✓ 反馈 1.4s。
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: _saveSteps,
                        child: Container(
                          height: 24,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: _stepsSavedFlash
                                ? p.success.withValues(alpha: 0.16)
                                : p.panel3,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: _stepsSavedFlash
                                    ? p.success.withValues(alpha: 0.5)
                                    : p.line),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(_stepsSavedFlash ? Icons.check : Icons.save_outlined,
                                size: 11,
                                color: _stepsSavedFlash ? p.success : p.ink3),
                            const SizedBox(width: 3),
                            Text(_stepsSavedFlash ? '已保存' : '保存',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: _stepsSavedFlash ? p.success : p.ink2)),
                          ]),
                        ),
                      ),
                    ],
                  ),
                  if (store.model!.protocol != 'openai')
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('该服务商为非 OpenAI 兼容协议，当前不可用；请选择 OpenAI 兼容端点。',
                          style: TextStyle(fontSize: 10, color: p.warn)),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 服务商下拉（桌面/平板）：切服务商同时刷新模型与内置端点。
  Widget _providerDropdown(BuildContext context, AppStore store) {
    return nonSelect<String>(
      context,
      value: store.settings.providerId,
      items: [
        for (final id in store.registry.providerIds)
          DropdownMenuItem(
            value: id,
            child: Text(store.registry.provider(id)?['name']?.toString() ?? id,
                style: const TextStyle(fontSize: 12)),
          ),
      ],
      onChanged: (id) async {
        if (id == null || id == store.settings.providerId) return;
        final models = (store.registry.provider(id)?['models'] as Map?) ?? const {};
        // 显式 String 归一：keys 是 List<dynamic>，firstWhere 的 orElse 闭包
        // 推断成 () => dynamic 会以子类型错误崩溃（2026-11-13 实证）。
        var first = '';
        for (final k in models.keys) {
          if ((models[k] as Map?)?['tool_call'] == true) {
            first = k.toString();
            break;
          }
        }
        if (first.isEmpty && models.isNotEmpty) first = models.keys.first.toString();
        store.settings
          ..providerId = id
          ..modelId = first
          ..baseUrl = _endpointForProvider(store, id)
          ..thinkingLevel = 'auto';
        _baseController.text = store.settings.baseUrl;
        _query = '';
        await store.saveSettings();
        if (mounted) setState(() {});
      },
    );
  }

  /// 模型行：点按打开底部选择面板；面板里搜索、更新清单、勾选。
  Widget _modelRow(BuildContext context, AppStore store,
      {required String keyName, bool mobile = false}) {
    final p = context.palette;
    final model = store.model;
    final emptyRegistry = store.registry.providerIds.isEmpty;
    final name = emptyRegistry
        ? '模型清单未加载'
        : model?.name ?? (store.settings.modelId.isEmpty ? '还没有选择模型' : store.settings.modelId);
    final meta = emptyRegistry
        ? '点按打开模型清单'
        : model == null
            ? '从模型清单里选择一个'
            : '${formatTokens(model.context)} 上下文${model.toolCall ? ' · 可执行操作' : ''}';
    return InkWell(
      key: ValueKey(keyName),
      borderRadius: BorderRadius.circular(10),
      onTap: () => _showModelPicker(context, store),
      child: Container(
        constraints: BoxConstraints(minHeight: mobile ? 52 : 40),
        padding: EdgeInsets.symmetric(horizontal: mobile ? 14 : 10, vertical: 8),
        decoration: BoxDecoration(
          color: p.panel3.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(mobile ? 12 : 8),
          border: Border.all(color: p.line),
        ),
        child: Row(
          children: [
            Icon(Icons.auto_awesome, size: mobile ? 18 : 14, color: p.accent),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: mobile ? 15 : 12, color: p.ink)),
                  const SizedBox(height: 1),
                  Text(meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: mobile ? 12 : 10, color: p.ink4)),
                ],
              ),
            ),
            Text('选择',
                style: TextStyle(fontSize: mobile ? 13 : 10, color: p.accent)),
            Icon(Icons.chevron_right, size: mobile ? 20 : 14, color: p.ink4),
          ],
        ),
      ),
    );
  }

  /// 模型选择底部面板：0.7 屏高、拖拽把手、安全区、搜索 + 更新 + 勾选。
  Future<void> _showModelPicker(BuildContext context, AppStore store) async {
    final p = context.palette;
    _query = '';
    final providerName =
        (store.registry.provider(store.settings.providerId)?['name'] ?? store.settings.providerId)
            .toString();
    final picked = await showModalBottomSheet<ModelInfo>(
      context: context,
      backgroundColor: p.panel,
      isScrollControlled: true,
      builder: (ctx) => FractionallySizedBox(
        key: const ValueKey('model-picker-sheet'),
        heightFactor: 0.7,
        child: SafeArea(
          top: false,
          child: StatefulBuilder(
            builder: (ctx, setSheet) {
              final models = store.registry.flatten().where((m) {
                if (m.providerId != store.settings.providerId) return false;
                if (_query.isEmpty) return true;
                final q = _query.toLowerCase();
                return m.id.toLowerCase().contains(q) || m.name.toLowerCase().contains(q);
              }).take(200).toList();
              return Column(
                children: [
                  // 拖拽把手（触屏/桌面的底部面板同一语义）。
                  Center(
                    child: Container(
                      key: const ValueKey('model-picker-handle'),
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(top: 10, bottom: 10),
                      decoration: BoxDecoration(
                        color: p.ink4.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('选择模型',
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.ink)),
                        ),
                        Text(providerName, style: TextStyle(fontSize: 12, color: p.ink4)),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('model-picker-search'),
                            onChanged: (v) => setSheet(() => _query = v),
                            style: TextStyle(fontSize: 13, color: p.ink),
                            decoration: InputDecoration(
                              hintText: '搜索模型…',
                              isDense: true,
                              prefixIcon: const Icon(Icons.search, size: 16),
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(color: p.line),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          key: const ValueKey('model-picker-refresh'),
                          onPressed: () async {
                            await store.refreshModels();
                            if (ctx.mounted) setSheet(() {});
                          },
                          icon: const Icon(Icons.refresh, size: 14),
                          label: const Text('更新清单', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: models.isEmpty
                        ? Center(
                            child: Text(
                              store.registry.providerIds.isEmpty ? '模型清单还没有加载，点上方更新重试' : '没有找到匹配的模型',
                              style: TextStyle(fontSize: 13, color: p.ink4),
                            ),
                          )
                        : ListView.builder(
                            key: const ValueKey('model-picker-list'),
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                            itemCount: models.length,
                            itemBuilder: (ctx, i) {
                              final m = models[i];
                              final active = store.settings.modelId == m.id;
                              return InkWell(
                                key: ValueKey('model-picker-${m.id}'),
                                borderRadius: BorderRadius.circular(10),
                                onTap: () => Navigator.pop(ctx, m),
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  margin: const EdgeInsets.only(bottom: 4),
                                  decoration: BoxDecoration(
                                    color: active ? p.accentSoft : Colors.transparent,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                          active
                                              ? Icons.check_circle
                                              : Icons.radio_button_off,
                                          size: 18,
                                          color: active ? p.accent : p.ink4),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(children: [
                                              Flexible(
                                                child: Text(m.name,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                        fontSize: 14,
                                                        fontWeight: FontWeight.w500,
                                                        color: p.ink)),
                                              ),
                                              if (m.toolCall) ...[
                                                const SizedBox(width: 6),
                                                Pill(label: '可操作', color: p.success),
                                              ],
                                              if (m.reasoning) ...[
                                                const SizedBox(width: 4),
                                                Pill(label: '会思考', color: p.accent),
                                              ],
                                            ]),
                                            const SizedBox(height: 2),
                                            Text('${m.id} · ${formatTokens(m.context)} 上下文',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    fontFamily: 'Menlo',
                                                    color: p.ink4)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  // 自定义模型 ID：清单外的模型也能用（服务商自定义模型/新上线
                  // 未收录），输入 ID 直接生效——与自定义端点同一开放度。
                  Padding(
                    key: const ValueKey('model-picker-custom'),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _customModelController,
                            style: TextStyle(fontSize: 13, color: p.ink),
                            decoration: InputDecoration(
                              hintText: '自定义模型 ID…',
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 12),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(color: p.line),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () =>
                              _useCustomModel(ctx, store, setSheet),
                          child: const Text('使用', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    if (picked == null) return;
    store.settings.modelId = picked.id;
    if (store.settings.baseUrl.trim().isEmpty) store.settings.baseUrl = picked.baseUrl;
    _baseController.text = store.settings.baseUrl;
    await store.saveSettings();
    if (mounted) setState(() {});
  }

  /// 面板内「自定义模型 ID」：输入即生效（清单外模型），落盘后关面板。
  Future<void> _useCustomModel(
      BuildContext sheetCtx, AppStore store, StateSetter setSheet) async {
    final id = _customModelController.text.trim();
    if (id.isEmpty) return;
    store.settings.modelId = id;
    await store.saveSettings();
    if (sheetCtx.mounted) Navigator.pop(sheetCtx);
    if (mounted) setState(() {});
  }

  List<String> _levels(ModelInfo model) {
    final out = <String>{'auto'};
    for (final opt in model.reasoningOptions) {
      if (opt is Map) {
        if (opt['type'] == 'effort' && opt['values'] is List) {
          for (final v in opt['values'] as List) {
            out.add(v.toString());
          }
        } else if (opt['type'] == 'toggle') {
          out.addAll(['off', 'on']);
        }
      }
    }
    if (out.length == 1) out.add('medium');
    return out.toList();
  }

  Widget _appearance(BuildContext context, AppStore store) {
    final p = context.palette;
    // 「主面」只在聊天优先壳（手机四向、iPad 竖屏）生效；桌面/iPad 横屏是
    // 工作区优先壳，主面由壳层裁决（Welcome / Workspace），不展示无效开关。
    final size = MediaQuery.sizeOf(context);
    final hostOs = switch (Theme.of(context).platform) {
      TargetPlatform.macOS => HostOs.macos,
      TargetPlatform.windows => HostOs.windows,
      TargetPlatform.linux => HostOs.linux,
      TargetPlatform.iOS => HostOs.ios,
      TargetPlatform.android => HostOs.android,
      TargetPlatform.fuchsia => HostOs.fuchsia,
    };
    final chatFirst = LayoutSpec.classify(
      width: size.width,
      height: size.height,
      os: hostOs,
    ).usesChatFirstShell;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('主题'),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final item in [('dark', '深色', Icons.dark_mode_outlined), ('light', '浅色', Icons.light_mode_outlined)])
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () async {
                      store.settings.theme = item.$1;
                      await store.saveSettings();
                    },
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: store.settings.theme == item.$1 ? p.accentSoft : p.panel2.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: store.settings.theme == item.$1 ? p.accent : p.line),
                      ),
                      child: Row(
                        children: [
                          Icon(item.$3, size: 16, color: store.settings.theme == item.$1 ? p.accent : p.ink3),
                          const SizedBox(width: 8),
                          Text(item.$2, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: p.ink)),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (chatFirst) ...[
            const SizedBox(height: 18),
            const SectionLabel('主面'),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final item in [(true, '聊天流', Icons.forum_outlined), (false, '经典 Welcome', Icons.home_outlined)])
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () async {
                        if (store.settings.chatStreamHome == item.$1) return;
                        store.settings.chatStreamHome = item.$1;
                        await store.saveSettings();
                      },
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: store.settings.chatStreamHome == item.$1 ? p.accentSoft : p.panel2.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: store.settings.chatStreamHome == item.$1 ? p.accent : p.line),
                        ),
                        child: Row(
                          children: [
                            Icon(item.$3, size: 16, color: store.settings.chatStreamHome == item.$1 ? p.accent : p.ink3),
                            const SizedBox(width: 8),
                            Text(item.$2, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: p.ink)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              store.settings.chatStreamHome
                  ? '聊天流是默认主面；点顶栏「工作区」打开设计视图，按 Esc 回到聊天流。'
                  : '启动停留在经典 Welcome；点顶栏「聊天流」进入聊天流。',
              style: TextStyle(fontSize: 10, height: 1.4, color: p.ink4),
            ),
          ],
          const SizedBox(height: 18),
          const SectionLabel('快捷键'),
          const SizedBox(height: 8),
          for (final row in [
            ('命令面板', modCombo('⌘K')),
            ('保存', modCombo('⌘S')),
            ('撤销 / 重做', modCombo('⌘Z / ⇧⌘Z')),
            ('画布 / 文档', modCombo('⌘1 / ⌘2')),
            ('源码 / 演示', modCombo('⌘3 / ⌘4')),
            ('适配窗口', modCombo('⌘0')),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(child: Text(row.$1, style: TextStyle(fontSize: 12, color: p.ink3))),
                  Text(row.$2, style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                ],
              ),
            ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: p.panel2.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(10)),
            child: Text('界面语言：简体中文 · 后续接入英文与更多语言。',
                style: TextStyle(fontSize: 11, color: p.ink3)),
          ),
        ],
      ),
    );
  }

  static bool _isDesktopPlatform(TargetPlatform platform) =>
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.windows ||
      platform == TargetPlatform.linux;

  /// 合并的「运行方式」卡：内置（默认）/ 连接桌面二选一。
  ///
  /// 只有选「连接桌面」才展开地址与连接码；「检测连接」内联呈现
  /// 检测中 / 已连接 / 失败原因，失败不静默回落——用户能看见结果。
  Widget _runtimeCard(BuildContext context, AppStore store, {bool mobile = false}) {
    final p = context.palette;
    final remote = store.settings.agentRuntime == agentRuntimeServer;
    final canHost = _isDesktopPlatform(Theme.of(context).platform);

    Widget field({required String keyName, required String label, required TextEditingController controller,
        String? hint, bool obscure = false}) {
      final decoration = mobile
          ? _mDecoration(context, hint: hint)
          : InputDecoration(
              hintText: hint,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: p.line)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: p.line)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: p.accent)),
            );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: mobile ? 12 : 10, color: p.ink3)),
          const SizedBox(height: 4),
          TextField(
            key: ValueKey(keyName),
            controller: controller,
            obscureText: obscure,
            style: TextStyle(fontSize: mobile ? 14 : 11, fontFamily: 'Menlo', color: p.ink),
            decoration: decoration,
          ),
        ],
      );
    }

    final children = <Widget>[
      Text('选择助手在哪里执行：内置在本机完成；也可以连接另一台电脑上开启的连接，本机只负责显示与编辑。',
          style: TextStyle(fontSize: mobile ? 12 : 10, height: 1.5, color: p.ink4)),
      const SizedBox(height: 10),
      _runtimeOption(
        context,
        keyName: mobile ? 'settings-m-runtime-local' : 'settings-runtime-local',
        selected: !remote,
        icon: Icons.memory,
        title: '内置',
        note: '默认。在本机执行，画布改动仍经设计校验。',
        trailing: Text(store.engineReady ? '本机引擎就绪' : '本机运行',
            style: TextStyle(fontSize: 10, color: p.success)),
        onTap: () async {
          if (!remote) return;
          store.settings.agentRuntime = agentRuntimeLocal;
          await store.saveSettings();
          if (mounted) setState(() {});
        },
      ),
      const SizedBox(height: 6),
      _runtimeOption(
        context,
        keyName: mobile ? 'settings-m-runtime-remote' : 'settings-runtime-remote',
        selected: remote,
        icon: Icons.desktop_mac_outlined,
        title: '连接桌面',
        note: '在另一台电脑上执行；先在那边开启「手机连接」，再把地址与连接码填到这里。',
        trailing: Pill(
          label: _remoteConnected ? '已连接' : '可选',
          color: _remoteConnected ? p.success : p.ink4,
        ),
        onTap: () async {
          if (remote) return;
          store.settings.agentRuntime = agentRuntimeServer;
          await store.saveSettings();
          if (mounted) setState(() {});
        },
      ),
      if (remote) ...[
        const SizedBox(height: 12),
        if (mobile) ...[
          field(
            keyName: 'settings-m-remote-url',
            label: '桌面地址',
            hint: '粘贴桌面端显示的地址',
            controller: _remoteUrlController,
          ),
          const SizedBox(height: 10),
          field(
            keyName: 'settings-m-remote-token',
            label: '连接码（桌面端显示的一次性码）',
            controller: _remoteTokenController,
            obscure: true,
          ),
        ] else
          Row(
            children: [
              Expanded(
                child: field(
                  keyName: 'settings-remote-url',
                  label: '桌面地址',
                  hint: '粘贴桌面端显示的地址',
                  controller: _remoteUrlController,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: field(
                  keyName: 'settings-remote-token',
                  label: '连接码（必填）',
                  controller: _remoteTokenController,
                  obscure: true,
                ),
              ),
            ],
          ),
        const SizedBox(height: 6),
        Text('连接码是桌面端显示的一次性码，必须填写；地址与连接码只保存在本机。',
            style: TextStyle(fontSize: mobile ? 11 : 9, height: 1.4, color: p.ink4)),
        const SizedBox(height: 10),
        Row(
          children: [
            SizedBox(
              height: mobile ? 44 : 30,
              child: OutlinedButton.icon(
                key: ValueKey(mobile ? 'settings-m-remote-test' : 'settings-remote-test'),
                onPressed: _remoteTesting ? null : () => _probeRemote(store),
                icon: const Icon(Icons.cable, size: 14),
                label: Text('检测连接', style: TextStyle(fontSize: mobile ? 13 : 11)),
              ),
            ),
            const SizedBox(width: 10),
            if (_remoteTesting) ...[
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 1.8),
              ),
              const SizedBox(width: 6),
              Text('正在检测…', style: TextStyle(fontSize: mobile ? 12 : 10, color: p.ink3)),
            ] else if (_remoteMessage != null) ...[
              Icon(_remoteConnected ? Icons.check_circle : Icons.error_outline,
                  size: 14, color: _remoteConnected ? p.success : p.warn),
              const SizedBox(width: 5),
              Expanded(
                child: Text(_remoteMessage!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: mobile ? 12 : 10,
                        color: _remoteConnected ? p.success : p.warn)),
              ),
            ],
          ],
        ),
        if (store.settings.serverUrl.isNotEmpty ||
            store.remote != null ||
            _remoteConnected) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey(mobile ? 'settings-m-remote-disconnect' : 'settings-remote-disconnect'),
              onPressed: _remoteTesting
                  ? null
                  : () async {
                      await store.disconnectRemoteDesktop();
                      _remoteUrlController.clear();
                      _remoteTokenController.clear();
                      if (!mounted) return;
                      setState(() {
                        _remoteConnected = false;
                        _remoteMessage = '已断开桌面连接，接下来使用本机运行';
                      });
                      store.toasts.info('已断开桌面连接');
                    },
              icon: const Icon(Icons.link_off, size: 14),
              label: Text('断开桌面', style: TextStyle(fontSize: mobile ? 13 : 11)),
            ),
          ),
        ],
      ],
      // 桌面端同时可以充当「连接桌面」宿主：手机/iPad 连到这台电脑。
      if (canHost) ...[
        const SizedBox(height: 12),
        _desktopHostCard(context, store, mobile: mobile),
      ],
    ];

    if (mobile) {
      return _mCard(context,
          title: '运行方式',
          helper: '地址与连接码都只保存在本机；检测失败会如实显示原因。',
          children: children);
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.panel2.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  /// 桌面端宿主卡：手机/iPad 连接这台电脑的唯一入口。
  ///
  /// 打开后显示本机实际监听的地址与一次性连接码；关闭即停止监听。没有
  /// 这一步，应用里就从未启动过宿主，设置卡上的「桌面端显示的地址」也就
  /// 永远不存在。
  Widget _desktopHostCard(BuildContext context, AppStore store, {required bool mobile}) {
    final p = context.palette;
    final status = store.desktopHostStatus;
    final running = status?.running ?? false;
    final busy = store.desktopHostBusy;
    final switchOn = running || (busy && store.settings.desktopHostEnabled);

    Widget valueBlock(String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: mobile ? 11 : 9, color: p.ink4)),
              const SizedBox(height: 2),
              SelectableText(
                value,
                style: TextStyle(
                  fontSize: mobile ? 13 : 11,
                  fontFamily: 'Menlo',
                  height: 1.4,
                  color: color ?? p.ink,
                ),
              ),
            ],
          ),
        );

    return Container(
      key: ValueKey(mobile ? 'settings-m-desktop-host' : 'settings-desktop-host'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.panel3.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: running ? p.success.withValues(alpha: 0.55) : p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.phone_iphone, size: 16, color: running ? p.success : p.ink3),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('局域网远程',
                        style: TextStyle(fontSize: mobile ? 14 : 12, fontWeight: FontWeight.w600, color: p.ink)),
                    const SizedBox(height: 2),
                    Text('开启后，同一局域网内的手机 / iPad 直连本机执行任务；本机不对公网开放。',
                        style: TextStyle(fontSize: mobile ? 11 : 9, height: 1.4, color: p.ink4)),
                  ],
                ),
              ),
              Switch.adaptive(
                key: ValueKey(mobile ? 'settings-m-desktop-host-switch' : 'settings-desktop-host-switch'),
                value: switchOn,
                onChanged: busy
                    ? null
                    : (value) async {
                        // 局域网远程语义（用户裁决 2026-11-19）：开启即对
                        // 局域网开放，不再要求单独开「允许局域网访问」。
                        if (value) await store.setDesktopHostAllowLan(true);
                        await store.setDesktopHostEnabled(value);
                        if (mounted) setState(() {});
                      },
              ),
            ],
          ),
          if (busy)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.8),
                  ),
                  const SizedBox(width: 6),
                  Text('正在启动…', style: TextStyle(fontSize: mobile ? 12 : 10, color: p.ink3)),
                ],
              ),
            )
          else if (store.desktopHostError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('连接没有启动成功，请稍后再试。',
                  style: TextStyle(fontSize: mobile ? 11 : 9, color: p.warn)),
            )
          else if (running && status != null) ...[
            const SizedBox(height: 10),
            valueBlock(
              status.lanEnabled && status.lanUrls.isNotEmpty
                  ? '桌面地址'
                  : '本机地址（手机需开启局域网访问）',
              status.lanEnabled && status.lanUrls.isNotEmpty
                  ? status.lanUrls.first
                  : status.baseUrl,
            ),
            valueBlock('连接码', status.token),
            if (status.lanEnabled && status.lanUrls.length > 1) ...[
              valueBlock('其他局域网地址', status.lanUrls.skip(1).join('\n')),
            ],
            if (status.lanEnabled) ...[
              Text(status.warning,
                  style: TextStyle(fontSize: mobile ? 11 : 9, height: 1.4, color: p.warn)),
              const SizedBox(height: 6),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  key: ValueKey(mobile ? 'settings-m-desktop-host-copy' : 'settings-desktop-host-copy'),
                  onPressed: () {
                    final url = status.lanEnabled && status.lanUrls.isNotEmpty
                        ? status.lanUrls.first
                        : status.baseUrl;
                    Clipboard.setData(ClipboardData(text: '$url\n${status.token}'));
                    store.toasts.info('已复制地址与连接码');
                  },
                  icon: const Icon(Icons.copy_all_outlined, size: 14),
                  label: Text('复制地址与连接码', style: TextStyle(fontSize: mobile ? 12 : 10)),
                ),
                TextButton.icon(
                  key: ValueKey(mobile ? 'settings-m-desktop-host-rotate' : 'settings-desktop-host-rotate'),
                  onPressed: () {
                    store.regenerateDesktopHostToken();
                    setState(() {});
                  },
                  icon: const Icon(Icons.autorenew, size: 14),
                  label: Text('换一个连接码', style: TextStyle(fontSize: mobile ? 12 : 10)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text('允许局域网访问（同一 Wi-Fi 下的手机可连接）',
                      style: TextStyle(fontSize: mobile ? 11 : 9, height: 1.4, color: p.ink3)),
                ),
                Switch.adaptive(
                  key: ValueKey(mobile ? 'settings-m-desktop-host-lan' : 'settings-desktop-host-lan'),
                  value: status.lanEnabled,
                  onChanged: busy
                      ? null
                      : (value) async {
                          await store.setDesktopHostAllowLan(value);
                          if (mounted) setState(() {});
                        },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _runtimeOption(
    BuildContext context, {
    required String keyName,
    required bool selected,
    required IconData icon,
    required String title,
    required String note,
    required Widget trailing,
    required VoidCallback onTap,
  }) {
    final p = context.palette;
    return InkWell(
      key: ValueKey(keyName),
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? p.accentSoft : p.panel3.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? p.accent : p.line),
        ),
        child: Row(
          children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 18, color: selected ? p.accent : p.ink4),
            const SizedBox(width: 9),
            Icon(icon, size: 16, color: selected ? p.accent : p.ink3),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: p.ink)),
                  const SizedBox(height: 1),
                  Text(note, style: TextStyle(fontSize: 11, height: 1.4, color: p.ink3)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }

  Future<void> _probeRemote(AppStore store) async {
    final url = _remoteUrlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _remoteConnected = false;
        _remoteMessage = '先填写桌面地址';
      });
      return;
    }
    // 宿主对每条 /v1 请求都要求连接码；空输入只允许复用上次保存的码，
    // 两者都没有就明确提示，不能发出必然 401 的探测。
    final typedToken = _remoteTokenController.text.trim();
    final token = typedToken.isEmpty ? store.serverToken : typedToken;
    if (token.isEmpty) {
      setState(() {
        _remoteConnected = false;
        _remoteMessage = '先填写连接码（桌面端显示的连接码）';
      });
      return;
    }
    setState(() {
      _remoteTesting = true;
      _remoteConnected = false;
      _remoteMessage = null;
    });
    RemoteDesktopStatus status;
    try {
      status = await store.testRemoteConnection(url, token: token);
    } catch (e) {
      debugPrint('[settings] connect probe failed: $e');
      status = const RemoteDesktopStatus.notConfigured();
    }
    if (!mounted) return;
    var connected = status.connected;
    if (connected) {
      try {
        // 检测通过即接线：路由切到桌面端；失败按下一次探测的真实结果呈现。
        status = await store.applyRemoteDesktop(url, token: token);
        connected = status.connected;
      } catch (e) {
        debugPrint('[settings] connect apply failed: $e');
        connected = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _remoteTesting = false;
      _remoteConnected = connected;
      _remoteMessage = connected ? '已连接' : status.message;
    });
    if (connected) {
      store.toasts.success('已连接桌面');
    }
  }

  Widget _agent(BuildContext context, AppStore store) {
    final p = context.palette;
    final cacheRate = (store.usage['inputTokens'] as num? ?? 0) > 0
        ? ((store.usage['cachedTokens'] as num? ?? 0) / (store.usage['inputTokens'] as num)) * 100
        : 0;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionLabel('运行方式'),
          const SizedBox(height: 8),
          _runtimeCard(context, store),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: p.panel2.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.layers, size: 14, color: p.accent),
                    const SizedBox(width: 5),
                    Text('上下文与缓存', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink)),
                    const SizedBox(width: 6),
                    Pill(label: '自动管理', color: p.accent),
                  ],
                ),
                const SizedBox(height: 6),
                Text('项目说明与工具说明会优先复用；新的改动只追加到最新结果，不重写历史。',
                    style: TextStyle(fontSize: 11, height: 1.5, color: p.ink3)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _metric(context, '上下文窗口', formatTokens(store.model?.context)),
                    const SizedBox(width: 6),
                    _metric(context, '本轮输入', formatTokens(store.usage['inputTokens'] as num?)),
                    const SizedBox(width: 6),
                    _metric(context, '缓存命中', cacheRate > 0 ? '${cacheRate.round()}%' : '—'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _labeled(context, '最大步数', TextFormField(
                initialValue: store.settings.maxSteps.toString(),
                style: TextStyle(fontSize: 11, fontFamily: 'Menlo', color: p.ink),
                onChanged: (v) async {
                  final n = int.tryParse(v);
                  if (n == null) return;
                  store.settings.maxSteps = n.clamp(4, 600);
                  await store.saveSettings();
                },
                onFieldSubmitted: (v) async {
                  store.settings.maxSteps = (int.tryParse(v) ?? 300).clamp(4, 600);
                  await store.saveSettings();
                },
              ))),
              const SizedBox(width: 10),
              Expanded(child: _labeled(context, '项目位置', TextFormField(
                initialValue: store.projectPath ?? store.projectName,
                readOnly: true,
                style: TextStyle(fontSize: 11, fontFamily: 'Menlo', color: p.ink3),
              ))),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text('删除本项目的对话记忆；画布与文档不受影响。',
                    style: TextStyle(fontSize: 11, color: p.ink3)),
              ),
              OutlinedButton.icon(
                onPressed: () => store.clearAgentSession(),
                icon: const Icon(Icons.delete_outline, size: 13),
                label: const Text('清空会话'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: p.panel2.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(10)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('上下文管理', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink)),
                const SizedBox(height: 6),
                for (final line in [
                  '工具结果去掉整份源码，只保留摘要与最新状态',
                  '旧的读取结果会被占位替换，避免上下文重复堆积',
                  '上下文窗口来自随包发布的模型清单',
                  '会话超过 80 条自动压缩为摘要，不额外调用模型',
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('· $line', style: TextStyle(fontSize: 10, height: 1.45, color: p.ink3)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value) {
    final p = context.palette;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(color: p.bgElevated.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(8)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: TextStyle(fontSize: 13, fontFamily: 'Menlo', fontWeight: FontWeight.w600, color: p.ink)),
            Text(label, style: TextStyle(fontSize: 10, color: p.ink4)),
          ],
        ),
      ),
    );
  }

  Widget _about(BuildContext context, AppStore store) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const NonLogo(size: 40),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('NaN', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink)),
                Text('AI-native product design studio', style: TextStyle(fontSize: 11, color: p.ink3)),
              ],
            ),
            const Spacer(),
            Pill(label: 'v0.1', color: p.accent),
          ],
        ),
        const SizedBox(height: 16),
        for (final row in [
          ('应用版本', '0.1 · 本地优先'),
          ('设计引擎', store.api == null ? '未就绪' : '就绪'),
          ('项目文件', '加密单文件 · 保存在本机'),
          ('模型清单', '内置快照 · 可手动更新'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              children: [
                SizedBox(width: 72, child: Text(row.$1, style: TextStyle(fontSize: 11, color: p.ink4))),
                Expanded(child: Text(row.$2, style: TextStyle(fontSize: 11, fontFamily: 'Menlo', color: p.ink2))),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Text('每个项目是一份加密项目文件；你与内置智能体的每次修改都经设计校验后写回同一份文档。',
            style: TextStyle(fontSize: 11, height: 1.55, color: p.ink3)),
        const Spacer(),
        Text('模型清单来自内置快照；上下文与缓存策略在本机确定性执行。',
            style: TextStyle(fontSize: 10, color: p.ink4)),
      ],
    );
  }

  Widget _acp(BuildContext context, AppStore store) {
    final p = context.palette;
    return ListView(
      children: [
        Text('外部智能体', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink)),
        const SizedBox(height: 4),
        Text('自动检测本机已安装、支持通用协作协议的外部智能体（Claude Code / Codex / Kimi / Gemini / Qwen 等）。'
            '选中后右侧输入框的消息将发给该智能体，流式回显进时间线；内置智能体保持可用。',
            style: TextStyle(fontSize: 11, height: 1.5, color: p.ink3)),
        const SizedBox(height: 12),
        if (_acpError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: p.warn.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: p.warn.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Expanded(child: Text(_acpError!, style: TextStyle(fontSize: 11, color: p.warn))),
                  TextButton(
                    onPressed: _loadAcpAgents,
                    child: const Text('重试', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),
          ),
        _acpOption(context, store, null, '内置智能体', '一句话 → 文档 → 原型（默认）', true, false, ''),
        for (final a in _acpAgents)
          _acpOption(
            context,
            store,
            a.id,
            a.name,
            a.probeState == 'probing' ? '协议探测中…' : a.note,
            a.selectable,
            a.grayed,
            a.probeState == 'probing'
                ? '探测中'
                : a.probeState == 'verified'
                    ? '已验证'
                    : a.installed
                        ? '已安装'
                        : '未安装',
          ),
        const SizedBox(height: 10),
        Text('检测基于本机已安装的智能体；部分适配器需要先全局安装。'
            '权限请求自动放行并记录在时间线；文件读写限制在工作区目录内。',
            style: TextStyle(fontSize: 10, height: 1.5, color: p.ink4)),
      ],
    );
  }

  Widget _acpOption(BuildContext context, AppStore store, String? id, String name, String note, bool selectable, bool grayed, String detail) {
    final p = context.palette;
    final selected = store.settings.acpAgentId == id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: !selectable
            ? null
            : () async {
                store.settings
                  ..acpAgentId = id
                  ..acpAgentName = id == null ? null : name;
                await store.saveSettings();
                if (mounted) setState(() {});
              },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? p.accentSoft : p.panel2.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? p.accent.withValues(alpha: 0.5) : p.line),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 14,
                color: selectable ? (selected ? p.accent : p.ink4) : p.ink4.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: selectable ? p.ink : p.ink4)),
                      ),
                      if (grayed) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(color: p.panel3, borderRadius: BorderRadius.circular(4)),
                          child: Text('即将接入',
                              style: TextStyle(fontSize: 10, color: p.ink4)),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(note, style: TextStyle(fontSize: 10, color: selectable ? p.ink3 : p.ink4)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(detail,
                  style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 手机端独立布局（2026-11-17 重做） ----------------
  //
  // 入口：phoneLayout（手机竖屏 + 手机横屏矮窗）。结构为 iOS 式
  // 「分组根页 → 下钻详情」：根页 4 个分组行（≥64 高、大标题 22、
  // 关闭/返回 44×44）；详情页单列卡片（输入 48 高、正文字号 13–15、
  // 页面滚动 + 键盘安全区）。桌面/平板的三档布局（顶部 tab / 侧栏）
  // 完全不变，两条路径共用同一套 settings 字段与保存逻辑。

  Widget _mobileFrame(BuildContext context, AppStore store) {
    final p = context.palette;
    const titles = <String, String>{
      'models': '模型与端点',
      'agent': '智能体',
      'appearance': '外观与交互',
      'about': '关于',
    };
    final section = _mobileSection;
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: p.panel,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: Column(
          children: [
            Container(
              height: 60,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
              child: Row(
                children: [
                  if (section != null)
                    SizedBox(
                      width: 44,
                      height: 44,
                      child: IconButton(
                        key: const ValueKey('settings-mobile-back'),
                        tooltip: '返回',
                        onPressed: () => setState(() => _mobileSection = null),
                        icon: Icon(Icons.arrow_back, size: 22, color: p.ink2),
                      ),
                    )
                  else
                    const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      section == null ? '设置' : (titles[section] ?? '设置'),
                      style: TextStyle(
                        fontSize: section == null ? 22 : 18,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: IconButton(
                      key: const ValueKey('settings-mobile-close'),
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close, size: 22, color: p.ink3),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: section == null
                  ? _mobileRoot(context, store)
                  : _mobileDetail(context, store, section),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileRoot(BuildContext context, AppStore store) {
    final p = context.palette;
    final provider = store.registry.provider(store.settings.providerId);
    final providerName = (provider?['name'] ?? store.settings.providerId).toString();
    final modelName = store.model?.name ?? store.settings.modelId;
    return ListView(
      key: const ValueKey('settings-mobile-root'),
      padding: EdgeInsets.fromLTRB(16, 16, 16, 32 + MediaQuery.viewInsetsOf(context).bottom),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        _mSectionTile(context,
            id: 'models',
            icon: Icons.memory,
            title: '模型与端点',
            subtitle: '$providerName · $modelName',
            onTap: () => setState(() => _mobileSection = 'models')),
        _mSectionTile(context,
            id: 'agent',
            icon: Icons.smart_toy_outlined,
            title: '智能体',
            subtitle:
                '${store.settings.agentRuntime == agentRuntimeServer ? '连接桌面' : '内置智能体'} · 最大步数 ${store.settings.maxSteps}',
            onTap: () => setState(() => _mobileSection = 'agent')),
        _mSectionTile(context,
            id: 'appearance',
            icon: Icons.palette_outlined,
            title: '外观与交互',
            subtitle:
                '${store.settings.theme == 'light' ? '浅色' : '深色'} · ${store.settings.chatStreamHome ? '聊天流' : '经典 Welcome'}',
            onTap: () => setState(() => _mobileSection = 'appearance')),
        _mSectionTile(context,
            id: 'about',
            icon: Icons.info_outline,
            title: '关于',
            subtitle: 'NaN v0.1 · 本地优先',
            onTap: () => setState(() => _mobileSection = 'about')),
        const SizedBox(height: 10),
        Text('设置即时生效并保存在本机；模型清单来自内置快照，可随时更新。',
            style: TextStyle(fontSize: 12, height: 1.5, color: p.ink4)),
      ],
    );
  }

  Widget _mSectionTile(BuildContext context,
      {required String id,
      required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onTap}) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        key: ValueKey('settings-m-$id'),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: p.panel2.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: p.line),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 19, color: p.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: p.ink4)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: p.ink4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mobileDetail(BuildContext context, AppStore store, String section) {
    return switch (section) {
      'appearance' => _mAppearance(context, store),
      'agent' => _mAgent(context, store),
      'about' => _mAbout(context, store),
      _ => _mModels(context, store),
    };
  }

  Widget _mModels(BuildContext context, AppStore store) {
    final p = context.palette;
    final provider = store.registry.provider(store.settings.providerId);
    final providerName = (provider?['name'] ?? store.settings.providerId).toString();
    return ListView(
      key: const ValueKey('settings-m-detail-models'),
      padding: EdgeInsets.fromLTRB(16, 16, 16, 32 + MediaQuery.viewInsetsOf(context).bottom),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        _mCard(context, title: '服务商', children: [
          InkWell(
            key: const ValueKey('settings-m-provider'),
            borderRadius: BorderRadius.circular(10),
            onTap: () => _mPickProvider(context, store),
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: p.panel3.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.line),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(providerName, style: TextStyle(fontSize: 15, color: p.ink)),
                        if (store.registry.providerIds.isEmpty)
                          Text('模型清单未加载，点此重试',
                              style: TextStyle(fontSize: 12, color: p.warn)),
                      ],
                    ),
                  ),
                  Icon(Icons.expand_more, size: 20, color: p.ink4),
                ],
              ),
            ),
          ),
        ]),
        _mCard(context, title: '模型', children: [
          _modelRow(context, store, keyName: 'settings-m-model-row', mobile: true),
        ]),
        _mCard(context, title: '端点',
            helper: _customEndpoint
                ? '自定义端点已生效（兼容网关 / 中转）。'
                : '内置端点来自随包清单；打开自定义端点可接入兼容网关 / 中转。', children: [
          TextField(
            key: const ValueKey('settings-m-endpoint'),
            controller: _baseController,
            readOnly: !_customEndpoint,
            style: TextStyle(
                fontSize: 13,
                fontFamily: 'Menlo',
                color: _customEndpoint ? p.ink : p.ink2),
            decoration: _mDecoration(context,
                hint: _customEndpoint ? 'https://your-gateway.example/v1' : '内置端点',
                suffix: _customEndpoint
                    ? IconButton(
                        tooltip: '恢复内置端点',
                        onPressed: () => _setCustomEndpoint(false, store),
                        icon: Icon(Icons.restart_alt, size: 18, color: p.ink4))
                    : Icon(Icons.lock_outline, size: 18, color: p.ink4)),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text('自定义端点',
                    style: TextStyle(fontSize: 12, color: p.ink2)),
              ),
              Switch.adaptive(
                key: const ValueKey('settings-m-endpoint-custom'),
                value: _customEndpoint,
                activeColor: p.accent,
                onChanged: (v) => _setCustomEndpoint(v, store),
              ),
            ],
          ),
        ]),
        _mCard(context, title: 'API Key（只存本机）', helper: '仅保存在本机设置中，不上传。', children: [
          TextField(
            key: const ValueKey('settings-m-apikey'),
            controller: _keyController,
            obscureText: !_keyVisible,
            style: TextStyle(fontSize: 13, fontFamily: 'Menlo', color: p.ink),
            autocorrect: false,
            enableSuggestions: false,
            decoration: _mDecoration(context,
                hint: 'sk-…',
                suffix: IconButton(
                  tooltip: _keyVisible ? '隐藏' : '显示',
                  onPressed: () => setState(() => _keyVisible = !_keyVisible),
                  icon: Icon(
                      _keyVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                      size: 20,
                      color: p.ink4),
                )),
            onSubmitted: (v) async {
              store.settings.apiKey = v.trim();
              await store.saveSettings();
            },
            onTapOutside: (_) async {
              store.settings.apiKey = _keyController.text.trim();
              await store.saveSettings();
            },
          ),
        ]),
        MediaPipeModelCard(service: widget.mediaPipeService),
        const SizedBox(height: 14),
        if (store.model != null)
          _mCard(context, title: '思考等级',
              helper: '当前模型：${store.model!.name} · ${formatTokens(store.model!.context)} 上下文',
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final level in _levels(store.model!))
                      InkWell(
                        key: ValueKey('settings-m-thinking-$level'),
                        borderRadius: BorderRadius.circular(8),
                        onTap: () async {
                          store.settings.thinkingLevel = level;
                          await store.saveSettings();
                          if (mounted) setState(() {});
                        },
                        child: Container(
                          // 移动端最小触控目标 44（review settings-3：此前 34）。
                          height: 44,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: store.settings.thinkingLevel == level ? p.accent : p.panel3,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(level,
                              style: TextStyle(
                                  fontSize: 13,
                                  color: store.settings.thinkingLevel == level
                                      ? Colors.white
                                      : p.ink3)),
                        ),
                      ),
                  ],
                ),
              ]),
      ],
    );
  }

  Future<void> _mPickProvider(BuildContext context, AppStore store) async {
    final p = context.palette;
    final ids = store.registry.providerIds.toList();
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: p.panel,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.7,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text('选择服务商',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.ink)),
              ),
              if (ids.isEmpty)
                ListTile(
                  minVerticalPadding: 14,
                  title: Text('模型清单未加载', style: TextStyle(fontSize: 15, color: p.ink3)),
                  subtitle: Text('点按重新加载内置模型清单',
                      style: TextStyle(fontSize: 12, color: p.ink4)),
                  onTap: () async {
                    await store.refreshModels();
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) setState(() {});
                  },
                ),
              for (final id in ids)
                ListTile(
                  key: ValueKey('settings-m-provider-$id'),
                  minVerticalPadding: 14,
                  title: Text(store.registry.provider(id)?['name']?.toString() ?? id,
                      style: TextStyle(fontSize: 15, color: p.ink)),
                  subtitle: Text(id,
                      style: TextStyle(fontSize: 11, fontFamily: 'Menlo', color: p.ink4)),
                  trailing: id == store.settings.providerId
                      ? Icon(Icons.check, size: 20, color: p.accent)
                      : null,
                  onTap: () => Navigator.pop(ctx, id),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || picked == store.settings.providerId) return;
    final pv = store.registry.provider(picked);
    final models = (pv?['models'] as Map?) ?? const {};
    var first = '';
    for (final k in models.keys) {
      if ((models[k] as Map?)?['tool_call'] == true) {
        first = k.toString();
        break;
      }
    }
    if (first.isEmpty && models.isNotEmpty) first = models.keys.first.toString();
    store.settings
      ..providerId = picked
      ..modelId = first
      ..baseUrl = _endpointForProvider(store, picked)
      ..thinkingLevel = 'auto';
    _baseController.text = store.settings.baseUrl;
    _query = '';
    await store.saveSettings();
    if (mounted) setState(() {});
  }

  Widget _mAppearance(BuildContext context, AppStore store) {
    final p = context.palette;
    return ListView(
      key: const ValueKey('settings-m-detail-appearance'),
      padding: EdgeInsets.fromLTRB(16, 16, 16, 32 + MediaQuery.viewInsetsOf(context).bottom),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        _mCard(context, title: '主题', children: [
          _mRadioRow(context,
              label: '深色',
              selected: store.settings.theme != 'light',
              onTap: () async {
                store.settings.theme = 'dark';
                await store.saveSettings();
                if (mounted) setState(() {});
              }),
          _mRadioRow(context,
              label: '浅色',
              selected: store.settings.theme == 'light',
              onTap: () async {
                store.settings.theme = 'light';
                await store.saveSettings();
                if (mounted) setState(() {});
              }),
        ]),
        _mCard(context, title: '启动主面', children: [
          _mRadioRow(context,
              label: '聊天流',
              note: '默认；顶栏「工作区」进设计视图',
              selected: store.settings.chatStreamHome,
              onTap: () async {
                store.settings.chatStreamHome = true;
                await store.saveSettings();
                if (mounted) setState(() {});
              }),
          _mRadioRow(context,
              label: '经典 Welcome',
              note: '启动停留在主页卡片',
              selected: !store.settings.chatStreamHome,
              onTap: () async {
                store.settings.chatStreamHome = false;
                await store.saveSettings();
                if (mounted) setState(() {});
              }),
        ]),
        _mCard(context, title: '界面语言',
            helper: '当前：简体中文。移动端输入由系统键盘接管，多语言界面后续接入。', children: [
          Row(children: [
            Icon(Icons.translate, size: 18, color: p.ink3),
            const SizedBox(width: 8),
            Text('简体中文', style: TextStyle(fontSize: 15, color: p.ink)),
          ]),
        ]),
      ],
    );
  }

  Widget _mAgent(BuildContext context, AppStore store) {
    final p = context.palette;
    final cacheRate = (store.usage['inputTokens'] as num? ?? 0) > 0
        ? ((store.usage['cachedTokens'] as num? ?? 0) / (store.usage['inputTokens'] as num)) * 100
        : 0;
    return ListView(
      key: const ValueKey('settings-m-detail-agent'),
      padding: EdgeInsets.fromLTRB(16, 16, 16, 32 + MediaQuery.viewInsetsOf(context).bottom),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        _runtimeCard(context, store, mobile: true),
        Row(children: [
          _mStat(context, '上下文窗口', formatTokens(store.model?.context)),
          _mStat(context, '本轮输入', formatTokens(store.usage['inputTokens'] as num?)),
          _mStat(context, '缓存命中', cacheRate > 0 ? '${cacheRate.round()}%' : '—', last: true),
        ]),
        const SizedBox(height: 14),
        _mCard(context, title: '步数与会话', children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('settings-m-steps'),
                  controller: _stepsController,
                  keyboardType: TextInputType.number,
                  style: TextStyle(fontSize: 15, fontFamily: 'Menlo', color: p.ink),
                  decoration: _mDecoration(context, hint: '300'),
                  onChanged: (v) async {
                    final n = int.tryParse(v);
                    if (n == null) return;
                    store.settings.maxSteps = n.clamp(4, 600);
                    await store.saveSettings();
                  },
                  onSubmitted: (_) => _saveSteps(),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _saveSteps,
                  icon: Icon(_stepsSavedFlash ? Icons.check : Icons.save_outlined,
                      size: 16, color: _stepsSavedFlash ? p.success : p.ink3),
                  label: Text(_stepsSavedFlash ? '已保存' : '保存',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _stepsSavedFlash ? p.success : p.ink2)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(children: [
            Text('项目位置', style: TextStyle(fontSize: 13, color: p.ink3)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(store.projectPath ?? store.projectName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontFamily: 'Menlo', color: p.ink4)),
            ),
          ]),
        ]),
        _mCard(context, title: '会话记忆', helper: '删除本项目的对话记忆；画布与文档不受影响。', children: [
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              onPressed: () => store.clearAgentSession(),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('清空会话', style: TextStyle(fontSize: 14)),
            ),
          ),
        ]),
        _mCard(context, title: '上下文治理', children: [
          for (final line in [
            '工具结果去掉整份源码，只保留摘要与最新状态',
            '旧的读取结果会被占位替换，避免上下文重复堆积',
            '上下文窗口来自随包发布的模型清单',
            '会话超过 80 条自动压缩为摘要，不额外调用模型',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('· $line', style: TextStyle(fontSize: 12, height: 1.5, color: p.ink3)),
            ),
        ]),
      ],
    );
  }

  Widget _mStat(BuildContext context, String label, String value, {bool last = false}) {
    final p = context.palette;
    return Expanded(
      child: Container(
        margin: EdgeInsets.only(right: last ? 0 : 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: p.bgElevated.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 15, fontFamily: 'Menlo', fontWeight: FontWeight.w600, color: p.ink)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, color: p.ink4)),
          ],
        ),
      ),
    );
  }

  Widget _mAbout(BuildContext context, AppStore store) {
    final p = context.palette;
    return ListView(
      key: const ValueKey('settings-m-detail-about'),
      padding: EdgeInsets.fromLTRB(16, 16, 16, 32 + MediaQuery.viewInsetsOf(context).bottom),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: p.panel2.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: p.line),
          ),
          child: Row(
            children: [
              const NonLogo(size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('NaN',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.ink)),
                    Text('AI-native product design studio',
                        style: TextStyle(fontSize: 12, color: p.ink3)),
                  ],
                ),
              ),
              Pill(label: 'v0.1', color: p.accent),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _mCard(context, title: '运行信息', children: [
          for (final row in [
            ('应用版本', '0.1 · 本地优先'),
            ('设计引擎', store.api == null ? '未就绪' : '就绪'),
            ('项目文件', '加密单文件 · 保存在本机'),
            ('模型清单', '内置快照 · 可手动更新'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                      width: 92,
                      child: Text(row.$1, style: TextStyle(fontSize: 13, color: p.ink4))),
                  Expanded(
                    child: Text(row.$2,
                        style: TextStyle(fontSize: 13, fontFamily: 'Menlo', color: p.ink2)),
                  ),
                ],
              ),
            ),
        ]),
        _mCard(context, title: '唯一事实源', children: [
          Text('每个项目是一份加密项目文件；你与内置智能体的每次修改都经设计校验后写回同一份文档。',
              style: TextStyle(fontSize: 13, height: 1.6, color: p.ink3)),
        ]),
      ],
    );
  }

  Widget _mCard(BuildContext context,
      {required String title, String? helper, required List<Widget> children}) {
    final p = context.palette;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: p.panel2.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.ink2)),
          const SizedBox(height: 10),
          ...children,
          if (helper != null) ...[
            const SizedBox(height: 8),
            Text(helper, style: TextStyle(fontSize: 12, height: 1.5, color: p.ink4)),
          ],
        ],
      ),
    );
  }

  InputDecoration _mDecoration(BuildContext context, {String? hint, Widget? suffix}) {
    final p = context.palette;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: p.line),
    );
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: 13, color: p.ink4),
      isDense: true,
      filled: true,
      fillColor: p.panel3.withValues(alpha: 0.55),
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: p.accent, width: 1.4),
      ),
    );
  }

  Widget _mRadioRow(BuildContext context,
      {required String label,
      String? note,
      required bool selected,
      required VoidCallback onTap}) {
    final p = context.palette;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: selected ? p.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? p.accent : p.line),
        ),
        child: Row(
          children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 20, color: selected ? p.accent : p.ink4),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: 15, color: p.ink)),
                  if (note != null)
                    Text(note, style: TextStyle(fontSize: 12, color: p.ink4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _labeled(BuildContext context, String label, Widget child) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 10, color: p.ink3)),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}
