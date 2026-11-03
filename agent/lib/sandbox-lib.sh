#!/system/bin/sh
# =============================================================================
# sandbox-lib.sh —— 小米9 沙箱运维库
#
# 目标环境（不再做向下兼容）：
#   Android 11 / MIUI 12.5 / arm64 / Magisk 31.1 / mksh / toybox
#
# 约定
#   1. 调用方不要 set -e。每个 ensure_* 自己处理失败，互不影响。
#   2. 每个 ensure_* 先读回真实状态，有差异才写；重复执行应当零写入。
#   3. SANDBOX_DRY_RUN=1 时只报告差异，不写入。
#   4. 结果累计到 SB_CHANGED / SB_UNCHANGED / SB_FAILED，由 sb_summary 汇总。
# =============================================================================

SANDBOX_ROOT=/data/adb/sandbox
SANDBOX_LOG_DIR="${SANDBOX_ROOT}/log"
SANDBOX_RUN_DIR="${SANDBOX_ROOT}/run"
SANDBOX_BACKUP_DIR="${SANDBOX_ROOT}/backup"
SANDBOX_POLICY_DIR="${SANDBOX_ROOT}/policy"
SANDBOX_BOOT_DIR="${SANDBOX_ROOT}/boot"
SANDBOX_BIN_DIR="${SANDBOX_ROOT}/bin"
SANDBOX_RUNTIME_DIR="${SANDBOX_ROOT}/runtime"
SANDBOX_ALPINE_ROOT="${SANDBOX_RUNTIME_DIR}/alpine"

# Magisk v31.1 在 crDroid 13 上把运行时二进制放在 /debug_ramdisk，
# /data/adb/magisk 只有空目录，所以固定用 ramdisk 路径。
MAGISK_BIN_DIR=/debug_ramdisk
MAGISK="${MAGISK_BIN_DIR}/magisk"
# magiskpolicy / magiskboot 不在 ramdisk（v31.1 只放 magisk 主二进制），
# 由部署脚本放到 sandbox 自己的 tools 目录
MAGISKPOLICY=/data/adb/sandbox/tools/magiskpolicy
MAGISKBOOT=/data/adb/sandbox/tools/magiskboot

SANDBOX_DRY_RUN="${SANDBOX_DRY_RUN:-0}"
SANDBOX_TAG="$(basename "$0" .sh)"
SANDBOX_LOG_FILE="${SANDBOX_LOG_DIR}/${SANDBOX_TAG}.log"

SB_CHANGED=0
SB_UNCHANGED=0
SB_FAILED=0

# --- 日志 ---------------------------------------------------------------------

sb_init() {
    mkdir -p "$SANDBOX_LOG_DIR" "$SANDBOX_RUN_DIR" "$SANDBOX_BACKUP_DIR"
    [ -f "$SANDBOX_LOG_FILE" ] || : > "$SANDBOX_LOG_FILE"
    [ "$(wc -c < "$SANDBOX_LOG_FILE")" -gt 262144 ] && mv -f "$SANDBOX_LOG_FILE" "${SANDBOX_LOG_FILE}.1"
    sb_log INFO "===== ${SANDBOX_TAG} start (dry_run=${SANDBOX_DRY_RUN}) ====="
}

sb_log() {
    _level="$1"
    shift
    _line="$(date '+%Y-%m-%d %H:%M:%S') [${SANDBOX_TAG}] [${_level}] $*"
    printf '%s\n' "$_line"
    printf '%s\n' "$_line" >> "$SANDBOX_LOG_FILE"
}

sb_info() { sb_log INFO "$@"; }
sb_ok() { sb_log OK "$@"; }
sb_warn() { sb_log WARN "$@"; }
sb_err() { sb_log ERROR "$@"; }

sb_record_changed() { SB_CHANGED=$((SB_CHANGED + 1)); sb_ok "$@"; }
sb_record_unchanged() { SB_UNCHANGED=$((SB_UNCHANGED + 1)); sb_info "already satisfied: $*"; }
sb_record_failed() { SB_FAILED=$((SB_FAILED + 1)); sb_err "$@"; }

sb_summary() {
    sb_log INFO "===== summary: changed=${SB_CHANGED} unchanged=${SB_UNCHANGED} failed=${SB_FAILED} ====="
    [ "$SB_FAILED" -eq 0 ]
}

# --- 探测 ---------------------------------------------------------------------

sb_is_root() { [ "$(id -u)" = 0 ]; }
sb_boot_completed() { [ "$(getprop sys.boot_completed)" = 1 ]; }
sb_magiskd_ready() { "$MAGISK" -v >/dev/null 2>&1; }
sb_settings_ready() { settings list global >/dev/null 2>&1; }

