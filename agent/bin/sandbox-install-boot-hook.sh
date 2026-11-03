#!/system/bin/sh
# =============================================================================
# sandbox-install-boot-hook.sh —— 把 post-fs-data 钩子幂等注入 boot.img
#
# 幂等的判断依据不是文件时间戳，而是：
#   1. 解开当前 boot.img 后，ramdisk.cpio 里是否已有目标 entry
#   2. 已存在的 entry 内容是否与源文件逐字节相同（cmp）
# 两者都满足才跳过，否则才重打包并写回 boot 分区。
#
# 写回前会把当前 boot 分区备份到 /data/adb/sandbox/backup/。
#
# 用法：
#   sandbox-install-boot-hook.sh            检查并注入（需要时写 boot 分区）
#   sandbox-install-boot-hook.sh --dry-run  只检查，不写
#   sandbox-install-boot-hook.sh --status   只报告当前钩子状态
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../lib/sandbox-lib.sh"

SANDBOX_BOOT_DIR="${SANDBOX_ROOT}/boot"
SANDBOX_LIB_DIR="${SANDBOX_ROOT}/lib"
SOURCE_SCRIPT="${SANDBOX_BIN_DIR}/sandbox-post-fs-data.sh"
SOURCE_RC="${SANDBOX_BOOT_DIR}/sandbox-overlay.rc"
ENTRY_SCRIPT="overlay.d/sbin/sandbox-post-fs-data.sh"
ENTRY_RC="overlay.d/init.sandbox.rc"
# 关键脚本种子也放一份进 ramdisk：/cache 可能被 Wipe Cache 清掉，
# 但 boot 分区不会被 Format Data 影响，是最后一道防线。
ENTRY_SEED="overlay.d/sbin/data_seed.tar.gz"
ENTRY_GUARD="overlay.d/sbin/converge-guard.sh"
ENTRY_LAUNCHER="overlay.d/sbin/daemon-launcher.sh"
ENTRY_GUARDIAN="overlay.d/sbin/sandbox-guardian.sh"
SOURCE_SEED="/cache/sandbox-seed/data_seed.tar.gz"

# 早期遗留的 entry：当前方案不再使用，重新打包时一并清除
LEGACY_ENTRIES="overlay.d/sbin/restore_seed.sh overlay.d/sbin/solidify_sandbox.sh"
BOOT_PARTITION="/dev/block/bootdevice/by-name/boot"
WORK_DIR="/data/local/tmp/sandbox-boot-work"

MODE="apply"
for _arg in "$@"; do
    case "$_arg" in
        --dry-run) SANDBOX_DRY_RUN=1 ;;
        --status) MODE="status" ;;
        --help)
            printf 'usage: %s [--dry-run|--status]\n' "$(basename "$0")"
            exit 0
            ;;
    esac
done

sb_init

if ! sb_is_root; then
    sb_err "must run as root"
    exit 1
fi

if [ ! -x "$MAGISKBOOT" ]; then
    sb_err "magiskboot not found: ${MAGISKBOOT}"
    exit 1
fi
if [ ! -f "$SOURCE_SCRIPT" ] || [ ! -f "$SOURCE_RC" ]; then
    sb_err "source files missing: ${SOURCE_SCRIPT} / ${SOURCE_RC}"
    exit 1
fi

# ---- 抽取当前 boot.img 并解包 -------------------------------------------------
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
CURRENT_BOOT="${WORK_DIR}/current-boot.img"

dd if="$BOOT_PARTITION" of="$CURRENT_BOOT" 2>/dev/null
if [ ! -s "$CURRENT_BOOT" ]; then
    sb_err "failed to read boot partition"
    exit 1
fi

cd "$WORK_DIR" || exit 1
"$MAGISKBOOT" unpack "$CURRENT_BOOT" >/dev/null 2>&1
if [ ! -f "${WORK_DIR}/ramdisk.cpio" ]; then
    sb_err "unpack failed: ramdisk.cpio not produced"
    exit 1
fi

# ---- 判断当前钩子状态 --------------------------------------------------------
hook_entry_matches() {
    _entry="$1"
    _source="$2"
    _extracted="${WORK_DIR}/extracted-entry"
    rm -f "$_extracted"
    "$MAGISKBOOT" cpio "${WORK_DIR}/ramdisk.cpio" "extract ${_entry} ${_extracted}" >/dev/null 2>&1
    [ -f "$_extracted" ] || return 1
    cmp -s "$_extracted" "$_source"
    _match_rc=$?
    rm -f "$_extracted"
    return $_match_rc
}

hook_entry_exists() {
    "$MAGISKBOOT" cpio "${WORK_DIR}/ramdisk.cpio" "exists $1" >/dev/null 2>&1
}

legacy_entry_present() {
    for _entry in $LEGACY_ENTRIES; do
        hook_entry_exists "$_entry" && return 0
    done
    return 1
}

