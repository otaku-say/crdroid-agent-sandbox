#!/system/bin/sh
# =============================================================================
# sandbox-input.sh —— 向当前焦点输入框输入任意 Unicode 文本（中文 / emoji）
#
# 为什么需要它：`input text` 走 KeyCharacterMap，只能输出 ASCII；
# 中文必须经由 ADBKeyBoard 这个输入法接收广播后 commitText。
#
# 用法：
#   sandbox-input.sh "小米9测试"        输入文本（自动切换 IME 再切回，不影响你手动打字）
#   sandbox-input.sh --clear            清空当前输入框
#   sandbox-input.sh --replace "文本"   清空并输入（一次 IME 切换，最可靠）
#   sandbox-input.sh --key 66           发送按键（66 = ENTER）
#   sandbox-input.sh --ime on           切到 ADBKeyBoard（批量输入前调用，省掉每次切换开销）
#   sandbox-input.sh --ime off          切回原来的输入法
#
# 退出码：0 成功；1 输入法不可用；2 参数错误
# =============================================================================

ADB_IME_ID=com.android.adbkeyboard/.AdbIME
STATE_FILE=/data/adb/sandbox/state/last_input_method
RUN_DIR=/data/adb/sandbox/run

usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

current_ime() {
    settings get secure default_input_method
}

adb_ime_enabled() {
    ime list -s 2>/dev/null | grep -qx "$ADB_IME_ID"
}

ensure_adb_ime_enabled() {
    adb_ime_enabled && return 0
    ime enable "$ADB_IME_ID" >/dev/null 2>&1
    adb_ime_enabled
}

# 只接受形如 "package/.ServiceName" 的合法 IME id。
# 切换 IME 的瞬间 settings 服务可能返回 "cmd: Failure ..."，
# 早期版本把这类错误文本当 IME id 存了下来，导致再也切不回去。
is_valid_ime_id() {
    case "$1" in
        */*) return 0 ;;
        *) return 1 ;;
    esac
}

remember_current_ime() {
    mkdir -p "$(dirname "$STATE_FILE")"
    _n=0
    while [ "$_n" -lt 5 ]; do
        _cur="$(current_ime 2>/dev/null)"
        if is_valid_ime_id "$_cur"; then
            printf '%s\n' "$_cur" > "$STATE_FILE"
            return 0
        fi
        sleep 0.3
        _n=$((_n + 1))
    done
    return 1
}

restore_ime() {
    [ -f "$STATE_FILE" ] || return 0
    _saved="$(cat "$STATE_FILE")"
    is_valid_ime_id "$_saved" || return 0
    if [ "$(current_ime)" != "$_saved" ]; then
        ime set "$_saved" >/dev/null 2>&1
        _n=0
        while [ "$_n" -lt 10 ]; do
            [ "$(current_ime)" = "$_saved" ] && return 0
            sleep 0.2
            _n=$((_n + 1))
        done
    fi
    return 0
}

switch_to_adb_ime() {
    if [ "$(current_ime)" = "$ADB_IME_ID" ]; then
        return 0
    fi
    remember_current_ime
    ime set "$ADB_IME_ID" >/dev/null 2>&1
    # 等 IME 绑定完成，否则广播会丢
    _n=0
    while [ "$_n" -lt 10 ]; do
        [ "$(current_ime)" = "$ADB_IME_ID" ] && break
        sleep 0.2
        _n=$((_n + 1))
    done
    [ "$(current_ime)" = "$ADB_IME_ID" ]
}

send_b64() {
    _payload="$(printf '%s' "$1" | base64 | tr -d '\n')"
    am broadcast -a ADB_INPUT_B64 --es msg "$_payload" >/dev/null 2>&1
}

case "$1" in
    --clear)
        ensure_adb_ime_enabled || exit 1
        switch_to_adb_ime || exit 1
        am broadcast -a ADB_CLEAR_TEXT >/dev/null 2>&1
        restore_ime
        ;;
    --replace)
        shift
        [ -n "$*" ] || usage
        ensure_adb_ime_enabled || exit 1
        switch_to_adb_ime || exit 1
        am broadcast -a ADB_CLEAR_TEXT >/dev/null 2>&1
        sleep 0.4
        send_b64 "$*"
        sleep 0.4
        restore_ime
        ;;
    --key)
        [ -n "$2" ] || usage
        ensure_adb_ime_enabled || exit 1
        switch_to_adb_ime || exit 1
        am broadcast -a ADB_INPUT_CODE --ei code "$2" >/dev/null 2>&1
        restore_ime
        ;;
    --ime)
        case "$2" in
            on)
                ensure_adb_ime_enabled || exit 1
                switch_to_adb_ime || exit 1
                ;;
            off) restore_ime ;;
            *) usage ;;
        esac
        ;;
    '' | --help | -h) usage ;;
    *)
        ensure_adb_ime_enabled || { echo "ADBKeyBoard not installed or not enabled" >&2; exit 1; }
        switch_to_adb_ime || { echo "failed to switch input method" >&2; exit 1; }
        send_b64 "$*"
        # 等 commitText 落地再切回，避免文本丢失
        sleep 0.3
        restore_ime
        ;;
esac
