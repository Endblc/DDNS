#!/bin/bash

# --- 脚本元信息与颜色定义 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[0;33m"
NC="\033[0m"
Info="${GREEN}[信息]${NC}"
Error="${RED}[错误]${NC}"
Tip="${YELLOW}[提示]${NC}"

# --- 环境检查 ---
check_root(){
    if [[ $(whoami) != "root" ]]; then
        echo -e "${Error}请以root身份执行该脚本！"
        exit 1
    fi
}

check_curl() {
    if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
        echo -e "${YELLOW}正在安装必要依赖 curl/jq...${NC}"
        apt-get update && apt-get install -y curl jq
    fi
}

# --- 核心安装与文件生成 ---
install_ddns(){
    mkdir -p /etc/DDNS
    cp "$0" /usr/bin/ddns && chmod +x /usr/bin/ddns

    # 只有当配置文件不存在时才创建默认配置
    if [ ! -f "/etc/DDNS/.config" ]; then
        cat <<'EOF' > /etc/DDNS/.config
Domain="your_domain.com"
Domainv6="your_domainv6.com" 
Email=""
Api_key="your_api_token"
Telegram_Bot_Token=""
Telegram_Chat_ID=""
EOF
        chmod 600 /etc/DDNS/.config
    fi

    # 生成执行脚本 (始终覆盖更新)
    cat <<'EOF' > /etc/DDNS/DDNS
#!/bin/bash
WORK_DIR="/etc/DDNS"
LOG_FILE="/var/log/ddns.log"
source $WORK_DIR/.config

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"; }

# 获取根域名
get_root_domain() {
    echo "$1" | awk -F. '{print $(NF-1)"."$NF}'
}

# 获取 Zone ID
get_zone_id() {
    local root_domain=$(get_root_domain "$1")
    # 注意：新版API只需 Authorization: Bearer <TOKEN>
    local response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$root_domain" \
         -H "Authorization: Bearer $Api_key" \
         -H "Content-Type: application/json")
    local zid=$(echo "$response" | jq -r '.result[0].id' 2>/dev/null)
    if [[ -z "$zid" || "$zid" == "null" ]]; then
        log "获取ZoneID失败! 域名: $root_domain。响应: $response"
        echo ""
    else
        echo "$zid"
    fi
}

# 获取 Record ID
get_record_id() {
    local zid=$1 type=$2 name=$3
    local response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zid/dns_records?type=$type&name=$name" \
         -H "Authorization: Bearer $Api_key" \
         -H "Content-Type: application/json")
    echo "$response" | jq -r '.result[0].id' 2>/dev/null
}

# 更新记录
update_record() {
    local type=$1 domain=$2 ip=$3 old_ip=$4 file=$5
    if [[ "$ip" == "$old_ip" ]]; then return 0; fi
    
    local zid=$(get_zone_id "$domain")
    [ -z "$zid" ] && return 1
    
    local rid=$(get_record_id "$zid" "$type" "$domain")
    if [[ -z "$rid" || "$rid" == "null" ]]; then
        log "获取RecordID失败: $domain"
        return 1
    fi

    local response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$zid/dns_records/$rid" \
         -H "Authorization: Bearer $Api_key" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"$type\",\"name\":\"$domain\",\"content\":\"$ip\",\"ttl\":60,\"proxied\":false}")
    
    if [[ "$response" == *"\"success\":true"* ]]; then
        echo "$ip" > "$WORK_DIR/$file"
        log "更新成功: $domain -> $ip"
        echo "更新成功: $domain -> $ip"
    else
        log "更新失败: $domain。响应: $response"
    fi
}

# 主执行逻辑
ipv4=$(curl -s4 --max-time 10 https://api.ipify.org || curl -s4 --max-time 10 https://ip.sb)
ipv6=$(curl -s6 --max-time 10 https://api6.ipify.org || curl -s6 --max-time 10 https://ip.sb)
old_v4=$(cat $WORK_DIR/.old_ipv4 2>/dev/null)
old_v6=$(cat $WORK_DIR/.old_ipv6 2>/dev/null)

if [[ -n "$Domain" && "$Domain" != "your_domain.com" && -n "$ipv4" ]]; then
    update_record "A" "$Domain" "$ipv4" "$old_v4" ".old_ipv4"
fi
if [[ -n "$Domainv6" && "$Domainv6" != "your_domainv6.com" && -n "$ipv6" ]]; then
    update_record "AAAA" "$Domainv6" "$ipv6" "$old_v6" ".old_ipv6"
fi
EOF
    chmod 700 /etc/DDNS/DDNS
}

# --- 设置功能 ---
set_api(){
    echo -e "${Tip}请输入 Cloudflare API Token (切勿填错，注意前后无空格):"
    read -p "Token: " token
    # 去除输入中可能的空格
    token=$(echo $token | xargs)
    if [ -z "$token" ]; then echo "Token 不能为空"; return 1; fi
    sed -i "s|^Api_key=.*|Api_key=\"$token\"|" /etc/DDNS/.config
    echo -e "${Info}API Token 已更新。"
}

set_domain(){
    read -p "IPv4 域名 (如 v4.kanata.im): " v4
    read -p "IPv6 域名 (如 v6.kanata.im): " v6
    sed -i "s|^Domain=.*|Domain=\"$v4\"|" /etc/DDNS/.config
    sed -i "s|^Domainv6=.*|Domainv6=\"$v6\"|" /etc/DDNS/.config
    echo -e "${Info}域名设置已更新。"
}

run_service(){
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
Description=DDNS Timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Unit=ddns.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now ddns.timer
    echo -e "${Info}定时任务已启动 (每5分钟执行一次)。"
}

# --- 菜单 ---
main(){
    check_root
    check_curl
    install_ddns
    
    clear
    echo -e "${GREEN}Cloudflare DDNS 工具 (API Token 专用修复版)${NC}"
    echo -e "------------------------------------------"
    echo -e "1. 修改域名"
    echo -e "2. 修改 API Token"
    echo -e "3. 立即运行一次"
    echo -e "4. 查看运行日志"
    echo -e "5. 启动/重启定时任务"
    echo -e "0. 退出"
    echo -e "------------------------------------------"
    read -p "请选择 [0-5]: " opt
    case "$opt" in
        1) set_domain; main ;;
        2) set_api; main ;;
        3) /etc/DDNS/DDNS; read -p "按回车继续..."; main ;;
        4) tail -n 20 /var/log/ddns.log; read -p "按回车继续..."; main ;;
        5) run_service; sleep 2; main ;;
        0) exit 0 ;;
        *) main ;;
    esac
}

main
