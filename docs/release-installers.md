# 桌面安装包发布说明

本文给维护者看：安装包从哪里来、怎么在本地复现、签名与已知限制。
普通用户请直接看 GitHub Release 页面。

## 1. 安装包在哪

- 发布页：<https://github.com/asdshuaishuai/NoNDesign/releases>
- tag：`v` + 仓库根 `VERSION` 的内容（当前 `v0.1.0`）
- 资产（只有安装包，不再有便携版压缩包）：

| 文件 | 内容 | 产出位置 |
| --- | --- | --- |
| `NaN-<版本>-macos-arm64.dmg` | macOS 安装包（含 NaN.app + Applications 拖拽链接 + 卷标 + 卷图标） | `dist/`（本地产）/ Release（线上） |
| `NaN-<版本>-windows-x64-setup.exe` | Windows 安装程序（Program Files、开始菜单、桌面快捷方式、卸载项） | 同上 |
| `SHA256SUMS.txt` | 两个安装包的 SHA-256 | 同上 |

版本号唯一来源是仓库根 `VERSION`，`app/pubspec.yaml` 的 `version:` 必须同步；
工作流不读 pubspec，也不允许在别处写版本号。

## 2. 由哪个工作流构建

`.github/workflows/desktop-release.yml`

触发：

- push 到 `release/2026-11-18-nan`
- 手动 `workflow_dispatch`

job 依赖结构：

```
gate (macos-26，arm64)
  ├── macos-release (macos-26，arm64) ─┐
  └── windows-release (windows-latest) ─┴── release (ubuntu-latest，contents: write)
```

> 2026-11-19 起 runs-on 从 macos-15 改为 **macos-26**：实测 macos-15 标签在公开仓库上
> 长时间排队（20 分钟仍未分配 runner），macos-26 立即分配且是 arm64
> （Image: macos-26-arm64）；job 里的 `uname` 守卫继续兜住架构
> （见 `desktop-release.yml` 的 macos-release 注释）。

- **gate**：`flutter pub get` → `flutter analyze --no-pub`（零容忍）→
  `flutter test --no-pub`（失败时降并发重试一次）。不打包；测试不过，两个安装包
  job 不会启动。gate 放在 **macOS（arm64）**：整套测试目前只在 macOS 上完整验证过
  （平台分支、应用内 WebView、本地引擎动态库、系统 SQLite），而 gate 红掉就直接
  出不了安装包，所以优先用已验证环境。想换回 Linux 前，需要先在 Linux 上跑绿
  全量 analyze + test 并留下证据。
  - analyze 门禁是**零容忍**（不带 `--no-fatal-infos`）。曾经有一批 info 级
    既有告警（Flutter 3.50 把 material.dart 标记为 deprecated），当时用
    `--no-fatal-infos` 放行、workflow 注释记 131 条；material → material_ui
    迁移已在 2026-11-19 完成并复验 `flutter analyze --no-pub` 零告警，开关已
    按「迁移完成后删掉即可恢复零容忍」的自设条件移除。今后新增 info 必须在
    引入时就修掉，不允许再攒批次级白名单。
  - flutter test 一次串行重试：个别用例对调度时序敏感（对端断连、检索防抖、流式
    增量），在本机稳定通过、在共享 runner 上偶发失败。第一次失败时打 warning 并
    用 `--concurrency=2` 重跑一次；两次都失败才判门禁红（不静默跳过任何用例）。
- **macos-release**：`flutter build macos --release --no-pub` →
  `scripts/installer/make_dmg.sh`。脚本自己检查应用包路径、复制到临时目录、
  ad-hoc 签名、生成卷图标文件、先做可读写镜像并给卷根写「自定义图标」标记，
  再压缩成只读 UDZO；最后挂载回读校验 `NaN.app`、`Applications` 链接与
  卷图标标记都在。
- **windows-release**：`flutter build windows --release --no-pub` →
  `choco install innosetup` → `ISCC scripts\installer\nan.iss`，
  版本/Release 目录/图标/输出目录都通过 `/D` 参数传入。
- **release**：下载两个 artifact → `sha256sum` 生成 `SHA256SUMS.txt` →
  用 `docs/release-notes.md` 渲染中文正文 → `softprops/action-gh-release@v2`
  创建或更新 `v<VERSION>` Release。`overwrite_files: true`（等价 `--clobber`），
  同一版本可重复运行。

release job 必须显式声明：

```yaml
permissions:
  contents: write
```

`GITHUB_TOKEN` 由 Actions 自动提供，不需要额外 secret。job 级的
`contents: write` 会覆盖默认权限；但如果仓库/组织策略把 token 权限上限锁成
只读（**Settings → Actions → General → Workflow permissions** 或组织级
Actions 策略），创建 tag 和 Release 会 403，需要放开到可写。不需要 PAT。

## 3. 本地复现

前置：Flutter 3.50.0；macOS 本机还需 Xcode 命令行工具（`ditto`、`hdiutil`、
`codesign`、`sips`、`iconutil`、`SetFile`）；Windows 本机需 Inno Setup 6.x。

### macOS

```bash
cd app
flutter pub get
flutter build macos --release
cd ..
bash scripts/installer/make_dmg.sh
```

默认读 `app/build/macos/Build/Products/Release/NaN.app`、读 `VERSION`、
输出 `dist/NaN-<版本>-macos-arm64.dmg`。可覆盖：