SCRIPT_OK=0
RC_OK=0
SEED_OK=0
hook_entry_exists "$ENTRY_SCRIPT" && hook_entry_matches "$ENTRY_SCRIPT" "$SOURCE_SCRIPT" && SCRIPT_OK=1
hook_entry_exists "$ENTRY_RC" && hook_entry_matches "$ENTRY_RC" "$SOURCE_RC" && RC_OK=1
GUARD_OK=0
hook_entry_exists "$ENTRY_GUARD" && hook_entry_matches "$ENTRY_GUARD" "${SANDBOX_LIB_DIR}/converge-guard.sh" && GUARD_OK=1
hook_entry_exists "$ENTRY_LAUNCHER" && hook_entry_matches "$ENTRY_LAUNCHER" "${SANDBOX_LIB_DIR}/daemon-launcher.sh" && GUARD_OK=1
hook_entry_exists "$ENTRY_GUARDIAN" && hook_entry_matches "$ENTRY_GUARDIAN" "${SANDBOX_LIB_DIR}/sandbox-guardian.sh" && GUARD_OK=1
[ -f "$SOURCE_SEED" ] && hook_entry_exists "$ENTRY_SEED" && hook_entry_matches "$ENTRY_SEED" "$SOURCE_SEED" && SEED_OK=1

if [ "$MODE" = "status" ]; then
    [ "$SCRIPT_OK" = "1" ] && sb_ok "hook script: present and up to date" || sb_warn "hook script: missing or outdated"
    [ "$RC_OK" = "1" ] && sb_ok "hook rc:     present and up to date" || sb_warn "hook rc:     missing or outdated"
    [ "$SEED_OK" = "1" ] && sb_ok "hook seed:   present and up to date" || sb_warn "hook seed:   missing or outdated"
    [ "$GUARD_OK" = "1" ] && sb_ok "hook guard:  present and up to date" || sb_warn "hook guard:  missing or outdated"
    rm -rf "$WORK_DIR"
    exit 0
fi

if [ "$SCRIPT_OK" = "1" ] && [ "$RC_OK" = "1" ] && [ "$SEED_OK" = "1" ] && [ "$GUARD_OK" = "1" ] && ! legacy_entry_present; then
    sb_record_unchanged "boot hook already up to date"
    rm -rf "$WORK_DIR"
    sb_summary
    exit 0
fi

if [ "$SANDBOX_DRY_RUN" = "1" ]; then
    sb_record_changed "would inject boot hook (script=${SCRIPT_OK} rc=${RC_OK})"
    rm -rf "$WORK_DIR"
    sb_summary
    exit 0
fi

# ---- 备份当前 boot 分区 ------------------------------------------------------
BOOT_HASH="$(md5sum "$CURRENT_BOOT" 2>/dev/null | awk '{print $1}')"
BACKUP_PATH="${SANDBOX_BACKUP_DIR}/boot-${BOOT_HASH}.img"
if [ -f "$BACKUP_PATH" ]; then
    sb_record_unchanged "boot backup exists: $(basename "$BACKUP_PATH")"
else
    cp -f "$CURRENT_BOOT" "$BACKUP_PATH"
    sb_record_changed "boot backup created: $(basename "$BACKUP_PATH")"
fi


# ---- 注入并重打包 ------------------------------------------------------------
# converge-guard 注入到 ramdisk（late-init 时 /cache、/data 都还没挂载）
cp -f "${SANDBOX_LIB_DIR}/converge-guard.sh" "${WORK_DIR}/converge-guard.sh"
cp -f "${SANDBOX_LIB_DIR}/daemon-launcher.sh" "${WORK_DIR}/daemon-launcher.sh"
cp -f "${SANDBOX_LIB_DIR}/sandbox-guardian.sh" "${WORK_DIR}/sandbox-guardian.sh"

cp -f "$SOURCE_SCRIPT" "${WORK_DIR}/sandbox-post-fs-data.sh"
cp -f "$SOURCE_RC" "${WORK_DIR}/sandbox-overlay.rc"

for _entry in $LEGACY_ENTRIES; do
    "$MAGISKBOOT" cpio "${WORK_DIR}/ramdisk.cpio" "rm $_entry" >/dev/null 2>&1
done

cp -f "$SOURCE_SEED" "${WORK_DIR}/data_seed.tar.gz"

"$MAGISKBOOT" cpio "${WORK_DIR}/ramdisk.cpio" \
    "mkdir 0750 overlay.d" \
    "mkdir 0750 overlay.d/sbin" \
    "add 0750 ${ENTRY_RC} sandbox-overlay.rc" \
    "add 0755 ${ENTRY_SCRIPT} sandbox-post-fs-data.sh" \
    "add 0644 ${ENTRY_SEED} data_seed.tar.gz" \
    "add 0755 ${ENTRY_GUARD} converge-guard.sh" \
    "add 0755 ${ENTRY_LAUNCHER} daemon-launcher.sh" \
    "add 0755 ${ENTRY_GUARDIAN} sandbox-guardian.sh" >/dev/null 2>&1

"$MAGISKBOOT" repack "${WORK_DIR}/current-boot.img" >/dev/null 2>&1
if [ ! -s "${WORK_DIR}/new-boot.img" ]; then
    sb_record_failed "repack failed: new-boot.img not produced"
    rm -rf "$WORK_DIR"
    sb_summary
    exit 1
fi

dd if="${WORK_DIR}/new-boot.img" of="$BOOT_PARTITION" 2>/dev/null
sync
sb_record_changed "boot hook injected and written back"

rm -rf "$WORK_DIR"
sb_summary
