#!/bin/bash

# --- 脚本元信息与颜色定义 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[0;33m"
NC="\033[0m"
GREEN_ground="\033[42;37m"
RED_ground="\033[41;37m"
Info="${GREEN}[信息]${NC}"
Error="${RED}[错误]${NC}"
Tip="${YELLOW}[提示]${NC}"

# --- 脚本欢迎界面 ---
cop_info(){
clear
echo -e "${GREEN}#######################################################
#      ${RED} DDNS 一键脚本 (Cloudflare API Token版) ${GREEN} #
#               作者: ${YELLOW}LAOWANG           ${GREEN}#
#             https://github.com/chinggirltube                  ${GREEN}#
#  ${YELLOW}优化: 完美支持 Bearer Token, 修复 ZoneID 获取逻辑 ${GREEN} #
#######################################################${NC}"
echo -e "${Info}此版本已修复 Cloudflare 新版 API 鉴权问题。 "
echo
}

# --- 环境检查 ---

# 检查系统
if ! grep -qiE "debian|ubuntu" /etc/os-release; then
    echo -e "${Error}本脚本仅支持 Debian 或 Ubuntu 系统。"
    exit 1
fi

# 检查root权限
check_root(){
    if [[ $(whoami) != "root" ]]; then
        echo -e "${Error}请以root身份执行该脚本！"
        exit 1
    fi
}

# 检查并安装curl和jq
check_curl() {
    if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
        echo -e "${YELLOW}未检测到 curl 或 jq，正在安装...${NC}"
        apt-get update && apt-get install -y curl jq
        if [ $? -ne 0 ]; then
            echo -e "${RED}安装 curl/jq 失败，请手动安装后重试。${NC}"
            exit 1
        fi
    fi
}

# --- 核心安装与文件生成 ---

