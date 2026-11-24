/// `scene.json`（scene 模式事实源）v1：解析、确定性校验、编译成 `src/scene.js`。
///
/// 契约见 `docs/three-contract.md` §2/§3：scene 模式里 `scene.json` 是唯一事实源，
/// 编译产物 `src/scene.js` 只是派生；节点 ≤200；id 稳定、父子关系合法；
/// 同一份 scene.json 两次编译必须**字节相同**（golden 可锚定）。
library;

import '../creative/creative_schema.dart';

/// 一条校验问题（scene 专属；与 creative 契约同形：pointer + code + message）。
final class ThreeSceneIssue {
  const ThreeSceneIssue(
    this.pointer,
    this.code,
    this.message, {
    this.blocking = true,
  });

  final String pointer;
  final String code;
  final String message;
  final bool blocking;

  Map<String, Object?> toJson() => <String, Object?>{
    'pointer': pointer,
    'code': code,
    'message': message,
    'blocking': blocking,
  };
}

/// scene.json 里支持的基础几何（v1 只做可程序化校验的图元）。
enum ThreeSceneGeometryType { box, sphere, cylinder, plane }

/// 一个节点：geometry + transform + material + parent。
final class ThreeSceneNode {
  const ThreeSceneNode({
    required this.id,
    required this.type,
    required this.size,
    this.segments = const <int>[24, 16],
    this.position = const <double>[0, 0, 0],
    this.rotation = const <double>[0, 0, 0],
    this.scale = const <double>[1, 1, 1],
    this.color = '#c9a06a',
    this.roughness = 0.8,
    this.metalness = 0.1,
    this.parent,
  });

  final String id;
  final ThreeSceneGeometryType type;

  /// box: [w,h,d]；sphere: [r, r, r]；cylinder: [rTop, rBottom, h]；plane: [w, d, 0]。
  final List<double> size;
  final List<int> segments;
  final List<double> position;
  final List<double> rotation;

  /// 欧拉角（度，绕 x/y/z）。
  final List<double> scale;
  final String color;
  final double roughness;
  final double metalness;
  final String? parent;
}

/// 校验 + 编译的纯函数入口（无 IO；service 层负责读写）。
final class ThreeSceneDocument {
  const ThreeSceneDocument({
    required this.nodes,
    this.cameraPosition,
    this.cameraTarget,
    this.background,
  });

  final List<ThreeSceneNode> nodes;
  final List<double>? cameraPosition;
  final List<double>? cameraTarget;
  final String? background;

  static const int maxNodes = 200;

