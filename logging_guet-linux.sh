#!/usr/bin/env bash
# 桂林电子科技大学校园网登录。使用前请复制并填写 guet-config.sh。
# 基于原 macOS 脚本调整；具体网络环境下的兼容性请以实测为准。

set -u
export LC_ALL=C

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_file="$script_dir/guet-config.sh"

for dependency in curl base64 tr; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf '缺少依赖：%s\n' "$dependency" >&2
        exit 1
    fi
done

if [[ ! -f "$config_file" ]]; then
    printf '请先将 guet-config.example.sh 复制为 guet-config.sh 并填写配置。\n' >&2
    exit 1
fi
# 配置文件是 shell 代码，请仅使用自己信任的文件。
source "$config_file"
if [[ -z "${GUET_ACCOUNT:-}" || -z "${GUET_PASSWORD:-}" ]]; then
    printf '请在 guet-config.sh 中填写账号和密码。\n' >&2
    exit 1
fi
GUET_ISP=${GUET_ISP:-}

is_online() {
    local result
    result=$(curl -fsS --max-time 5 http://captive.apple.com/hotspot-detect.html 2>/dev/null) || return 1
    [[ "$result" == *'<TITLE>Success</TITLE>'* || "$result" == *'<title>Success</title>'* ]]
}

urlencode() {
    local input=$1 result='' char hex i
    for ((i=0; i<${#input}; i++)); do
        char=${input:i:1}
        case "$char" in
            [a-zA-Z0-9.~_-]) result+="$char" ;;
            *) printf -v hex '%%%02X' "'$char"; result+="$hex" ;;
        esac
    done
    printf '%s' "$result"
}

if is_online; then
    printf '网络已可用，无需重复认证。\n'
    exit 0
fi

printf '正在获取校园网认证信息……\n'
# 沿用原脚本的跳转地址；某些校园网环境可能需要调整。
redirect=$(curl -sS -L --max-time 10 -o /dev/null -w '%{url_effective}' 'http://1.2.3.4/' 2>/dev/null) || {
    printf '无法获取认证页面，请检查校园网连接。\n' >&2
    exit 1
}
if [[ "$redirect" != *\?* ]]; then
    printf '认证页面没有返回所需参数，请检查校园网连接。\n' >&2
    exit 1
fi
query=${redirect#*\?}
query=${query%%#*}
wlan_user_ip='' wlan_user_mac='' wlan_ac_ip='' wlan_ac_name=''
IFS='&' read -r -a pairs <<< "$query"
for pair in "${pairs[@]}"; do
    key=${pair%%=*}
    value=${pair#*=}
    case "$key" in
        wlanuserip) wlan_user_ip=$value ;;
        wlanusermac) wlan_user_mac=$value ;;
        wlanacip) wlan_ac_ip=$value ;;
        wlanacname) wlan_ac_name=$value ;;
    esac
done
wlan_user_mac=${wlan_user_mac//:/}
wlan_user_mac=${wlan_user_mac//-/}
if [[ -z "$wlan_user_ip" || -z "$wlan_user_mac" ]]; then
    printf '认证页面缺少设备 IP 或 MAC 信息，无法登录。\n' >&2
    exit 1
fi
# 保留重定向中的百分号编码，同时拒绝会改变 URL 结构的字符。
for value in "$wlan_user_ip" "$wlan_user_mac" "$wlan_ac_ip" "$wlan_ac_name"; do
    if [[ ! "$value" =~ ^[a-zA-Z0-9._~%:-]*$ ]]; then
        printf '认证页面返回了无法处理的参数。\n' >&2
        exit 1
    fi
done

# 保留原脚本的密码规则：去除 Base64 末尾填充，再添加一个等号。
password_base64=$(printf '%s' "$GUET_PASSWORD" | base64 | tr -d '\n\r=')
account_encoded=$(urlencode ",0,${GUET_ACCOUNT}@${GUET_ISP}")
password_encoded=$(urlencode "${password_base64}=")
login_url="http://10.0.1.5:801/eportal/portal/login?callback=dr1004&login_method=1&user_account=${account_encoded}&user_password=${password_encoded}&wlan_user_ip=${wlan_user_ip}&wlan_user_ipv6=&wlan_user_mac=${wlan_user_mac}&wlan_ac_ip=${wlan_ac_ip}&wlan_ac_name=${wlan_ac_name}&jsVersion=4.2&terminal_type=1&lang=zh-cn&v=3713&lang=zh"

printf '正在发送认证请求……\n'
# 通过标准输入提供 URL，避免将包含密码的 URL 放到 curl 命令行参数中。
status=$(printf 'url = "%s"\n' "$login_url" | curl -sS --max-time 10 --config - -H 'Referer: http://10.0.1.5/' -o /dev/null -w '%{http_code}' 2>/dev/null) || {
    printf '认证请求未完成，请检查网络后重试。\n' >&2
    exit 1
}
if [[ "$status" != 200 ]]; then
    printf '认证服务器返回 HTTP %s，请检查网络后重试。\n' "$status" >&2
    exit 1
fi
sleep 1
if is_online; then
    printf '认证后检测到网络可用。\n'
else
    printf '认证请求已发送，但尚未确认联网，请检查账号、运营商或认证页面。\n' >&2
    exit 1
fi
