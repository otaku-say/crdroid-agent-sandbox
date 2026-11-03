#!/system/bin/sh
# =============================================================================
# sandbox-ui.sh —— 基于 UI 层级的应用操控（不截图、不 OCR、不调多模态模型）
#
# 原理：uiautomator dump 拿到当前界面的无障碍层级（每个控件都有 text /
# content-desc / class / bounds），据此直接计算点击坐标。相比截图+OCR：
#   * 不需要把图片塞进模型上下文，token 从数万降到几百
#   * 不受分辨率、字体、深色模式、动画影响
#   * 坐标来自系统真实布局，不会出现 OCR 误识别
#
# 用法：
#   sandbox-ui.sh dump               输出当前界面的紧凑控件清单
#   sandbox-ui.sh find <文本>         查找控件，输出其中心坐标
#   sandbox-ui.sh tap <文本>          点击文本匹配的第一个控件
#   sandbox-ui.sh wait <文本> [秒]    轮询等待控件出现
#   sandbox-ui.sh focused             输出当前焦点输入框的已有文本
#   sandbox-ui.sh scroll <up|down>    在当前可滚动区域滚动一屏
#
# dump 输出格式（每行一个控件）：
#   序号 | 类型 | 文本 | 中心坐标 | 标记
#   标记含义：tap=可点击  input=输入框  scroll=可滚动
# =============================================================================

UI_XML=/data/local/tmp/.sandbox-ui.xml
MAX_LINES=80

AWK_LIB='
function attr(s, key,   re, out) {
    re = key "=\"[^\"]*\""
    if (!match(s, re)) return ""
    out = substr(s, RSTART, RLENGTH)
    sub(key "=\"", "", out)
    sub(/"$/, "", out)
    return out
}
function center(b,   p, n) {
    if (!match(b, /\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]/)) return ""
    b = substr(b, RSTART, RLENGTH)
    gsub(/\]\[/, " ", b)
    gsub(/[\[\]]/, "", b)
    n = split(b, p, /[ ,]+/)
    if (n < 4) return ""
    return int((p[1] + p[3]) / 2) "," int((p[2] + p[4]) / 2)
}
function flags(s,   f) {
    f = ""
    if (attr(s, "clickable") == "true") f = f " tap"
    if (attr(s, "scrollable") == "true") f = f " scroll"
    if (attr(s, "class") ~ /EditText/) f = f " input"
    return f
}
'

dump_ui() {
    uiautomator dump "$UI_XML" >/dev/null 2>&1 || return 1
    [ -s "$UI_XML" ] || return 1

    sed 's/></>\n</g' "$UI_XML" | awk "$AWK_LIB"'
/<node / {
    text = attr($0, "text")
    desc = attr($0, "content-desc")
    cls  = attr($0, "class")
    f    = flags($0)
    label = (text != "") ? text : desc
    if (label == "" && f == "") next
    if (label == "" && cls !~ /EditText|Button|CheckBox|Switch|ImageView/) next
    pos = center(attr($0, "bounds"))
    if (pos == "") next
    short = cls
    sub(/^android\.widget\./, "", short)
    sub(/^android\.view\./, "", short)
    sub(/^miui\.widget\./, "miui:", short)
    sub(/^android\./, "", short)
    gsub(/[ \t]+/, " ", label)
    if (length(label) > 40) label = substr(label, 1, 40) "..."
    count++
    if (count > '"$MAX_LINES"') exit
    printf "%d | %s | %s | %s |%s\n", count, short, label, pos, f
}'
    echo "# total: $(sed 's/></>\n</g' "$UI_XML" | grep -c '<node ')"
}

find_center() {
    _pattern="$1"
    uiautomator dump "$UI_XML" >/dev/null 2>&1 || return 1
    sed 's/></>\n</g' "$UI_XML" | awk -v pat="$_pattern" "$AWK_LIB"'
/<node / {
    text = attr($0, "text")
    desc = attr($0, "content-desc")
    if (text != pat && desc != pat && index(text, pat) == 0 && index(desc, pat) == 0) next
    pos = center(attr($0, "bounds"))
    if (pos == "") next
    print pos
    exit
}'
}

focused_text() {
    uiautomator dump "$UI_XML" >/dev/null 2>&1 || return 1
    sed 's/></>\n</g' "$UI_XML" | awk "$AWK_LIB"'
/<node / {
    if (attr($0, "class") !~ /EditText/) next
    printf "focused=%s text=%s\n", attr($0, "focused"), attr($0, "text")
}'
}

scroll_screen() {
    _dir="$1"
    case "$_dir" in
        up)   input swipe 540 700 540 1600 300 ;;
        down) input swipe 540 1600 540 700 300 ;;
        *) echo "usage: $0 scroll <up|down>" >&2; return 2 ;;
    esac
    sleep 0.5
}

case "$1" in
    dump) dump_ui ;;
    find)
        [ -n "$2" ] || { echo "usage: $0 find <text>" >&2; exit 2; }
        _pos="$(find_center "$2")"
        if [ -n "$_pos" ]; then echo "$_pos"; else echo "not found: $2" >&2; exit 1; fi
        ;;
    tap)
        [ -n "$2" ] || { echo "usage: $0 tap <text>" >&2; exit 2; }
        _pos="$(find_center "$2")"
        if [ -z "$_pos" ]; then echo "not found: $2" >&2; exit 1; fi
        input tap "${_pos%,*}" "${_pos#*,}"
        echo "tapped: $2 @ ${_pos}"
        ;;
    wait)
        [ -n "$2" ] || { echo "usage: $0 wait <text> [seconds]" >&2; exit 2; }
        _limit="${3:-15}"
        _n=0
        while [ "$_n" -lt "$_limit" ]; do
            if [ -n "$(find_center "$2")" ]; then echo "found: $2"; exit 0; fi
            sleep 1
            _n=$((_n + 1))
        done
        echo "timeout waiting for: $2" >&2
        exit 1
        ;;
    focused) focused_text ;;
    scroll) scroll_screen "$2" ;;
    *)
        sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
