import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:nondesign/core/workspace_stage.dart';

void main() {
  test('3D v2 工具事件 → 阶段线 + 确定性门结果卡数据面', () {
    final store = AppStore(toasts: ToastService(autoDismiss: false));
    store.applyThreeWorkspaceEvent('migrate', <String, dynamic>{
      'ok': true,
      'already_migrated': false,
    });
    store.applyThreeWorkspaceEvent('plan_validate', <String, dynamic>{
      'ok': true,
      'valid': true,
    });
    store.applyThreeWorkspaceEvent('measure', <String, dynamic>{
      'ok': true,
      'part_count': 3,
    });
    store.applyThreeWorkspaceEvent('check', <String, dynamic>{
      'ok': true,
      'verdict': 'ERROR',
      'caps': <String, double>{'floating': 0.6},
      'gates': <dynamic>[
        <String, Object?>{'id': 'connectivity', 'verdict': 'ERROR'},
        <String, Object?>{'id': 'contract', 'verdict': 'PASS'},
      ],
      'fix_hints': <String>['connectivity: 沿 y 平移 -0.050 m 落地'],
    });
    expect(store.threePipelineStages.map((s) => s.id).toList(), <String>[
      'migrate',
      'plan',
      'measure',
      'check',
    ]);
    expect(
      store.threePipelineStages.every(
        (s) => s.state == WorkspaceStageState.done,
      ),
      isTrue,
    );
    expect(store.threeGateVerdict, 'ERROR');
    expect(store.threeGateGateCount, 2);
    expect(store.threeGateFixHints.single, contains('平移'));
    expect(store.threeGateError, isNull);

    store.dismissThreeGateResult();
    expect(store.threePipelineStages, isEmpty);
    expect(store.threeGateVerdict, isNull);
    expect(store.threeGateFixHints, isEmpty);
  });

  test('工具失败 → 阶段标 failed + 显性错误，不冒充通过', () {
    final store = AppStore(toasts: ToastService(autoDismiss: false));
    store.applyThreeWorkspaceEvent('check', <String, dynamic>{
      'ok': false,
      'error': 'three_measure_missing',
      'message': '还没有测量：先让预览页跑起来再跑门',
    });
    expect(store.threePipelineStages.single.state, WorkspaceStageState.failed);
    expect(store.threeGateError, '还没有测量：先让预览页跑起来再跑门');
    expect(store.threeGateVerdict, isNull);
  });
}
