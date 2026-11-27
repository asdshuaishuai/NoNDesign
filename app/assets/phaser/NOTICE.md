# Phaser（vendored，引擎短片运行时）

| 项 | 值 |
| --- | --- |
| 上游 | `phaser`（Phaser Studio Inc. / Richard Davey） |
| 版本 | **4.2.1**（2026-11-28 用户裁决把引擎选型从 Phaser 3 升级到 4.x；本文件是 4.x 首个 vendored 版本） |
| 来源 | npm registry `phaser@4.2.1` 的 `dist/phaser.min.js`（下载后入库；运行时不联网、不读远端） |
| 许可证 | MIT，原文见同目录 `LICENSE.md` |
| 产物 | `phaser.min.js`（1,375,976 B）+ `build-manifest.json`（版本 / 来源 / 字节 / sha256） |

## 用途与边界

* 用于**引擎短片**（`screenplay.json` 编译成 Phaser 播放页）——该批次按
  `docs/plan-creative-workbench.md` §5.0 **仍是未施工**；本目录是**只入库、未接线**的
  运行时（用户 2026-11-28 裁决：先引入引擎，暂不启用）。
* 页面纪律与其他 WebView 面一致：自包含单文件、CSP 关网、零外链、不读本地文件；
  确定性：固定 fps/整数帧、种子化随机、禁止 wall clock。
* 只允许本项目自研的**编译产物**驱动（Agent 只写 JSON，不写 Phaser 代码），
  与 v1 常规视频（Dart 矢量 + DOM 短片）互不影响。

## 校验

`build-manifest.json` 钉住字节数与 sha256；`app/test/creative_stack_guard_test.dart`
逐字对账（改产物不更新清单 = 测试红）。重建/升级时同时更新清单与 NOTICE。