# sb_wait_until <描述> <秒> <检查命令...>
sb_wait_until() {
    _desc="$1"
    _limit="$2"
    shift 2
    _n=0
    while [ "$_n" -lt "$_limit" ]; do
        "$@" && return 0
        sleep 1
        _n=$((_n + 1))
    done
    sb_warn "timeout ${_limit}s waiting for: ${_desc}"
    return 1
}

# --- 幂等：属性 ---------------------------------------------------------------
# ro.* 由 init 写死，只能用 resetprop -n 覆写内存值。
# 其余属性用 setprop，才能触发 property 变更回调。

sb_ensure_ro_prop() {
    _key="$1"
    _want="$2"
    _cur="$(getprop "$_key")"
    [ "$_cur" = "$_want" ] && { sb_record_unchanged "ro property ${_key}=${_want}"; return 0; }
    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would set ro property ${_key}: '${_cur}' -> '${_want}'"; return 0; }
    resetprop -n "$_key" "$_want"
    _cur="$(getprop "$_key")"
    [ "$_cur" = "$_want" ] && { sb_record_changed "ro property ${_key}=${_want}"; return 0; }
    sb_record_failed "ro property ${_key} stayed '${_cur}', expected '${_want}'"
    return 1
}

sb_ensure_prop() {
    _key="$1"
    _want="$2"
    _cur="$(getprop "$_key")"
    [ "$_cur" = "$_want" ] && { sb_record_unchanged "property ${_key}=${_want}"; return 0; }
    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would set property ${_key}: '${_cur}' -> '${_want}'"; return 0; }
    setprop "$_key" "$_want"
    _cur="$(getprop "$_key")"
    [ "$_cur" = "$_want" ] && { sb_record_changed "property ${_key}=${_want}"; return 0; }
    sb_record_failed "property ${_key} stayed '${_cur}', expected '${_want}'"
    return 1
}

# --- 幂等：settings -----------------------------------------------------------

sb_ensure_setting() {
    _ns="$1"
    _key="$2"
    _want="$3"
    _cur="$(settings get "$_ns" "$_key")"
    [ "$_cur" = "$_want" ] && { sb_record_unchanged "setting ${_ns}/${_key}=${_want}"; return 0; }
    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would set ${_ns}/${_key}: '${_cur}' -> '${_want}'"; return 0; }
    settings put "$_ns" "$_key" "$_want"
    _cur="$(settings get "$_ns" "$_key")"
    [ "$_cur" = "$_want" ] && { sb_record_changed "setting ${_ns}/${_key}=${_want}"; return 0; }
    sb_record_failed "setting ${_ns}/${_key} stayed '${_cur}'"
    return 1
}

# --- 幂等：应用包 -------------------------------------------------------------

sb_package_state() {
    pm list packages -e | grep -qx "package:$1" && { printf enabled; return; }
    pm list packages -d | grep -qx "package:$1" && { printf disabled; return; }
    printf missing
}

sb_ensure_package_disabled() {
    _pkg="$1"
    case "$(sb_package_state "$_pkg")" in
        disabled) sb_record_unchanged "package ${_pkg} disabled"; return 0 ;;
        missing) sb_record_unchanged "package ${_pkg} not installed"; return 0 ;;
    esac
    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would disable package ${_pkg}"; return 0; }
    pm disable-user --user 0 "$_pkg" >/dev/null
    [ "$(sb_package_state "$_pkg")" = disabled ] && { sb_record_changed "package ${_pkg} -> disabled"; return 0; }
    sb_record_failed "package ${_pkg} not disabled"
    return 1
}

# --- 幂等：默认 Home ---------------------------------------------------------

sb_current_home_activity() {
    cmd package resolve-activity --brief \
        -a android.intent.action.MAIN -c android.intent.category.HOME | tail -n 1
}

sb_ensure_home_activity() {
    _want="$1"
    _cur="$(sb_current_home_activity)"
    [ "$_cur" = "$_want" ] && { sb_record_unchanged "home activity ${_want}"; return 0; }
    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would set home activity: '${_cur}' -> '${_want}'"; return 0; }
    cmd package set-home-activity "$_want"
    _cur="$(sb_current_home_activity)"
    [ "$_cur" = "$_want" ] && { sb_record_changed "home activity -> ${_want}"; return 0; }
    sb_record_failed "home activity stayed '${_cur}'"
    return 1
}

