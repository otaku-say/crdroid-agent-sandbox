#!/system/bin/sh
# =============================================================================
# sandbox-guardian.sh —— 单进程常驻守护（由 init service 管理）
#
# 为什么合并成一个进程：
#   从脚本里 fork 的守护进程会在父进程（converge）退出时被 init 按 process
#   group 杀掉，setsid 也救不回来。改成 init 直接管理单个常驻进程，内部顺序
#   调用三个检查的 --once 模式，最稳且日志集中。
#
# 职责：
#   1. 等 /data 就绪后跑一次 sandbox-boot-converge.sh
#   2. 之后每 60 秒：watchdog（adbd/WiFi/温度/磁盘）→ battery（充放电区间）
#      → location-guard（出口 IP → GPS）
# =============================================================================

SANDBOX_BIN=/data/adb/sandbox/bin
LOG=/data/adb/sandbox/log/sandbox-guardian.log
INTERVAL=60

log_line() {
    _msg="$(date '+%Y-%m-%d %H:%M:%S') [guardian] $*"
    [ -d /data/adb/sandbox/log ] && printf '%s\n' "$_msg" >> "$LOG" 2>/dev/null
}

# 等 /data 挂载（init 在 late-init 就启动本服务，此时 /data 可能还没好）
_n=0
while [ ! -d /data/adb ] && [ "$_n" -lt 180 ]; do
    sleep 1
    _n=$((_n + 1))
done
[ -d /data/adb ] || exit 1

# 等系统基本起来，避开首屏 dexopt 高峰
sleep 60

if [ -x "$SANDBOX_BIN/sandbox-boot-converge.sh" ]; then
    log_line "running initial converge"
    sh "$SANDBOX_BIN/sandbox-boot-converge.sh"
fi

log_line "entering steady-state loop (interval=${INTERVAL}s)"

while true; do
    for _script in sandbox-watchdog.sh sandbox-battery-guard.sh sandbox-location-guard.sh; do
        [ -x "$SANDBOX_BIN/$_script" ] && sh "$SANDBOX_BIN/$_script" --once
    done
    sleep "$INTERVAL"
done
