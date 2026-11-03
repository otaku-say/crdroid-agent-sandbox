#!/system/bin/sh
# =============================================================================
# sandbox-doctor.sh —— 沙箱只读体检
#
# 完全不修改系统，只读取状态并输出 PASS / WARN / FAIL。
# 退出码：0 = 全部 PASS（允许 WARN），1 = 存在 FAIL。
#
# 用法：sandbox-doctor.sh [--quiet]   --quiet 只输出非 PASS 项
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../lib/sandbox-lib.sh"

ADB_TCP_PORT=5555
SCREEN_BRIGHTNESS_LEVEL=450
DEVICE_LOCALE="zh-CN"
HOME_ACTIVITY="com.miui.home/.launcher.Launcher"
ADB_SHELL_UID=2000

QUIET=0
for _arg in "$@"; do
    case "$_arg" in
        --quiet) QUIET=1 ;;
        --help) printf 'usage: %s [--quiet]\n' "$(basename "$0")"; exit 0 ;;
    esac
done

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

report() {
    _state="$1"
    _name="$2"
    _detail="$3"
    case "$_state" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
        WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    esac
    if [ "$_state" = "PASS" ] && [ "$QUIET" = "1" ]; then
        return 0
    fi
    printf '[%-4s] %-26s %s\n' "$_state" "$_name" "$_detail"
}

check_equals() {
    _name="$1"
    _actual="$2"
    _expect="$3"
    if [ "$_actual" = "$_expect" ]; then
        report PASS "$_name" "$_actual"
    else
        report FAIL "$_name" "actual='${_actual}' expect='${_expect}'"
    fi
}

printf '===== 小米9 沙箱体检 %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S')"

# ---- 1. root / magisk -------------------------------------------------------
if sb_is_root; then
    report PASS "root" "uid=0"
else
    report FAIL "root" "uid=$(id -u 2>/dev/null)"
fi

if [ -x "$MAGISK" ]; then
    report PASS "magisk binary" "$MAGISK"
    if sb_magiskd_ready; then
        report PASS "magiskd" "$("$MAGISK" -v 2>/dev/null)"
    else
        report FAIL "magiskd" "not responding"
    fi
else
    report FAIL "magisk binary" "missing: ${MAGISK}"
fi

if [ -x "/data/adb/magisk/magisk64" ] || [ -x "/data/adb/magisk/magisk" ]; then
    report PASS "/data/adb/magisk" "present"
else
    report FAIL "/data/adb/magisk" "missing (need reseed)"
fi

# ---- 2. 只读属性 ------------------------------------------------------------
check_equals "ro.adb.secure" "$(getprop ro.adb.secure)" "0"
check_equals "ro.debuggable" "$(getprop ro.debuggable)" "1"

BOOT_COMPLETED="$(getprop sys.boot_completed)"
if [ "$BOOT_COMPLETED" = "1" ]; then
    report PASS "boot_completed" "1"
else
    report WARN "boot_completed" "'${BOOT_COMPLETED}'"
fi

# ---- 3. settings ------------------------------------------------------------
check_equals "global device_provisioned" "$(settings get global device_provisioned 2>/dev/null)" "1"
check_equals "secure user_setup_complete" "$(settings get secure user_setup_complete 2>/dev/null)" "1"
check_equals "system system_locales" "$(settings get system system_locales 2>/dev/null)" "$DEVICE_LOCALE"
check_equals "global adb_enabled" "$(settings get global adb_enabled 2>/dev/null)" "1"
check_equals "global development_enabled" "$(settings get global development_enabled 2>/dev/null)" "1"
check_equals "system screen_brightness" "$(settings get system screen_brightness 2>/dev/null)" "$SCREEN_BRIGHTNESS_LEVEL"
check_equals "system screen_brightness_mode" "$(settings get system screen_brightness_mode 2>/dev/null)" "0"
check_equals "secure tv_user_setup_complete" "$(settings get secure tv_user_setup_complete 2>/dev/null)" "1"
check_equals "secure adb_install_need_confirm" "$(settings get secure adb_install_need_confirm 2>/dev/null)" "0"
check_equals "global package_verifier_enable" "$(settings get global package_verifier_enable 2>/dev/null)" "0"
check_equals "global verifier_verify_adb_installs" "$(settings get global verifier_verify_adb_installs 2>/dev/null)" "0"
check_equals "transition_animation_scale" "$(settings get global transition_animation_scale 2>/dev/null)" "0"
check_equals "animator_duration_scale" "$(settings get global animator_duration_scale 2>/dev/null)" "0"
check_equals "system screen_off_timeout" "$(settings get system screen_off_timeout 2>/dev/null)" "1800000"
check_equals "stay_on_while_plugged_in" "$(settings get global stay_on_while_plugged_in 2>/dev/null)" "7"
check_equals "secure lockscreen.disabled" "$(settings get secure lockscreen.disabled 2>/dev/null)" "1"

