import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/creative/creative_skill.dart';
import 'package:nondesign/core/dart_agent.dart';

void main() {
  test('设计 run 注入统一创作 skill：事实源/门/盲评/交付纪律在场', () {
    final instructions = composeDartInstructions(
      mode: 'build',
      projectMap: 'MBT',
      designSpec: const <String, dynamic>{},
      docs: const <String, dynamic>{},
      templates: const <dynamic>[],
      components: const <dynamic>[],
      hasWorkspaceTools: true,
    );
    expect(instructions, contains('CREATIVE WORKBENCH'));
    expect(instructions, contains('代码是事实源'));
    expect(instructions, contains('acceptance'));
    expect(instructions, contains('门'));
    expect(instructions, contains('生成者与评审者分离'));
    expect(instructions, contains('最佳轮'));
    expect(instructions, contains('不要给自己打分'));
  });

  test('workspace run 注入核心纪律 + 本工作台纪律（不塞设计文档面）', () {
    final instructions = composeDartInstructions(
      mode: 'workspace',
      projectMap: '',
      designSpec: const <String, dynamic>{},
      docs: const <String, dynamic>{},
      templates: const <dynamic>[],
      components: const <dynamic>[],
      hasWorkspaceTools: true,
      workspaceHint: 'three',
    );
    expect(instructions, contains('WORKSPACE DISCIPLINE (three)'));
    expect(instructions, contains('代码是事实源'));
    expect(instructions, isNot(contains('## PROJECT MAP')));
    expect(instructions, isNot(contains('## DESIGN SPEC')));
    // 工具清单按工作台收窄，不再列视频/热应用工具。
    expect(instructions, contains('three_list'));
    expect(instructions, isNot(contains('video_list')));
    expect(instructions, isNot(contains('hotapp_list')));
  });

  test('蒸馏 skill 与权威文档一致的关键词在 Dart 侧可断言', () {
    expect(creativeWorkbenchCore, contains('spec'));
    expect(creativeWorkbenchCore, contains('plan'));
    expect(creativeWorkbenchCore, contains('门'));
    expect(creativeSkillForWorkspace('video'), contains('video'));
  });
}