  /// 解析 + 校验；问题全部收集，不 fail-fast。
  static ({ThreeSceneDocument? document, List<ThreeSceneIssue> issues}) parse(
    Object? raw,
  ) {
    final List<ThreeSceneIssue> issues = <ThreeSceneIssue>[];
    if (raw is! Map) {
      return (
        document: null,
        issues: <ThreeSceneIssue>[
          const ThreeSceneIssue(
            '',
            'scene_not_object',
            'scene.json 必须是 JSON 对象',
          ),
        ],
      );
    }
    if (creativeInt(raw['v']) != 1) {
      issues.add(
        const ThreeSceneIssue('/v', 'scene_unsupported_version', 'v1 只认 v=1'),
      );
    }
    final List<ThreeSceneNode> nodes = <ThreeSceneNode>[];
    final Set<String> ids = <String>{};
    final Map<String, String?> parents = <String, String?>{};
    final Object? rawNodes = raw['nodes'];
    if (rawNodes is! List) {
      issues.add(
        const ThreeSceneIssue('/nodes', 'scene_nodes_invalid', 'nodes 必须是数组'),
      );
    } else {
      if (rawNodes.length > maxNodes) {
        issues.add(
          ThreeSceneIssue(
            '/nodes',
            'scene_too_many_nodes',
            '节点 ${rawNodes.length} 超过上限 $maxNodes',
          ),
        );
      }
      for (int i = 0; i < rawNodes.length; i++) {
        final String pointer = '/nodes/$i';
        final Object? item = rawNodes[i];
        if (item is! Map) {
          issues.add(
            ThreeSceneIssue(pointer, 'scene_node_invalid', 'node 必须是对象'),
          );
          continue;
        }
        final String? id = creativeNonEmptyString(item['id']);
        if (id == null || !creativeIsSnakeCase(id)) {
          issues.add(
            ThreeSceneIssue(
              '$pointer/id',
              'scene_node_id_invalid',
              'id 必须是 ASCII snake_case',
            ),
          );
        } else if (!ids.add(id)) {
          issues.add(
            ThreeSceneIssue(
              '$pointer/id',
              'scene_node_id_duplicate',
              '节点 id 重复：$id',
            ),
          );
        }
        final String? typeName = creativeNonEmptyString(item['type']);
        ThreeSceneGeometryType? type;
        for (final ThreeSceneGeometryType value
            in ThreeSceneGeometryType.values) {
          if (value.name == typeName) type = value;
        }
        if (type == null) {
          issues.add(
            ThreeSceneIssue(
              '$pointer/type',
              'scene_geometry_unsupported',
              'type 必须是 ${ThreeSceneGeometryType.values.map((v) => v.name).join('/')}',
            ),
          );
        }
        final List<double> size = _vec(
          item['size'],
          '$pointer/size',
          issues,
          requiredLength: 3,
        );
        if (type != null) {
          final int positiveCount = type == ThreeSceneGeometryType.plane
              ? 2
              : 3;
          for (int axis = 0; axis < positiveCount; axis++) {
            if (size[axis] <= 0) {
              issues.add(
                ThreeSceneIssue(
                  '$pointer/size/$axis',
                  'scene_size_invalid',
                  '尺寸必须为正数（plane 第三维可为 0）',
                ),
              );
            }
          }
        }
        final List<double> position = _vec(
          item['position'],
          '$pointer/position',
          issues,
          optional: true,
        );
        final List<double> rotation = _vec(
          item['rotation'],
          '$pointer/rotation',
          issues,
          optional: true,
        );
        final List<double> scale = _vec(
          item['scale'],
          '$pointer/scale',
          issues,
          optional: true,
          defaultValue: const <double>[1, 1, 1],
        );
        final List<int> segments = _ints(
          item['segments'],
          '$pointer/segments',
          issues,
        );
        final String? color = item['color']?.toString();
        if (color != null && !creativeIsHexColor(color)) {
          issues.add(
            ThreeSceneIssue(
              '$pointer/color',
              'scene_color_invalid',
              'color 必须是 #rrggbb',
            ),
          );
        }
        final double? roughness = creativeFiniteDouble(item['roughness']);
        final double? metalness = creativeFiniteDouble(item['metalness']);
        if (item['roughness'] != null &&
            (roughness == null || roughness < 0 || roughness > 1)) {
          issues.add(
            ThreeSceneIssue(
              '$pointer/roughness',
              'scene_material_invalid',
              'roughness 必须在 0–1',
            ),
          );
        }
        if (item['metalness'] != null &&
            (metalness == null || metalness < 0 || metalness > 1)) {
          issues.add(
            ThreeSceneIssue(
              '$pointer/metalness',
              'scene_material_invalid',
              'metalness 必须在 0–1',
            ),
          );
        }
        String? parent;
        if (item['parent'] != null) {
          parent = creativeNonEmptyString(item['parent']);
          if (parent == null || !creativeIsSnakeCase(parent)) {
            issues.add(
              ThreeSceneIssue(
                '$pointer/parent',
                'scene_parent_invalid',
                'parent 必须是合法 id 或 null',
              ),
            );
          }
        }
        if (id != null && type != null) {
          parents[id] = parent;
          nodes.add(
            ThreeSceneNode(
              id: id,
              type: type,
              size: size,
              segments: segments.isEmpty ? <int>[24, 16] : segments,
              position: position,
              rotation: rotation,
              scale: scale,
              color: color ?? '#c9a06a',
              roughness: roughness ?? 0.8,
              metalness: metalness ?? 0.1,
              parent: parent,
            ),
          );
        }
      }
      for (final MapEntry<String, String?> entry in parents.entries) {
        final String? parent = entry.value;
        if (parent != null && !parents.containsKey(parent)) {
          issues.add(
            ThreeSceneIssue(
              '/nodes/${entry.key}/parent',
              'scene_parent_missing',
              '节点 ${entry.key} 的 parent $parent 不存在',
            ),
          );
        }
        // 环检测：沿 parent 链最多走 nodes.length 步。
        String? cursor = parent;
        int depth = 0;
        while (cursor != null && depth <= parents.length) {
          if (cursor == entry.key) {
            issues.add(
              ThreeSceneIssue(
                '/nodes/${entry.key}/parent',
                'scene_parent_cycle',
                '节点 ${entry.key} 的父子关系成环',
              ),
            );
            break;
          }
          cursor = parents[cursor];
          depth++;
        }
      }
    }
    final List<double>? cameraPosition = raw['camera'] is Map
        ? _vec(
            (raw['camera'] as Map)['position'],
            '/camera/position',
            issues,
            optional: true,
          )
        : null;
    final List<double>? cameraTarget = raw['camera'] is Map
        ? _vec(
            (raw['camera'] as Map)['target'],
            '/camera/target',
            issues,
            optional: true,
          )
        : null;
    final String? background = raw['env'] is Map
        ? creativeNonEmptyString((raw['env'] as Map)['background'])
        : null;
    if (background != null && !creativeIsHexColor(background)) {
      issues.add(
        const ThreeSceneIssue(
          '/env/background',
          'scene_color_invalid',
          'background 必须是 #rrggbb',
        ),
      );
    }
    if (issues.any((issue) => issue.blocking)) {
      return (document: null, issues: issues);
    }
    return (
      document: ThreeSceneDocument(
        nodes: nodes,
        cameraPosition: cameraPosition,
        cameraTarget: cameraTarget,
        background: background,
      ),
      issues: issues,
    );
  }
}

