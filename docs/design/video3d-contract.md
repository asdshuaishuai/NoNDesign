# 3D 视频数据契约 v1（草案）

> 状态：**设计草案（D3）已实现契约核心 + 项目存储 + 预览页编译器 + 首个工作台（2026-11-25，只读预览）**。`scene3d.json` / `screenplay3d.json`
> 是 3D 视频项目的事实源；产物（HTML/帧/证据）是派生。agent 只写 JSON，不写 JS/React。
>
> 关联：[video3d-execution.md](video3d-execution.md) · [video-tracks-adr.md](video-tracks-adr.md) ·
> [three-contract.md](../three-contract.md) §3（3D 项目布局纪律）

## 1. 项目布局

```
<projectsRoot>/portfolio/video3d/<name>/
  scene3d.json        场景事实源
  screenplay3d.json   镜头/时间事实源
  artifacts/          渲染帧/contact sheet/measurement（派生）
  judge/rNN/          盲评证据轮次（后续批次）
```

旧 3D/视频项目**不迁移**；3D 视频是新项目类型，首版只支持从空项目新建/由 agent 写入。

## 2. `scene3d.json` v1

```json
{
  "v": 1,
  "units": "m",
  "environment": {"background": "#0b0d12"},
  "nodes": [
    {"id": "floor", "type": "box", "size": [10, 0.1, 10],
     "position": [0, 0, 0], "rotation": [0, 0, 0], "scale": [1, 1, 1],
     "material": {"color": "#9a8c7a", "roughness": 0.9, "metalness": 0},
     "parent": null,
     "asset": null}
  ],
  "lights": [
    {"id": "key", "type": "directional", "intensity": 1.0, "color": "#ffffff",
     "position": [4, 6, 4], "target": [0, 0, 0]}
  ],
  "cameras": [
    {"id": "hero", "position": [4, 2, 4], "target": [0, 1, 0], "fov": 45}
  ]
}
```

* 节点 ≤256；`id` ASCII snake_case 唯一；`type` 只支持 box/sphere/cylinder/plane
  （与 3D 建模 scene v1 同族）；`size` 有限正数（plane 第三维可为 0）；
  `parent` 存在/无环；`asset` 是项目内相对 glTF 路径或 null（v1 可选）。
* 材质字段：`color` #rrggbb、roughness/metalness 0–1；
* 灯光：type ∈ directional/point/ambient；强度/位置有限；
* 相机：position/target 有限，fov ∈ [10, 120]。
* 校验失败不炸项目，但不得编译进预览；错误码带 pointer + 人话 fix hint。

## 3. `screenplay3d.json` v1

```json
{
  "v": 1,
  "fps": 30,
  "format": {"width": 720, "height": 1280},
  "shots": [
    {"id": "s1", "duration": 5.0,
     "scene": {"from": 0.0, "to": 5.0},
     "camera": {"id": "hero", "move": {"from": [4,2,4], "to": [3,2.2,4],
                "target": [0,1,0], "easing": "easeInOut"}},
     "cues": []}
  ]
}
```

* `fps` 固定 30（v1）；镜头 id 唯一；duration > 0；镜头总时长 = 片长；
* `camera` 可引用 `scene3d.json` 的相机 id，或给 from/to 覆盖（v1 只支持固定/线性/缓动，
  不支持复杂路径/物理）；
* `cues` 为可选事件（v1 只保留字段，不接音频/TTS/VFX）；
* 所有时间用秒（编译时转整数帧）；随机种子在 screenplay 顶层可选，缺省 0。

## 4. 校验与编译

* Dart 纯函数 `verifyVideo3d(scene, screenplay)` → `{verified, checks[]}`；
* `compileVideo3d(scene, screenplay)` → 确定性 HTML/场景代码；同输入字节相同；
* 校验失败时禁止生成新预览；已有预览保留但标记 stale（不静默替换）；
* 体积/资产/节点上限与错误码（`video3d_*`）在实现时补人话映射。

## 5. v1 不做

音频/TTS/VFX/字幕/转场特效/角色骨骼；导出成片；移动端完整编辑；与常规视频项目互转。
