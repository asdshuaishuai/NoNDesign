# three-live（vendored）

| 项 | 值 |
| --- | --- |
| 上游 | google/three-live |
| 版本 | 1.4.0（npm `three-live@1.4.0`） |
| 来源 | `https://cdn.jsdelivr.net/npm/three-live@1.4.0/dist/three-live.min.js`，与 npm 包内 `dist/three-live.min.js` 字节一致 |
| 许可证 | Apache-2.0，原文见同目录 `THREE-LIVE-LICENSE`（文件头部也保留了上游版权声明） |
| 上游源码 | `https://github.com/google/three-live` |
| 文件 | `three-live.min.js`（224,716 B） |

## 本地补丁（仅此一处，必须保留）

上游默认让 sandbox worker 用 `importScripts(<bundle blob URL>)` 装载自身引擎。`file://`
页面在 Chromium/WebKit 下得到的 blob 是 opaque origin（`blob:null/…`），worker 里
`importScripts` 该 blob 会被网络层拒绝；应用内预览正是 `file://` 直开（无端口、无
本地服务），所以原样 vendor 会白屏。

补丁把「worker 需要的引擎源码」放进 worker 的启动脚本，而不再远程装载：

1. 主线程启动 worker 前，页面把本内联脚本的 `textContent` 挂到
   `globalThis.__three_live_engine_source__`（见 `preview.html` 的
   `#three-live-runtime` 片段，页面仍是单文件自包含）。
2. worker 源码改为「引擎源码 + 上游启动代码」拼接：在
   `` return `'use strict';(${Qs.toString()})` `` 前插入
   `(globalThis.__three_live_engine_source__||"")+`。
3. worker 启动时若引擎已在场（`r.THREE`），跳过 `importScripts`：
   `x(L)` → `(r.THREE||x(L))`。

补丁只改这两处字符串；上游的 sandbox 边界（脚本在 Worker 里用 `new Function`
编译、`postMessage` 白名单、移除网络/存储 API、`SECURITY_3D_MAX_*` 限额）全部原样
保留。因为 worker 里仍有 `new Function`，预览页 CSP 需要 `script-src 'unsafe-eval'`；
worker 也通过 `worker-src blob:` 创建——这两条是 `allow-client-scripts` 路径的
最小放宽，`connect-src 'none'` / `default-src 'none'` 不变。

复现：

```bash
npm pack three-live@1.4.0 && tar -xzf three-live-1.4.0.tgz
# 对 package/dist/three-live.min.js 做上面两处字符串替换后写入本目录
```

## 版本升级步骤

1. `npm pack three-live@<新版本>`，替换 `three-live.min.js` 并重新核对上面两处
   字符串是否仍唯一存在（`app/test/three_live_vendor_test.dart` 会守门）。
2. 同步 `NOTICE.md` 的版本/来源/长度，重跑 `three_live_vendor_test.dart` 与
   Chrome/WKWebView 实机渲染证据（`dist/screens/`）。
