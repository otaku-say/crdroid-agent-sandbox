#!/system/bin/sh
# =============================================================================
# sandbox-battery-guard.sh —— 电池区间停充守护（长期插电场景的电池鼓包防护）
#
# 运行方式：由 sandbox-boot-converge.sh 以单实例方式拉起，pidfile 记录在
#           /data/adb/sandbox/run/battery-guard.pid
#
# 策略：容量 >= 55% 停止充电，<= 45% 恢复充电，在 45%~55% 区间来回。
# 幂等：只在需要改变时写 sysfs，状态未变化不重复写、不重复记日志。
# =============================================================================

export PATH="/system/bin:/system/xbin:/vendor/bin:${PATH}"

BATTERY_PAUSE_ABOVE=55
BATTERY_RESUME_BELOW=45
BATTERY_TEMP_PAUSE=420      # 42.0℃（0.1℃ 单位）以上暂停充电，充电本身会显著发热
BATTERY_TEMP_RESUME=380     # 38.0℃ 以下恢复
POLL_SECONDS=60

CAPACITY_NODE="/sys/class/power_supply/battery/capacity"
TEMP_NODE="/sys/class/power_supply/battery/temp"
CHARGING_ENABLE_NODE="/sys/class/power_supply/battery/battery_charging_enabled"
INPUT_SUSPEND_NODE="/sys/class/power_supply/battery/input_suspend"

LOG_FILE="/data/adb/sandbox/log/sandbox-battery-guard.log"
PID_FILE="/data/adb/sandbox/run/battery-guard.pid"
mkdir -p /data/adb/sandbox/log /data/adb/sandbox/run 2>/dev/null

# 单实例：已有存活实例则直接退出
if [ -f "$PID_FILE" ]; then
    EXISTING_PID="$(cat "$PID_FILE" 2>/dev/null)"
    # 同样要核对 cmdline，避免 PID 复用导致误判
    if [ -n "$EXISTING_PID" ] && [ "$EXISTING_PID" != "$$" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        case "$(tr '\0' ' ' < "/proc/${EXISTING_PID}/cmdline" 2>/dev/null)" in
            *"$SELF_NAME"*) exit 0 ;;
        esac
    fi
fi
printf '%s\n' "$$" > "$PID_FILE"

log_line() {
    _msg="$(date '+%Y-%m-%d %H:%M:%S') [battery-guard] $*"
    printf '%s\n' "$_msg" >> "$LOG_FILE" 2>/dev/null
}

# 只在目标值不同时才写 sysfs；返回 0 表示已满足
write_if_different() {
    _node="$1"
    _want="$2"
    _cur="$(cat "$_node" 2>/dev/null)"
    if [ "$_cur" = "$_want" ]; then
        return 0
    fi
    printf '%s\n' "$_want" > "$_node" 2>/dev/null
    return 0
}

set_charging_enabled() {
    write_if_different "$CHARGING_ENABLE_NODE" "$1"
    write_if_different "$INPUT_SUSPEND_NODE" "$([ "$1" = "1" ] && echo 0 || echo 1)"
}

# 上次动作落盘，--once 模式下也能保持状态
STATE_FILE=/data/adb/sandbox/run/battery-guard.state
LAST_ACTION="$(cat "$STATE_FILE" 2>/dev/null)"

run_check() {

    CAPACITY="$(cat "$CAPACITY_NODE" 2>/dev/null)"
    TEMP="$(cat "$TEMP_NODE" 2>/dev/null)"

    # 温度优先于电量：高温时先停充，避免边充边热
    if [ -n "$TEMP" ] && [ "$TEMP" -ge "$BATTERY_TEMP_PAUSE" ]; then
        if [ "$LAST_ACTION" != "temp-pause" ]; then
            set_charging_enabled 0
            log_line "temp=$((TEMP / 10)).$((TEMP % 10))C -> charging paused (overheat)"
            LAST_ACTION="temp-pause"
        fi
        sleep "$POLL_SECONDS"
        continue
    fi
    if [ -n "$TEMP" ] && [ "$TEMP" -le "$BATTERY_TEMP_RESUME" ] && [ "$LAST_ACTION" = "temp-pause" ]; then
        set_charging_enabled 1
        log_line "temp=$((TEMP / 10)).$((TEMP % 10))C -> charging resumed"
        LAST_ACTION="resume"
    fi

    if [ -n "$CAPACITY" ]; then
        if [ "$CAPACITY" -ge "$BATTERY_PAUSE_ABOVE" ]; then
            if [ "$LAST_ACTION" != "pause" ]; then
                set_charging_enabled 0
                log_line "capacity=${CAPACITY}% -> charging paused"
                LAST_ACTION="pause"
            fi
        elif [ "$CAPACITY" -le "$BATTERY_RESUME_BELOW" ]; then
            if [ "$LAST_ACTION" != "resume" ]; then
                set_charging_enabled 1
                log_line "capacity=${CAPACITY}% -> charging resumed"
                LAST_ACTION="resume"
            fi
        fi
    fi
}

save_last_action() {
    printf '%s\n' "$LAST_ACTION" > "$STATE_FILE" 2>/dev/null
}

case "$1" in
    --once)
        run_check
        [ -n "${STATE_FILE:-}" ] && save_last_action 2>/dev/null
        exit 0
        ;;
esac

log_line "started (pause>=${BATTERY_PAUSE_ABOVE}% resume<=${BATTERY_RESUME_BELOW}%)"
while true; do
    run_check
    save_last_action
    sleep "$POLL_SECONDS"
done