# ---- 3.1 时间制式 / 收音机 / 自动化友好 -----------------------------------
check_equals "system time_12_24" "$(settings get system time_12_24 2>/dev/null)" "24"
check_equals "global bluetooth_on" "$(settings get global bluetooth_on 2>/dev/null)" "1"
check_equals "global mobile_data" "$(settings get global mobile_data 2>/dev/null)" "1"
check_equals "window_animation_scale" "$(settings get global window_animation_scale 2>/dev/null)" "0"
check_equals "accelerometer_rotation" "$(settings get system accelerometer_rotation 2>/dev/null)" "0"

CHINESE_IME="com.android.adbkeyboard/.AdbIME"
if pm list packages 2>/dev/null | grep -qx "package:com.android.adbkeyboard"; then
    if ime list -s 2>/dev/null | grep -qx "$CHINESE_IME"; then
        report PASS "chinese input ime" "enabled"
    else
        report FAIL "chinese input ime" "installed but not enabled"
    fi
else
    report FAIL "chinese input ime" "ADBKeyBoard not installed"
fi

# ---- 4. 无线 ADB ------------------------------------------------------------
WIFI_IP="$(ip -f inet addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)"
if sb_port_is_listening "$ADB_TCP_PORT"; then
    report PASS "adbd tcp:${ADB_TCP_PORT}" "listening"
else
    report FAIL "adbd tcp:${ADB_TCP_PORT}" "not listening"
fi
if [ -n "$WIFI_IP" ]; then
    report PASS "wlan0 ipv4" "$WIFI_IP"
else
    report FAIL "wlan0 ipv4" "no address (局域网不可达)"
fi

# ---- 5. su 授权 -------------------------------------------------------------
if sb_magiskd_ready; then
    SU_POLICY="$("$MAGISK" --sqlite \
        "SELECT policy FROM policies WHERE uid=${ADB_SHELL_UID};" 2>/dev/null \
        | tr -d '[:space:]' | sed 's/^[^=]*=//')"
    check_equals "su policy uid=${ADB_SHELL_UID}" "$SU_POLICY" "2"
else
    report WARN "su policy uid=${ADB_SHELL_UID}" "magiskd not ready"
fi

# ---- 6. SELinux 运行时规则 ---------------------------------------------------
SELINUX_RULE_PRESENT=0
if [ -x "$MAGISKPOLICY" ]; then
    if "$MAGISKPOLICY" --print-rules 2>/dev/null \
        | grep -q "logpersistd_logging_prop"; then
        SELINUX_RULE_PRESENT=1
    fi
fi
if [ "$SELINUX_RULE_PRESENT" = "1" ]; then
    report PASS "selinux logpersist rule" "loaded"
else
    report FAIL "selinux logpersist rule" "missing (开发者选项会闪退)"
fi

# ---- 7. 桌面与电池守护 -------------------------------------------------------
check_equals "home activity" "$(sb_current_home_activity)" "$HOME_ACTIVITY"

