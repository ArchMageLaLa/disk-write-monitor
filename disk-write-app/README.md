# 磁盘写入量 · macOS 小窗口版

一个原生 Mac 窗口应用，实时显示硬盘写入速度。不依赖浏览器、不需要终端，
内置 smartctl，拷给朋友也能直接用。

## 交付物

| 文件 | 用途 |
| --- | --- |
| `dist/磁盘写入量.dmg` | 发给别人的安装包（1.7 MB） |
| `dist/磁盘写入量.app` | 应用本体，可直接拖进「应用程序」 |
| `dist/第一次使用请看这里.txt` | 给朋友的简短说明 |

## 安装

1. 双击 `磁盘写入量.dmg`。
2. 把图标拖到旁边的「应用程序」。
3. 第一次打开：右键图标 →「打开」→ 再点一次「打开」。

因为没做苹果开发者签名，系统会拦一下；右键打开一次之后就正常了。
如果连右键也不让开，在终端执行一次：

```bash
xattr -dr com.apple.quarantine "/Applications/磁盘写入量.app"
```

## 系统要求

- macOS 13 (Ventura) 或更高
- Apple Silicon 与 Intel 都可以（通用二进制）
- 不需要另外安装 smartmontools，已内置

## 界面

- **当前写入速度**：每秒写入多少 MB
- **曲线**：最近 60 秒
- **本次会话写入 / 累计写入 / 本次峰值 / 硬盘温度**
- 右上角「暂停」可冻结曲线；关掉窗口即退出

## 数据来源

内置 smartctl 读取 NVMe 的 `Data Units Written`，1 unit = 512,000 字节。
每秒采样一次，只读，不写盘，不联网。

内置的 smartctl 来自 smartmontools 7.5，按 GPLv2 发布，许可证全文随包
放在 `Contents/Resources/LICENSE-smartmontools.txt`，`NOTICE.txt` 里有
源码地址。因此本应用**不能上架 App Store**，私下分享没问题。

## 自己重新构建

```bash
./build.sh
```

需要命令行工具（`xcode-select --install`）。脚本会编译 arm64 与 x86_64、
合并成通用二进制、内置 smartctl、临时签名并尝试生成 dmg。

注意：`hdiutil` 在受限沙箱里可能创建失败，这时在普通终端里再跑一次脚本即可。

## 目录

```
src/DiskWrites.swift   应用源码（界面 + 采样 + 图表）
src/Info.plist         应用信息
src/make-icon.swift    生成图标 PNG
src/make-icns.py       把 PNG 拼成 .icns
resources/AppIcon.icns 应用图标
build.sh               一键构建
first-run.txt          给朋友的首次使用说明
```

## 已知限制

- 默认监控 `/dev/disk0`（内置盘）。外接盘需要改源码里的 device 参数。
- 读不到 SMART 时窗口会显示错误提示，不会静默显示 0。
- 未做公证，跨机器分发时对方需要右键打开或清除 quarantine 标记。