# --- 幂等：TCP 监听 -----------------------------------------------------------
# 不走 netstat：Android 11 的 toybox netstat 没有 -p，输出不可靠。
# 直接读 /proc/net/tcp{,6}：第 2 列尾部是 HEX 端口，第 4 列 0A 表示 LISTEN。

sb_port_is_listening() {
    _hex="$(printf '%04X' "$1")"
    awk -v suffix=":${_hex}" \
        '$2 ~ (suffix "$") && $4 == "0A" { found = 1 } END { exit(found ? 0 : 1) }' \
        /proc/net/tcp /proc/net/tcp6
}

sb_ensure_adb_tcp_listener() {
    _port="$1"
    sb_ensure_prop service.adb.tcp.port "$_port"
    sb_port_is_listening "$_port" && { sb_record_unchanged "adbd listening on tcp:${_port}"; return 0; }
    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would restart adbd to listen on tcp:${_port}"; return 0; }
    setprop ctl.restart adbd
    _n=0
    while [ "$_n" -lt 10 ]; do
        sleep 1
        sb_port_is_listening "$_port" && { sb_record_changed "adbd listening on tcp:${_port}"; return 0; }
        _n=$((_n + 1))
    done
    sb_record_failed "adbd still not listening on tcp:${_port}"
    return 1
}

# --- 幂等：SELinux 运行时策略 -------------------------------------------------
# Magisk 31.1 的 magiskpolicy 语句不带冒号：
#   allow system_app logpersistd_logging_prop property_service set
# 带冒号的 .te 写法会报 Syntax error。

sb_selinux_policy_loaded() {
    _file="$1"
    [ -r "$_file" ] || return 1
    _live="$("$MAGISKPOLICY" --print-rules)"
    while IFS= read -r _rule; do
        case "$_rule" in
            allow\ *) ;;
            *) continue ;;
        esac
        _key="$(printf '%s' "$_rule" | awk '{print $1, $2, $3, $4}')"
        case "$_live" in
            *"$_key"*) ;;
            *) return 1 ;;
        esac
    done < "$_file"
    return 0
}

sb_apply_selinux_policy() {
    _file="$1"
    sb_selinux_policy_loaded "$_file" && { sb_record_unchanged "selinux policy loaded: $(basename "$_file")"; return 0; }
    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would apply selinux policy $(basename "$_file")"; return 0; }
    _out="$("$MAGISKPOLICY" --live --apply "$_file" 2>&1)"
    case "$_out" in
        *"Syntax error"*|*"does not exist"*)
            sb_record_failed "selinux policy rejected: $(printf '%s' "$_out" | head -2 | tr '\n' ' ')"
            return 1
            ;;
    esac
    sb_record_changed "selinux policy applied: $(basename "$_file")"
}

# --- 幂等：Magisk su 授权 -----------------------------------------------------
# magisk --sqlite 的查询输出形如 "policy=2"。

sb_ensure_su_policy() {
    _uid="$1"
    _want="$2"
    sb_magiskd_ready || { sb_record_failed "magiskd not ready (su policy uid=${_uid})"; return 1; }
    _cur="$("$MAGISK" --sqlite "SELECT policy FROM policies WHERE uid=${_uid};" | tr -d '[:space:]' | sed 's/^[^=]*=//')"
    [ "$_cur" = "$_want" ] && { sb_record_unchanged "su policy uid=${_uid} policy=${_want}"; return 0; }
    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would set su policy uid=${_uid} policy=${_want}"; return 0; }
    "$MAGISK" --sqlite \
        "REPLACE INTO policies (uid, policy, until, logging, notification) VALUES (${_uid}, ${_want}, 0, 1, 0);" >/dev/null
    _cur="$("$MAGISK" --sqlite "SELECT policy FROM policies WHERE uid=${_uid};" | tr -d '[:space:]' | sed 's/^[^=]*=//')"
    [ "$_cur" = "$_want" ] && { sb_record_changed "su policy uid=${_uid} -> ${_want}"; return 0; }
    sb_record_failed "su policy uid=${_uid} stayed '${_cur}'"
    return 1
}

# --- 幂等：后台守护（pidfile 由守护脚本自己写）--------------------------------

