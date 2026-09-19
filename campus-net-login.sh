#!/bin/sh
# 中南大学校园网自动认证脚本 (Dr.COM eportal) v6
# 用法: campus-net-login.sh [-q] [-f]
#   -q  静默模式（仅写日志）
#   -f  强制登录（跳过在线检测）
# 配置文件: /etc/campus-net.conf
# 建议由 cron 定期执行: */1 * * * * /usr/bin/campus-net-login.sh -q
#
# 登录格式（2026-09-19 从门户页面实际抓取，与浏览器完全一致）:
#   GET http://10.1.1.1:801/eportal/portal/login
#     ?login_method=1
#     &user_account=,0,<账号>@unicomn     (前缀 ,0, + 联通后缀 @unicomn)
#     &user_password=<密码>
#     &wlan_user_ip=<WAN IP>
#     &wlan_user_ipv6=
#     &wlan_user_mac=<WAN MAC 大写>
#     &wlan_ac_ip=&wlan_ac_name=
#     &jsVersion=4.1.3
#     &terminal_type=1&lang=zh-cn
#
# 恢复流程:
#   1. 登录一次（eportal 接口）→ 验证（最长90秒）
#   2. 未恢复 → 注销清理后重试一次（最长90秒）

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

CONF="/etc/campus-net.conf"
LOG="/var/log/campus-net.log"
LOCK="/tmp/campus-net.lock"
QUIET=0
FORCE=0

for arg in "$@"; do
        case "$arg" in
                -q) QUIET=1 ;;
                -f) FORCE=1 ;;
        esac
done

log() {
        echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
        [ "$QUIET" = "0" ] && echo "$*"
}

# 防止并发运行
if ! mkdir "$LOCK" 2>/dev/null; then
        if [ -n "$(find "$LOCK" -mmin +10 2>/dev/null)" ]; then
                rmdir "$LOCK" 2>/dev/null
                mkdir "$LOCK" 2>/dev/null || exit 0
        else
                exit 0
        fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

[ -f "$CONF" ] || { log "错误: 配置文件 $CONF 不存在"; exit 1; }
. "$CONF"

WAN_IF="${WAN_IF:-eth0}"
CHECK_IP="${CHECK_IP:-223.5.5.5}"
CHECK_IP2="${CHECK_IP2:-119.29.29.29}"
PORTAL_HOST="${PORTAL_HOST:-portal.csu.edu.cn}"
PORTAL_IP="${PORTAL_IP:-10.1.1.1}"
EPORTAL_URL="${EPORTAL_URL:-http://10.1.1.1:801/eportal/portal}"
JSV="4.1.3"

get_wan_ip() {
        ip -4 addr show "$WAN_IF" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1
}

get_wan_mac() {
        cat "/sys/class/net/$WAN_IF/address" 2>/dev/null | tr -d ':'
}

