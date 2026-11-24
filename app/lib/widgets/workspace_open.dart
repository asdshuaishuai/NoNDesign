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
import 'three_workspace.dart';
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

/// 进音乐工作台：项目由工作台自己的项目库列表切换（顶栏菜单暂不列音乐项目）。
void openMusicWorkspace(AppStore store) {
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
  }
}