BATTERY_PIDFILE="${SANDBOX_RUN_DIR}/battery-guard.pid"
if [ -f "$BATTERY_PIDFILE" ]; then
    BATTERY_PID="$(cat "$BATTERY_PIDFILE" 2>/dev/null)"
    if [ -n "$BATTERY_PID" ] && kill -0 "$BATTERY_PID" 2>/dev/null; then
        report PASS "battery-guard" "running (pid ${BATTERY_PID})"
    else
        report WARN "battery-guard" "pidfile stale"
    fi
else
    report WARN "battery-guard" "not started"
fi

WATCHDOG_PIDFILE="${SANDBOX_RUN_DIR}/watchdog.pid"
if [ -f "$WATCHDOG_PIDFILE" ]; then
    WATCHDOG_PID="$(cat "$WATCHDOG_PIDFILE" 2>/dev/null)"
    if [ -n "$WATCHDOG_PID" ] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
        report PASS "watchdog" "running (pid ${WATCHDOG_PID})"
    else
        report WARN "watchdog" "pidfile stale"
    fi
else
    report WARN "watchdog" "not started"
fi

BATTERY_CAPACITY="$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)"
BATTERY_STATUS="$(cat /sys/class/power_supply/battery/status 2>/dev/null)"
if [ -n "$BATTERY_CAPACITY" ]; then
    report PASS "battery" "${BATTERY_CAPACITY}% ${BATTERY_STATUS:-?}"
else
    report WARN "battery" "capacity unreadable"
fi

# ---- 8. Alpine 运行时 -------------------------------------------------------
if [ -x "${SANDBOX_ALPINE_ROOT}/bin/busybox" ]; then
    report PASS "alpine runtime" "$(du -sh "${SANDBOX_ALPINE_ROOT}" 2>/dev/null | awk '{print $1}')"
    PYTHON_VERSION="$(chroot "${SANDBOX_ALPINE_ROOT}" /usr/bin/python3 --version 2>/dev/null)"
    NODE_VERSION="$(chroot "${SANDBOX_ALPINE_ROOT}" /usr/bin/node --version 2>/dev/null)"
    [ -n "$PYTHON_VERSION" ] && report PASS "python" "$PYTHON_VERSION" || report FAIL "python" "not runnable"
    [ -n "$NODE_VERSION" ] && report PASS "node" "$NODE_VERSION" || report FAIL "node" "not runnable"
else
    report FAIL "alpine runtime" "missing: ${SANDBOX_ALPINE_ROOT}"
fi

RUNTIME_SEED=/cache/sandbox-seed/alpine-rootfs.tar.gz
if [ -f "$RUNTIME_SEED" ]; then
    report PASS "runtime seed" "$(ls -lh "$RUNTIME_SEED" | awk '{print $5}')"
else
    report FAIL "runtime seed" "missing (格式化 /data 后无法还原运行时)"
fi

# ---- 8.5 恢复链路完整性（Format Data 后能不能回来）-------------------------
CACHE_SEED=/cache/sandbox-seed/data_seed.tar.gz
if [ -f "$CACHE_SEED" ]; then
    if tar -tzf "$CACHE_SEED" >/dev/null 2>&1 \
        && tar -tzf "$CACHE_SEED" 2>/dev/null | grep -qx "data/adb/sandbox/bin/sandbox-post-fs-data.sh"; then
        report PASS "cache seed" "$(ls -lh "$CACHE_SEED" | awk '{print $5}') 含 sandbox 脚本"
    else
        report FAIL "cache seed" "损坏或缺少 sandbox 脚本"
    fi
else
    report FAIL "cache seed" "missing: ${CACHE_SEED} (Format Data 后无法恢复)"
fi

RAMDISK_SEED=/debug_ramdisk/data_seed.tar.gz
if [ -f "$RAMDISK_SEED" ]; then
    report PASS "ramdisk seed" "$(ls -lh "$RAMDISK_SEED" | awk '{print $5}') 兜底副本"
else
    report FAIL "ramdisk seed" "missing（boot 分区内的兜底副本）"
fi

