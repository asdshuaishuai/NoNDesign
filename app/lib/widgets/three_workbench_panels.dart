/// 3D 工作台的内容区专属面板：场景大纲 + 节点检查器 + 底部状态条。
///
/// 2026-11-24 工作台独立适配（UI-2 首批）：3D 不再只把设计画布的「源码/规范」
/// 侧栏换皮，而是有自己的**视口优先**内容布局——左侧大纲、右侧检查器、底部
/// 状态条；共享外壳（TitleBar/Rail/右 chat/StatusBar）仍由外层提供。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// 面板头部统一规格：左侧大纲 / 右侧检查器 / 设计面左栏都用同一个高度与内边距。
///
/// 44 = NonSpace.xxl(32) + NonSpace.md(12)：不引入新的魔法数，也不为两个面板
/// 各写一套「差不多」的头部。新增面板必须复用 [_PanelHeader]。
const double panelHeaderHeight = NonSpace.xxl + NonSpace.md;

/// 面板头部（标题 > 关键值 > 说明 的第一级）：固定高度 + 左右 md 内边距 +
/// 底边 1px 分隔（就是面板唯一的外边框，不再叠第二层 Divider）。
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.headKey,
    required this.icon,
    required this.title,
    this.trailing,
  });

  final Key headKey;
  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: headKey,
      height: panelHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: NonSpace.md),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 13, color: p.ink4),
          const SizedBox(width: NonSpace.sm),
          // 区块标题统一 NonType.bodyStrong；列表/说明各自低一档，见下面注释。
          Text(
            title,
            style: NonType.of(
              NonType.bodyStrong,
              color: p.ink,
              weight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 大纲条目种类（只做 layout/检查器分区，不是场景事实源）。
enum ThreeOutlinerKind { component, material, camera, node }

/// 一条大纲条目（从 legacy spec / v2 scene 投影出来的只读视图）。
final class ThreeOutlinerItem {
  const ThreeOutlinerItem({
    required this.id,
    required this.kind,
    required this.label,
    this.detail = '',
    this.data = const <String, Object?>{},
  });

  final String id;
  final ThreeOutlinerKind kind;

  /// 用户可读名字（优先 `what`/`view`/材质名，不把内部 id 当主文案）。
  final String label;
  final String detail;
  final Map<String, Object?> data;

  IconData get icon => switch (kind) {
    ThreeOutlinerKind.component => Icons.category_outlined,
    ThreeOutlinerKind.material => Icons.palette_outlined,
    ThreeOutlinerKind.camera => Icons.videocam_outlined,
    ThreeOutlinerKind.node => Icons.widgets_outlined,
  };
}

/// 检查器一次受控属性编辑：只描述「哪个对象、改哪些字段」，不持有事实源。
///
/// 面板只产出补丁；合并进项目规范、走服务校验与刷新由工作台负责
/// （3D 视口/gizmo 与 scene.json 编辑器不在本批次）。
final class ThreeInspectorEdit {
  const ThreeInspectorEdit({
    required this.kind,
    required this.id,
    required this.fields,
  });

  final ThreeOutlinerKind kind;

  /// 组件/材质的裸 id（不含 `component:`/`material:` 前缀）；相机固定为 `camera`。
  final String id;

  /// 只包含**改动过的**字段（未动过的字段不写入，避免把默认值写回规范）。
  final Map<String, Object?> fields;

  @override
  String toString() => 'ThreeInspectorEdit(${kind.name}:$id, $fields)';
}

const Set<String> _componentEditableKeys = <String>{
  'what',
  'size_scale',
  'material',
};
const Set<String> _materialEditableKeys = <String>{
  'color_hex',
  'roughness',
  'metalness',
};
const Set<String> _cameraEditableKeys = <String>{'view'};

/// 可编辑字段的人话标签（检查器表单、内容区只读摘要与通用检查器共用）。
///
/// 键是 legacy spec 的真实字段名；未知键原样返回（只读行不丢信息）。
String threeInspectorFieldLabel(String key) => switch (key) {
  'what' => '组件名称',
  'size_scale' => '尺寸比例',
  'material' => '材质',
  'color_hex' => '材质颜色',
  'roughness' => '粗糙度',
  'metalness' => '金属感',
  'view' => '视角',
  _ => key,
};

/// `#RRGGBB` 颜色文本（检查器受控输入的唯一合法形状）。
final RegExp _colorHexPattern = RegExp(r'^#[0-9a-fA-F]{6}$');

/// 校验一条检查器补丁，返回 null 表示可以保存；否则是一句可直接上屏的修正提示。
///
/// 工作台保存前再跑一遍（面板本地校验 + 主链路服务校验，不做单点信任）。
String? validateThreeInspectorEdit(ThreeInspectorEdit edit) {
  if (edit.fields.isEmpty) return '还没有要保存的修改';
  switch (edit.kind) {
    case ThreeOutlinerKind.component:
      for (final String key in edit.fields.keys) {
        if (!_componentEditableKeys.contains(key)) {
          return '组件不支持属性「$key」';
        }
      }
      final Object? what = edit.fields['what'];
      if (what != null && (what is! String || what.trim().isEmpty)) {
        return '组件名称不能为空';
      }
      final Object? sizeScale = edit.fields['size_scale'];
      if (sizeScale != null &&
          (sizeScale is! num || !sizeScale.isFinite || sizeScale <= 0)) {
        return '尺寸比例要填一个大于 0 的数字';
      }
      final Object? material = edit.fields['material'];
      if (material != null && material is! String) {
        return '材质引用要填材质 id';
      }
      break;
    case ThreeOutlinerKind.material:
      for (final String key in edit.fields.keys) {
        if (!_materialEditableKeys.contains(key)) {
          return '材质不支持属性「$key」';
        }
      }
      final Object? color = edit.fields['color_hex'];
      if (color != null &&
          (color is! String || !_colorHexPattern.hasMatch(color.trim()))) {
        return '颜色要写成 #RRGGBB（例如 #c9a06a）';
      }
      for (final String key in const <String>['roughness', 'metalness']) {
        final Object? value = edit.fields[key];
        if (value != null &&
            (value is! num || !value.isFinite || value < 0 || value > 1)) {
          return '粗糙度和金属感要填 0 到 1 之间的数字';
        }
      }
      break;
    case ThreeOutlinerKind.camera:
      for (final String key in edit.fields.keys) {
        if (!_cameraEditableKeys.contains(key)) {
          return '相机不支持属性「$key」';
        }
      }
      final Object? view = edit.fields['view'];
      if (view != null && (view is! String || view.trim().isEmpty)) {
        return '相机视角不能为空';
      }
      break;
    case ThreeOutlinerKind.node:
      return '场景节点属性编辑在场景编辑器批次接入';
  }
  return null;
}

/// 把一条检查器补丁合并进一份规范副本；返回 null 表示目标对象已不在大纲里。
///
/// 纯函数：不修改传入的 [spec]（列表/对象都是浅拷贝后替换目标项），
/// 供工作台在保存前做受控合并，也让测试能单独锚定字段白名单/定位语义。
/// 调用方应先跑 [validateThreeInspectorEdit]。
Map<String, dynamic>? applyThreeInspectorEdit(
  Map<String, dynamic> spec,
  ThreeInspectorEdit edit,
) {
  if (edit.kind == ThreeOutlinerKind.node || edit.fields.isEmpty) return null;
  final Set<String> allowed = switch (edit.kind) {
    ThreeOutlinerKind.component => _componentEditableKeys,
    ThreeOutlinerKind.material => _materialEditableKeys,
    ThreeOutlinerKind.camera => _cameraEditableKeys,
    ThreeOutlinerKind.node => const <String>{},
  };
  for (final String key in edit.fields.keys) {
    if (!allowed.contains(key)) {
      throw ArgumentError('检查器不支持属性字段：$key');
    }
  }
  final String targetId = edit.id.trim();
  if (edit.kind == ThreeOutlinerKind.camera) {
    final Object? rawCamera = spec['camera'];
    if (rawCamera is! Map) return null;
    final Map<String, dynamic> next = Map<String, dynamic>.from(spec);
    next['camera'] = Map<String, dynamic>.from(rawCamera)..addAll(edit.fields);
    return next;
  }
  final String listKey = edit.kind == ThreeOutlinerKind.component
      ? 'components'
      : 'materials';
  final Object? rawList = spec[listKey];
  if (rawList is! List) return null;
  final List<dynamic> items = List<dynamic>.from(rawList);
  for (var i = 0; i < items.length; i++) {
    final Object? raw = items[i];
    if (raw is! Map) continue;
    if ((raw['id'] ?? '').toString().trim() != targetId) continue;
    items[i] = Map<String, dynamic>.from(raw)..addAll(edit.fields);
    final Map<String, dynamic> next = Map<String, dynamic>.from(spec);
    next[listKey] = items;
    return next;
  }
  return null;
}

/// 从 3D legacy spec 投影出大纲条目（components/materials/camera）。
///
/// 这不是第二事实源：只用于 3D 工作台的大纲/检查器读取；v2 scene.json 的
/// 节点投影在后续 scene 模式适配时接同一模型。坏项跳过，不炸整份大纲。
List<ThreeOutlinerItem> threeOutlinerItemsFromSpec(Map<String, dynamic>? spec) {
  if (spec == null) return const <ThreeOutlinerItem>[];
  final List<ThreeOutlinerItem> items = <ThreeOutlinerItem>[];
  final Object? components = spec['components'];
  if (components is List) {
    for (final Object? item in components) {
      if (item is! Map) continue;
      final String id = (item['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      items.add(
        ThreeOutlinerItem(
          id: 'component:$id',
          kind: ThreeOutlinerKind.component,
          label: (item['what'] ?? id).toString(),
          detail: id,
          data: Map<String, Object?>.from(item),
        ),
      );
    }
  }
  final Object? materials = spec['materials'];
  if (materials is List) {
    for (final Object? item in materials) {
      if (item is! Map) continue;
      final String id = (item['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      final String color = (item['color_hex'] ?? '').toString();
      items.add(
        ThreeOutlinerItem(
          id: 'material:$id',
          kind: ThreeOutlinerKind.material,
          label: id,
          detail: color,
          data: Map<String, Object?>.from(item),
        ),
      );
    }
  }
  final Object? camera = spec['camera'];
  if (camera is Map && camera.isNotEmpty) {
    items.add(
      ThreeOutlinerItem(
        id: 'camera',
        kind: ThreeOutlinerKind.camera,
        label: (camera['view'] ?? '作者相机').toString(),
        detail: '相机',
        data: Map<String, Object?>.from(camera),
      ),
    );
  }
  return items;
}

/// 从 v2 `scene.json` 的 nodes 投影大纲条目（scene 模式事实源）。
///
/// code 模式的 scene.json 是派生投影，也按同一视图展示；节点 id 是场景事实源
/// 的 key，坏了/缺 id 的节点跳过而不是让整份大纲消失。
List<ThreeOutlinerItem> threeOutlinerItemsFromScene(
  Map<String, Object?>? scene,
) {
  if (scene == null) return const <ThreeOutlinerItem>[];
  final Object? rawNodes = scene['nodes'];
  if (rawNodes is! List) return const <ThreeOutlinerItem>[];
  final List<ThreeOutlinerItem> items = <ThreeOutlinerItem>[];
  for (final Object? raw in rawNodes) {
    if (raw is! Map) continue;
    final String id = (raw['id'] ?? '').toString().trim();
    if (id.isEmpty) continue;
    final String type = (raw['type'] ?? 'node').toString();
    items.add(
      ThreeOutlinerItem(
        id: 'node:$id',
        kind: ThreeOutlinerKind.node,
        label: id,
        detail: type,
        data: Map<String, Object?>.from(raw),
      ),
    );
  }
  return items;
}

/// 左侧场景大纲（3D 专属；可折叠由外层布局决定）。
class ThreeOutlinerPanel extends StatelessWidget {
  const ThreeOutlinerPanel({
    super.key,
    required this.items,
    this.selectedId,
    required this.onSelect,
  });

  final List<ThreeOutlinerItem> items;
  final String? selectedId;
  final ValueChanged<ThreeOutlinerItem> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('three-workbench-outliner'),
      color: p.bgElevated.withValues(alpha: 0.9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PanelHeader(
            headKey: const ValueKey('three-outliner-head'),
            icon: Icons.account_tree_outlined,
            title: '场景大纲',
            trailing: Text(
              '${items.length}',
              style: NonType.of(NonType.caption, color: p.ink4),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(NonSpace.lg),
                      child: Text(
                        '还没有场景内容\n先让 NaN 生成规格/场景',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: NonType.caption,
                          height: 1.5,
                          color: p.ink4,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    // 行高一致（单行标签 + 右侧 mono 详情）：固定 itemExtent
                    // 让滚动只构建/重绘可视行，且随系统字号缩放一起变高，
                    // 不会出现「文字变大压出黄条」。
                    itemExtent:
                        MediaQuery.textScalerOf(context).scale(NonType.body) *
                            NonType.lineBody +
                        NonSpace.lg +
                        NonSpace.xxs,
                    padding: const EdgeInsets.symmetric(
                      vertical: NonSpace.sm,
                      horizontal: NonSpace.sm,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final active = item.id == selectedId;
                      return InkWell(
                        key: ValueKey('three-outliner-${item.id}'),
                        borderRadius: BorderRadius.circular(NonRadius.sm),
                        onTap: () => onSelect(item),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: NonSpace.sm,
                            vertical: NonSpace.sm,
                          ),
                          child: Row(
                            children: <Widget>[
                              Icon(
                                item.icon,
                                size: 13,
                                color: active ? p.accent : p.ink4,
                              ),
                              const SizedBox(width: NonSpace.sm),
                              Expanded(
                                child: Text(
                                  item.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: NonType.body,
                                    color: active ? p.ink : p.ink2,
                                    fontWeight: active
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                              if (item.detail.isNotEmpty)
                                Text(
                                  item.detail,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: NonType.micro,
                                    fontFamily: 'Menlo',
                                    color: p.ink4,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 右侧节点检查器（3D 专属；与设计检查器/视频镜头检查器分开）。
///
/// 组件/材质/相机走受控控件（TextField / Slider / 颜色文本），面板只维护
/// 草稿并显式产出 [ThreeInspectorEdit]；保存/重置动作可见，面板不直接改
/// 事实源。v2 `scene.json` 的节点（`node`）仍只读——场景编辑器不在本批次。
class ThreeNodeInspector extends StatefulWidget {
  const ThreeNodeInspector({
    super.key,
    this.item,
    this.sceneChars = 0,
    this.currentPass = '',
    this.onSaveEdit,
    this.readOnly = false,
  });

  final ThreeOutlinerItem? item;
  final int sceneChars;
  final String currentPass;

  /// 保存动作：只回传受控补丁；合并规范、写盘与刷新由工作台接线。
  /// 为 null 时视为只读预览（保存按钮禁用）。
  final ValueChanged<ThreeInspectorEdit>? onSaveEdit;

  /// 只读摘要：宽屏下右侧共享窄栏的「检查」tab 才是唯一编辑入口，内容区
  /// 这块降级为只读（同一属性不出现两处可编辑、避免状态不同步）。
  /// 窄屏（内容区没有这块检查器、右栏走 sheet）保持默认 false 的可编辑面。
  final bool readOnly;

  @override
  State<ThreeNodeInspector> createState() => _ThreeNodeInspectorState();
}

class _ThreeNodeInspectorState extends State<ThreeNodeInspector> {
  final TextEditingController _whatCtl = TextEditingController();
  final TextEditingController _sizeCtl = TextEditingController();
  final TextEditingController _materialCtl = TextEditingController();
  final TextEditingController _colorCtl = TextEditingController();
  final TextEditingController _viewCtl = TextEditingController();

  /// 当前选中项的可编辑字段「磁盘值」，重置与脏判断都以它为基准。
  Map<String, Object?> _source = const <String, Object?>{};
  double _roughness = 0.5;
  double _metalness = 0.0;
  double _roughnessSeed = 0.5;
  double _metalnessSeed = 0.0;
  String _signature = '';
  String? _localError;

  @override
  void initState() {
    super.initState();
    _seedFrom(widget.item);
  }

  @override
  void dispose() {
    _whatCtl.dispose();
    _sizeCtl.dispose();
    _materialCtl.dispose();
    _colorCtl.dispose();
    _viewCtl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ThreeNodeInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_signatureFor(widget.item) != _signature) {
      // 保存后快照刷新 / 外部生成改写了规范：以磁盘值为准重新播种。
      _seedFrom(widget.item);
    }
  }

  /// 只把「检查器可见的可编辑字段」纳入签名：run 刷新里无关字段变化不应
  /// 把用户正在输入的草稿抹掉。
  static String _signatureFor(ThreeOutlinerItem? item) {
    if (item == null) return '';
    final Map<String, Object?> data = item.data;
    final List<Object?> values = switch (item.kind) {
      ThreeOutlinerKind.component => <Object?>[
        data['what'],
        data['size_scale'],
        data['material'],
      ],
      ThreeOutlinerKind.material => <Object?>[
        data['color_hex'],
        data['roughness'],
        data['metalness'],
      ],
      ThreeOutlinerKind.camera => <Object?>[data['view']],
      ThreeOutlinerKind.node => <Object?>[item.id],
    };
    return '${item.id}|${jsonEncode(values)}';
  }

  void _seedFrom(ThreeOutlinerItem? item) {
    _localError = null;
    _source = const <String, Object?>{};
    _roughnessSeed = 0.5;
    _metalnessSeed = 0.0;
    _roughness = _roughnessSeed;
    _metalness = _metalnessSeed;
    _signature = _signatureFor(item);
    _whatCtl.clear();
    _sizeCtl.clear();
    _materialCtl.clear();
    _colorCtl.clear();
    _viewCtl.clear();
    final Map<String, Object?> data = item?.data ?? const <String, Object?>{};
    switch (item?.kind) {
      case ThreeOutlinerKind.component:
        final String what = (data['what'] ?? '').toString();
        final Object? rawSize = data['size_scale'];
        final String material = (data['material'] ?? '').toString();
        _source = <String, Object?>{
          'what': what,
          'size_scale': rawSize,
          'material': material,
        };
        _whatCtl.text = what;
        _sizeCtl.text = rawSize is num ? '$rawSize' : '';
        _materialCtl.text = material;
        break;
      case ThreeOutlinerKind.material:
        final String color = (data['color_hex'] ?? '').toString();
        _source = <String, Object?>{
          'color_hex': color,
          'roughness': data['roughness'],
          'metalness': data['metalness'],
        };
        _colorCtl.text = color;
        _roughnessSeed = _unitSeed(data['roughness'], 0.5);
        _metalnessSeed = _unitSeed(data['metalness'], 0.0);
        _roughness = _roughnessSeed;
        _metalness = _metalnessSeed;
        break;
      case ThreeOutlinerKind.camera:
        final String view = (data['view'] ?? '').toString();
        _source = <String, Object?>{'view': view};
        _viewCtl.text = view;
        break;
      case ThreeOutlinerKind.node:
      case null:
        break;
    }
  }

  static double _unitSeed(Object? raw, double fallback) {
    if (raw is num && raw.isFinite) {
      return raw.toDouble().clamp(0.0, 1.0);
    }
    return fallback;
  }

  String _sourceText(String key) => (_source[key] ?? '').toString();

  String _sourceTrimmed(String key) => _sourceText(key).trim();

  bool _sizeChanged() {
    final String text = _sizeCtl.text.trim();
    final Object? source = _source['size_scale'];
    if (text.isEmpty) return source != null;
    final double? parsed = double.tryParse(text);
    if (source is! num) return true;
    return parsed != source.toDouble();
  }

  bool get _dirty => switch (widget.item?.kind) {
    ThreeOutlinerKind.component =>
      _whatCtl.text.trim() != _sourceTrimmed('what') ||
          _sizeChanged() ||
          _materialCtl.text.trim() != _sourceTrimmed('material'),
    ThreeOutlinerKind.material =>
      _colorCtl.text.trim() != _sourceTrimmed('color_hex') ||
          _roughness != _roughnessSeed ||
          _metalness != _metalnessSeed,
    ThreeOutlinerKind.camera => _viewCtl.text.trim() != _sourceTrimmed('view'),
    ThreeOutlinerKind.node => false,
    null => false,
  };

  static Set<String> _editableKeysOf(ThreeOutlinerKind kind) => switch (kind) {
    ThreeOutlinerKind.component => _componentEditableKeys,
    ThreeOutlinerKind.material => _materialEditableKeys,
    ThreeOutlinerKind.camera => _cameraEditableKeys,
    ThreeOutlinerKind.node => const <String>{},
  };

  static String _bareId(ThreeOutlinerItem item) {
    if (item.id.startsWith('component:')) {
      return item.id.substring('component:'.length);
    }
    if (item.id.startsWith('material:')) {
      return item.id.substring('material:'.length);
    }
    return item.id;
  }

  void _reset() {
    setState(() => _seedFrom(widget.item));
  }

  ThreeInspectorEdit? _reject(String message) {
    setState(() => _localError = message);
    return null;
  }

  void _save() {
    final ThreeOutlinerItem? item = widget.item;
    final ValueChanged<ThreeInspectorEdit>? onSave = widget.onSaveEdit;
    if (item == null || onSave == null) return;
    final ThreeInspectorEdit? edit = _collectEdit(item);
    if (edit == null) return;
    if (edit.fields.isEmpty) {
      setState(() => _localError = '还没有要保存的修改');
      return;
    }
    final String? invalid = validateThreeInspectorEdit(edit);
    if (invalid != null) {
      setState(() => _localError = invalid);
      return;
    }
    setState(() => _localError = null);
    onSave(edit);
  }

  ThreeInspectorEdit? _collectEdit(ThreeOutlinerItem item) {
    final Map<String, Object?> fields = <String, Object?>{};
    switch (item.kind) {
      case ThreeOutlinerKind.component:
        final String what = _whatCtl.text.trim();
        if (what.isEmpty) return _reject('组件名称不能为空');
        if (what != _sourceTrimmed('what')) fields['what'] = what;
        final Object? sourceSize = _source['size_scale'];
        final String sizeText = _sizeCtl.text.trim();
        if (sizeText.isEmpty) {
          if (sourceSize != null) return _reject('尺寸比例要填一个大于 0 的数字');
        } else {
          final double? size = double.tryParse(sizeText);
          if (size == null || !size.isFinite || size <= 0) {
            return _reject('尺寸比例要填一个大于 0 的数字');
          }
          if (sourceSize is! num || sourceSize.toDouble() != size) {
            fields['size_scale'] = size;
          }
        }
        final String material = _materialCtl.text.trim();
        if (material != _sourceTrimmed('material')) {
          fields['material'] = material;
        }
        break;
      case ThreeOutlinerKind.material:
        final String color = _colorCtl.text.trim();
        final String sourceColor = _sourceTrimmed('color_hex');
        if (color.isEmpty) {
          if (sourceColor.isNotEmpty) {
            return _reject('颜色要写成 #RRGGBB（例如 #c9a06a）');
          }
        } else if (!_colorHexPattern.hasMatch(color)) {
          return _reject('颜色要写成 #RRGGBB（例如 #c9a06a）');
        }
        if (color != sourceColor) fields['color_hex'] = color;
        if (_roughness != _roughnessSeed) fields['roughness'] = _roughness;
        if (_metalness != _metalnessSeed) fields['metalness'] = _metalness;
        break;
      case ThreeOutlinerKind.camera:
        final String view = _viewCtl.text.trim();
        if (view.isEmpty) return _reject('相机视角不能为空');
        if (view != _sourceTrimmed('view')) fields['view'] = view;
        break;
      case ThreeOutlinerKind.node:
        return null;
    }
    return ThreeInspectorEdit(
      kind: item.kind,
      id: _bareId(item),
      fields: fields,
    );
  }

  Widget _fieldText(
    NonPalette p,
    String field,
    TextEditingController controller, {
    String? hint,
    bool numeric = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NonSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(field, style: TextStyle(fontSize: NonType.micro, color: p.ink4)),
          const SizedBox(height: NonSpace.xs),
          TextField(
            key: ValueKey('three-inspector-field-$field'),
            controller: controller,
            style: TextStyle(fontSize: NonType.body, color: p.ink),
            cursorColor: p.accent,
            keyboardType: numeric
                ? const TextInputType.numberWithOptions(decimal: true)
                : null,
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(fontSize: NonType.micro, color: p.ink4),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: NonSpace.sm,
                vertical: NonSpace.sm,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(NonRadius.sm),
                borderSide: BorderSide(color: p.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(NonRadius.sm),
                borderSide: BorderSide(color: p.line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(NonRadius.sm),
                borderSide: BorderSide(color: p.accent),
              ),
            ),
            onChanged: (_) => setState(() => _localError = null),
          ),
        ],
      ),
    );
  }

  Widget _fieldSlider(
    NonPalette p,
    String field,
    double value,
    ValueChanged<double> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NonSpace.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(field, style: TextStyle(fontSize: NonType.micro, color: p.ink4)),
              const Spacer(),
              Text(
                value.toStringAsFixed(2),
                style: TextStyle(
                  // 关键值比标签高一档：滑块数值是「值」，不是说明。
                  fontSize: NonType.body,
                  fontFamily: 'Menlo',
                  color: p.ink2,
                ),
              ),
            ],
          ),
          Slider(
            key: ValueKey('three-inspector-field-$field'),
            value: value,
            divisions: 100,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _editableFields(NonPalette p, ThreeOutlinerItem item) {
    switch (item.kind) {
      case ThreeOutlinerKind.component:
        return Column(
          children: <Widget>[
            _fieldText(p, 'what', _whatCtl, hint: '组件是什么'),
            _fieldText(
              p,
              'size_scale',
              _sizeCtl,
              hint: '大于 0 的比例',
              numeric: true,
            ),
            _fieldText(p, 'material', _materialCtl, hint: '材质 id，可留空'),
          ],
        );
      case ThreeOutlinerKind.material:
        return Column(
          children: <Widget>[
            _fieldText(p, 'color_hex', _colorCtl, hint: '#RRGGBB'),
            _fieldSlider(
              p,
              'roughness',
              _roughness,
              (value) => setState(() {
                _roughness = value;
                _localError = null;
              }),
            ),
            _fieldSlider(
              p,
              'metalness',
              _metalness,
              (value) => setState(() {
                _metalness = value;
                _localError = null;
              }),
            ),
          ],
        );
      case ThreeOutlinerKind.camera:
        return _fieldText(p, 'view', _viewCtl, hint: '例如：略高处斜看');
      case ThreeOutlinerKind.node:
        return const SizedBox.shrink();
    }
  }

  /// 不在可编辑白名单里的其余字段仍按只读行展示（不丢信息、不误导）。
  Widget _readOnlyRows(NonPalette p, ThreeOutlinerItem item) {
    final Set<String> editable = _editableKeysOf(item.kind);
    final List<MapEntry<String, Object?>> rows = <MapEntry<String, Object?>>[
      for (final MapEntry<String, Object?> entry in item.data.entries)
        if (entry.key != 'id' && !editable.contains(entry.key)) entry,
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: NonSpace.xs),
        Text('其他属性', style: TextStyle(fontSize: NonType.micro, color: p.ink4)),
        const SizedBox(height: NonSpace.xs),
        for (final entry in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: NonSpace.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 78,
                  child: Text(
                    entry.key,
                    style: TextStyle(fontSize: NonType.micro, color: p.ink4),
                  ),
                ),
                Expanded(
                  child: Text(
                    '${entry.value}',
                    style: TextStyle(
                      // 关键值统一 NonType.body（比标签高一档、比标题低一档）。
                      fontSize: NonType.body,
                      color: p.ink2,
                      height: NonType.lineCaption,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 只读摘要（宽屏降级）：把可编辑字段按「标签 → 当前值」只读列出，并
  /// 指向右栏「检查」tab（唯一编辑入口）。不渲染输入控件，避免和右栏同时
  /// 编辑同一属性。
  Widget _readOnlySummary(NonPalette p, ThreeOutlinerItem item) {
    final Set<String> editable = _editableKeysOf(item.kind);
    final List<MapEntry<String, Object?>> rows = <MapEntry<String, Object?>>[
      for (final MapEntry<String, Object?> entry in item.data.entries)
        if (editable.contains(entry.key)) entry,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final MapEntry<String, Object?> entry in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: NonSpace.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 78,
                  child: Text(
                    threeInspectorFieldLabel(entry.key),
                    style: TextStyle(fontSize: NonType.micro, color: p.ink4),
                  ),
                ),
                Expanded(
                  child: Text(
                    '${entry.value ?? ''}',
                    style: TextStyle(
                      fontSize: NonType.body,
                      color: p.ink2,
                      height: NonType.lineCaption,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: NonSpace.sm),
        Text(
          '在右侧「3D 检查」栏修改这些属性；这里只读展示当前值。',
          style: TextStyle(
            fontSize: NonType.caption,
            height: NonType.lineBody,
            color: p.ink4,
          ),
        ),
      ],
    );
  }

  Widget _actions(NonPalette p) {
    final bool editable =
        widget.item != null && widget.item!.kind != ThreeOutlinerKind.node;
    final bool canSave = editable && _dirty && widget.onSaveEdit != null;
    return Padding(
      padding: const EdgeInsets.only(top: NonSpace.xxs),
      child: Row(
        children: <Widget>[
          TextButton(
            key: const ValueKey('three-inspector-reset'),
            onPressed: editable && _dirty ? _reset : null,
            style: TextButton.styleFrom(
              foregroundColor: p.ink3,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: NonSpace.sm),
              minimumSize: const Size(0, 30),
            ),
            child: const Text('重置', style: TextStyle(fontSize: NonType.caption)),
          ),
          const Spacer(),
          FilledButton(
            key: const ValueKey('three-inspector-save'),
            onPressed: canSave ? _save : null,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: NonSpace.md, vertical: NonSpace.sm),
              minimumSize: const Size(0, 30),
              textStyle: const TextStyle(fontSize: NonType.caption),
            ),
            child: const Text('保存属性'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    final ThreeOutlinerItem? item = widget.item;
    return Container(
      key: const ValueKey('three-workbench-inspector'),
      color: p.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PanelHeader(
            headKey: const ValueKey('three-inspector-head'),
            icon: Icons.tune,
            title: '检查器',
          ),
          if (item == null)
            _InspectorEmpty(
              p: p,
              sceneChars: widget.sceneChars,
              currentPass: widget.currentPass,
            )
          else
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(NonSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.label,
                      style: TextStyle(
                        fontSize: NonType.bodyStrong,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                      ),
                    ),
                    const SizedBox(height: NonSpace.xs),
                    Text(switch (item.kind) {
                      ThreeOutlinerKind.component => '组件',
                      ThreeOutlinerKind.material => '材质',
                      ThreeOutlinerKind.camera => '相机',
                      ThreeOutlinerKind.node => '节点',
                    }, style: TextStyle(fontSize: NonType.micro, color: p.ink4)),
                    const SizedBox(height: NonSpace.md),
                    if (item.kind == ThreeOutlinerKind.node) ...<Widget>[
                      _readOnlyRows(p, item),
                      const SizedBox(height: NonSpace.sm),
                      Text(
                        '场景节点属性编辑在场景编辑器批次接入；这里只做只读投影。',
                        style: TextStyle(
                          fontSize: NonType.caption,
                          height: NonType.lineBody,
                          color: p.ink4,
                        ),
                      ),
                    ] else if (widget.readOnly) ...<Widget>[
                      _readOnlySummary(p, item),
                      _readOnlyRows(p, item),
                    ] else ...<Widget>[
                      _editableFields(p, item),
                      _readOnlyRows(p, item),
                      if (widget.onSaveEdit == null)
                        Text(
                          '只读预览：打开项目后可以保存属性。',
                          style: TextStyle(
                            fontSize: NonType.caption,
                            height: NonType.lineBody,
                            color: p.ink4,
                          ),
                        ),
                      if (_localError != null)
                        Padding(
                          key: const ValueKey('three-inspector-error'),
                          padding: const EdgeInsets.only(top: NonSpace.xxs, bottom: NonSpace.sm),
                          child: Text(
                            _localError!,
                            style: TextStyle(
                              fontSize: NonType.micro,
                              height: 1.4,
                              color: p.danger,
                            ),
                          ),
                        ),
                      _actions(p),
                      const SizedBox(height: NonSpace.sm),
                      Text(
                        '保存后写回项目规范，不改场景代码；重新生成时生效。',
                        style: TextStyle(
                          fontSize: NonType.caption,
                          height: NonType.lineBody,
                          color: p.ink4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InspectorEmpty extends StatelessWidget {
  const _InspectorEmpty({
    required this.p,
    required this.sceneChars,
    required this.currentPass,
  });

  final NonPalette p;
  final int sceneChars;
  final String currentPass;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(NonSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '场景概览',
              style: TextStyle(
                fontSize: NonType.bodyStrong,
                fontWeight: FontWeight.w700,
                color: p.ink,
              ),
            ),
            const SizedBox(height: NonSpace.md),
            _kv(p, '当前层', currentPass.isEmpty ? '—' : currentPass),
            _kv(p, '场景代码', '$sceneChars 字符'),
            const SizedBox(height: NonSpace.sm),
            Text(
              '在左侧大纲选择组件/材质/相机查看并编辑属性。',
              style: TextStyle(
                fontSize: NonType.caption,
                height: NonType.lineBody,
                color: p.ink4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(NonPalette p, String key, String value) => Padding(
    padding: const EdgeInsets.only(bottom: NonSpace.sm),
    child: Row(
      children: <Widget>[
        SizedBox(
          width: 78,
          child: Text(key, style: TextStyle(fontSize: NonType.micro, color: p.ink4)),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(fontSize: NonType.body, color: p.ink2),
          ),
        ),
      ],
    ),
  );
}

/// 3D 内容区底部状态条高度：与 `WorkbenchLayout(three).bottomBarHeight`
/// （34 = NonSpace.xxl + NonSpace.xxs）保持同一档，widget 不再另写 30。
const double threeWorkbenchStatusBarHeight = NonSpace.xxl + NonSpace.xxs;

/// 3D 内容区底部状态条（不是共享外壳的 StatusBar）。
class ThreeWorkbenchStatusBar extends StatelessWidget {
  const ThreeWorkbenchStatusBar({
    super.key,
    this.height = threeWorkbenchStatusBarHeight,
    required this.currentPass,
    required this.blocked,
    required this.attempts,
    this.gateVerdict,
  });

  final String currentPass;
  final bool blocked;
  final int attempts;
  final String? gateVerdict;

  /// 高度由宿主按 `WorkbenchLayout.bottomBarHeight` 传入（默认 34）。
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      key: const ValueKey('three-workbench-status'),
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: NonSpace.md),
      decoration: BoxDecoration(
        color: p.bgElevated,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            blocked ? Icons.error_outline : Icons.view_in_ar_outlined,
            size: 12,
            color: blocked ? p.warn : p.ink4,
          ),
          const SizedBox(width: NonSpace.sm),
          Text(
            blocked
                ? '已阻塞 · $currentPass'
                : '当前层 · ${currentPass.isEmpty ? '—' : currentPass}',
            style: TextStyle(fontSize: NonType.caption, color: blocked ? p.warn : p.ink3),
          ),
          const SizedBox(width: NonSpace.md),
          Text('尝试 $attempts', style: TextStyle(fontSize: NonType.micro, color: p.ink4)),
          const Spacer(),
          if (gateVerdict != null)
            Text(
              '门 · $gateVerdict',
              style: TextStyle(
                fontSize: NonType.micro,
                color: gateVerdict == 'ERROR' ? p.warn : p.ink4,
              ),
            ),
        ],
      ),
    );
  }
}