# IP 转大端整数（与门户 JS ipToParseInt 一致）
ip_to_int() {
        IFS=. read -r a b c d <<EOF
$1
EOF
        echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# HTTP 劫持探测: 返回 1=确定离线, 0=在线
http_offline() {
        body=$(curl -s -m 6 "http://$CHECK_IP/" 2>/dev/null)
        if echo "$body" | grep -q "Authentication is required"; then
                return 1
        fi
        if [ -n "$body" ]; then
                return 0
        fi
        body2=$(curl -s -m 6 "http://$CHECK_IP2/" 2>/dev/null)
        if echo "$body2" | grep -q "Authentication is required"; then
                return 1
        fi
        [ -n "$body2" ] && return 0
        ping -c 2 -W 3 "$CHECK_IP" >/dev/null 2>&1
}

is_online() {
        http_offline
}

# 查询本机 IP 的会话年龄（秒）；无会话返回空
session_age() {
        ip="$1"
        mac="$2"
        chk=$(curl -s -m 10 -G \
                --data-urlencode "callback=dr0" \
                --data-urlencode "username=${USERNAME}" \
                --data-urlencode "password=${PASSWORD}" \
                --data-urlencode "ip=${ip}" \
                --data-urlencode "wlan_ac_name=" \
                --data-urlencode "wlan_ac_ip=" \
                --data-urlencode "mac=${mac}" \
                --data-urlencode "login_method=1" \
                --data-urlencode "jsVersion=${JSV}" \
                "${EPORTAL_URL}/Custom/online_data")
        echo "$chk" | sed -n "s/.*\"online_ip\":\"${ip}\"[^}]*\"time_long\":\"\([0-9]*\)\".*/\1/p" | head -n1
}

# 注销本机会话（官方 mac/unbind 流程）
logout_session() {
        ip="$1"
        mac="$2"
        ip_int=$(ip_to_int "$ip")
        resp=$(curl -s -m 10 -G \
                --data-urlencode "callback=dr0" \
                --data-urlencode "user_account=${USERNAME}" \
                --data-urlencode "wlan_user_mac=$(echo "$mac" | tr 'a-f' 'A-F')" \
                --data-urlencode "wlan_user_ip=${ip_int}" \
                --data-urlencode "jsVersion=${JSV}" \
                "${EPORTAL_URL}/mac/unbind")
        log "注销返回: $(echo "$resp" | head -c 150)"
}

# 登录（eportal 接口，与浏览器抓包完全一致的参数）
login_eportal() {
        suffix="$1"
        ip="$2"
        mac="$3"
        curl -sk -m 20 -G \
                --data-urlencode "callback=dr$$" \
                --data-urlencode "login_method=1" \
                --data-urlencode "user_account=,0,${USERNAME}${suffix}" \
                --data-urlencode "user_password=${PASSWORD}" \
                --data-urlencode "wlan_user_ip=${ip}" \
                --data-urlencode "wlan_user_ipv6=" \
                --data-urlencode "wlan_user_mac=$(echo "$mac" | tr 'a-f' 'A-F')" \
                --data-urlencode "wlan_ac_ip=" \
                --data-urlencode "wlan_ac_name=" \
                --data-urlencode "jsVersion=${JSV}" \
                --data-urlencode "terminal_type=1" \
                --data-urlencode "lang=zh-cn" \
                --data-urlencode "v=$$" \
                "${EPORTAL_URL}/login"
}

# 登录一次（按优先级尝试后缀），返回 0=成功
try_login_once() {
        ip="$1"
        mac="$2"

        resp=$(login_eportal "$ISP_SUFFIX" "$ip" "$mac")
        if [ "$(echo "$resp" | sed -n 's/.*"result":\([0-9]*\).*/\1/p' | head -n1)" = "1" ]; then
                log "登录成功 [eportal ${ISP_SUFFIX}]"
                return 0
        fi
        log "登录失败 [eportal ${ISP_SUFFIX}]: $(echo "$resp" | head -c 200)"

        if [ -n "$ISP_SUFFIX_ALT" ]; then
                resp=$(login_eportal "$ISP_SUFFIX_ALT" "$ip" "$mac")
                if [ "$(echo "$resp" | sed -n 's/.*"result":\([0-9]*\).*/\1/p' | head -n1)" = "1" ]; then
                        log "登录成功 [eportal ${ISP_SUFFIX_ALT}]"
                        return 0
                fi
                log "登录失败 [eportal ${ISP_SUFFIX_ALT}]: $(echo "$resp" | head -c 200)"
        fi

        return 1
}

# 验证连通性，$1=重试轮数（每轮6秒）
verify() {
        rounds="$1"
        i=1
        while [ "$i" -le "$rounds" ]; do
                sleep 6
                if is_online; then
                        log "连通性验证通过（等待 $((i*6)) 秒）"
                        return 0
                fi
                i=$((i+1))
        done
        return 1
}

main() {
        if [ "$FORCE" = "0" ] && is_online; then
                [ "$QUIET" = "0" ] && log "网络已在线，无需操作"
                exit 0
        fi

        ip=$(get_wan_ip)
        mac=$(get_wan_mac)
        if [ -z "$ip" ]; then
                log "错误: 无法获取 $WAN_IF 的 IP，等待下次检测"
                exit 1
        fi

        log "检测到未认证 (IP=$ip MAC=$mac)，开始处理..."

        # 强制模式: 直接登录
        if [ "$FORCE" = "1" ]; then
                try_login_once "$ip" "$mac" || exit 1
                verify 15 && exit 0
                exit 1
        fi

        # 步骤1: 记录会话状态（诊断用）
        age=$(session_age "$ip" "$mac")
        [ -n "$age" ] && log "本机存在会话记录（${age}秒）"

        # 步骤2: 登录一次 + 验证（最长90秒）
        try_login_once "$ip" "$mac"
        if verify 15; then
                exit 0
        fi

        # 步骤3: 未恢复 → 注销清理后重试
        log "首次登录未恢复，注销清理后重试..."
        logout_session "$ip" "$mac"
        sleep 3
        try_login_once "$ip" "$mac"
        if verify 15; then
                exit 0
        fi

        log "警告: 多次尝试后仍未恢复连通性"
        exit 1
}

main
