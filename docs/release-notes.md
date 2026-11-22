# NaN __VERSION__

NaN 桌面版安装包（macOS / Windows）。本页文件由本仓库自动构建并发布。

## 下载哪个

| 系统 | 文件 | 说明 |
| --- | --- | --- |
| macOS（Apple 芯片） | `NaN-__VERSION__-macos-arm64.dmg` | 安装包，拖入「应用程序」即可 |
| Windows 10/11 64 位 | `NaN-__VERSION__-windows-x64-setup.exe` | 安装程序，双击安装 |
| 校验 | `SHA256SUMS.txt` | 两个安装包的 SHA-256 |

## macOS 安装

1. 下载 `NaN-__VERSION__-macos-arm64.dmg`，双击打开。
2. 把 **NaN** 拖到旁边的 **Applications（应用程序）** 文件夹。
3. 从「应用程序」启动 NaN。

> **首次打开需要右键 → 打开。** 本版本没有 Apple 开发者签名、没有公证，
> 直接双击可能提示「无法打开，因为 Apple 无法验证」。请在 Finder 里
> **右键点 NaN → 打开 → 再点「打开」**；也可以到
> 「系统设置 → 隐私与安全性」里点「仍要打开」。只需确认一次。

系统要求：macOS 12 或更高，Apple 芯片（M 系列）。Intel Mac 暂不支持。

## Windows 安装

1. 下载 `NaN-__VERSION__-windows-x64-setup.exe`，双击运行。
2. 按向导完成安装。默认装到 **Program Files\NaN**，并创建开始菜单和桌面快捷方式。
3. 从开始菜单或桌面启动 NaN。

> **SmartScreen 提示：** 安装包没有商业代码签名证书，Windows 可能提示
> 「Windows 已保护你的电脑」。点 **更多信息 → 仍要运行** 即可继续；
> 这是未签名程序的常规提示，不代表安装包有问题。

卸载：Windows「设置 → 应用 → 已安装的应用 → NaN → 卸载」，
或开始菜单里的「Uninstall NaN」。

系统要求：Windows 10 / 11 64 位。

## 校验安装包

下载后可在终端核对校验和（macOS）：

```bash
shasum -a 256 -c SHA256SUMS.txt
```

Windows 可用 `certutil -hashfile <文件名> SHA256` 计算，再与 `SHA256SUMS.txt` 对照。

## 说明

- 安装包本身**不需要联网**即可完成安装和启动；应用内的部分智能能力在首次使用
  时可能需要下载模型或填写服务配置。
- 本页只有安装包，不提供便携版压缩包。
- 遇到问题请到 [Issues](https://github.com/asdshuaishuai/NoNDesign/issues) 反馈，
  并注明系统版本与安装包文件名。
