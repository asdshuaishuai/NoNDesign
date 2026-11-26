// 通用检查器面板：把 `CheckSheet` 渲染成可编辑的属性表。
//
// 唯一渲染器——所有工作台的「检查」tab 都用它，不要在别处再写一套属性表单。
// 字段类型与写回语义见 `core/inspect/check_field.dart`。
library;

import 'package:material_ui/material_ui.dart';

import '../core/inspect/check_field.dart';
import '../core/theme.dart';

/// 检查器面板：空态提示 + 分组属性行。
class CheckPanel extends StatefulWidget {
  const CheckPanel({super.key, required this.controller});

  final WorkbenchCheckController controller;

  @override
  State<CheckPanel> createState() => _CheckPanelState();
}

class _CheckPanelState extends State<CheckPanel> {
  /// 正在写回的字段（避免连点/并发写同一字段）。
  final Set<String> _busyKeys = <String>{};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(CheckPanel old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _apply(String key, Object? value) async {
    if (_busyKeys.contains(key)) return;
    setState(() => _busyKeys.add(key));
    try {
      await widget.controller.update(key, value);
    } finally {
      if (mounted) setState(() => _busyKeys.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    final CheckSheet? sheet = widget.controller.sheet;
    if (sheet == null) {
      return Container(
        key: const ValueKey('check-panel-empty'),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(NonSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.tune, size: 26, color: p.ink4),
            const SizedBox(height: NonSpace.md),
            Text(
              '选中一个元素',
              style: NonType.of(
                NonType.subtitle,
                color: p.ink,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: NonSpace.sm),
            Text(
              '在画布/视口/时间线上选中元素后，这里会显示它的属性，改完即写入项目。',
              textAlign: TextAlign.center,
              style: NonType.of(
                NonType.body,
                color: p.ink3,
                height: NonType.lineBody,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      key: const ValueKey('check-panel'),
      color: p.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(context, p, sheet),
          Divider(height: 1, color: p.line),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('check-panel-fields'),
              padding: const EdgeInsets.symmetric(vertical: NonSpace.sm),
              itemCount: sheet.fields.length,
              itemBuilder: (BuildContext context, int i) {
                final CheckField f = sheet.fields[i];
                return _FieldRow(
                  key: ValueKey('check-row:${f.key}'),
                  field: f,
                  busy: _busyKeys.contains(f.key),
                  onApply: (Object? v) => _apply(f.key, v),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, NonPalette p, CheckSheet sheet) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NonSpace.md,
        NonSpace.md,
        NonSpace.md,
        NonSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (sheet.kindLabel.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NonSpace.sm,
                    vertical: NonSpace.xxs,
                  ),
                  decoration: BoxDecoration(
                    color: p.accentSoft,
                    borderRadius: BorderRadius.circular(NonRadius.sm),
                  ),
                  child: Text(
                    sheet.kindLabel,
                    style: NonType.of(NonType.micro, color: p.accent),
                  ),
                ),
              if (sheet.kindLabel.isNotEmpty) const SizedBox(width: NonSpace.sm),
              Expanded(
                child: Text(
                  sheet.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: NonType.of(
                    NonType.subtitle,
                    color: p.ink,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (sheet.subtitle.isNotEmpty) ...<Widget>[
            const SizedBox(height: NonSpace.xs),
            Text(
              sheet.subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: NonType.of(NonType.caption, color: p.ink3),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单行属性：左侧标签、右侧编辑控件。
class _FieldRow extends StatefulWidget {
  const _FieldRow({
    super.key,
    required this.field,
    required this.busy,
    required this.onApply,
  });

  final CheckField field;
  final bool busy;
  final ValueChanged<Object?> onApply;

  @override
  State<_FieldRow> createState() => _FieldRowState();
}

class _FieldRowState extends State<_FieldRow> {
  late final TextEditingController _text = TextEditingController(
    text: _displayValue(widget.field),
  );
  late final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commitText();
    });
  }

  @override
  void didUpdateWidget(_FieldRow old) {
    super.didUpdateWidget(old);
    if (old.field.value != widget.field.value && !_focus.hasFocus) {
      _text.text = _displayValue(widget.field);
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  static String _displayValue(CheckField f) => switch (f.kind) {
    CheckFieldKind.text => (f.value ?? '').toString(),
    CheckFieldKind.number => (f.value ?? '').toString(),
    CheckFieldKind.color => _hex(f.value),
    CheckFieldKind.toggle => (f.value == true) ? '开' : '关',
    CheckFieldKind.select => (f.value ?? '').toString(),
    CheckFieldKind.readOnly => (f.value ?? '').toString(),
  };

  static String _hex(Object? v) {
    if (v is int) {
      final int rgb = v & 0xFFFFFF;
      return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
    }
    return (v ?? '').toString();
  }

  void _commitText() {
    final CheckField f = widget.field;
    if (f.kind == CheckFieldKind.number) {
      final num? parsed = num.tryParse(_text.text.trim());
      if (parsed == null) return;
      final num clamped = _clamp(parsed, f.min, f.max);
      if (clamped != f.value) widget.onApply(clamped);
      return;
    }
    if (f.kind == CheckFieldKind.text) {
      final String next = _text.text.trim();
      if (next != (f.value ?? '').toString()) widget.onApply(next);
    }
  }

  static num _clamp(num v, num? min, num? max) {
    num out = v;
    if (min != null && out < min) out = min;
    if (max != null && out > max) out = max;
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final NonPalette p = context.palette;
    final CheckField f = widget.field;
    final bool editable =
        f.enabled && f.kind != CheckFieldKind.readOnly && !widget.busy;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NonSpace.md,
        vertical: NonSpace.xs,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(
              f.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NonType.of(NonType.caption, color: p.ink3),
            ),
          ),
          const SizedBox(width: NonSpace.sm),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _editor(context, p, f, editable),
            ),
          ),
          if (f.unit.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: NonSpace.xs),
              child: Text(
                f.unit,
                style: NonType.of(NonType.micro, color: p.ink4),
              ),
            ),
        ],
      ),
    );
  }

  Widget _editor(
    BuildContext context,
    NonPalette p,
    CheckField f,
    bool editable,
  ) {
    switch (f.kind) {
      case CheckFieldKind.readOnly:
        return Text(
          _displayValue(f),
          key: ValueKey('check-value:${f.key}'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: NonType.of(NonType.body, color: p.ink2),
        );
      case CheckFieldKind.toggle:
        return Align(
          alignment: Alignment.centerLeft,
          child: Switch(
            key: ValueKey('check-toggle:${f.key}'),
            value: f.value == true,
            onChanged: editable
                ? (bool v) => widget.onApply(v)
                : null,
          ),
        );
      case CheckFieldKind.select:
        if (f.options.isEmpty) {
          return Text(
            _displayValue(f),
            style: NonType.of(NonType.body, color: p.ink2),
          );
        }
        return DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            key: ValueKey('check-select:${f.key}'),
            value: f.options.contains(f.value) ? f.value as String : null,
            hint: Text(
              '选择',
              style: NonType.of(NonType.caption, color: p.ink3),
            ),
            isDense: true,
            style: NonType.of(NonType.body, color: p.ink2),
            onChanged: editable
                ? (String? v) {
                    if (v != null) widget.onApply(v);
                  }
                : null,
            items: <DropdownMenuItem<String>>[
              for (final String o in f.options)
                DropdownMenuItem<String>(value: o, child: Text(o)),
            ],
          ),
        );
      case CheckFieldKind.color:
        return InkWell(
          key: ValueKey('check-color:${f.key}'),
          onTap: editable ? () => _pickColor(context, f) : null,
          borderRadius: BorderRadius.circular(NonRadius.sm),
          child: Row(
            children: <Widget>[
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: Color(f.value is int ? f.value as int : 0xFF888888),
                  borderRadius: BorderRadius.circular(NonRadius.sm),
                  border: Border.all(color: p.line),
                ),
              ),
              const SizedBox(width: NonSpace.sm),
              Text(
                _hex(f.value),
                style: NonType.of(NonType.body, color: p.ink2),
              ),
            ],
          ),
        );
      case CheckFieldKind.number:
      case CheckFieldKind.text:
        return SizedBox(
          height: NonType.body + 16,
          child: TextField(
            key: ValueKey('check-input:${f.key}'),
            controller: _text,
            focusNode: _focus,
            enabled: editable,
            keyboardType: f.kind == CheckFieldKind.number
                ? const TextInputType.numberWithOptions(decimal: true, signed: true)
                : TextInputType.text,
            style: NonType.of(NonType.body, color: p.ink2),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: NonSpace.sm,
                vertical: NonSpace.xs,
              ),
              filled: true,
              fillColor: p.panel2,
              hintText: f.hint.isEmpty ? null : f.hint,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(NonRadius.sm),
                borderSide: BorderSide(color: p.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(NonRadius.sm),
                borderSide: BorderSide(color: p.line),
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(NonRadius.sm),
                borderSide: BorderSide(color: p.line),
              ),
            ),
            onSubmitted: (_) => _commitText(),
          ),
        );
    }
  }

  Future<void> _pickColor(BuildContext context, CheckField f) async {
    final List<int> swatches = <int>[
      0xFF9A8C7A,
      0xFFC9A06A,
      0xFFE8D8B0,
      0xFF66CCFF,
      0xFF9B8CFF,
      0xFF34D399,
      0xFFFFB42D,
      0xFFFF5F7E,
      0xFF202430,
      0xFFF0F2F8,
    ];
    final int? picked = await showDialog<int>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(
          '选择颜色',
          style: NonType.of(NonType.subtitle, color: context.palette.ink),
        ),
        content: Wrap(
          spacing: NonSpace.sm,
          runSpacing: NonSpace.sm,
          children: <Widget>[
            for (final int c in swatches)
              InkWell(
                key: ValueKey('check-swatch:${c.toRadixString(16)}'),
                onTap: () => Navigator.of(context).pop(c),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Color(c),
                    borderRadius: BorderRadius.circular(NonRadius.sm),
                    border: Border.all(color: context.palette.line),
                  ),
                ),
              ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (picked != null) widget.onApply(picked);
  }
}
