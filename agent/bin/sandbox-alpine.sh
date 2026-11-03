#!/system/bin/sh
# =============================================================================
# sandbox-alpine.sh —— 在 Alpine 运行时里执行命令
#
# 用法：
#   sandbox-alpine.sh                     进入交互 shell
#   sandbox-alpine.sh python3 -V          执行单条命令
#   sandbox-alpine.sh apk add <pkg>       给运行时装包（写入 /data，重启保留）
#
# rootfs: /data/adb/sandbox/runtime/alpine
# 格式化 /data 后由 sandbox-post-fs-data.sh 从 /cache/sandbox-seed 自动还原。
#
# 所有挂载都在 unshare -m 的私有命名空间里完成，不会触碰宿主 /dev /proc /sys。
# =============================================================================

ROOTFS=/data/adb/sandbox/runtime/alpine
RUNTIME_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MOUNT_RUN=/data/adb/sandbox/lib/alpine-mount-run.sh

if [ ! -x "${ROOTFS}/bin/busybox" ]; then
    printf 'alpine runtime missing: %s\n' "$ROOTFS" >&2
    exit 1
fi

# Android 没有 /etc/resolv.conf，chroot 内需要自带
printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n' \
    > "${ROOTFS}/etc/resolv.conf"

export SBX_ROOTFS="$ROOTFS"
export SBX_PATH="$RUNTIME_PATH"

if [ "$#" -eq 0 ]; then
    exec unshare -m /system/bin/sh "$MOUNT_RUN" /bin/sh -l
fi

exec unshare -m /system/bin/sh "$MOUNT_RUN" "$@"
