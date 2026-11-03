#!/system/bin/sh
# =============================================================================
# sandbox-boot-converge.sh —— 运行期状态收敛器
#
# 运行时机：由 /data/adb/service.d/sandbox-boot-converge.sh 在开机 late_start 阶段调用，
#           也可以随时手动执行（例如改完配置后补跑一次）。
#
# 职责：把系统的运行期状态收敛到沙箱基线。每一项都是幂等的：
#   已满足 -> 打印 "already satisfied" 且不写入
#   不满足 -> 写入并读回校验，校验失败计入 failed
#
# 用法：
#   sandbox-boot-converge.sh             正常收敛
#   sandbox-boot-converge.sh --dry-run   只报告差异，不写入
#   sandbox-boot-converge.sh --no-wait   不等待开机完成（手动调试用）
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../lib/sandbox-lib.sh"

# ---- 沙箱基线（改这里就能改行为，脚本其余部分不用动）-------------------------
ADB_TCP_PORT=5555
SCREEN_BRIGHTNESS_LEVEL=450
DEVICE_LOCALE="zh-CN"
HOME_ACTIVITY="com.android.launcher3/.uioverrides.QuickstepLauncher"
ADB_SHELL_UID=2000
ADB_SHELL_SU_POLICY=2          # 2 = Magisk "grant" 永久授权
SELINUX_POLICY_FILE="${SANDBOX_POLICY_DIR}/sandbox-logpersist.te"
BATTERY_GUARD_SCRIPT="${SANDBOX_BIN_DIR}/sandbox-battery-guard.sh"
BATTERY_GUARD_PIDFILE="${SANDBOX_RUN_DIR}/battery-guard.pid"
WATCHDOG_SCRIPT="${SANDBOX_BIN_DIR}/sandbox-watchdog.sh"
WATCHDOG_PIDFILE="${SANDBOX_RUN_DIR}/watchdog.pid"
LOCATION_GUARD_SCRIPT="${SANDBOX_BIN_DIR}/sandbox-location-guard.sh"
LOCATION_GUARD_PIDFILE="${SANDBOX_RUN_DIR}/location-guard.pid"
ADB_KEYBOARD_APK=/cache/sandbox-seed/ADBKeyboard.apk
MOCK_GPS_APK=/cache/sandbox-seed/MockMyGPS.apk

WAIT_FOR_BOOT=1

# ---- 参数解析 ---------------------------------------------------------------
for _arg in "$@"; do
    case "$_arg" in
        --dry-run) SANDBOX_DRY_RUN=1 ;;
        --no-wait) WAIT_FOR_BOOT=0 ;;
        --help)
            printf 'usage: %s [--dry-run] [--no-wait]\n' "$(basename "$0")"
            exit 0
            ;;
    esac
done

sb_init

if ! sb_is_root; then
    sb_err "must run as root (uid=$(id -u 2>/dev/null))"
    exit 1
fi

# ---- 等待系统就绪 -----------------------------------------------------------
if [ "$WAIT_FOR_BOOT" = "1" ]; then
    # 首启（Format Data 后）要编译全盘 dex/oat，可能远超 5 分钟。
    # 等不到也不 exit：先把不依赖 zygote 的部分做完，由 service.d 入口重试补齐。
    if sb_wait_until "sys.boot_completed=1" 600 sb_boot_completed; then
        sb_info "boot completed"
    else
        sb_warn "boot not completed after 600s, continuing with best-effort convergence"
    fi
fi

sb_wait_until "magiskd ready" 60 sb_magiskd_ready
sb_wait_until "settings provider" 60 sb_settings_ready

# -----------------------------------------------------------------------------
# 1. 开机相关标志：跳过 MIUI 新手向导
# -----------------------------------------------------------------------------
sb_ensure_setting global device_provisioned 1
sb_ensure_setting secure user_setup_complete 1
sb_ensure_setting secure tv_user_setup_complete 1
sb_ensure_setting system system_locales "$DEVICE_LOCALE"

# -----------------------------------------------------------------------------
# 2. 开发者选项与 ADB
# -----------------------------------------------------------------------------
sb_ensure_setting global development_enabled 1
sb_ensure_setting global adb_enabled 1
sb_ensure_setting secure adb_install_need_confirm 0
sb_ensure_setting global package_verifier_enable 0
sb_ensure_setting global verifier_verify_adb_installs 0

