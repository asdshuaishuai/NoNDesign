/// 设计模块的项目内「验证原型」：把画布原型派生为自包含 HTML + manifest，
/// 并做确定性覆盖验证（每屏 `data-screen`、每条连线 `data-nav`）。
///
/// 与旧「由原型生成热应用」的区别：这里**不调用模型**、不生成新应用，产物是
/// 设计项目自身的一个派生视图（存在 `.ddp` 的 docs 元数据里），服务于
/// `creative-workbench` 的「世界必须可验证」原则。契约见
/// `docs/design-contract.md` 与 `docs/skills/creative-workbench/references/judging.md`。
library;

import 'dart:convert';

/// 原型里的一屏（来自引擎 render 信封的画板：标题/尺寸/引擎自渲染 SVG）。
final class DesignPrototypeScreen {
  const DesignPrototypeScreen({
    required this.id,
    required this.title,
    required this.width,
    required this.height,
    this.svg = '',
  });

  final String id;
  final String title;
  final double width;
  final double height;

  /// 引擎自渲染 SVG（内容层唯一真源）；空 = 旧信封，退回占位框。
  final String svg;

  Map<String, Object?> toManifestJson() => <String, Object?>{
    'id': id,
    'title': title,
    'width': width,
    'height': height,
  };
}

/// 原型里的一条跳转（`from` 屏 → `to` 屏）。
final class DesignPrototypeFlow {
  const DesignPrototypeFlow({
    required this.from,
    required this.to,
    this.trigger = '',
  });

  final String from;
  final String to;

  /// 引擎 trigger（`tap:<node>` 等）；只作诊断，不参与覆盖门。
  final String trigger;

  Map<String, Object?> toManifestJson() => <String, Object?>{
    'from': from,
    'to': to,
    if (trigger.isNotEmpty) 'trigger': trigger,
  };
}

/// 一条确定性检查（覆盖门）。
final class DesignPrototypeCheck {
  const DesignPrototypeCheck(this.id, this.ok, this.detail);

  final String id;
  final bool ok;
  final String detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'ok': ok,
    'detail': detail,
  };
}

/// 项目内验证原型的落盘形状（序列化进 `.ddp` 的 docs 元数据）。
final class DesignPrototypeDocument {
  const DesignPrototypeDocument({
    required this.html,
    required this.manifest,
    this.verified = false,
    this.checks = const <DesignPrototypeCheck>[],
    this.builtAt = '',
  });

  final String html;
  final Map<String, Object?> manifest;
  final bool verified;
  final List<DesignPrototypeCheck> checks;
  final String builtAt;

  static const String schema = 'nan.design.prototype/1';

  Map<String, Object?> toProjectMetadata() => <String, Object?>{
    'schema': schema,
    'html': html,
    'manifest': manifest,
    'verified': verified,
    'checks': checks
        .map((DesignPrototypeCheck c) => c.toJson())
        .toList(growable: false),
    'builtAt': builtAt,
  };

  /// 从项目 docs 元数据恢复；形状不合法返回 null（不阻塞项目打开）。
  static DesignPrototypeDocument? fromProjectMetadata(Object? raw) {
    if (raw is! Map) return null;
    final html = raw['html'];
    final manifest = raw['manifest'];
    if (html is! String || html.trim().isEmpty || manifest is! Map) return null;
    final checksRaw = raw['checks'];
    final checks = <DesignPrototypeCheck>[];
    if (checksRaw is List) {
      for (final item in checksRaw) {
        if (item is! Map) continue;
        final id = item['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        checks.add(
          DesignPrototypeCheck(
            id,
            item['ok'] == true,
            item['detail']?.toString() ?? '',
          ),
        );
      }
    }
    return DesignPrototypeDocument(
      html: html,
      manifest: Map<String, Object?>.from(manifest.cast<Object?, Object?>()),
      verified: raw['verified'] == true,
      checks: checks,
      builtAt: raw['builtAt']?.toString() ?? '',
    );
  }
}

/// 验证原型：构建 + 覆盖校验（纯函数，无 IO / 无模型）。
abstract final class DesignPrototypeBuilder {
  const DesignPrototypeBuilder._();

