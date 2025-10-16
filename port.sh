#!/bin/bash
#
# port_forward_cn_only.sh
# 端口转发中转服务器专用防火墙脚本（最终整合版）
# ✅ 仅限制 INPUT 入站（中国IP+白名单允许，其余全部DROP）
# ✅ FORWARD 始终 ACCEPT，确保 Nypass / 转发功能不受影响
# ✅ OUTPUT 始终 ACCEPT
# ✅ 自动检测当前公网IP是否属于中国段，海外 IP 自动加入白名单并幽默提示
# ✅ 日志限速记录 [FW-BLOCK]
# ✅ 支持 Debian 9/10/11/12/13
# ✅ 执行结束会显示彩色自检状态 🍏 ACCEPT / 🔴 DROP
#

set -euo pipefail

# ==================== 配置区 ====================
WHITELIST_SET="cn_whitelist"
CHINA_SET="china_ipset"
IP_LIST_URL="https://www.ipdeny.com/ipblocks/data/countries/cn.zone"
BACKUP_DIR="/root/firewall-backups"
LOG_PREFIX="[FW-BLOCK]"
ENABLE_LOGGING=true
# ================================================

# 检测是否为测试模式
TEST_MODE=false
if [ "${1:-}" = "--test" ] || [ "${1:-}" = "-t" ]; then
    TEST_MODE=true
fi

# 彩色输出（兼容）
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    log_error "必须使用 root 运行: sudo bash $0"
    exit 1
fi

# 创建备份目录
mkdir -p "${BACKUP_DIR}"

# 如果 TEST 模式，检测依赖
if [ "$TEST_MODE" = true ]; then
    log_info "测试模式：检查依赖..."
    for cmd in iptables ipset curl mktemp; do
        if command -v $cmd >/dev/null 2>&1; then
            echo "  ✓ $cmd: 已安装"
        else
            echo "  ✗ $cmd: 未安装"
        fi
    done
    exit 0
fi

log_step "步骤 1/6: 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y ipset iptables curl >/dev/null

# 检测管理IP
log_step "步骤 2/6: 检测公网IP"
DETECTED_IP=""
for url in "https://ipinfo.io/ip" "https://api.ipify.org" "https://ifconfig.me"; do
    DETECTED_IP=$(curl -s --connect-timeout 5 "$url" | tr -d '\n\r' || true)
    if echo "$DETECTED_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        break
    fi
done
if [ -z "$DETECTED_IP" ]; then
    DETECTED_IP="未知"
fi
log_info "当前公网IP: ${GREEN}${DETECTED_IP}${NC}"

log_step "步骤 3/6: 下载中国IP段并创建 IP 集合"
ipset create "${CHINA_SET}" hash:net family inet 2>/dev/null || ipset flush "${CHINA_SET}"
ipset create "${WHITELIST_SET}" hash:ip family inet 2>/dev/null || true

TMPFILE=$(mktemp)
curl -fsSL "$IP_LIST_URL" -o "$TMPFILE"
COUNT=0
while read -r CIDR; do
    [[ -z "$CIDR" ]] && continue
    ipset add "${CHINA_SET}" "$CIDR" 2>/dev/null && COUNT=$((COUNT+1))
done < "$TMPFILE"
rm -f "$TMPFILE"
log_info "导入 ${GREEN}${COUNT}${NC} 条中国 IP 段"

# 检测当前 IP 是否在中国段
echo ""
echo "🌏 检测当前IP是否属于中国段..."
if ipset test "${CHINA_SET}" "${DETECTED_IP}" >/dev/null 2>&1; then
    echo -e "🍏 当前IP ${GREEN}${DETECTED_IP}${NC} 属于中国，无需加入白名单"
else
    echo -e "🌍 当前IP ${YELLOW}${DETECTED_IP}${NC} 不在中国段"
    echo -e "😎 为防止你把自己锁门外，我已贴心地将你加入白名单"
    ipset add "${WHITELIST_SET}" "${DETECTED_IP}" 2>/dev/null || true
fi
# ==================== 备份并应用防火墙规则 ====================
log_step "步骤 4/6: 备份现有 iptables 规则"
BACKUP_FILE="${BACKUP_DIR}/iptables-$(date +%Y%m%d-%H%M%S).rules"
iptables-save > "$BACKUP_FILE"
log_info "已备份到: ${BACKUP_FILE}"

log_step "步骤 5/6: 应用 INPUT 防火墙规则（仅限制入站）"

# 清空 INPUT 旧规则
iptables -F INPUT

# ✅ 保证 FORWARD / OUTPUT 全部放行，避免影响 Nypass 转发
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# 允许本地回环
iptables -A INPUT -i lo -j ACCEPT

# 允许已建立的连接
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 放行白名单 IP
iptables -A INPUT -m set --match-set "${WHITELIST_SET}" src -j ACCEPT

# 放行中国 IP 段
iptables -A INPUT -m set --match-set "${CHINA_SET}" src -j ACCEPT

# 记录日志（限速）
if [ "$ENABLE_LOGGING" = true ]; then
    iptables -A INPUT -m limit --limit 10/min -j LOG --log-prefix "${LOG_PREFIX} " --log-level 4
fi

# 拒绝所有其他入站
iptables -A INPUT -j DROP
# ==================== 自检状态输出 ====================
log_step "步骤 6/6: 防火墙规则应用完成，自检状态如下"

echo ""
echo -e "${GREEN}✅ 防火墙规则已成功生效${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 兼容 Debian12/13 nftables 后端的 FORWARD 策略检测方式
FORWARD_POLICY=$(iptables -L FORWARD -n 2>/dev/null | head -n 1 | grep -qi "ACCEPT" && echo "ACCEPT" || echo "DROP")

if [ "$FORWARD_POLICY" = "ACCEPT" ]; then
    echo -e "🧱 FORWARD 链默认策略：🍏 ${GREEN}ACCEPT${NC}"
else
    echo -e "🧱 FORWARD 链默认策略：🔴 ${RED}${FORWARD_POLICY}${NC}  (⚠ 如为中转服务器可能影响 Nypass)"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "🔍 INPUT 链前 20 条规则如下："
iptables -L INPUT -n --line-numbers | head -n 20
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo -e "📌 若 SSH 被锁，可在云控制台执行紧急恢复："
echo -e "   ${YELLOW}iptables -F INPUT && iptables -P INPUT ACCEPT${NC}"
echo ""
echo -e "📂 回滚备份文件位于：${GREEN}${BACKUP_FILE}${NC}"
echo -e "   可还原：iptables-restore < ${BACKUP_FILE}"
echo ""
echo -e "${GREEN}🎯 当前服务器已仅允许 中国IP + 白名单 访问，出站与转发保持自由${NC}"
echo -e "✨ 脚本执行完毕！祝你使用愉快 😎"
echo ""

exit 0
