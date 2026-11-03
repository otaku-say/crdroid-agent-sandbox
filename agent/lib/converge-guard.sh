#!/system/bin/sh
# =============================================================================
# converge-guard.sh —— 首次开机（Format Data 后）的收敛补偿
#
# 场景：/data/adb 在 post-fs-data 才从种子恢复，而 magiskd 已经在更早的时候
# 扫描过 /data/adb/service.d，导致 sandbox-boot-converge.sh 那一次不会被执行。
# post-fs-data 里 fork 的后台进程又会被 init 在阶段切换时清理掉，所以只能
# 由 init service 来做这件事。
#
# 逻辑：等 45 秒让正常路径完成；若本次开机标记不存在，说明 service.d 没跑到，
# 这里补跑一次收敛。
# =============================================================================

MARKER=/data/adb/sandbox/run/.converged-this-boot

sleep 45
[ -f "$MARKER" ] && exit 0

CONVERGE=/data/adb/sandbox/bin/sandbox-boot-converge.sh
[ -f "$CONVERGE" ] || exit 0

echo "$(date '+%Y-%m-%d %H:%M:%S') [converge-guard] normal path skipped, running converge" \
    >> /data/adb/sandbox/log/sandbox-boot-converge.log 2>/dev/null
sh "$CONVERGE"
