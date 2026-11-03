#!/system/bin/sh
# =============================================================================
# sandbox-mock-location.sh —— 虚拟 GPS 定位
#
# provider：Mock my GPS (com.github.warren_bank.mock_location, 672KB)
#
# 它支持 Geo-Intent 静默设置，因此完全不需要 UI 自动化：
#   am start -a android.intent.action.VIEW -d "geo:lat,lng" \
#       -n <pkg>/<pkg>.ui.GeoIntentActivity \
#       --ei purpose 1 --ez silent_update true --ez force_start true
#     purpose=1 固定位置，silent_update+force_start 表示静默生效且覆盖正在进行的 mock
#
# 权限（缺一不可，否则 intent 会停在授权页而不是开始 mock）：
#   android:mock_location、android:system_alert_window
#   ACCESS_FINE_LOCATION、ACCESS_COARSE_LOCATION
#
# 用法：
#   sandbox-mock-location.sh --status              输出模式、目标与当前位置
#   sandbox-mock-location.sh --set <lat> <lng>     手动锁定位（切到 MODE=manual）
#   sandbox-mock-location.sh --set                 重新应用当前记住的坐标
#   sandbox-mock-location.sh --auto                交回 IP 跟随器控制（MODE=auto）
#   sandbox-mock-location.sh --ensure              不是目标位置才设置
#
# 记住的坐标在 /data/adb/sandbox/state/location.conf，
# agent 直接 --set 传参即可，无需手工改文件。
# =============================================================================

CONF=/data/adb/sandbox/state/location.conf
LOG=/data/adb/sandbox/log/sandbox-mock-location.log
PKG=com.github.warren_bank.mock_location
ACTIVITY="${PKG}.ui.GeoIntentActivity"

mkdir -p /data/adb/sandbox/log

log_line() {
    _msg="$(date '+%Y-%m-%d %H:%M:%S') [mock-location] $*"
    printf '%s\n' "$_msg"
    printf '%s\n' "$_msg" >> "$LOG" 2>/dev/null
}

current_position() {
    dumpsys location 2>/dev/null \
        | grep -m1 "last location=" \
        | grep -oE '[-0-9]+\.[0-9]+,-[0-9]+\.[0-9]+' \
        | head -n 1
}

read_conf() {
    LAT="$(sed -n 's/^LATITUDE=//p' "$CONF" 2>/dev/null | head -n 1)"
    LNG="$(sed -n 's/^LONGITUDE=//p' "$CONF" 2>/dev/null | head -n 1)"
    if [ -z "$LAT" ] || [ -z "$LNG" ]; then
        log_line "ERROR: ${CONF} missing LATITUDE/LONGITUDE"
        return 1
    fi
    return 0
}

# dumpsys 只输出 6 位小数，配置可能是 7 位，必须按容差比较。
# 0.0002 度约 22 米，足够判断"是不是同一个位置"。
same_as_target() {
    _pos="$(current_position)"
    [ -n "$_pos" ] || return 1
    _cur_lat="$(printf '%s' "$_pos" | cut -d, -f1)"
    _cur_lng="$(printf '%s' "$_pos" | cut -d, -f2)"
    awk -v a="$_cur_lat" -v b="$LAT" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d < 0.0002) }' \
        && awk -v a="$_cur_lng" -v b="$LNG" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d < 0.0002) }'
}

# 「显示操纵杆」= 模式指示器：
#   MODE=auto   -> fixed_joystick_enabled=false（不显示，表示跟随出口 IP）
#   MODE=manual -> fixed_joystick_enabled=true （显示，表示 agent 手动锁定）
# 改 prefs 前必须 force-stop，否则运行中的进程会把内存值写回覆盖。
set_joystick() {
    _want="$1"
    _prefs="/data/data/${PKG}/shared_prefs/PREFS.xml"
    [ -f "$_prefs" ] || return 0

    if grep -q "fixed_joystick_enabled\" value=\"${_want}\"" "$_prefs"; then
        return 0
    fi

    _owner="$(stat -c '%u:%g' "/data/data/${PKG}" 2>/dev/null)"
    am force-stop "$PKG" >/dev/null 2>&1
    sleep 1

    if grep -q 'fixed_joystick_enabled' "$_prefs"; then
        sed -i "s/\(fixed_joystick_enabled\" value=\"\)[a-z]*/\1${_want}/" "$_prefs"
    else
        sed -i "s|</map>|    <boolean name=\"fixed_joystick_enabled\" value=\"${_want}\" />\n</map>|" "$_prefs"
    fi

    [ -n "$_owner" ] && chown "$_owner" "$_prefs" 2>/dev/null
    log_line "changed: indicator joystick -> ${_want} (mode=${_want:+$([ "$_want" = true ] && echo manual || echo auto)})"
}

