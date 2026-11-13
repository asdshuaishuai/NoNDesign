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

  @override
  void initState() {
    super.initState();
    final store = context.read<AppStore>();
    _keyController = TextEditingController(text: store.settings.apiKey);
    _baseController = TextEditingController(text: store.settings.baseUrl);
  }

  @override
  void dispose() {
    _keyController.dispose();
    _baseController.dispose();
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
                  IconAction(icon: Icons.close, tooltip: '关闭', size: 28, onTap: () => Navigator.pop(context)),
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
                      border: Border(bottom: BorderSide(color: p.line)),
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
              // 左右两列：左列标题+思考等级；右列元数据（context/步数）独立
              // 成栏、右缘互相对齐——原来两个右对齐碎片散在两行，视觉孤立。
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.auto_awesome, size: 13, color: p.accent),
                                const SizedBox(width: 5),
                                Flexible(
                                  child: Text(store.model!.name,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: p.ink)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
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
                                          borderRadius: BorderRadius.circular(5),
                                        ),
                                        child: Text(level,
                                            style: TextStyle(
                                                fontSize: 10,
                                                color: store.settings.thinkingLevel == level ? Colors.white : p.ink3)),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('${formatTokens(store.model!.context)} context',
                              style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink4)),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('步数', style: TextStyle(fontSize: 10, color: p.ink3)),
                              const SizedBox(width: 4),
                              SizedBox(
                                width: 54,
                                height: 24,
                                child: TextFormField(
                                  initialValue: store.settings.maxSteps.toString(),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 10, fontFamily: 'Menlo', color: p.ink),
                                  decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 3)),
                                  onFieldSubmitted: (v) async {
                                    store.settings.maxSteps = (int.tryParse(v) ?? 60).clamp(4, 200);
                                    await store.saveSettings();
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
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
                    borderRadius: BorderRadius.circular(11),
                    onTap: () async {
                      store.settings.theme = item.$1;
                      await store.saveSettings();
                    },
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: store.settings.theme == item.$1 ? p.accentSoft : p.panel2.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(11),
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
                onFieldSubmitted: (v) async {
                  store.settings.maxSteps = (int.tryParse(v) ?? 60).clamp(4, 200);
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
        decoration: BoxDecoration(color: p.bgElevated.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(7)),
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
