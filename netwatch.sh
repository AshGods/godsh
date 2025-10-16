#!/bin/bash
#
# setup_netwatch.sh
# 一键部署网络监控 + 自动关机守护服务（含日志 & Telegram 通知占位）
#

NETWATCH_SCRIPT="/root/netwatch.sh"
SERVICE_FILE="/etc/systemd/system/netwatch.service"
LOG_FILE="/var/log/netwatch.log"

echo "=============================="
echo "🚀 NetWatch 自动部署开始"
echo "=============================="

# 1. 自动安装 tcping & curl
echo "🧪 检查 tcping 和 curl ..."
if ! command -v tcping &>/dev/null; then
    echo "📦 安装 tcping ..."
    apt update -y >/dev/null 2>&1
    apt install -y tcping >/dev/null 2>&1
fi

if ! command -v curl &>/dev/null; then
    echo "📦 安装 curl ..."
    apt update -y >/dev/null 2>&1
    apt install -y curl >/dev/null 2>&1
fi

# 2. 写入监控脚本
echo "📝 写入 ${NETWATCH_SCRIPT}"

cat > ${NETWATCH_SCRIPT} << 'EOF'
#!/bin/bash

TARGET1="8.8.8.8"
TARGET2="1.1.1.1"
PORT=53
FAIL_LIMIT=10
FAIL_COUNT=0
LOG_FILE="/var/log/netwatch.log"

# Telegram Bot 配置（请手动填写）
BOT_TOKEN="__REPLACE_ME__"
CHAT_ID="__REPLACE_ME__"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 确保日志文件存在
touch "$LOG_FILE"

log "=== NetWatch 启动，目标 DNS：${TARGET1}:${PORT} & ${TARGET2}:${PORT} ==="

while true; do
    tcping -q -t 1 $TARGET1 $PORT >/dev/null 2>&1
    R1=$?
    tcping -q -t 1 $TARGET2 $PORT >/dev/null 2>&1
    R2=$?

    if [[ $R1 -ne 0 && $R2 -ne 0 ]]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log "[FAIL] ${TARGET1}:${PORT} ✖ | ${TARGET2}:${PORT} ✖  ($FAIL_COUNT/$FAIL_LIMIT)"
    else
        if [[ $FAIL_COUNT -gt 0 ]]; then
            log "[RECOVER] 恢复正常，计数清零"
        fi
        FAIL_COUNT=0
        log "[OK]   ${TARGET1}:${PORT} ✔ | ${TARGET2}:${PORT} ✔"
    fi

    if [[ $FAIL_COUNT -ge $FAIL_LIMIT ]]; then
        log "[CRITICAL] 连续 $FAIL_LIMIT 次失败，准备关机！"

        # Telegram 通知（仅在配置后生效）
        if [[ "$BOT_TOKEN" != "__REPLACE_ME__" && "$CHAT_ID" != "__REPLACE_ME__" ]]; then
            MESSAGE="🛑 DNS 摸鱼中\n服务器 $(hostname) 已连续 ${FAIL_LIMIT} 次联络不上外网！\n5 秒后我就自裁关机了 🤖💣"
            curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                -d "chat_id=${CHAT_ID}" -d "text=${MESSAGE}" >/dev/null 2>&1
            log "[INFO] Telegram 通知已发送"
        else
            log "[INFO] Telegram 未配置，跳过通知"
        fi

        sleep 5
        poweroff
        exit 0
    fi

    sleep 1
done
EOF

chmod +x ${NETWATCH_SCRIPT}

# 3. 写入 systemd 服务配置
echo "📝 写入 ${SERVICE_FILE}"

cat > ${SERVICE_FILE} << EOF
[Unit]
Description=Network Connectivity Watchdog (TCP DNS Monitor)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash ${NETWATCH_SCRIPT}
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

# 4. 启动并设置开机自启
echo "✅ 启动 NetWatch 服务"
systemctl daemon-reload
systemctl enable netwatch.service
systemctl start netwatch.service

echo "=============================="
echo "🎯 部署完成！当前服务状态："
systemctl status netwatch.service | sed -n '1,5p'
echo "=============================="
echo "📌 日志路径：${LOG_FILE}"
echo "📌 若需马上查看日志：tail -f ${LOG_FILE}"
echo "📌 若要启用 Telegram 通知，请编辑："
echo "    nano /root/netwatch.sh   # 填入 BOT_TOKEN 和 CHAT_ID"
echo "=============================="