# sb_ensure_daemon <脚本路径> <pidfile> <标签> [init服务名]
# 给了服务名就走 init 管理（进程不会被 converge 退出时按 process group 杀掉）
sb_ensure_daemon() {
    _script="$1"
    _pidfile="$2"
    _label="$3"
    _service="${4:-}"
    _daemon_base="$(basename "$_script")"
    if [ -f "$_pidfile" ]; then
        _pid="$(cat "$_pidfile")"
        # PID 会被系统复用，必须核对 cmdline 确实是目标脚本，
        # 否则重启后会把无关进程误判成"守护进程还活着"而跳过启动。
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            case "$(tr '\0' ' ' < "/proc/${_pid}/cmdline" 2>/dev/null)" in
                *"$_daemon_base"*)
                    sb_record_unchanged "daemon ${_label} running (pid ${_pid})"
                    return 0
                    ;;
            esac
        fi
    fi
    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would start daemon ${_label}"; return 0; }
    rm -f "$_pidfile"
    setsid sh "$_script" >/dev/null 2>&1 < /dev/null &
    _n=0
    while [ "$_n" -lt 5 ]; do
        sleep 1
        if [ -f "$_pidfile" ]; then
            _pid="$(cat "$_pidfile")"
            if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
                sb_record_changed "daemon ${_label} started (pid ${_pid})"
                return 0
            fi
        fi
        _n=$((_n + 1))
    done
    sb_record_failed "daemon ${_label} failed to start"
    return 1
}

# --- 幂等：安装 APK -----------------------------------------------------------
# 已安装则跳过；APK 从种子目录取，装完清理临时文件。

sb_ensure_package_installed() {
    _pkg="$1"
    _apk="$2"
    pm list packages 2>/dev/null | grep -qx "package:${_pkg}" && {
        sb_record_unchanged "package ${_pkg} installed"
        return 0
    }
    [ -f "$_apk" ] || { sb_record_failed "apk missing: ${_apk}"; return 1; }
    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would install ${_apk}"; return 0; }
    _stage=/data/local/tmp/sandbox-install.apk
    cp -f "$_apk" "$_stage"
    chmod 644 "$_stage"
    pm install -r "$_stage" >/dev/null 2>&1
    rm -f "$_stage"
    pm list packages 2>/dev/null | grep -qx "package:${_pkg}" && {
        sb_record_changed "package ${_pkg} installed from $(basename "$_apk")"
        return 0
    }
    sb_record_failed "package ${_pkg} install failed"
    return 1
}

# --- 幂等：启用输入法 ---------------------------------------------------------

sb_ensure_ime_enabled() {
    _ime="$1"
    ime list -s 2>/dev/null | grep -qx "$_ime" && {
        sb_record_unchanged "ime ${_ime} enabled"
        return 0
    }
    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would enable ime ${_ime}"; return 0; }
    # 刚安装完 APK 时 IME 服务尚未注册，enable 会失败，需要重试
    _ime_tries=0
    while [ "$_ime_tries" -lt 10 ]; do
        ime enable "$_ime" >/dev/null 2>&1
        ime list -s 2>/dev/null | grep -qx "$_ime" && {
            sb_record_changed "ime ${_ime} enabled"
            return 0
        }
        sleep 1
        _ime_tries=$((_ime_tries + 1))
    done
    sb_record_failed "ime ${_ime} not enabled after retries"
    return 1
}

# --- 幂等：收音机开关（蓝牙 / 移动数据）--------------------------------------
# MIUI 的 `svc data enable` 只写 mobile_data1（分卡开关），不会同步 global
# mobile_data 总开关，所以两者都要落。

sb_ensure_bluetooth_enabled() {
    _bt_cur="$(settings get global bluetooth_on)"
    [ "$_bt_cur" = 1 ] && { sb_record_unchanged "bluetooth enabled"; return 0; }
    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would enable bluetooth"; return 0; }
    svc bluetooth enable >/dev/null 2>&1
    _n=0
    while [ "$_n" -lt 10 ]; do
        sleep 1
        [ "$(settings get global bluetooth_on)" = 1 ] && { sb_record_changed "bluetooth enabled"; return 0; }
        _n=$((_n + 1))
    done
    sb_record_failed "bluetooth not enabled"
    return 1
}

sb_ensure_mobile_data_enabled() {
    _md_cur="$(settings get global mobile_data)"
    [ "$_md_cur" = 1 ] && { sb_record_unchanged "mobile data enabled"; return 0; }
    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would enable mobile data"; return 0; }
    svc data enable >/dev/null 2>&1
    settings put global mobile_data 1
    _n=0
    while [ "$_n" -lt 10 ]; do
        sleep 1
        [ "$(settings get global mobile_data)" = 1 ] && { sb_record_changed "mobile data enabled"; return 0; }
        _n=$((_n + 1))
    done
    sb_record_failed "mobile data not enabled"
    return 1
}

