#!/system/bin/sh
# =============================================================================
# sandbox-watchdog.sh —— 7x24 无人值守看门狗
#
# 每分钟检查一次设备是否仍然"可被 agent 使用"，异常时尝试自愈并留痕。
# 只做低风险修复（重启 adbd、清理日志），不会重启设备、不会改系统策略。
#
# 检查项：
#   1. adbd 是否在 5555 监听      -> 不在则 ctl.restart adbd
#   2. wlan0 是否拿到 IPv4        -> 记录（WiFi 重连交给系统）
#   3. 电池温度                   -> 超过 45℃ 记警告，超过 50℃ 记错误
#   4. /data 剩余空间             -> 低于 2GB 清理自身日志
#   5. 日志总量                   -> 超过 50MB 滚动
#
# pidfile 由本脚本自己写；由 sandbox-boot-converge.sh 以单实例拉起。
# =============================================================================

ADB_TCP_PORT=5555
CHECK_INTERVAL=60
TEMP_WARN=450          # 0.1℃ 单位：45.0℃
TEMP_CRIT=500          # 50.0℃
DISK_FREE_MIN_KB=2097152   # 2GB
LOG_TOTAL_MAX_KB=51200     # 50MB

PIDFILE=/data/adb/sandbox/run/watchdog.pid
LOG_DIR=/data/adb/sandbox/log
LOG_FILE="${LOG_DIR}/sandbox-watchdog.log"

mkdir -p /data/adb/sandbox/run "$LOG_DIR"

SELF_NAME="$(basename "$0")"

if [ -f "$PIDFILE" ]; then
    EXISTING_PID="$(cat "$PIDFILE")"
    # 同样要核对 cmdline，避免 PID 复用导致误判
    if [ -n "$EXISTING_PID" ] && [ "$EXISTING_PID" != "$$" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        case "$(tr '\0' ' ' < "/proc/${EXISTING_PID}/cmdline" 2>/dev/null)" in
            *"$SELF_NAME"*) exit 0 ;;
        esac
    fi
fi
printf '%s\n' "$$" > "$PIDFILE"

log_line() {
    _msg="$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $*"
    printf '%s\n' "$_msg" >> "$LOG_FILE"
}

rotate_log() {
    [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt 1048576 ] \
        && mv -f "$LOG_FILE" "${LOG_FILE}.1"
    _total="$(du -sk "$LOG_DIR" 2>/dev/null | awk '{print $1}')"
    if [ "${_total:-0}" -gt "$LOG_TOTAL_MAX_KB" ]; then
        for _f in "$LOG_DIR"/*.log.1; do
            [ -f "$_f" ] && rm -f "$_f"
        done
        log_line "log dir exceeded ${LOG_TOTAL_MAX_KB}KB, dropped rolled files"
    fi
}

port_is_listening() {
    _hex="$(printf '%04X' "$1")"
    awk -v suffix=":${_hex}" \
        '$2 ~ (suffix "$") && $4 == "0A" { found = 1 } END { exit(found ? 0 : 1) }' \
        /proc/net/tcp /proc/net/tcp6
}

wlan_ipv4() {
    ip -f inet addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1
}

run_check() {
    # --- 1. adb 端口 ---------------------------------------------------------
    if ! port_is_listening "$ADB_TCP_PORT"; then
        log_line "WARN adbd not listening on ${ADB_TCP_PORT}, restarting"
        setprop ctl.restart adbd
        sleep 3
        if port_is_listening "$ADB_TCP_PORT"; then
            log_line "OK adbd recovered on ${ADB_TCP_PORT}"
        else
            log_line "ERROR adbd still down on ${ADB_TCP_PORT}"
        fi
    fi

    # --- 2. WiFi -------------------------------------------------------------
    WLAN_IP="$(wlan_ipv4)"
    if [ -z "$WLAN_IP" ]; then
        log_line "WARN wlan0 has no IPv4 (wifi down?)"
    fi

    # --- 3. 温度 -------------------------------------------------------------
    TEMP="$(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
    if [ -n "$TEMP" ]; then
        if [ "$TEMP" -ge "$TEMP_CRIT" ]; then
            log_line "ERROR battery temp $((TEMP / 10)).$((TEMP % 10))C >= 50C"
        elif [ "$TEMP" -ge "$TEMP_WARN" ]; then
            log_line "WARN battery temp $((TEMP / 10)).$((TEMP % 10))C >= 45C"
        fi
    fi

    # --- 4. 磁盘 -------------------------------------------------------------
    FREE_KB="$(df -k /data 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt "$DISK_FREE_MIN_KB" ]; then
        log_line "WARN /data free ${FREE_KB}KB < 2GB, rotating logs"
        rotate_log
    fi

    # --- 5. 屏幕方向（MIUI 有时会在启动后把自动旋转改回开启）---------------
    if [ "$(settings get system accelerometer_rotation 2>/dev/null)" != "0" ]; then
        settings put system accelerometer_rotation 0
        log_line "FIXED accelerometer_rotation -> 0 (was changed by system)"
    fi

    # --- 6. 日志 -------------------------------------------------------------
    rotate_log

    
}

case "$1" in
    --once)
        run_check
        [ -n "${STATE_FILE:-}" ] && save_last_action 2>/dev/null
        exit 0
        ;;
esac

log_line "started (interval=${CHECK_INTERVAL}s)"
while true; do
    run_check
    sleep "$CHECK_INTERVAL"
done