  /// 构建自包含 HTML。约束（design-contract）：
  /// * 每屏 `<section data-screen="<id>">`；
  /// * 每条连线在 `from` 段内 `<… data-nav="<to>">`；
  /// * 零网络引用（CSS/JS/图全内联）；manifest 内嵌为 JSON（`<` 已转义）；
  /// * 只显示入口屏，点击 `data-nav` 切屏。
  static DesignPrototypeDocument build({
    required String projectName,
    required String entry,
    required List<DesignPrototypeScreen> screens,
    required List<DesignPrototypeFlow> flows,
    Map<String, String> palette = const <String, String>{},
    String builtAt = '',
  }) {
    final covered = <String>[];
    final sections = StringBuffer();
    for (final screen in screens) {
      covered.add(screen.id);
      final flowsFrom = flows.where(
        (DesignPrototypeFlow f) => f.from == screen.id,
      );
      final nav = StringBuffer();
      for (final flow in flowsFrom) {
        nav.write(
          '<button class="nav" type="button" data-nav="${_escapeAttr(flow.to)}">'
          '前往 ${_escapeText(_titleOf(screens, flow.to))}</button>',
        );
      }
      final art = screen.svg.trim().isEmpty
          ? '<div class="placeholder">${_escapeText(screen.title)}</div>'
          : screen.svg;
      sections.write(
        '<section class="screen" data-screen="${_escapeAttr(screen.id)}" '
        'data-title="${_escapeAttr(screen.title)}">'
        '<div class="art">$art</div>'
        '${nav.isEmpty ? '' : '<nav class="navs">$nav</nav>'}'
        '</section>',
      );
    }
    final manifest = <String, Object?>{
      'schema': DesignPrototypeDocument.schema,
      'project': projectName,
      'entry': entry,
      'screens': screens
          .map((DesignPrototypeScreen s) => s.toManifestJson())
          .toList(growable: false),
      'flows': flows
          .map((DesignPrototypeFlow f) => f.toManifestJson())
          .toList(growable: false),
      if (builtAt.isNotEmpty) 'builtAt': builtAt,
    };
    final manifestJson = jsonEncode(manifest)
        .replaceAll('<', r'\u003c')
        .replaceAll('>', r'\u003e')
        .replaceAll('&', r'\u0026');
    final bg = palette['background'] ?? '#f7f8fa';
    final panel = palette['surface'] ?? '#ffffff';
    final ink = palette['text'] ?? '#14161a';
    final accent = palette['primary'] ?? '#6e7bff';
    final muted = palette['muted'] ?? '#6b7280';
    final html =
        '<!doctype html>\n'
        '<html lang="zh-CN"><head><meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        '<title>${_escapeText(projectName)} · 验证原型</title>\n'
        '<style>\n'
        ':root{color-scheme:light}*{box-sizing:border-box}\n'
        'body{margin:0;background:$bg;color:$ink;font-family:Inter,system-ui,sans-serif}\n'
        'header{display:flex;align-items:center;gap:12px;padding:12px 16px;background:$panel;'
        'border-bottom:1px solid rgba(20,22,26,.08);position:sticky;top:0;z-index:2}\n'
        'header b{font-size:14px}header span{font-size:12px;color:$muted}\n'
        'main{display:flex;justify-content:center;padding:16px}\n'
        '.screen{display:none;background:$panel;border-radius:12px;overflow:hidden;'
        'box-shadow:0 8px 30px rgba(20,22,26,.08);width:100%;max-width:960px}\n'
        '.screen[data-active="true"]{display:block}\n'
        '.art{width:100%;overflow:hidden}.art svg{display:block;width:100%;height:auto}\n'
        '.placeholder{padding:80px 24px;text-align:center;color:$muted;font-size:13px}\n'
        '.navs{display:flex;flex-wrap:wrap;gap:8px;padding:12px 16px;'
        'border-top:1px solid rgba(20,22,26,.08)}\n'
        '.nav{border:1px solid rgba(20,22,26,.12);background:$panel;color:$ink;'
        'border-radius:999px;padding:6px 12px;font-size:12px;cursor:pointer}\n'
        '.nav:hover{border-color:$accent;color:$accent}\n'
        '</style></head><body>\n'
        '<header><b>${_escapeText(projectName)}</b><span id="screen-label"></span></header>\n'
        '<main id="stage">$sections</main>\n'
        '<script type="application/json" id="nan-prototype-manifest">$manifestJson</script>\n'
        '<script>\n'
        '(function(){\n'
        'var manifest=JSON.parse(document.getElementById("nan-prototype-manifest").textContent);\n'
        'var screens=Array.prototype.slice.call(document.querySelectorAll(".screen"));\n'
        'function show(id){var hit=null;for(var i=0;i<screens.length;i++){'
        'if(screens[i].getAttribute("data-screen")===id)hit=screens[i];}\n'
        'if(!hit)return;for(var i=0;i<screens.length;i++){'
        'screens[i].setAttribute("data-active",screens[i]===hit?"true":"false");}\n'
        'var label=document.getElementById("screen-label");'
        'label.textContent=hit.getAttribute("data-title")||hit.getAttribute("data-screen");}\n'
        'document.addEventListener("click",function(e){var t=e.target;'
        'while(t&&t!==document){if(t.hasAttribute&&t.hasAttribute("data-nav")){'
        'e.preventDefault();show(t.getAttribute("data-nav"));return;}t=t.parentNode;}});\n'
        'var initial=manifest.entry||manifest.screens[0].id;show(initial);\n'
        'window.__nanPrototype={manifest:manifest,show:show};\n'
        '})();\n'
        '</script></body></html>\n';
    final checks = verify(html, screens, flows, entry: entry);
    return DesignPrototypeDocument(
      html: html,
      manifest: manifest,
      verified: checks.every((DesignPrototypeCheck check) => check.ok),
      checks: checks,
      builtAt: builtAt,
    );
  }