# 一次性把权限全部放开，之后 intent 不会被任何授权弹窗拦住。
# 每次 apply 都跑一遍，成本极低（appops/pm grant 都是幂等操作）。
ensure_permissions() {
    # 关键 appops
    for _op in \
        android:mock_location \
        android:system_alert_window \
        android:fine_location \
        android:coarse_location \
        android:background_start_activity \
        android:start_foreground \
        android:run_in_background \
        android:wake_lock; do
        appops set "$PKG" "$_op" allow >/dev/null 2>&1
    done

    # 运行时权限
    for _perm in \
        ACCESS_FINE_LOCATION \
        ACCESS_COARSE_LOCATION \
        ACCESS_BACKGROUND_LOCATION \
        FOREGROUND_SERVICE \
        RECEIVE_BOOT_COMPLETED \
        WAKE_LOCK; do
        pm grant "$PKG" "android.permission.$_perm" >/dev/null 2>&1
    done

    # 指定为系统 mock location provider
    settings put secure mock_location "$PKG" >/dev/null 2>&1

    # 电池优化白名单，避免 7x24 运行中被休眠杀掉
    dumpsys deviceidle whitelist +"$PKG" >/dev/null 2>&1
}

apply_target() {
    log_line "applying ${LAT},${LNG}"
    ensure_permissions

    # 操纵杆充当即时可见的模式指示器
    if [ "$(conf_value MODE)" = "manual" ]; then
        set_joystick true
    else
        set_joystick false
    fi

    # 唤醒一次，避免锁屏状态下 Activity 起不来
    input keyevent KEYCODE_WAKEUP >/dev/null 2>&1

    am start -a android.intent.action.VIEW \
        -d "geo:${LAT},${LNG}" \
        -n "${PKG}/${ACTIVITY}" \
        --ei purpose 1 \
        --ez silent_update true \
        --ez force_start true >/dev/null 2>&1

    # intent 通常是秒级生效，给最多 10 秒余量
    _n=0
    while [ "$_n" -lt 10 ]; do
        sleep 1
        if same_as_target; then
            log_line "OK: position = ${LAT},${LNG}"
            return 0
        fi
        _n=$((_n + 1))
    done

    log_line "ERROR: position did not change, now=$(current_position)"
    return 1
}

# <lat> <lng> <mode: manual|auto>
write_conf() {
    # 圆整到 6 位小数，和 dumpsys 输出精度对齐
    _w_lat="$(printf '%.6f' "$1" 2>/dev/null || printf '%s' "$1")"
    _w_lng="$(printf '%.6f' "$2" 2>/dev/null || printf '%s' "$2")"
    mkdir -p "$(dirname "$CONF")"
    {
        echo "# 由 sandbox-mock-location.sh 维护"
        echo "# MODE=manual: agent 指定，IP 跟随器不介入"
        echo "# MODE=auto:   sandbox-location-guard.sh 按出口 IP 自动同步"
        echo "MODE=$3"
        echo "LATITUDE=$_w_lat"
        echo "LONGITUDE=$_w_lng"
    } > "$CONF"
    chmod 600 "$CONF"
}

conf_value() {
    sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -n 1
}

case "$1" in
    --status)
        read_conf || exit 1
        echo "mode   : $(conf_value MODE)"
        echo "target : ${LAT},${LNG}"
        echo "current: $(current_position)"
        ;;
    --ensure)
        read_conf || exit 1
        if same_as_target; then
            log_line "already satisfied: position = ${LAT},${LNG}"
            exit 0
        fi
        apply_target
        ;;
    --set)
        if [ -n "$2" ] && [ -n "$3" ]; then
            write_conf "$2" "$3" manual
            log_line "manual lock: target=${2},${3}"
        fi
        read_conf || exit 1
        apply_target
        ;;
    --auto-apply)
        # 供 location-guard 调用：更新坐标但保持 auto 模式
        [ -n "$2" ] && [ -n "$3" ] || exit 2
        write_conf "$2" "$3" auto
        read_conf || exit 1
        apply_target
        ;;
    --auto)
        _cur_lat="$(conf_value LATITUDE)"
        _cur_lng="$(conf_value LONGITUDE)"
        write_conf "$_cur_lat" "$_cur_lng" auto
        # 清掉上一次的出口 IP，让 guard 下一轮立即按当前 IP 重新同步
        rm -f /data/adb/sandbox/state/last_export_ip
        set_joystick false
        log_line "mode switched to auto, will follow export IP within one guard cycle"
        ;;
    *)
        sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