[ -f /cache/sandbox-seed/ADBKeyboard.apk ] && report PASS "keyboard apk" "present" \
    || report FAIL "keyboard apk" "missing"

RAMDISK_HOOK=/debug_ramdisk/sandbox-post-fs-data.sh
DATA_HOOK=/data/adb/sandbox/bin/sandbox-post-fs-data.sh
if [ -f "$RAMDISK_HOOK" ] && [ -f "$DATA_HOOK" ]; then
    if [ "$(md5sum "$RAMDISK_HOOK" | awk '{print $1}')" = "$(md5sum "$DATA_HOOK" | awk '{print $1}')" ]; then
        report PASS "ramdisk hook" "in sync"
    else
        report FAIL "ramdisk hook" "out of sync (需重新 sandbox-install-boot-hook.sh)"
    fi
else
    report FAIL "ramdisk hook" "missing ${RAMDISK_HOOK}"
fi

if [ -f /data/adb/sandbox/SEED.manifest ]; then
    _manifest_bad="$(cd / && sha256sum -c /data/adb/sandbox/SEED.manifest 2>&1 | grep -vc ': OK$')"
    [ "${_manifest_bad:-1}" -eq 0 ] && report PASS "seed manifest" "all files match" \
        || report FAIL "seed manifest" "${_manifest_bad} file(s) mismatch"
else
    report FAIL "seed manifest" "missing"
fi

# ---- 8.6 虚拟定位 -----------------------------------------------------------
if [ -f /data/adb/sandbox/state/location.conf ]; then
    _mock_target_lat="$(sed -n 's/^LATITUDE=//p' /data/adb/sandbox/state/location.conf | head -n 1)"
    _mock_target_lng="$(sed -n 's/^LONGITUDE=//p' /data/adb/sandbox/state/location.conf | head -n 1)"
    _mock_cur="$(dumpsys location 2>/dev/null | grep -m1 'last location=' | grep -oE '[-0-9]+\.[0-9]+,-[0-9]+\.[0-9]+' | head -n 1)"
    if [ -n "$_mock_cur" ]; then
        _mock_lat="$(printf '%s' "$_mock_cur" | cut -d, -f1)"
        _mock_lng="$(printf '%s' "$_mock_cur" | cut -d, -f2)"
        if awk -v a="$_mock_lat" -v b="$_mock_target_lat" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<0.0002)}' \
            && awk -v a="$_mock_lng" -v b="$_mock_target_lng" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<0.0002)}'; then
            report PASS "mock location" "${_mock_lat},${_mock_lng}"
        else
            report WARN "mock location" "actual ${_mock_cur} != target ${_mock_target_lat},${_mock_target_lng}"
        fi
    else
        report WARN "mock location" "no position reported"
    fi
else
    report WARN "mock location" "location.conf missing"
fi

# ---- 9. 持久化资产 -----------------------------------------------------------
if [ -f "/system/etc/sandbox_seed/data_seed.tar" ]; then
    report PASS "seed tar" "$(ls -lh /system/etc/sandbox_seed/data_seed.tar 2>/dev/null | awk '{print $5}')"
else
    report WARN "seed tar" "missing (格式化 /data 后无法回灌)"
fi

BOOT_BACKUP_COUNT="$(ls -1 "${SANDBOX_BACKUP_DIR}"/boot-*.img 2>/dev/null | wc -l | tr -d ' ')"
if [ "${BOOT_BACKUP_COUNT:-0}" -gt 0 ]; then
    report PASS "boot backup" "${BOOT_BACKUP_COUNT} 份"
else
    report WARN "boot backup" "无备份"
fi

if [ -x /data/adb/magisk/magiskboot ]; then
    report PASS "magiskboot" "$(ls -lh /data/adb/magisk/magiskboot 2>/dev/null | awk '{print $5}')"
else
    report FAIL "magiskboot" "missing"
fi

# ---- 汇总 -------------------------------------------------------------------
printf -- '-----------------------------------------------------------\n'
printf 'PASS=%s  WARN=%s  FAIL=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