# 安装DDNS相关文件
install_ddns(){
    # 备份旧版本
    if [ -d "/etc/DDNS" ]; then
        echo -e "${Tip}检测到已存在的DDNS目录，将备份为 /etc/DDNS.bak_$(date +%s)"
        mv /etc/DDNS "/etc/DDNS.bak_$(date +%s)" 2>/dev/null
    fi

    mkdir -p /etc/DDNS
    cp "$0" /usr/bin/ddns && chmod +x /usr/bin/ddns

    # 创建纯净的配置文件
    cat <<'EOF' > /etc/DDNS/.config
Domain="your_domain.com"
Domainv6="your_domainv6.com" 
Email=""
Api_key="your_api_token"
Telegram_Bot_Token=""
Telegram_Chat_ID=""
EOF
    chmod 600 /etc/DDNS/.config

    touch /etc/DDNS/.old_ipv4 && chmod 600 /etc/DDNS/.old_ipv4
    touch /etc/DDNS/.old_ipv6 && chmod 600 /etc/DDNS/.old_ipv6

    # ================================================================= #
    # 生成执行脚本：核心逻辑已修改为 Bearer Token
    # ================================================================= #
    cat <<'EOF' > /etc/DDNS/DDNS
#!/bin/bash
WORK_DIR="/etc/DDNS"
LOG_FILE="/var/log/ddns.log"
declare -A ZONE_ID_CACHE

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

send_telegram_notification(){
    local message="$1"
    if [[ -n "$Telegram_Bot_Token" && -n "$Telegram_Chat_ID" ]]; then
        curl -s --connect-timeout 10 -X POST "https://api.telegram.org/bot$Telegram_Bot_Token/sendMessage" \
             -d chat_id="$Telegram_Chat_ID" -d text="$message" >> "$LOG_FILE" 2>&1
    fi
}

get_root_domain() {
    echo "$1" | awk -F. '{print $(NF-1)"."$NF}'
}

get_zone_id() {
    local full_domain=$1
    local root_domain
    root_domain=$(get_root_domain "$full_domain")
    if [[ -n "${ZONE_ID_CACHE[$root_domain]}" ]]; then
        echo "${ZONE_ID_CACHE[$root_domain]}"
        return
    fi
    # 修改点：使用 Authorization: Bearer
    ZONE_ID_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$root_domain" \
         -H "Authorization: Bearer $Api_key" \
         -H "Content-Type: application/json")
    zone_id_val=$(echo "$ZONE_ID_RESPONSE" | jq -r '.result[] | select(.name=="'"$root_domain"'") | .id' 2>/dev/null)
    if [ -z "$zone_id_val" ]; then
        log "错误: 无法获取 Zone ID for '$root_domain'。请检查 Token 权限。响应: $ZONE_ID_RESPONSE"
        echo ""
    else
        ZONE_ID_CACHE["$root_domain"]="$zone_id_val"
        echo "$zone_id_val"
    fi
}

get_dns_record_id() {
    local zone_id=$1
    local record_type=$2
    local domain_name=$3
    # 修改点：使用 Authorization: Bearer
    DNS_ID_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=$record_type&name=$domain_name" \
         -H "Authorization: Bearer $Api_key" \
         -H "Content-Type: application/json")
    echo "$DNS_ID_RESPONSE" | jq -r '.result[0].id' 2>/dev/null
}

update_dns_record() {
    local record_type=$1
    local domain=$2
    local public_ip=$3
    local old_ip=$4
    local old_ip_file=$5
    if [[ "$public_ip" == "$old_ip" ]]; then return 0; fi
    local zone_id
    zone_id=$(get_zone_id "$domain")
    if [ -z "$zone_id" ]; then return 1; fi
    local dns_id
    dns_id=$(get_dns_record_id "$zone_id" "$record_type" "$domain")
    if [ -z "$dns_id" ]; then return 1; fi
    # 修改点：使用 Authorization: Bearer
    response=$(curl -s -w "%{http_code}" -X PUT "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$dns_id" \
         -H "Authorization: Bearer $Api_key" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"$record_type\",\"name\":\"$domain\",\"content\":\"$public_ip\",\"ttl\":60,\"proxied\":false}")
    http_code=${response: -3}
    body=${response::-3}
    if [ "$http_code" -eq 200 ] && [[ "$body" == *"\"success\":true"* ]]; then
        log "成功: $domain 更新为 $public_ip"
        echo "$public_ip" > "$old_ip_file"
        echo "$domain -> $public_ip"
        return 0
    else
        log "失败: $domain 更新失败。响应: $body"
        return 1
    fi
}

log "====== DDNS 开始 ======"
cd "$WORK_DIR" || exit 1
source .config
ipv4=$(curl -s4 --max-time 10 https://api.ipify.org || curl -s4 --max-time 10 https://ip.sb)
ipv6=$(curl -s6 --max-time 10 https://api6.ipify.org || curl -s6 --max-time 10 https://ip.sb)
old_v4=$(cat .old_ipv4 2>/dev/null)
old_v6=$(cat .old_ipv6 2>/dev/null)
notif=""
if [[ -n "$Domain" && "$Domain" != "your_domain.com" && -n "$ipv4" ]]; then
    res=$(update_dns_record "A" "$Domain" "$ipv4" "$old_v4" ".old_ipv4")
    [ $? -eq 0 ] && [ -n "$res" ] && notif+="$res "
fi
if [[ -n "$Domainv6" && "$Domainv6" != "your_domainv6.com" && -n "$ipv6" ]]; then
    res=$(update_dns_record "AAAA" "$Domainv6" "$ipv6" "$old_v6" ".old_ipv6")
    [ $? -eq 0 ] && [ -n "$res" ] && notif+="$res "
fi
[ -n "$notif" ] && send_telegram_notification "DDNS成功: $notif"
log "====== DDNS 结束 ======"
EOF
    chmod 700 /etc/DDNS/DDNS
    touch /var/log/ddns.log && chmod 644 /var/log/ddns.log
}

# --- 管理功能 ---

set_cloudflare_api(){
    echo -e "${Tip}API Token模式下无需填邮箱，回车即可。"
    read -p "Cloudflare 邮箱: " email
    read -p "Cloudflare API Token: " api_key
    if [ -z "$api_key" ]; then
        echo -e "${Error}Token不能为空！"
        return 1
    fi
    sed -i "s/^Email=.*/Email=\"$email\"/" /etc/DDNS/.config
    sed -i "s/^Api_key=.*/Api_key=\"$api_key\"/" /etc/DDNS/.config
    # 重新生成子脚本以防配置未生效
    install_ddns >/dev/null 2>&1
}

set_domain(){
    read -p "IPv4 域名 (v4.kanata.im): " domain_v4
    read -p "IPv6 域名 (v6.kanata.im): " domain_v6
    sed -i "s/^Domain=.*/Domain=\"$domain_v4\"/" /etc/DDNS/.config
    sed -i "s/^Domainv6=.*/Domainv6=\"$domain_v6\"/" /etc/DDNS/.config
}

set_telegram_settings(){
    read -p "Telegram Bot Token: " token
    read -p "Telegram Chat ID: " chat_id
    sed -i "s/^Telegram_Bot_Token=.*/Telegram_Bot_Token=\"$token\"/" /etc/DDNS/.config
    sed -i "s/^Telegram_Chat_ID=.*/Telegram_Chat_ID=\"$chat_id\"/" /etc/DDNS/.config
}

run_ddns(){
    cat <<EOF > /etc/systemd/system/ddns.service
[Unit]
Description=DDNS Service
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /etc/DDNS/DDNS
WorkingDirectory=/etc/DDNS

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > /etc/systemd/system/ddns.timer
[Unit]
Description=DDNS Timer (5min)

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=ddns.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now ddns.timer
    systemctl start ddns.service
    echo -e "${Info}服务已启动！"
}

go_ahead(){
    echo -e "${Tip}选择：1.启动 | 3.改域名 | 4.改API Token | 7.看日志 | 9.立即运行 | 0.退出"
    read -p "选项: " option
    case "$option" in
        1) run_ddns; main ;;
        3) set_domain; main ;;
        4) set_cloudflare_api; main ;;
        7) tail -f /var/log/ddns.log ;;
        9) /etc/DDNS/DDNS; main ;;
        0) exit 0 ;;
        *) main ;;
    esac
}

main(){
    if [[ -z "$IS_RECURSIVE" ]]; then cop_info; fi
    if [ ! -f "/etc/DDNS/.config" ]; then
        install_ddns
        set_cloudflare_api
        set_domain
        set_telegram_settings
        run_ddns
    fi
    export IS_RECURSIVE=true
    go_ahead
}

check_root
check_curl
main