/// 编译成 `src/scene.js`（确定性：相同输入 → 相同字节；无随机/时间）。
String compileThreeScene(ThreeSceneDocument doc) {
  final StringBuffer out = StringBuffer();
  out.writeln(
    '// Generated from scene.json by NaN (deterministic build; do not edit by hand).',
  );
  out.writeln(
    'export default function build(THREE, scene, camera, controls, renderer) {',
  );
  out.writeln('  const nodes = {};');
  out.writeln('  function geometry(node) {');
  out.writeln('    switch (node.type) {');
  out.writeln(
    "      case 'box': return new THREE.BoxGeometry(node.size[0], node.size[1], node.size[2]);",
  );
  out.writeln(
    "      case 'sphere': return new THREE.SphereGeometry(node.size[0], node.segments[0], node.segments[1]);",
  );
  out.writeln(
    "      case 'cylinder': return new THREE.CylinderGeometry(node.size[0], node.size[1], node.size[2], node.segments[0]);",
  );
  out.writeln(
    "      case 'plane': return new THREE.PlaneGeometry(node.size[0], node.size[1]);",
  );
  out.writeln(
    "      default: throw new Error('unsupported geometry: ' + node.type);",
  );
  out.writeln('    }');
  out.writeln('  }');
  out.writeln('  function material(node) {');
  out.writeln('    return new THREE.MeshStandardMaterial({');
  out.writeln('      color: new THREE.Color(node.color),');
  out.writeln('      roughness: node.roughness,');
  out.writeln('      metalness: node.metalness,');
  out.writeln('      name: node.id,');
  out.writeln('    });');
  out.writeln('  }');
  out.writeln('  const defs = [');
  for (final ThreeSceneNode node in doc.nodes) {
    out.writeln('    {');
    out.writeln("      id: '${_js(node.id)}', type: '${node.type.name}',");
    out.writeln(
      '      size: [${_nums(node.size)}], segments: [${node.segments.join(', ')}],',
    );
    out.writeln(
      '      position: [${_nums(node.position)}], rotation: [${_nums(node.rotation)}], '
      'scale: [${_nums(node.scale)}],',
    );
    out.writeln(
      "      color: '${_js(node.color)}', roughness: ${_num(node.roughness)}, "
      'metalness: ${_num(node.metalness)},',
    );
    out.writeln(
      "      parent: ${node.parent == null ? 'null' : "'${_js(node.parent!)}'"},",
    );
    out.writeln('    },');
  }
  out.writeln('  ];');
  out.writeln('  for (const def of defs) {');
  out.writeln('    const node = JSON.parse(JSON.stringify(def));');
  out.writeln(
    '    const mesh = new THREE.Mesh(geometry(node), material(node));',
  );
  out.writeln('    mesh.name = node.id;');
  out.writeln(
    "    mesh.position.set(node.position[0], node.position[1], node.position[2]);",
  );
  out.writeln('    mesh.rotation.set(');
  out.writeln('      THREE.MathUtils.degToRad(node.rotation[0]),');
  out.writeln('      THREE.MathUtils.degToRad(node.rotation[1]),');
  out.writeln('      THREE.MathUtils.degToRad(node.rotation[2]));');
  out.writeln(
    '    mesh.scale.set(node.scale[0], node.scale[1], node.scale[2]);',
  );
  out.writeln('    nodes[node.id] = mesh;');
  out.writeln('  }');
  out.writeln('  for (const def of defs) {');
  out.writeln('    const mesh = nodes[def.id];');
  out.writeln(
    '    if (def.parent) nodes[def.parent].add(mesh); else scene.add(mesh);',
  );
  out.writeln('  }');
  if (doc.cameraPosition != null) {
    out.writeln('  camera.position.set(${_nums(doc.cameraPosition!)});');
  }
  if (doc.cameraTarget != null) {
    out.writeln('  controls.target.set(${_nums(doc.cameraTarget!)});');
    out.writeln('  controls.update();');
  }
  if (doc.background != null) {
    out.writeln(
      "  scene.background = new THREE.Color('${_js(doc.background!)}');",
    );
  }
  out.writeln(
    "  return { metrics: { scene_nodes: ${doc.nodes.length}, source: 'scene.json' } };",
  );
  out.writeln('}');
  return out.toString();
}

