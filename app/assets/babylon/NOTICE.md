# Babylon.js（vendored，tree-shaken 降级渲染面）

| 项 | 值 |
| --- | --- |
| 上游 | `@babylonjs/core`（BabylonJS/Babylon.js） |
| 版本 | **9.38.0**（`package.json` 精确锁定，构建时与 `node_modules` 实装版本逐字核对） |
| 来源 | npm registry `@babylonjs/core@9.38.0`（构建期安装，产物入库；运行时不联网） |
| 许可证 | Apache-2.0，原文见同目录 `LICENSE` |
| 产物 | `babylon.min.js`（1,648,767 B）+ `build-manifest.json`（版本/入口/产物的 sha256 与字节数） |
| 构建源 | `third_party/babylon_web/entry.js` + `build.mjs`（esbuild 0.28.2、format iife、global `NAN_BABYLON`） |

## 为什么是 tree-shaken 子集，而不是完整 UMD

Babylon 9 的完整 UMD `babylon.min.js` 约 **8.9 MB**；内联进单文件预览页会让页面膨胀到
不可用。这里只打包真实用到的子集（Engine / Scene / FreeCamera / MeshBuilder 四种几何 /
StandardMaterial / Ambient·Directional·Point 灯光 / Vector3·Color3·Color4），产物约
**1.6 MB**，与 three.js（1.27 MB）同量级。

## 用途与边界

* 只作为 **3D 视频预览的降级渲染面**（页面渲染器选择顺序：`three` → `babylon` → `canvas2d`），
  由页面注入的同一个 `cameraAt(frame)` 驱动，保证「场景 + 镜头 + 帧号」是唯一输入；
* **不联网、不读本地文件、不使用随机/墙钟**；
* 渲染器身份如实回传（`babylon_webgl_v9`），**不冒充** three 的像素结果——同一场景在
  两档渲染器下外观相近但**不承诺逐字节一致**（材质/抗锯齿实现不同）；
* 完整 Babylon 的其余能力（物理/PBR/后处理/GLTF 加载器等）**没有打包**，不做承诺。

## 重建

```bash
cd third_party/babylon_web
npm install --no-audit --no-fund
node build.mjs        # 校验版本 → 打包 → 写 app/assets/babylon/
```

产物不含时间戳/主机路径：同输入同字节；改 `entry.js` 或版本后必须重建并提交。
