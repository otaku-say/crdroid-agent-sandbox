#!/system/bin/sh
# =============================================================================
# sandbox-post-fs-data.sh —— boot ramdisk 阶段
#
# 运行位置：/sbin/sandbox-post-fs-data.sh（由 overlay.d 从 boot.img 注入）
# 运行时机：init 的 post-fs-data，早于 zygote
#
# 职责：
#   1. 覆写 ro.* 只读属性
#   2. 持久化 adb tcp 端口（Format Data 后 /data/property 也是空的，必须重建）
#   3. 从种子恢复 /data/adb（Magisk 环境 + 全部运维脚本），并按 manifest 校验
#   4. 恢复 Alpine 运行时
#
# 种子副本：/cache/sandbox-seed（主）→ /vendor/sandbox_seed（备）
# 两份都必须含 SEED.manifest，恢复后逐文件校验 sha256。
# =============================================================================

export PATH="/sbin:/debug_ramdisk:/system/bin:/system/xbin:/vendor/bin"

# 每次开机重置"已收敛"标记，供 converge-guard 判断本次开机是否真的跑过
rm -f /data/adb/sandbox/run/.converged-this-boot 2>/dev/null

LOG_DIR=/data/adb/sandbox/log
LOG_FILE="${LOG_DIR}/sandbox-post-fs-data.log"
mkdir -p "$LOG_DIR" 2>/dev/null

LOG_TAG=post-fs-data
log_line() { log "$@"; }
log() {
    _msg="$(date '+%Y-%m-%d %H:%M:%S') [${LOG_TAG}] $*"
    printf '%s\n' "$_msg"
    printf '%s\n' "$_msg" >> "$LOG_FILE" 2>/dev/null
}

set_ro_prop_if_needed() {
    _key="$1"
    _want="$2"
    _cur="$(getprop "$_key")"
    if [ "$_cur" = "$_want" ]; then
        log_line "already satisfied: ${_key}=${_want}"
        return 0
    fi
    resetprop -n "$_key" "$_want"
    _cur="$(getprop "$_key")"
    [ "$_cur" = "$_want" ] && log_line "changed: ${_key}=${_want}" \
        || log_line "FAILED: ${_key} stayed '${_cur}'"
}

# --- 1. ro.* 属性 -------------------------------------------------------------
set_ro_prop_if_needed ro.adb.secure 0
set_ro_prop_if_needed ro.debuggable 1
set_ro_prop_if_needed ro.setupwizard.mode DISABLED

# --- 2. adb tcp 端口持久化 ----------------------------------------------------
# Format Data 会清空 /data/property，而 service.adb.tcp.port 不是 persist 前缀，
# 必须写 persist.adb.tcp.port 才能在 adbd 启动前生效。
if [ "$(getprop persist.adb.tcp.port)" = "5555" ]; then
    log_line "already satisfied: persist.adb.tcp.port=5555"
else
    setprop persist.adb.tcp.port 5555
    log_line "changed: persist.adb.tcp.port=$(getprop persist.adb.tcp.port)"
fi

# --- 3. /data/adb 恢复 --------------------------------------------------------
# 三级种子副本，按可靠性排序：
#   ramdisk（boot 分区内，Format Data / Wipe Cache 都不影响）
#   /cache（可写，但 Wipe Cache 会清）
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SEED_RAMDISK="${SELF_DIR}/data_seed.tar.gz"
SEED_CACHE=/cache/sandbox-seed/data_seed.tar.gz

if [ ! -f "$SEED_CACHE" ]; then
    _wait=0
    while [ "$_wait" -lt 10 ] && [ ! -f "$SEED_CACHE" ]; do
        sleep 1
        _wait=$((_wait + 1))
    done
fi

if [ -f "$SEED_RAMDISK" ]; then
    SEED_TAR="$SEED_RAMDISK"
elif [ -f "$SEED_CACHE" ]; then
    SEED_TAR="$SEED_CACHE"
else
    SEED_TAR=""
fi

# 判据覆盖全部关键目录，任一缺失即整体重灌
NEED_RESTORE=0
[ -x /data/adb/magisk/magisk64 ] || [ -x /data/adb/magisk/magisk ] || NEED_RESTORE=1
[ -f /data/adb/sandbox/bin/sandbox-boot-converge.sh ] || NEED_RESTORE=1
[ -f /data/adb/sandbox/lib/sandbox-lib.sh ] || NEED_RESTORE=1
[ -f /data/adb/sandbox/policy/sandbox-logpersist.te ] || NEED_RESTORE=1
[ -f /data/adb/sandbox/boot/sandbox-overlay.rc ] || NEED_RESTORE=1
[ -f /data/adb/service.d/sandbox-boot-converge.sh ] || NEED_RESTORE=1

