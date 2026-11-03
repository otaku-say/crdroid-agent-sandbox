#!/bin/bash
# =============================================================================
# build.sh —— 把 crDroid 13 (cepheus) 原始包改造成 Agent 沙箱固件
#
# 用法：build.sh <base.zip> <twrp.img> <out.zip>
#
# 做四件事：
#   1. 把 agent/ 注入 /system/etc/agent（脚本、APK、配置）
#   2. 追加系统属性 + 注册 init service
#   3. 重新生成 system.new.dat.br / transfer.list
#   4. 打包 zip：去掉 vbmeta 刷入（改过的 system 会让它对不上），改成刷 TWRP
#
# AVB：不重签。刷完在 TWRP 里执行 `avbctl disable-verification` 即可，
#      这也是改 system 后能让设备正常启动的最小代价。
# =============================================================================
set -euo pipefail

BASE_ZIP="${1:?usage: build.sh <base.zip> <twrp.img> <out.zip>}"
TWRP_IMG="${2:?missing twrp.img}"
OUT_ZIP="${3:?missing out.zip}"

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLS="${HERE}/tools"
AGENT="${HERE}/../agent"
WORK="$(mktemp -d)"
MNT="$(mktemp -d)"
cleanup() {
    mountpoint -q "$MNT" && sudo umount "$MNT" || true
    rm -rf "$WORK" "$MNT"
}
trap cleanup EXIT

log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

log "1/7 解包原始固件"
unzip -q "$BASE_ZIP" -d "$WORK/base"
cd "$WORK/base"

log "2/7 还原 system 镜像"
brotli -d system.new.dat.br
python3 "$TOOLS/sdat2img.py" system.transfer.list system.new.dat system.img
ls -lh system.img

log "3/7 挂载并注入 agent 环境"
sudo mount -o loop,rw system.img "$MNT"

# --- 3.1 agent 目录 -----------------------------------------------------------
sudo rm -rf "$MNT/system/etc/agent"
sudo mkdir -p "$MNT/system/etc/agent"
sudo cp -a "$AGENT/bin" "$MNT/system/etc/agent/bin"
sudo cp -a "$AGENT/lib" "$MNT/system/etc/agent/lib"
sudo cp -a "$AGENT/apks" "$MNT/system/etc/agent/apks"
sudo cp -a "$AGENT/etc/policy" "$MNT/system/etc/agent/policy"
sudo mkdir -p "$MNT/system/etc/agent/state"
[ -f "$AGENT/state/wifi.conf" ] && sudo cp -a "$AGENT/state/wifi.conf" "$MNT/system/etc/agent/state/"
[ -f "$AGENT/state/location.conf" ] && sudo cp -a "$AGENT/state/location.conf" "$MNT/system/etc/agent/state/"
sudo chmod -R 0755 "$MNT/system/etc/agent/bin" "$MNT/system/etc/agent/lib"
sudo chmod -R 0644 "$MNT/system/etc/agent/policy"
sudo chmod -R 0644 "$MNT/system/etc/agent/apks"

# --- 3.2 init service ---------------------------------------------------------
# 常驻守护：单进程 guardian，内部依次跑 watchdog / battery / location。
# 用 init 管理而不是脚本 fork，避免被 process-group kill 带走。
sudo tee "$MNT/system/etc/init/sandbox-agent.rc" >/dev/null <<'RC'
service sandbox_guardian /system/bin/sh /system/etc/agent/bin/sandbox-guardian.sh
    user root
    seclabel u:r:su:s0
    class core
    group root system

service sandbox_converge /system/bin/sh /system/etc/agent/bin/sandbox-boot-converge.sh
    user root
    seclabel u:r:su:s0
    class core
    oneshot
    disabled

on property:sys.boot_completed=1
    start sandbox_converge
RC
sudo chmod 0644 "$MNT/system/etc/init/sandbox-agent.rc"

# --- 3.3 系统属性 -------------------------------------------------------------
if ! grep -q "AGENT_SANDBOX_PROPS" "$MNT/system/build.prop"; then
    sudo tee -a "$MNT/system/build.prop" >/dev/null <<'PROP'

# === AGENT_SANDBOX_PROPS ===
ro.adb.secure=0
persist.adb.tcp.port=5555
persist.sys.usb.config=mtp,adb
ro.setupwizard.mode=DISABLED
persist.sys.timezone=Asia/Shanghai
persist.sys.locale=zh-CN
ro.product.locale=zh-CN
PROP
fi

# --- 3.4 SELinux 上下文 -------------------------------------------------------
# 注入的文件默认继承 /system/etc 的上下文，这里显式修正关键可执行文件。
sudo restorecon -R "$MNT/system/etc/agent" 2>/dev/null || true
sudo restorecon "$MNT/system/etc/init/sandbox-agent.rc" 2>/dev/null || true

log "4/7 卸载并重新打包 system"
sync
sudo umount "$MNT"
python3 "$TOOLS/img2simg.py" system.img system.raw.img 2>/dev/null || img2simg system.img system.raw.img
# img2sdat 依赖同目录的 common/blockimgdiff/sparse_img，必须在 tools 目录内运行
(cd "$TOOLS" && python3 img2sdat.py "$WORK/base/system.raw.img" -o "$WORK/base" -v 4 >/dev/null)
# img2sdat 生成 system.new.dat + system.transfer.list；再压缩
[ -f system.new.dat ] && brotli -q 9 system.new.dat
ls -lh system.new.dat.br system.transfer.list

log "5/7 改写 updater-script"
# 去掉 vbmeta 刷入（system 已改，原 vbmeta 对不上；改用 TWRP 的 avbctl disable-verification）
grep -v 'vbmeta.img", "/dev/block/bootdevice/by-name/vbmeta"' \
    META-INF/com/google/android/updater-script > updater-script.new
{
    echo 'ui_print("Flashing TWRP recovery...");'
    echo 'package_extract_file("recovery.img", "/dev/block/bootdevice/by-name/recovery");'
    echo 'ui_print("");'
    echo 'ui_print("Agent sandbox firmware installed.");'
    echo 'ui_print("Now run in TWRP terminal:  avbctl disable-verification");'
    echo 'ui_print("then reboot.");'
} >> updater-script.new
mv updater-script.new META-INF/com/google/android/updater-script

log "6/7 放入 TWRP 镜像"
cp "$TWRP_IMG" recovery.img

log "7/7 打包"
rm -f "$OUT_ZIP"
zip -q -r "$OUT_ZIP" \
    META-INF boot.img dtbo.img recovery.img \
    system.new.dat.br system.transfer.list system.patch.dat \
    vendor.new.dat.br vendor.transfer.list vendor.patch.dat \
    install 2>/dev/null || \
zip -q -r "$OUT_ZIP" META-INF boot.img dtbo.img recovery.img \
    system.new.dat.br system.transfer.list \
    vendor.new.dat.br vendor.transfer.list

ls -lh "$OUT_ZIP"
log "完成：$OUT_ZIP"
log "刷机后记得在 TWRP 终端执行：avbctl disable-verification"
