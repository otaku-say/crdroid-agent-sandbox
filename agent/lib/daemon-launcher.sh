#!/system/bin/sh
# =============================================================================
# daemon-launcher.sh —— init service 的启动垫片
#
# 为什么需要它：守护脚本在 /data/adb/sandbox/bin 下，而 init 在 late-init
# 阶段就启动 service，此时 /data 可能还没挂载。这里先等 /data 就绪，
# 再 exec 真实脚本，PID 不变（init 能正确跟踪）。
#
# 用法：daemon-launcher.sh <discard脚本名> <脚本路径> [额外等待秒数]
# =============================================================================

_sleep_secs="${3:-0}"
_n=0
while [ ! -d /data/adb ] && [ "$_n" -lt 120 ]; do
    sleep 1
    _n=$((_n + 1))
done
[ "$_sleep_secs" -gt 0 ] && sleep "$_sleep_secs"

[ -f "$2" ] || exit 1
exec sh "$2"
