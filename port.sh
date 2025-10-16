#!/bin/bash
#
# port_forward_cn_only.sh
# 端口转发中转服务器专用防火墙脚本（最终版）
# ✅ 仅限制 INPUT 入站（中国IP+白名单允许，其余全部DROP）
# ✅ FORWARD 默认 ACCEPT，确保 Nypass / 转发功能不受影响
# ✅ OUTPUT 始终 ACCEPT
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
CRON_SCRIPT="/etc/cron.daily/update-china-ipset"
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

# 安全提示
log_step "步骤 3/6: 安全确认"
echo ""
echo "🚨 请确认是否已将管理IP加入白名单："
echo "  ipset create ${WHITELIST_SET} hash:ip 2>/dev/null || true"
echo "  ipset add ${WHITELIST_SET} ${DETECTED_IP}"
echo ""
read -p "确认继续? 输入 yes 执行: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    log_error "操作取消"
    exit 1
fi

# 创建 ipset 集合
log_step "步骤 4/6: 创建 IP 集合"
ipset create "${CHINA_SET}" hash:net family inet 2>/dev/null || ipset flush "${CHINA_SET}"
ipset create "${WHITELIST_SET}" hash:ip family inet 2>/dev/null || true

# 下载 CN IP 段
log_info "下载中国IP段..."
TMPFILE=$(mktemp)
curl -fsSL "$IP_LIST_URL" -o "$TMPFILE"
COUNT=0
while read -r CIDR; do
    [[ -z "$CIDR" ]] && continue
    ipset add "${CHINA_SET}" "$CIDR" 2>/dev/null && COUNT=$((COUNT+1))
done < "$TMPFILE"
rm -f "$TMPFILE"
log_info "导入 ${GREEN}${COUNT}${NC} 条中国 IP 段"

# 备份规则
log_step "步骤 5/6: 备份现有规则"
BACKUP_FILE="${BACKUP_DIR}/iptables-$(date +%Y%m%d-%H%M%S).rules"
iptables-save > "$BACKUP_FILE"
log_info "保存到 ${BACKUP_FILE}"

# 应用 INPUT 规则
log_step "步骤 6/6: 应用防火墙规则 (INPUT ONLY)"
iptables -F INPUT
iptables -P FORWARD ACCEPT     # ✅ 确保转发链放行（适配 Nypass）
iptables -P OUTPUT ACCEPT      # ✅ 出站无阻挡

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m set --match-set "${WHITELIST_SET}" src -j ACCEPT
iptables -A INPUT -m set --match-set "${CHINA_SET}" src -j ACCEPT
if [ "$ENABLE_LOGGING" = true ]; then
    iptables -A INPUT -m limit --limit 10/min -j LOG --log-prefix "${LOG_PREFIX} " --log-level 4
fi
iptables -A INPUT -j DROP

# ==================== 自检状态输出 ====================
echo ""
echo -e "${GREEN}✅ 防火墙规则已应用${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
FORWARD_POLICY=$(iptables -P FORWARD | awk '{print $3}')
if [ "$FORWARD_POLICY" = "ACCEPT" ]; then
    echo -e "🧱 FORWARD 链默认策略：🍏 ${GREEN}ACCEPT${NC}"
else
    echo -e "🧱 FORWARD 链默认策略：🔴 ${RED}${FORWARD_POLICY}${NC}  (⚠ 如为中转服务器可能影响 Nypass)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "🔍 INPUT 链前20条规则如下："
iptables -L INPUT -n --line-numbers | head -n 20
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo -e "📌 若 SSH 被锁，可在云控制台执行紧急恢复："
echo -e "    ${YELLOW}iptables -F INPUT && iptables -P INPUT ACCEPT${NC}"
echo ""
echo -e "或使用已生成的回滚脚本(如存在)："
echo -e "    ${YELLOW}bash ${BACKUP_DIR}/rollback.sh${NC}"
echo ""
echo -e "${GREEN}✅ 防火墙已成功生效，当前服务器仅允许中国IP + 白名单访问${NC}"
echo ""

exit 0
