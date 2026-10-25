#!/bin/bash
# 双击即可启动磁盘写入量面板
cd "$(dirname "$0")" || exit 1

echo "正在启动磁盘写入量面板…"
/usr/bin/python3 server.py "$@"

code=$?
if [ "$code" -ne 0 ]; then
  echo
  echo "启动失败（退出码 $code），把上面的报错发给 Codex 看看。"
  read -n 1 -s -r -p "按任意键关闭窗口…"
fi