```bash
bash scripts/installer/make_dmg.sh \
  --app /path/to/NaN.app \
  --version 0.1.0 \
  --out dist \
  --skip-sign        # 不重签，直接用构建时的签名
```

脚本在应用包不存在时会打印 `app/build/macos/...` 的实际目录树并以非 0 退出，
方便判断 Flutter 产物路径是否变化。

### Windows

```powershell
cd app
flutter pub get
flutter build windows --release
cd ..
choco install innosetup -y
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" `
    /DMyVersion=0.1.0 `
    "/DAppSourceDir=$PWD\app\build\windows\x64\runner\Release" `
    "/DOutputDir=$PWD\dist" `
    "/DAppIcon=$PWD\app\windows\runner\resources\app_icon.ico" `
    scripts\installer\nan.iss
```

产物：`dist\NaN-<版本>-windows-x64-setup.exe`。

安装向导语言：简体中文从 **Inno Setup 6.5.0** 起是官方语言文件
（`Languages\ChineseSimplified.isl`）。工作流编译前会检查这个文件，
存在就传 `/DWithChineseSimplified=1` 启用中文向导；旧版 Inno Setup 没这个
文件时保持英文向导并打 `::warning::`，不会联网下载第三方翻译。
本地手动编译时想启用中文，加一个参数即可：

```powershell
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" `
    /DMyVersion=0.1.0 /DWithChineseSimplified=1 `
    "/DAppSourceDir=$PWD\app\build\windows\x64\runner\Release" `
    "/DOutputDir=$PWD\dist" `
    "/DAppIcon=$PWD\app\windows\runner\resources\app_icon.ico" `
    scripts\installer\nan.iss
```

`nan.iss` 是纯 ASCII（兼容 Inno Setup 6.2 及更早版本按系统代码页读取无 BOM
文件的规则），中文文案全部来自官方语言文件。安装后的快捷方式、卸载项、
安装目录（Program Files\NaN）与版本号都不受语言影响。

### 门禁

```bash
cd app
flutter analyze --no-pub
flutter test --no-pub
```

CI 在 macOS（arm64，macos-26）上跑同一套，与本地验证环境一致；analyze 是
零容忍（info/warning/error 都红），flutter test
在 CI 失败时会降并发（`--concurrency=2`）重试一次。test 的重试是共享 runner
的时序兜底，本机稳定通过就不需要。如果将来有某个用例只在某一平台失败，改
gate 时要在 workflow 注释里写明原因并保留核心用例，不能静默把整段测试去掉。

## 4. 签名与公证现状

- **macOS**：仓库没有 Apple Developer ID 证书，也没有公证。构建后用
  `codesign --force --deep -s -` 做 ad-hoc 签名（脚本会打印签名信息，
  失败时给 `::warning::` 并回退到 Flutter 构建时的签名，不阻断打包）。
  ad-hoc 签名不等于可信分发：用户首次打开需要 **右键 → 打开**，或到
  「系统设置 → 隐私与安全性」点「仍要打开」。DMG 本身不签名。
- **Windows**：没有商业代码签名证书，`setup.exe` 未签名。用户会遇到
  SmartScreen「Windows 已保护你的电脑」，需要「更多信息 → 仍要运行」。
- 要消除以上提示，需要后续补：Apple Developer ID Application 证书 +
  `notarytool` 公证（CI secret：证书、密码、Apple ID/团队），以及
  Windows 代码签名证书（`signtool`）。这两项都不在本仓库当前范围内。

## 5. 已知限制

- **macOS 只出 arm64**：应用 `ARCHS=arm64`（MediaPipe 没有 Intel 切片），
  所以安装包是 Apple 芯片专用；`macos-release` 会先检查构建机是 arm64，
  不是就明确失败。Intel Mac 和通用包暂不支持。
- **Inno Setup 向导语言**：Inno Setup 6.5+ 时是简体中文；CI 若回落到旧版本
  （没有官方中文语言文件）则向导为英文并打 warning，安装结果与快捷方式不受影响。
- **安装包不联网**：安装过程不下载任何运行时；应用内部分智能能力首次使用时
  可能需要下载模型或填写服务配置。
- **没有自动更新**：升级需要下载新版本安装包覆盖安装（Windows 的 AppId 固定，
  覆盖安装沿用同一条卸载记录；macOS 拖入「应用程序」覆盖旧版）。
- **Release 资产可覆盖**：同一 `VERSION` 重复运行会更新同一个 tag 的资产；
  发新版本要先把 `VERSION` 和 `app/pubspec.yaml` 一起改掉。
- **构建耗时**：Windows job 里 `choco install innosetup` 约几十秒；
  macOS job 的 Flutter release 构建和原生依赖下载通常占大头。

## 6. 排查

- 找不到产物：两个构建 job 都会打印实际目录树后 `exit 1`，按日志里的
  `FullName` / `ls` 输出确认 Flutter 产物路径。
- 找不到 `ISCC.exe`：job 会列出已安装的 `ISCC.exe`；Chocolatey 装到
  `C:\Program Files (x86)\Inno Setup 6\ISCC.exe`，脚本同时兼容
  `Program Files\Inno Setup 6/7`。
- Release 上传失败：先确认 job 的 `contents: write` 与仓库 Actions 权限设置；
  资产已存在时由 `overwrite_files: true` 覆盖，不需要手动删。
- 想只验证打包、不发布：手动触发工作流后，两个构建 job 的 artifact
  在 run 页面可下载；release job 失败不会影响已产出的 artifact。