if [ "$NEED_RESTORE" -eq 0 ]; then
    log_line "already satisfied: /data/adb complete"
elif [ -z "$SEED_TAR" ]; then
    log_line "FAILED: /data/adb incomplete and no seed (checked ${SEED_RAMDISK}, ${SEED_CACHE})"
else
    log_line "changed: restoring /data/adb from ${SEED_TAR}"
    mkdir -p /data/adb /data/misc/adb /data/local/tmp
    tar -xpzf "$SEED_TAR" -C /
    chown -R 0:0 /data/adb 2>/dev/null
    chmod 700 /data/adb 2>/dev/null
    chmod -R 755 /data/adb/magisk /data/adb/service.d 2>/dev/null
    chmod -R 755 /data/adb/sandbox/bin /data/adb/sandbox/lib 2>/dev/null
    chmod 644 /data/adb/sandbox/policy/*.te /data/adb/sandbox/boot/*.rc 2>/dev/null
    restorecon -R /data/adb 2>/dev/null

    # manifest 校验：任何一项不匹配都说明种子与代码不同步
    if [ -f /data/adb/sandbox/SEED.manifest ]; then
        _bad="$(cd / && sha256sum -c /data/adb/sandbox/SEED.manifest 2>&1 | grep -v ': OK$')"
        if [ -z "$_bad" ]; then
            log_line "verified: SEED.manifest all OK"
        else
            log_line "ERROR: SEED.manifest mismatch: $(printf '%s' "$_bad" | head -3 | tr '\n' ' ')"
        fi
    else
        log_line "ERROR: SEED.manifest missing in seed"
    fi

    # 关键：本次开机 magiskd 扫描 service.d 时该目录还不存在（刚刚才被恢复），
    # 所以 sandbox-boot-converge.sh 不会被自动执行。必须在这里主动拉起一次，
    # 否则首启（Format Data 后）设备会停在"脚本齐全但守护进程全没起"的半残状态。
    # service.d 是本次开机才恢复的，magiskd 早已扫描完毕，不会自动执行。
    # post-fs-data 里 fork 的后台进程又会被 init 在阶段切换时回收，
    # 所以收敛交给 init service sandbox_converge_guard（late-init 后补偿执行）。
    log_line "service.d restored; converge delegated to sandbox_converge_guard"
fi

# --- 4. adb 公钥 --------------------------------------------------------------
if [ -s /data/misc/adb/adb_keys ]; then
    log_line "already satisfied: adb_keys present"
    chown -R 1000:2000 /data/misc/adb 2>/dev/null
    chmod 2770 /data/misc/adb 2>/dev/null
    chmod 0640 /data/misc/adb/adb_keys 2>/dev/null
else
    log_line "ERROR: adb_keys missing"
fi

# --- 5. Alpine 运行时 ---------------------------------------------------------
RUNTIME_ROOTFS=/data/adb/sandbox/runtime/alpine
RUNTIME_SEED=/cache/sandbox-seed/alpine-rootfs.tar.gz
RUNTIME_MARKER="${RUNTIME_ROOTFS}/.seed-complete"

if [ -x "${RUNTIME_ROOTFS}/bin/busybox" ] && [ -f "$RUNTIME_MARKER" ]; then
    log_line "already satisfied: alpine runtime"
elif [ -f "$RUNTIME_SEED" ]; then
    log_line "changed: restoring alpine runtime from ${RUNTIME_SEED}"
    for _mnt in proc sys dev; do
        umount "${RUNTIME_ROOTFS}/${_mnt}" 2>/dev/null
    done
    rm -rf "$RUNTIME_ROOTFS"
    mkdir -p "$RUNTIME_ROOTFS"
    if tar -xzf "$RUNTIME_SEED" -C "$RUNTIME_ROOTFS"; then
        printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n' \
            > "${RUNTIME_ROOTFS}/etc/resolv.conf"
        # 只有解包成功才写完成标记，避免半截 rootfs 被永久误判为完好
        date '+%Y-%m-%d %H:%M:%S' > "$RUNTIME_MARKER"
        log_line "verified: alpine runtime unpacked"
    else
        log_line "ERROR: alpine runtime unpack failed"
    fi
else
    log_line "FAILED: alpine runtime missing and ${RUNTIME_SEED} not found"
fi

log_line "done"