List<double> _vec(
  Object? raw,
  String pointer,
  List<ThreeSceneIssue> issues, {
  bool optional = false,
  int requiredLength = 3,
  List<double> defaultValue = const <double>[0, 0, 0],
}) {
  if (raw == null) {
    if (optional) {
      return defaultValue;
    }
    issues.add(ThreeSceneIssue(pointer, 'scene_number_invalid', '缺少数值数组'));
    return defaultValue;
  }
  if (raw is! List || raw.length != requiredLength) {
    issues.add(
      ThreeSceneIssue(
        pointer,
        'scene_number_invalid',
        '必须是 $requiredLength 个数字',
      ),
    );
    return const <double>[0, 0, 0];
  }
  final List<double> out = <double>[];
  for (int i = 0; i < raw.length; i++) {
    final Object? item = raw[i];
    if (item is! num || !item.isFinite) {
      issues.add(
        ThreeSceneIssue('$pointer/$i', 'scene_number_invalid', '必须是有限数字'),
      );
      out.add(0);
    } else {
      out.add(item.toDouble());
    }
  }
  return out;
}

List<int> _ints(Object? raw, String pointer, List<ThreeSceneIssue> issues) {
  if (raw == null) return const <int>[];
  if (raw is! List) {
    issues.add(
      ThreeSceneIssue(pointer, 'scene_number_invalid', 'segments 必须是数组'),
    );
    return const <int>[];
  }
  final List<int> out = <int>[];
  for (int i = 0; i < raw.length; i++) {
    final int? value = creativeInt(raw[i]);
    if (value == null || value <= 0) {
      issues.add(
        ThreeSceneIssue(
          '$pointer/$i',
          'scene_number_invalid',
          'segments 必须是正整数',
        ),
      );
      out.add(1);
    } else {
      out.add(value);
    }
  }
  return out;
}

String _num(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value
      .toStringAsFixed(6)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

String _nums(List<double> values) => values.map(_num).join(', ');

String _js(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll("'", "\\'")
    .replaceAll('\n', '\\n');
