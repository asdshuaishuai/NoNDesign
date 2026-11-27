// 工作区工具产物认领锚点：NaN 在工作区 run 里成功调用 three_create /
// hotapp_generate / video_create 之后，`AppStore` 必须把「当前项目」写进设置
// 并 notifyListeners——各工作台监听 store 才能自动切到新项目。
//
// 没有这一步的真实用户可见面是：run 结束提示「3D/视频/热应用已更新」，
// 而工作台里**没有东西**（列表不刷新、不切换、预览空白）。
//
// 驱动方式：`debugHandleAgentEvent` 直接喂工具事件（不启动 run、不打网络）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nondesign/core/app_paths.dart';
import 'package:nondesign/core/project_service.dart';
import 'package:nondesign/core/store.dart';
import 'package:nondesign/core/toast_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late AppStore store;
  var notifies = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    temp = Directory.systemTemp.createTempSync('workspace-adopt-');
    AppPaths.projectsRootOverride = temp;
    store = AppStore(
      projects: ProjectService(
        root: () async => Directory('${temp.path}/projects'),
      ),
      toasts: ToastService(autoDismiss: false),
    );
    store.recoveryDir = '${temp.path}/recovery';
    store.settingsMirrorDir = '${temp.path}/settings';
    notifies = 0;
    store.addListener(() => notifies++);
  });

  tearDown(() {
    AppPaths.projectsRootOverride = null;
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> start(String tool, Map<String, dynamic> args) =>
      store.debugHandleAgentEvent(<String, dynamic>{
        'type': 'tool_start',
        'tool': tool,
        'args': args,
      });

  Future<void> end(String tool, {bool ok = true}) =>
      store.debugHandleAgentEvent(<String, dynamic>{
        'type': 'tool_end',
        'tool': tool,
        'ok': ok,
      });

  group('工作区工具产物 → 工作台当前项目', () {
    test('three_create 成功 → threeProjectName 认领 + notify', () async {
      await start('three_create', <String, dynamic>{
        'name': 'island',
        'brief': '浮岛',
      });
      await end('three_create');
      expect(store.settings.threeProjectName, 'island');
      expect(notifies, greaterThan(0), reason: '工作台靠 notifyListeners 才能刷新');
    });

    test('three_create 失败 → 不认领（失败的项目不存在）', () async {
      await start('three_create', <String, dynamic>{
        'name': 'ghost',
        'brief': 'x',
      });
      await end('three_create', ok: false);
      expect(store.settings.threeProjectName, isEmpty);
    });

    test('three_pass 成功 → 仍是该项目的当前项目（层级推进不丢选中）', () async {
      await start('three_create', <String, dynamic>{
        'name': 'island',
        'brief': 'x',
      });
      await end('three_create');
      await start('three_pass', <String, dynamic>{'name': 'island'});
      await end('three_pass');
      expect(store.settings.threeProjectName, 'island');
    });

    test('hotapp_generate 成功 → hotappApp 认领', () async {
      await start('hotapp_generate', <String, dynamic>{
        'name': 'counter',
        'brief': '计数器',
      });
      await end('hotapp_generate');
      expect(store.settings.hotappApp, 'counter');
    });

    test('设计验证原型不是热应用产物 → 不认领 hotappApp', () async {
      store.settings.hotappApp = 'keep-me';
      await start('design_verify_prototype', <String, dynamic>{});
      await end('design_verify_prototype');
      expect(store.settings.hotappApp, 'keep-me');
    });

    test('video_create 成功 → videoProjectName 认领（工作台切到新片）', () async {
      await start('video_create', <String, dynamic>{'name': 'tagline-6s'});
      await end('video_create');
      expect(store.settings.videoProjectName, 'tagline-6s');
    });

    test('video_review 不是产出工具 → 不动当前视频项目', () async {
      store.settings.videoProjectName = 'keep-me';
      await start('video_review', <String, dynamic>{
        'timeline': <String, dynamic>{},
      });
      await end('video_review');
      expect(store.settings.videoProjectName, 'keep-me');
    });

    test('video3d_create 成功 → video3dProjectName 认领（工作台切到新项目）', () async {
      await start('video3d_create', <String, dynamic>{'name': 'stage'});
      await end('video3d_create');
      expect(store.video3dProjectName, 'stage');
    });

    test('video3d_status 不是产出工具 → 不动当前 3D 视频项目', () async {
      store.video3dProjectName = 'keep-me';
      await start('video3d_status', <String, dynamic>{'name': 'other'});
      await end('video3d_status');
      expect(store.video3dProjectName, 'keep-me');
    });

    test('无 name 参数的调用不认领（读类工具不抢当前项目）', () async {
      await start('three_list', <String, dynamic>{});
      await end('three_list');
      expect(store.settings.threeProjectName, isEmpty);
    });
  });
}
