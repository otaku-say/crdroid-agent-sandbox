#!/system/bin/sh
# =============================================================================
# alpine-mount-run.sh —— 在私有 mount namespace 内挂载伪文件系统并 chroot
#
# 由 sandbox-alpine.sh 通过 `unshare -m` 调用。
# 关键点：unshare 出来的 namespace 默认继承父级的 shared 传播属性，挂载仍会
# 传播回宿主；因此必须先用 busybox mount --make-rprivate / 切断传播。
# toybox 的 mount 不支持 --make-private，所以固定使用 Magisk 自带的 busybox。
#
# 背景：早期版本直接在宿主 namespace 里 bind /dev，删除 rootfs 时连带删掉了
# 宿主 /dev 设备节点，导致 adbd 无法创建 pty、系统黑屏。此文件是那次事故的修复。
# =============================================================================

: "${SBX_ROOTFS:?SBX_ROOTFS not set}"
: "${SBX_PATH:?SBX_PATH not set}"

BUSYBOX=/data/adb/sandbox/tools/busybox

"$BUSYBOX" mount --make-rprivate /

"$BUSYBOX" mount -t proc proc "${SBX_ROOTFS}/proc"
"$BUSYBOX" mount --rbind /dev "${SBX_ROOTFS}/dev"
"$BUSYBOX" mount --rbind /sys "${SBX_ROOTFS}/sys"

exec chroot "${SBX_ROOTFS}" /bin/sh -c "export PATH=${SBX_PATH}; exec \"\$@\"" sh "$@"
