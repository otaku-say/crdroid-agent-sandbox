# crDroid 13 Agent Sandbox Firmware (cepheus / 小米9)

把 crDroid 13 改造成开箱即用的 AI Agent 无人值守沙箱：内置 root 通道、无线 ADB、Linux 运行时、UI 自动化、虚拟定位。

## 固件里有什么

| 能力 | 实现 |
|---|---|
| 持久 root | Magisk 31.1（boot.img 已 patch） |
| 无线 ADB | `persist.adb.tcp.port=5555`，`ro.adb.secure=0` |
| Linux 运行时 | Alpine 3.24 + Python 3.14 / Node 24 / git（`/system/etc/agent/alpine`） |
| UI 自动化 | `sandbox-ui.sh`（读 uiautomator 层级，不截图不 OCR） |
| 中文输入 | ADBKeyBoard（`/system/etc/agent/apks`） |
| 虚拟定位 | Mock my GPS + geo-intent 静默设置 |
| 出口 IP 跟随 | `sandbox-location-guard.sh`（ipwho.is → GPS 坐标） |
| 常驻守护 | init service `sandbox_guardian`（adbd/WiFi/温度/磁盘/电池/定位） |
| 恢复 TWRP | 刷机最后写入 TWRP 3.7.0（recovery 分区） |

## 刷机

```bash
# 1. TWRP 里刷 zip
#    Wipe → Format Data（跨 ROM 必须）
#    Install → crdroid-agent-cepheus.zip

# 2. 刷完不要重启，先回 TWRP 终端（Advanced → Terminal）执行：
avbctl disable-verification
# system 被改过，必须关掉 AVB 验证才能启动

# 3. Reboot System
```

首次开机 3–5 分钟。

## 刷完自检

```bash
adb devices                                  # 应看到 USB 设备
adb shell getprop sys.boot_completed         # 1
adb shell 'sh /system/etc/agent/bin/sandbox-doctor.sh'
```

## 日常使用

```bash
S=/system/etc/agent/bin

$S/sandbox-doctor.sh                      # 体检
$S/sandbox-boot-converge.sh --dry-run     # 看配置差异
$S/sandbox-ui.sh dump                     # 当前界面控件清单
$S/sandbox-ui.sh tap "WLAN"               # 按文本点击
$S/sandbox-input.sh "中文"                 # 输入中文
$S/sandbox-alpine.sh python3 -V           # 跑运行时
$S/sandbox-mock-location.sh --set 34.05 -118.24   # 手动锁定位置
$S/sandbox-mock-location.sh --auto        # 交回 IP 跟随
```

## 自己构建

推到 tag 触发，或手动 `workflow_dispatch`：

```bash
git tag v1.0.0 && git push origin v1.0.0
```

构建依赖 `base-rom` Release 里的两个文件：
- `crDroidAndroid-13.0-*-cepheus-*.zip`
- `TWRP-*.img`

## 目录

```
agent/
├── bin/     运行时脚本（converge / doctor / ui / input / mock-location / guardian ...）
├── lib/     幂等原语与挂载封装
├── apks/    ADBKeyBoard, MockMyGPS
├── etc/     SELinux 策略、boot rc
└── state/   wifi.conf / location.conf 模板
scripts/
├── build.sh 主构建脚本
└── tools/   sdat2img / img2sdat
```

## 已知限制

- crDroid 13 的 FBE 与 TWRP 3.7.0 retrofit 版本兼容，可以解密 `/data`
- 改过 system 后 **必须** `avbctl disable-verification`，否则卡 boot
- 固件基于 2023-11 的 crDroid 9.11，安全补丁较旧