# -----------------------------------------------------------------------------
# 3. 依赖 APK：中文输入法 + 虚拟定位 provider
# -----------------------------------------------------------------------------
sb_ensure_package_installed com.android.adbkeyboard "$ADB_KEYBOARD_APK"
sb_ensure_ime_enabled com.android.adbkeyboard/.AdbIME
sb_ensure_package_installed com.github.warren_bank.mock_location "$MOCK_GPS_APK"

# -----------------------------------------------------------------------------
# 4. 显示：固定亮度、关闭自动亮度（沙箱常亮运维需要）
# -----------------------------------------------------------------------------
sb_ensure_setting system screen_brightness_mode 0
sb_ensure_setting system screen_brightness "$SCREEN_BRIGHTNESS_LEVEL"
sb_ensure_setting system time_12_24 24

# -----------------------------------------------------------------------------
# 5. 自动化友好：关动画、锁竖屏、延长超时、充电常亮、免锁屏
#    动画缩放为 0 后 uiautomator 拿到的层级不再等动画结束，点击坐标更稳
# -----------------------------------------------------------------------------
sb_ensure_setting global window_animation_scale 0
sb_ensure_setting global transition_animation_scale 0
sb_ensure_setting global animator_duration_scale 0
sb_ensure_setting system accelerometer_rotation 0
sb_ensure_setting system screen_off_timeout 1800000
sb_ensure_setting global stay_on_while_plugged_in 7
sb_ensure_setting secure lockscreen.disabled 1

# -----------------------------------------------------------------------------
# 6. 收音机默认开启（MIUI 的 svc data 只写 mobile_data1，总开关需另外落）
# -----------------------------------------------------------------------------
sb_ensure_bluetooth_enabled
sb_ensure_mobile_data_enabled

# -----------------------------------------------------------------------------
# 7. 桌面：固定 Home，避免 FallbackHome 与 miui.home 争抢导致闪烁
# -----------------------------------------------------------------------------
sb_ensure_home_activity "$HOME_ACTIVITY"

# -----------------------------------------------------------------------------
# 8. SELinux：修复开发者选项闪退（每次开机都必须重新 apply，live 策略会重置）
# -----------------------------------------------------------------------------
sb_apply_selinux_policy "$SELINUX_POLICY_FILE"

# -----------------------------------------------------------------------------
# 9. WiFi：Format Data 后 keystore 被重置，必须用明文凭据重新关联
# -----------------------------------------------------------------------------
sb_ensure_wlan_connected

# -----------------------------------------------------------------------------
# 10. 无线 ADB：固定 5555 并确保真的在监听
# -----------------------------------------------------------------------------
sb_ensure_adb_tcp_listener "$ADB_TCP_PORT"

# -----------------------------------------------------------------------------
# 11. Magisk：UID 2000 永久免弹窗授权
# -----------------------------------------------------------------------------
sb_ensure_su_policy "$ADB_SHELL_UID" "$ADB_SHELL_SU_POLICY"

# -----------------------------------------------------------------------------
# 12. 运行期服务开关（无可靠读回值，直接应用，重复执行无副作用）
# -----------------------------------------------------------------------------
if [ "$SANDBOX_DRY_RUN" != "1" ]; then
    dumpsys deviceidle disable >/dev/null 2>&1
    svc power stayon true >/dev/null 2>&1
    sb_info "applied: deviceidle disabled, stayon enabled"
fi

# -----------------------------------------------------------------------------
# 13. 常驻守护（battery / watchdog / location-guard）
#     由 init service sandbox_guardian 管理，见 lib/sandbox-guardian.sh。
#     converge 只负责一次性状态收敛，不再 fork 任何后台进程。
# -----------------------------------------------------------------------------
sb_info "daemons are managed by init service sandbox_guardian"

# -----------------------------------------------------------------------------
# 14. 原厂温控配置（thermal-*.conf 曾被方案删除，7x24 需要完整温控）
# -----------------------------------------------------------------------------
sb_ensure_thermal_profiles

sb_summary
