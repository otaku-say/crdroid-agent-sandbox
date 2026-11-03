#!/system/bin/sh
# =============================================================================
# sandbox-location-guard.sh —— 让 GPS 跟随出口 IP
#
# 背景：局域网用 passwall 透明代理，出口 IP 会随节点切换变化。
# 若 GPS 固定在美国而出口 IP 在中国，比对类服务会认为数据矛盾。
#
# 行为：
#   MODE=auto    每 INTERVAL 秒查询出口 IP，IP 或坐标变化时同步 GPS
#   MODE=manual  agent 用 --set 指定过位置，此时完全不动 GPS
#
# 手动优先：sandbox-mock-location.sh --set <lat> <lng> 会把 MODE 写成 manual；
#          --auto 可以把控制权交回跟随器。
#
# 查询失败（断网、代理未就绪）时跳过本轮，不破坏已生效的位置。
# =============================================================================

ALPINE=/data/adb/sandbox/bin/sandbox-alpine.sh
MOCK=/data/adb/sandbox/bin/sandbox-mock-location.sh
CONF=/data/adb/sandbox/state/location.conf
LOG=/data/adb/sandbox/log/sandbox-location-guard.log
INTERVAL=60
PIDFILE=/data/adb/sandbox/run/location-guard.pid
LAST_IP_FILE=/data/adb/sandbox/state/last_export_ip

mkdir -p /data/adb/sandbox/log /data/adb/sandbox/run

if [ -f "$PIDFILE" ]; then
    EXISTING_PID="$(cat "$PIDFILE")"
    if [ -n "$EXISTING_PID" ] && [ "$EXISTING_PID" != "$$" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        case "$(tr '\0' ' ' < "/proc/${EXISTING_PID}/cmdline" 2>/dev/null)" in
            *"$(basename "$0")"*) exit 0 ;;
        esac
    fi
fi
printf '%s\n' "$$" > "$PIDFILE"

log_line() {
    _msg="$(date '+%Y-%m-%d %H:%M:%S') [location-guard] $*"
    printf '%s\n' "$_msg" >> "$LOG" 2>/dev/null
}

conf_value() {
    sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -n 1
}

# 查询出口 IP 与地理坐标。
# 主用 ipwho.is（https，返回 ip + latitude + longitude + city，且和 Google 类
# 域名走同一条代理出口）；备用 ip-api.com（http，免费版不支持 https）。
# 输出：<ip> <lat> <lng> <city>  失败输出空。
query_geo() {
    _raw="$("$ALPINE" curl -s --max-time 12 https://ipwho.is/ 2>/dev/null | tr -d '\n')"
    _ip="$(printf '%s' "$_raw" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    _lat="$(printf '%s' "$_raw" | sed -n 's/.*"latitude"[[:space:]]*:[[:space:]]*\([-0-9.]*\).*/\1/p')"
    _lng="$(printf '%s' "$_raw" | sed -n 's/.*"longitude"[[:space:]]*:[[:space:]]*\([-0-9.]*\).*/\1/p')"
    _city="$(printf '%s' "$_raw" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

    if [ -z "$_ip" ] || [ -z "$_lat" ] || [ -z "$_lng" ]; then
        _raw="$("$ALPINE" curl -s --max-time 12 'http://ip-api.com/json/?fields=status,country,city,lat,lon,query' 2>/dev/null | tr -d '\n')"
        _ip="$(printf '%s' "$_raw" | sed -n 's/.*"query"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        _lat="$(printf '%s' "$_raw" | sed -n 's/.*"lat"[[:space:]]*:[[:space:]]*\([-0-9.]*\).*/\1/p')"
        _lng="$(printf '%s' "$_raw" | sed -n 's/.*"lon"[[:space:]]*:[[:space:]]*\([-0-9.]*\).*/\1/p')"
        _city="$(printf '%s' "$_raw" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    fi

    [ -n "$_ip" ] && [ -n "$_lat" ] && [ -n "$_lng" ] || return 1
    printf '%s %s %s %s\n' "$_ip" "$_lat" "$_lng" "$_city"
}

run_check() {

    MODE="$(conf_value MODE)"
    [ -z "$MODE" ] && MODE=auto

    # --- 保活：mock provider 消失（重启后 app 未启动 / 被系统杀掉）就重新拉起 ---
    # 这一步让 Mock my GPS 事实上具备了开机自启和自愈能力，
    # 不依赖 app 自身的 BOOT_COMPLETED。
    POS="$(dumpsys location 2>/dev/null | grep -m1 'last location=' | grep -oE '[-0-9]+\.[0-9]+,-[0-9]+\.[0-9]+' | head -n 1)"
    if [ -z "$POS" ]; then
        log_line "mock provider lost, re-applying (mode=${MODE})"
        "$MOCK" --ensure >/dev/null 2>&1 || log_line "WARN re-apply failed, will retry next cycle"
        sleep "$INTERVAL"
        continue
    fi

    if [ "$MODE" = "manual" ]; then
        sleep "$INTERVAL"
        continue
    fi

    GEO="$(query_geo)"
    if [ -z "$GEO" ]; then
        log_line "WARN geo lookup failed, keep current position"
        sleep "$INTERVAL"
        continue
    fi
    IP="$(printf '%s' "$GEO" | awk '{print $1}')"
    _lat="$(printf '%s' "$GEO" | awk '{print $2}')"
    _lng="$(printf '%s' "$GEO" | awk '{print $3}')"
    CITY="$(printf '%s' "$GEO" | cut -d' ' -f4-)"
    LOC="${_lat},${_lng}"

    LAST_IP="$(cat "$LAST_IP_FILE" 2>/dev/null)"
    if [ "$IP" = "$LAST_IP" ]; then
        sleep "$INTERVAL"
        continue
    fi

    log_line "export ip changed: ${LAST_IP:-none} -> ${IP} (${CITY:-?}), syncing gps to ${_lat},${_lng}"

    # --auto-apply 保持 auto 模式，不会把控制权切给 manual
    if "$MOCK" --auto-apply "$_lat" "$_lng"; then
        printf '%s\n' "$IP" > "$LAST_IP_FILE"
        log_line "OK gps synced"
    else
        log_line "ERROR gps sync failed"
    fi

}

case "$1" in
    --once)
        run_check
        [ -n "${STATE_FILE:-}" ] && save_last_action 2>/dev/null
        exit 0
        ;;
esac

log_line "started (interval=${INTERVAL}s)"
while true; do
    run_check
    sleep "$INTERVAL"
done