  /// 确定性覆盖验证。不跑模型、不做视觉判断：字节级检查。
  static List<DesignPrototypeCheck> verify(
    String html,
    List<DesignPrototypeScreen> screens,
    List<DesignPrototypeFlow> flows, {
    String entry = '',
  }) {
    final checks = <DesignPrototypeCheck>[];
    final marks = <String, int>{};
    for (final screen in screens) {
      final pattern = RegExp('data-screen="${RegExp.escape(screen.id)}"');
      final match = pattern.firstMatch(html);
      if (match != null) marks[screen.id] = match.start;
      checks.add(
        DesignPrototypeCheck(
          'screen_${screen.id}',
          match != null,
          match != null ? '画板 ${screen.id} 已实现' : '缺少画板 ${screen.id}',
        ),
      );
    }
    if (entry.isNotEmpty) {
      checks.add(
        DesignPrototypeCheck(
          'entry_screen',
          marks.containsKey(entry),
          marks.containsKey(entry) ? '入口画板 $entry 在场' : '入口画板 $entry 缺失',
        ),
      );
    }
    final ordered = marks.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    int sectionEnd(int pos) {
      for (final MapEntry<String, int> item in ordered) {
        if (item.value > pos) return item.value;
      }
      return html.length;
    }

    for (final flow in flows) {
      final fromPos = marks[flow.from];
      var ok = false;
      var detail = '跳转 ${flow.from} → ${flow.to}：来源画板不存在';
      if (fromPos != null) {
        final span = html.substring(fromPos, sectionEnd(fromPos));
        ok = span.contains('data-nav="${flow.to}"');
        detail = ok
            ? '跳转 ${flow.from} → ${flow.to} 已实现'
            : '跳转 ${flow.from} → ${flow.to} 缺少连线（data-nav）';
      }
      checks.add(
        DesignPrototypeCheck('flow_${flow.from}_${flow.to}', ok, detail),
      );
    }
    // 只查真正的资源引用；`xmlns="http://www.w3.org/2000/svg"` 是命名空间，
    // 不是网络请求。覆盖：src/href/url()/@import 指向 http(s):// 或 //。
    final external = RegExp(
      '(?:src|href)\\s*=\\s*["\']\\s*(?:https?:)?//'
      '|url\\(\\s*["\']?(?:https?:)?//'
      '|@import\\s+["\'](?:https?:)?//',
      caseSensitive: false,
    );
    final externalRefs = external.hasMatch(html);
    checks.add(
      DesignPrototypeCheck(
        'offline',
        !externalRefs,
        externalRefs ? '原型包含网络引用（必须自包含）' : '原型零网络引用',
      ),
    );
    checks.add(
      DesignPrototypeCheck(
        'self_contained_manifest',
        html.contains('nan-prototype-manifest'),
        'manifest 内嵌',
      ),
    );
    return checks;
  }

  static String _titleOf(List<DesignPrototypeScreen> screens, String id) {
    for (final screen in screens) {
      if (screen.id == id) return screen.title.isEmpty ? id : screen.title;
    }
    return id;
  }

  static String _escapeText(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _escapeAttr(String value) => _escapeText(value);
}
