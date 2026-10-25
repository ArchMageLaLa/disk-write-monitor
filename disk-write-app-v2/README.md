# 磁盘写入量 · v2（进程级 · 累计）

原生 macOS 小窗口，实时显示硬盘写入速度，并列出**从打开 App 起，哪个进程累计写得最多**。
内置 smartctl，不需要额外安装任何东西。

## 交付物

| 文件 | 用途 |
| --- | --- |
| `dist/磁盘写入量.dmg` | 发给别人的安装包 |
| `dist/磁盘写入量.app` | 应用本体 |
| `dist/第一次使用请看这里.txt` | 给朋友的首次使用说明 |

## 版本变化

- v2.1：进程排行榜改为**本次会话累计值**，进程退出后它的累计仍保留；
  列表全量显示，超出可视区域时在列表内向下滚动。
- v2.0：新增进程级排行榜（最初是 60 秒滚动窗口）。
- smartctl 读取增加自动重试（macOS 上偶发 `IOCreatePlugInInterfaceForService failed`）。
- 读取失败改为连续 3 次才提示，短时抖动不会刷屏。
- 窗口高度增加，其余视觉与 v1 一致。

## 安装

1. 双击 `磁盘写入量.dmg`。
2. 把图标拖进旁边的「应用程序」。
3. 第一次打开：右键 →「打开」→ 再点一次「打开」。

如果右键也不让开：

```bash
xattr -dr com.apple.quarantine "/Applications/磁盘写入量.app"
```

## 系统要求

- macOS 13 (Ventura) 及以上
- Apple Silicon 与 Intel 均可（通用二进制）
- 不需要安装 smartmontools

## 数据是怎么来的

| 指标 | 来源 | 含义 |
| --- | --- | --- |
| 当前写入速度 / 累计写入 | smartctl `Data Units Written` | 硬盘固件记录的落盘量 |
| 本次会话谁在写（累计） | `proc_pid_rusage` | 各进程自打开 App 起的写入请求量 |

两边数字不会完全相等：前者是真正落到闪存的字节，后者是系统收到的写请求，
中间还隔着文件系统缓存、APFS 压缩和快照。

## 已知限制

- **短命进程可能漏掉**。采样间隔 1 秒，只活几百毫秒的进程（例如一次性 `dd`）
  在采样时可能已经退出，不会出现在榜单里。持续写入的 App 不受影响。
- **累计值在重启后归零**。它统计的是本次打开 App 以来的写入，不做持久化。
- 进程列表显示全部条目，条目多时用鼠标或触控板在列表区域滚动。
- **部分系统进程看不到**。`kernel_task`、其他用户的进程可能读不到计数，
  因此榜单之和通常小于盘级写入量。
- 默认监控 `/dev/disk0`（内置盘）；外接盘需要改源码中的 device。
- 未做开发者签名与公证，跨机器分发时对方需右键打开。

## 自己构建

```bash
./build.sh
```

需要命令行工具（`xcode-select --install`）。脚本会编译 arm64 + x86_64、
合并通用二进制、内置 smartctl、临时签名并尝试生成 dmg。

`hdiutil` 在受限沙箱里可能创建失败，在普通终端重跑本脚本即可。

## 目录

```
src/DiskWrites.swift   界面 + smartctl 采样 + 进程归因
src/Info.plist         应用信息（版本 2.0）
src/make-icon.swift    生成图标
src/make-icns.py      PNG → .icns
resources/AppIcon.icns 图标
build.sh               一键构建
first-run.txt          给朋友的说明
archive/README.md      版本留档说明
```

## 许可证

内置 smartctl 来自 smartmontools 7.5（GPLv2），许可证全文随包放在
`Contents/Resources/LICENSE-smartmontools.txt`，源码地址见 `NOTICE.txt`。
因此本应用不能上架 App Store，私下分享没有问题。
