import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/keys.dart';
import '../core/store.dart';
import '../core/theme.dart';
import 'common.dart';

Future<void> showSettingsDialog(BuildContext context) async {
  await showNonDialog<void>(
    context: context,
    builder: (context) => const _SettingsDialog(),
  );
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();
  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  String _tab = 'models';
  String _query = '';
  late final TextEditingController _keyController;
  late final TextEditingController _baseController;
  List<AcpAgentInfo> _acpAgents = const [];
  // ACP 探测失败原因（含「本地服务未连接」）；null = 正常或未探测。
  String? _acpError;
  // 步数输入控制器：initState 赋值（字段初始化器访问不到局部 store）。
  late final TextEditingController _stepsController;
  bool _stepsSavedFlash = false;

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    _keyController = TextEditingController(text: store.settings.apiKey);
    _baseController = TextEditingController(text: store.settings.baseUrl);
    _stepsController = TextEditingController(text: store.settings.maxSteps.toString());
    _loadAcpAgents();
  }

  /// 显式保存按钮（用户点名）：把步数输入框的当前值提交并给出 ✓ 反馈。
  Future<void> _saveSteps() async {
    final store = context.read<AppStore>();
    store.settings.maxSteps =
        (int.tryParse(_stepsController.text) ?? store.settings.maxSteps).clamp(4, 600);
    await store.saveSettings();
    setState(() => _stepsSavedFlash = true);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _stepsSavedFlash = false);
    });
  }

  Future<void> _loadAcpAgents() async {
    final api = context.read<AppStore>().api;
    if (api == null) {
      if (mounted) setState(() => _acpError = '本地服务未连接');
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
      // 失败显性呈现（_acp 顶部错误行 + 重试），不再静默吞掉——
      // 服务未连上时用户要能分辨「没装 CLI」与「探测失败」。
      if (mounted) setState(() => _acpError = '检测失败：$e');
    }
  }

  @override
  void dispose() {
    _keyController.dispose();
    _baseController.dispose();
    _stepsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final p = context.palette;
    return Dialog(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: p.lineStrong)),
      child: SizedBox(
        width: 860,
        height: 600,
        child: Column(
          children: [
            Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
              child: Row(
                children: [
                  Text('设置', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink)),
                  const SizedBox(width: 8),
                  Text('模型、外观与 Agent 上下文策略', style: TextStyle(fontSize: 11, color: p.ink3)),
                  const Spacer(),
                  IconAction(icon: Icons.close, tooltip: '关闭', size: 26, onTap: () => Navigator.pop(context)),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Container(
                    width: 176,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: p.panel2.withValues(alpha: 0.3),
                      border: Border(right: BorderSide(color: p.line)),
                    ),
                    child: Column(
                      children: [
                        _nav(context, 'models', Icons.memory, '模型与端点'),
                        _nav(context, 'appearance', Icons.palette_outlined, '外观与交互'),
                        _nav(context, 'agent', Icons.speed, '上下文与缓存'),
                        _nav(context, 'acp', Icons.hub_outlined, '外部智能体'),
                        _nav(context, 'about', Icons.info_outline, '关于'),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: switch (_tab) {
                        'appearance' => _appearance(context, store),
                        'agent' => _agent(context, store),
                        'acp' => _acp(context, store),
                        'about' => _about(context, store),
                        _ => _models(context, store),
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nav(BuildContext context, String id, IconData icon, String label) {
    final p = context.palette;
    final active = _tab == id;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _tab = id),
      child: Container(
        height: 34,
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: active ? p.panel : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: active ? p.accent : p.ink4),
            const SizedBox(width: 7),
            Text(label, style: TextStyle(fontSize: 12, color: active ? p.ink : p.ink3)),
          ],
        ),
      ),
    );
  }

  Widget _models(BuildContext context, AppStore store) {
    final p = context.palette;
    final models = store.registry.flatten().where((m) {
      if (m.providerId != store.settings.providerId) return false;
      if (_query.isEmpty) return true;
      return m.id.toLowerCase().contains(_query.toLowerCase()) || m.name.toLowerCase().contains(_query.toLowerCase());
    }).take(160).toList();
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _labeled(context, '服务商', nonSelect<String>(context,
                  value: store.settings.providerId,
                      items: [
                    for (final id in store.registry.providerIds)
                      DropdownMenuItem(value: id, child: Text(store.registry.provider(id)?['name']?.toString() ?? id, style: const TextStyle(fontSize: 12))),
                  ],
                  onChanged: (id) async {
                    if (id == null) return;
                    final pv = store.registry.provider(id);
                    final models = (pv?['models'] as Map?) ?? const {};
                    // 显式 String 归一：keys 是 List<dynamic>，firstWhere 的
                    // orElse 闭包推断成 () => dynamic 会以子类型错误崩溃
                    // （2026-11-13 实证：选无 tool_call 模型的服务商即炸）。
                    var first = '';
                    for (final k in models.keys) {
                      if ((models[k] as Map?)?['tool_call'] == true) {
                        first = k.toString();
                        break;
                      }
                    }
                    if (first.isEmpty && models.isNotEmpty) {
                      first = models.keys.first.toString();
                    }
                    store.settings
                      ..providerId = id
                      ..modelId = first
                      ..baseUrl = (pv?['api'] ?? '').toString()
                      ..thinkingLevel = 'auto';
                    _baseController.text = store.settings.baseUrl;
                    await store.saveSettings();
                  },
                )),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _labeled(context, '端点', TextField(
                  controller: _baseController,
                  style: TextStyle(fontSize: 11, fontFamily: 'Menlo', color: p.ink2),
                  decoration: InputDecoration(hintText: 'https://…/v1', contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9)),
                  onSubmitted: (v) async {
                    store.settings.baseUrl = v.trim();
                    await store.saveSettings();
                  },
                  onTapOutside: (_) async {
                    store.settings.baseUrl = _baseController.text.trim();
                    await store.saveSettings();
                  },
                )),
              ),
            ],
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: TextStyle(fontSize: 12, color: p.ink),
                  decoration: const InputDecoration(hintText: '搜索模型…', prefixIcon: Icon(Icons.search, size: 15)),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => store.refreshModels(),
                icon: const Icon(Icons.refresh, size: 13),
                label: const Text('更新清单'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            constraints: const BoxConstraints(maxHeight: 250),
            decoration: BoxDecoration(
              border: Border.all(color: p.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: models.length,
              itemBuilder: (context, i) {
                final m = models[i];
                final active = store.settings.modelId == m.id;
                return InkWell(
                  onTap: () async {
                    store.settings.modelId = m.id;
                    if (store.settings.baseUrl.isEmpty) store.settings.baseUrl = m.baseUrl;
                    _baseController.text = store.settings.baseUrl;
                    await store.saveSettings();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: active ? p.accentSoft : Colors.transparent,
                      // 0.5px hairline；末行免画——末行底线与容器 Border.all
                      // 叠成 2px 假粗线（hairline 分隔线策略）。
                      border: i < models.length - 1
                          ? Border(bottom: BorderSide(color: p.line, width: 0.5))
                          : null,
                    ),
                    child: Row(
                      children: [
                        Icon(active ? Icons.radio_button_checked : Icons.radio_button_off,
                            size: 14, color: active ? p.accent : p.ink4),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(child: Text(m.name, overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: p.ink))),
                                  const SizedBox(width: 5),
                                  if (m.toolCall) Pill(label: 'tools', color: p.success),
                                  if (m.reasoning) Pill(label: 'thinking', color: p.accent),
                                ],
                              ),
                              Text('${m.id} · ${formatTokens(m.context)} ctx',
                                  style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
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
                      Text('${formatTokens(store.model!.context)} context',
                          style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
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
                      Text('步数', style: TextStyle(fontSize: 10, color: p.ink3)),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 54,
                        height: 24,
                        child: TextFormField(
                          controller: _stepsController,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink),
                          decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 3)),
                          // onChanged 即时保存：此前只挂 onFieldSubmitted，
                          // 改完不回车直接发送就丢值（plist 实测停在 60，
                          // 用户填的 300 未落盘 → Max turns (60) exceeded）。
                          onChanged: (v) async {
                            final n = int.tryParse(v);
                            if (n == null) return;
                            store.settings.maxSteps = n.clamp(4, 600);
                            await store.saveSettings();
                          },
                          onFieldSubmitted: (_) => _saveSteps(),
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

  Widget _agent(BuildContext context, AppStore store) {
    final p = context.palette;
    final cacheRate = (store.usage['inputTokens'] as num? ?? 0) > 0
        ? ((store.usage['cachedTokens'] as num? ?? 0) / (store.usage['inputTokens'] as num)) * 100
        : 0;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                    Text('前缀缓存分层', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink)),
                    const SizedBox(width: 6),
                    Pill(label: 'append-only', color: p.accent),
                  ],
                ),
                const SizedBox(height: 6),
                Text('上下文按「稳定 → 易变」排序；变更以追加方式进入最新 tool 结果，不重写历史。',
                    style: TextStyle(fontSize: 11, height: 1.5, color: p.ink3)),
                const SizedBox(height: 10),
                for (final row in [
                  ('L0', '静态指令 + 工具 schema', '逐字节稳定'),
                  ('L1', 'PROJECT MAP', '项目内稳定'),
                  ('L2', '设计规范 + 产品文档', '编辑后变化'),
                  ('L3', '会话记忆 + 最新 state', '每轮追加'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        SizedBox(width: 18, child: Text(row.$1, style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.accent))),
                        Expanded(child: Text(row.$2, style: TextStyle(fontSize: 10, color: p.ink3))),
                        Text(row.$3, style: TextStyle(fontSize: 10, color: p.ink4)),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
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
              Expanded(child: _labeled(context, '会话键', TextFormField(
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
                Text('确定性上下文治理', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink)),
                const SizedBox(height: 6),
                for (final line in [
                  '工具结果剥离 canonical 与 SVG，只保留摘要 + 最新 state',
                  '旧 read/inspect 结果被占位替换（去 supersede）',
                  '上下文窗口来自 models.dev 的 limit.context',
                  '会话超过 80 条自动压缩为确定性摘要，不额外调用 LLM',
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
                Text('NoNDesign', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink)),
                Text('AI-native product design studio', style: TextStyle(fontSize: 11, color: p.ink3)),
              ],
            ),
            const Spacer(),
            Pill(label: 'v0.1', color: p.accent),
          ],
        ),
        const SizedBox(height: 16),
        for (final row in [
          ('运行时', 'Flutter 3.50'),
          ('引擎', 'MoonViz classic wasm · 0.2 dev 构建'),
          // 不暴露裸 URL：本地引擎服务是应用自动拉起的实现细节，
          // 端口排障需要时看 ~/.nondesign/server.json 即可。
          ('本地引擎服务', store.api == null ? '未连接' : '随应用自动启动 · 就绪'),
          ('数据', '~/.nondesign · DDP 单文件'),
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
        Text('唯一事实源是一份 canonical .mbt.md；人类与 Agent 的每次修改都经引擎门校验后回写同一份文档。DDP 只是它的认证加密容器。',
            style: TextStyle(fontSize: 11, height: 1.55, color: p.ink3)),
        const Spacer(),
        Text('模型与端点来自 models.dev 快照；上下文与缓存策略在本地确定性执行。',
            style: TextStyle(fontSize: 10, color: p.ink4)),
      ],
    );
  }

  Widget _acp(BuildContext context, AppStore store) {
    final p = context.palette;
    final selected = store.settings.acpAgentId;
    return ListView(
      children: [
        Text('外部智能体（ACP 协议）', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink)),
        const SizedBox(height: 4),
        Text('自动检测本机已安装的支持 ACP 的智能体 CLI（Claude Code / Codex / Kimi / Gemini / Qwen 等）。'
            '选中后右侧输入框的消息将发给该智能体，流式回显进时间线；NoN 内置管线保持可用。',
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
        _acpOption(context, store, null, 'NoN 内置管线', '一句话 → 文档 → 原型（默认）', true, false, ''),
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
                        ? (a.executable ?? '适配器经 npx 拉取')
                        : '未安装',
          ),
        const SizedBox(height: 10),
        Text('检测基于 PATH 探测；适配器类（claude-code-acp 等）需先全局安装。'
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