# --- 幂等：恢复原厂温控配置 -----------------------------------------------
# 制定沙箱方案时 thermal-*.conf 被物理删除，thermal-engine 只能走内置默认策略。
# 7x24 无人值守需要完整温控，这里从 /system 的备份目录恢复到 /vendor/etc。
# /vendor 在本机是真实 rw ext4，写入直接持久化。

sb_ensure_thermal_profiles() {
    _thermal_src=/system/etc/miui_removed_backup/thermal
    _thermal_dst=/vendor/etc

    if [ ! -d "$_thermal_src" ]; then
        sb_record_unchanged "thermal backup dir absent (already original layout)"
        return 0
    fi

    _thermal_changed=0
    for _conf in "$_thermal_src"/*.conf; do
        [ -f "$_conf" ] || continue
        _name="$(basename "$_conf")"
        if cmp -s "$_conf" "${_thermal_dst}/${_name}" 2>/dev/null; then
            continue
        fi
        [ "$SANDBOX_DRY_RUN" = 1 ] && { _thermal_changed=$((_thermal_changed + 1)); continue; }
        cp -f "$_conf" "${_thermal_dst}/${_name}"
        chmod 644 "${_thermal_dst}/${_name}"
        restorecon "${_thermal_dst}/${_name}" 2>/dev/null
        _thermal_changed=$((_thermal_changed + 1))
    done

    if [ "$_thermal_changed" -eq 0 ]; then
        sb_record_unchanged "thermal profiles already restored"
        return 0
    fi
    if [ "$SANDBOX_DRY_RUN" = 1 ]; then
        sb_record_changed "would restore ${_thermal_changed} thermal profile(s)"
    else
        sb_record_changed "restored ${_thermal_changed} thermal profile(s) to /vendor/etc"
    fi
}

# --- 幂等：WiFi 连接 ---------------------------------------------------------
# Format Data 会抹掉 /data/misc/apexdata 的 WiFi 配置，且那份配置是用 keystore
# 里的密钥加密的，keystore 一并被抹掉后即便恢复 XML 也解不开。
# 唯一可行的自动恢复方式是拿明文凭据重新关联：
#   /data/adb/sandbox/state/wifi.conf  内容两行：SSID=xxx / PASSWORD=xxx

sb_wlan_ipv4() {
    ip -f inet addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1
}

sb_ensure_wlan_connected() {
    _wlan_ip="$(sb_wlan_ipv4)"
    if [ -n "$_wlan_ip" ]; then
        sb_record_unchanged "wlan0 connected (${_wlan_ip})"
        return 0
    fi

    _wifi_conf=/data/adb/sandbox/state/wifi.conf
    if [ ! -f "$_wifi_conf" ]; then
        sb_record_failed "wlan0 has no IPv4 and ${_wifi_conf} is missing"
        return 1
    fi

    _wifi_pass="$(sed -n 's/^PASSWORD=//p' "$_wifi_conf" | head -n 1)"
    # 用空格拼接成单词列表，避免 while-read 进入管道子 shell 后 exit 传不回来
    _wifi_ssids="$(sed -n 's/^SSID=//p' "$_wifi_conf" | tr '\n' ' ')"
    case "$_wifi_ssids" in
        *[!\ ]*) ;;
        *) sb_record_failed "wifi.conf has no SSID lines"; return 1 ;;
    esac

    [ "$SANDBOX_DRY_RUN" = 1 ] && { sb_record_changed "would join wifi: ${_wifi_ssids}"; return 0; }

    svc wifi enable >/dev/null 2>&1
    # 等 WiFi 真正打开，否则 connect-network 会被直接拒绝
    _n=0
    while [ "$_n" -lt 15 ]; do
        [ "$(settings get global wifi_on 2>/dev/null)" = 1 ] && break
        sleep 1
        _n=$((_n + 1))
    done
    sleep 3

    for _ssid in $_wifi_ssids; do
        sb_info "trying wifi: ${_ssid}"
        cmd wifi connect-network "$_ssid" wpa2 "$_wifi_pass" >/dev/null 2>&1
        _n=0
        while [ "$_n" -lt 15 ]; do
            sleep 2
            _wlan_ip="$(sb_wlan_ipv4)"
            [ -n "$_wlan_ip" ] && break
            _n=$((_n + 1))
        done
        if [ -n "$_wlan_ip" ]; then
            sb_record_changed "wlan0 joined ${_ssid} (${_wlan_ip})"
            return 0
        fi
    done

    sb_record_failed "wlan0 still has no IPv4 after trying: ${_wifi_ssids}"
    return 1
}
