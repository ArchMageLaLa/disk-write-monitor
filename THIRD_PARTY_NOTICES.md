# 第三方组件

## smartmontools（smartctl）

- 版本：7.5（r5714，2025-04-30）
- 用途：读取 NVMe 硬盘的 SMART 健康信息与累计写入量
- 许可证：GNU General Public License v2
- 源码：https://www.smartmontools.org/
- 发行包：https://sourceforge.net/projects/smartmontools/files/

应用打包时会把 `smartctl` 可执行文件放进
`磁盘写入量.app/Contents/Resources/smartctl`，并把许可证全文放在
`Contents/Resources/LICENSE-smartmontools.txt`。

因为内置了 GPLv2 组件，本项目整体按 GPL-2.0 发布，且不能上架 App Store。
