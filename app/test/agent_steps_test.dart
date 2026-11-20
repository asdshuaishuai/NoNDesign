// 无限步骤设定（2026-11-20）：
//
// 「无限」用一个远高于真实会话的哨兵值表达（agentUnlimitedSteps），
// 而不是 0/负数——ai_sdk 的 maxSteps=0 等于不执行。这里锚定三件事：
// 1. 旧存档没有 unlimitedSteps 字段时默认关闭；
// 2. 开关与数字一起往返持久化，数字作为关闭后的回退值不丢；
// 3. 普通步数仍受 4..600 的 server 语义约束，哨兵值原样放行。
import 'package:flutter_test/flutter_test.dart';

import 'package:nondesign/core/models.dart';

void main() {
  test('旧存档缺少 unlimitedSteps 时默认关闭', () {
    final settings = AppSettings.fromJson(const <String, dynamic>{'maxSteps': 120});
    expect(settings.unlimitedSteps, isFalse);
    expect(settings.effectiveMaxSteps, 120);
  });

  test('无限步骤与回退步数一起往返持久化', () {
    final settings = AppSettings(maxSteps: 320, unlimitedSteps: true);
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.unlimitedSteps, isTrue);
    expect(restored.maxSteps, 320);
    expect(restored.effectiveMaxSteps, agentUnlimitedSteps);
  });

  test('普通步数沿用 4..600，无限哨兵原样放行', () {
    expect(agentStepBudget(3), 4);
    expect(agentStepBudget(300), 300);
    expect(agentStepBudget(601), 600);
    expect(agentStepBudget(agentUnlimitedSteps), agentUnlimitedSteps);
  });
}
