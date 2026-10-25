#!/bin/bash
# smart-write-monitor.sh — 实时查看 Mac 磁盘真实写入量
#
# 原理：NVMe SMART 的 "Data Units Written" 是盘自己记的累计写入量，
#       1 unit = 1000 × 512 B = 512,000 B（NVMe 规范固定倍数）。
#       两次采样相减，得到这段时间真正落到 NAND 上的字节数。
#
# 用法：
#   ./smart-write-monitor.sh                  # /dev/disk0，每 1 秒刷新
#   ./smart-write-monitor.sh /dev/disk4       # 指定外接盘
#   ./smart-write-monitor.sh /dev/disk0 5     # 每 5 秒刷新（更省电）
#
# Ctrl-C 退出时会打印本次会话汇总。

set -u

DEV="${1:-/dev/disk0}"
INTERVAL="${2:-1}"
SMARTCTL="${SMARTCTL:-/usr/local/sbin/smartctl}"
UNIT_BYTES=512000

# 注意：smartctl 的退出码是位掩码，即使读到数据也可能非 0
# （例如 Apple 控制器不支持错误日志会置位），所以按输出内容判断。
if ! "$SMARTCTL" -x "$DEV" 2>/dev/null | grep -q '^Data Units Written:'; then
  echo "读不到 $DEV 的 SMART 数据。" >&2
  echo "试试：sudo $SMARTCTL -x $DEV" >&2
  exit 1
fi

sample() {
  "$SMARTCTL" -x "$DEV" 2>/dev/null | awk '
    /^Data Units Written:/              {gsub(",", "", $4); u = $4}
    /^Temperature:/                     {gsub(/[^0-9]/, "", $2); t = $2}
    /^Percentage Used:/                 {gsub(/[^0-9]/, "", $2); p = $2}
    /^Media and Data Integrity Errors:/ {gsub(/[^0-9]/, "", $2); e = $2}
    END {printf "%s %s %s %s\n", u, t + 0, p + 0, e + 0}'
}

read -r prev temp used mediaerr <<<"$(sample)"
first=$prev
start=$(date +%s)
last=$start
peak=0

printf '设备 %s   间隔 %ss   Ctrl-C 结束\n\n' "$DEV" "$INTERVAL"
printf '%s\n' "时间         本次写入    写入速率      累计写入   温度  寿命"

trap '{
  end=$(date +%s); secs=$((end - start)); [ "$secs" -lt 1 ] && secs=1
  cur=$(sample | awk "{print \$1}")
  awk -v a="$cur" -v b="$first" -v u="$UNIT_BYTES" -v s="$secs" -v p="$peak" \
    "BEGIN {
       gb = (a - b) * u / 1000000000;
       printf \"\n会话 %d 秒，新增写入 %.2f GB，平均 %.2f MB/s，峰值 %.2f MB/s\n\", s, gb, gb * 1024 / s, p;
     }"
  exit 0
}' INT TERM

while true; do
  sleep "$INTERVAL"
  line=$(sample)
  now=$(date +%s)
  read -r cur temp used mediaerr <<<"$line"

  dt=$((now - last))
  [ "$dt" -lt 1 ] && dt=1
  last=$now
  du=$((cur - prev))
  prev=$cur

  awk -v ts="$(date +%H:%M:%S)" -v du="$du" -v dt="$dt" -v cur="$cur" \
      -v b="$UNIT_BYTES" -v t="$temp" -v p="$used" 'BEGIN {
    mb   = du * b / 1000000;
    rate = du * b / 1000000 / dt;
    tot  = cur * b / 1000000000;
    printf "%-9s %8.1f MB %9.2f MB/s %10.1f GB %5d°C %4d%%\n", ts, mb, rate, tot, t, p;
  }'

  peak=$(awk -v a="$peak" -v d="$du" -v b="$UNIT_BYTES" -v t="$dt" \
    'BEGIN { r = d * b / 1000000 / t; print (r > a ? r : a) }')
done
