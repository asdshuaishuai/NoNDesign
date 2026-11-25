/// 工作台切换的唯一入口（用户裁决 2026-11-19）。
///
/// 规则：**一个项目只对应它自己的工作台类型，切换工作台 = 切换项目**。
/// 项目内部不允许再摆一排「主页/设计/3D/视频/热应用」的切换条；所有打开
/// 产物/项目的入口（顶栏项目菜单、主页作品集、最近项目、艺术架）都经这里，
/// 避免每处各写一份「设置开局全局 + setView」。
library;

import '../core/portfolio_entries.dart';
import '../core/store.dart';
import 'hotapp_workspace.dart';
import 'music_workspace.dart';
import 'three_workspace.dart';
import 'video3d_workspace.dart';
import 'video_workspace.dart';

/// 打开一个已有 3D 场景：3D 工作台在 initState 消费 `threeLoadOnOpen`。
void openThreeScene(AppStore store, String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return;
  threeLoadOnOpen = trimmed;
  store.setView('plugin:three');
}

/// 进 3D 工作台新建场景（不指定项目）：清掉当前项目名，工作台落空态套件面，
/// 由用户选套件或描述需求开新场景。
void newThreeScene(AppStore store) {
  store.setThreeProjectName('');
  store.setView('plugin:three');
}

/// 打开一个已有热应用：热应用工作台在 initState 消费 `hotAppLoadOnOpen`。
void openHotApp(AppStore store, String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return;
  hotAppLoadOnOpen = trimmed;
  store.setView('plugin:hotapp');
}

/// 进热应用工作台新建/导入应用（不指定应用）。
void newHotApp(AppStore store) {
  store.setHotApp('');
  store.setView('plugin:hotapp');
}

/// 进视频工作台。视频是代码动画工作台：没有独立的项目文件，视频文档本身
/// 就是它的「项目」（示例/动效合成短片在 store 里续接）。
void openVideoWorkspace(AppStore store) {
  store.setView('plugin:video');
}

/// 进 3D 视频工作台。
///
/// 3D 视频项目由工作台自己的项目库列表切换；传了 [name] 时把项目名经
/// `video3dLoadOnOpen` 一次性通道交给工作台（initState 消费）。不传 [name]
/// 则保持「列表首项」逻辑。已有项目的场景/镜头编辑仍未接线；工作台只读
/// 预览，另提供「新建最小项目」入口。
void openVideo3dWorkspace(AppStore store, [String? name]) {
  final String trimmed = (name ?? '').trim();
  // 普通打开一律清掉「落新建空态」标记，避免上一次的请求残留。
  video3dNewOnOpen = false;
  video3dLoadOnOpen = trimmed.isEmpty ? null : trimmed;
  store.setView('plugin:video3d');
}

/// 进 3D 视频工作台并落**新建空态**（顶栏「新建 3D 视频」用）。
///
/// 不自动打开列表首项；空态里的「新建 3D 视频」按钮拉起小对话框。已经在
/// 3D 视频工作台里时是无操作——用工作台自己的头部/列表「+」新建，避免一次
/// 性通道残留在下一个挂载实例上。
void newVideo3dProject(AppStore store) {
  if (store.view == 'plugin:video3d') return;
  video3dLoadOnOpen = null;
  video3dNewOnOpen = true;
  store.setView('plugin:video3d');
}

/// 进音乐工作台。
///
/// 音乐项目由工作台自己的项目库列表切换；传了 [name] 时把项目名经
/// `musicLoadOnOpen` 一次性通道交给工作台（initState 消费），并把 store 的
/// 当前音乐项目名换成它，顶栏「音乐」分区才能标出「当前」。不传 [name] 则
/// 保持原有「列表首项」逻辑；已在音乐工作台里时是无操作（不打断当前项目）。
void openMusicWorkspace(AppStore store, [String? name]) {
  final trimmed = (name ?? '').trim();
  if (trimmed.isEmpty) {
    if (store.view == 'plugin:music') return;
    musicLoadOnOpen = null;
    musicProjectSwitch.value = null;
    store.setMusicProjectName('');
  } else {
    musicLoadOnOpen = trimmed; // 新挂载的工作台在 initState 消费
    musicProjectSwitch.value = MusicProjectSwitch(trimmed); // 已挂载的工作台直接切
    store.setMusicProjectName(trimmed);
  }
  store.setView('plugin:music');
}

/// 按作品集条目的类型打开对应工作台（主页作品集 / 艺术架共用）。
void openPortfolioEntry(AppStore store, PortfolioEntry entry) {
  switch (entry.kind) {
    case 'hotapp':
      openHotApp(store, entry.ref);
    case 'three':
      openThreeScene(store, entry.ref);
    case 'video':
      videoLoadOnOpen = entry.path ?? entry.ref;
      store.setView('plugin:video');
    case 'video3d':
      // 作品集里的 3D 视频项目按项目名打开；写一次性通道 + 切视图，与顶栏
      // 「3D 视频」分区同一条路由（不在这里另写一份项目读取/预览逻辑）。
      openVideo3dWorkspace(store, entry.ref);
    case 'music':
      openMusicWorkspace(store, entry.ref);
  }
}
