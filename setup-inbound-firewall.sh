#!/bin/bash
set -Eeuo pipefail

umask 077

INSTALL_DIR=/etc/inbound-firewall
INSTALLED_SCRIPT=/usr/local/sbin/inbound-firewall-sync
INSTALLED_PORTS=$INSTALL_DIR/ports.conf
NFT_CONFIG=/etc/nftables.conf
SERVICE_FILE=/etc/systemd/system/inbound-firewall-sync.service
TIMER_FILE=/etc/systemd/system/inbound-firewall-sync.timer

# Change this once before distributing the script to your servers.
PORTS_URL='https://raw.githubusercontent.com/AshGods/godsh/refs/heads/main/inbound-firewall-ports.conf'

usage() {
  cat <<'EOF'
用法：
  sudo ./setup-inbound-firewall.sh
  ./setup-inbound-firewall.sh --dry-run --ports-file FILE --ssh-port PORT
  sudo /usr/local/sbin/inbound-firewall-sync --sync

安装前请修改脚本顶部的 PORTS_URL。systemd 定时器每分钟下载一次远程文件，
校验成功后更新本地缓存，并以原子方式应用新增和删除的端口。

PORTS_URL 必须返回与原始文件相同的逐行 JSON。每个 listen_port 都会同时
放行 TCP 和 UDP。

选项：
  --ports-file FILE  仅在预览模式下使用本地 JSON 文件。
  --dry-run          输出生成的规则，但不应用。
  --sync             立即下载并同步，供 systemd 调用。
  --ssh-port PORT    指定 SSH 端口，可重复使用；否则自动检测。
  -h, --help         显示帮助。
EOF
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

validate_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

validate_url() {
  case "$1" in
    https://*) return 0 ;;
    *) return 1 ;;
  esac
}

MODE=install
PORTS_FILE=''
SSH_PORT_ARGS=()
TEMP_FILES=()

cleanup() {
  if [ "${#TEMP_FILES[@]}" -gt 0 ]; then
    rm -f "${TEMP_FILES[@]}"
  fi
}
trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      [ "$MODE" = install ] || die '只能选择一种运行模式'
      MODE=dry-run
      shift
      ;;
    --sync)
      [ "$MODE" = install ] || die '只能选择一种运行模式'
      MODE=sync
      shift
      ;;
    --ports-file)
      [ "$#" -ge 2 ] || die '--ports-file 后面必须提供文件路径'
      PORTS_FILE=$2
      shift 2
      ;;
    --ssh-port)
      [ "$#" -ge 2 ] || die '--ssh-port 后面必须提供端口号'
      validate_port "$2" || die "SSH 端口无效：$2"
      SSH_PORT_ARGS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      [ "$#" -eq 0 ] || die '存在多余的位置参数'
      ;;
    -*)
      die "未知选项：$1"
      ;;
    *)
      die "多余参数：$1"
      ;;
  esac
done

if [ "$MODE" != dry-run ] && [ -n "$PORTS_FILE" ]; then
  die '--ports-file 只能与 --dry-run 一起使用；正式安装始终下载 PORTS_URL'
fi

if [ "$MODE" = install ]; then
  [ "$(id -u)" -eq 0 ] || die '请使用 root 权限运行（使用 sudo）'
  validate_url "$PORTS_URL" || die 'PORTS_URL 必须使用 HTTPS'
  case "$PORTS_URL" in
    *CHANGE-ME*) die '安装前请先修改脚本中的 PORTS_URL' ;;
  esac
  command -v apt-get >/dev/null 2>&1 || die '此安装脚本需要 Debian 的 apt-get'
  printf '正在更新软件包索引……\n'
  apt-get update
  printf '正在安装 nftables、curl 和 jq……\n'
  DEBIAN_FRONTEND=noninteractive apt-get install -y nftables curl jq
elif [ "$MODE" = sync ]; then
  [ "$(id -u)" -eq 0 ] || die '同步操作必须使用 root 权限运行'
  command -v curl >/dev/null 2>&1 || die '缺少 curl，继续保留上一版规则'
  command -v jq >/dev/null 2>&1 || die '缺少 jq，继续保留上一版规则'
  validate_url "$PORTS_URL" || die 'PORTS_URL 必须使用 HTTPS，继续保留上一版规则'
  case "$PORTS_URL" in
    *CHANGE-ME*) die '请修改已安装脚本中的 PORTS_URL' ;;
  esac
else
  [ -n "$PORTS_FILE" ] || die '--dry-run 必须同时提供 --ports-file FILE'
fi

if [ "$MODE" != dry-run ]; then
  DOWNLOAD_FILE=$(mktemp)
  TEMP_FILES+=("$DOWNLOAD_FILE")
  if ! curl --fail --silent --show-error --location \
      --proto '=https' --proto-redir '=https' \
      --connect-timeout 10 --max-time 30 \
      --output "$DOWNLOAD_FILE" "$PORTS_URL"; then
    die '远程文件下载失败，继续保留上一版规则和本地缓存'
  fi
  PORTS_FILE=$DOWNLOAD_FILE
fi

[ -r "$PORTS_FILE" ] || die "无法读取端口源文件：$PORTS_FILE"
command -v jq >/dev/null 2>&1 || die '提取 listen_port 需要 jq'

if ! LISTEN_PORTS=$(jq -er '
  def records:
    if type == "object" then .
    elif type == "array" then .[]
    else error("每个 JSON 值必须是对象或对象数组")
    end;

  records
  | .listen_port as $port
  | if (($port | type) == "number"
        and ($port | floor) == $port
        and $port >= 1
        and $port <= 65535)
    then $port
    else error("listen_port 必须是 1 到 65535 之间的整数")
    end
' "$PORTS_FILE" | sort -n -u); then
  die 'JSON 或 listen_port 校验失败，继续保留上一版规则和本地缓存'
fi

detect_ssh_ports() {
  local sshd_bin=''
  local output=''
  local current_port=''

  if [ -x /usr/sbin/sshd ]; then
    sshd_bin=/usr/sbin/sshd
  elif command -v sshd >/dev/null 2>&1; then
    sshd_bin=$(command -v sshd)
  else
    die '找不到 sshd，请使用 --ssh-port 指定当前 SSH 端口'
  fi

  output=$($sshd_bin -T 2>/dev/null) || die 'sshd 配置检查失败，请使用 --ssh-port 指定当前 SSH 端口'
  printf '%s\n' "$output" | awk '$1 == "port" { print $2 }'

  if [ -n "${SSH_CONNECTION:-}" ]; then
    current_port=$(printf '%s\n' "$SSH_CONNECTION" | awk '{ print $4 }')
    validate_port "$current_port" || die "SSH_CONNECTION 中的服务器端口无效：$current_port"
    printf '%s\n' "$current_port"
  fi
}

if [ "${#SSH_PORT_ARGS[@]}" -gt 0 ]; then
  SSH_PORTS=$(printf '%s\n' "${SSH_PORT_ARGS[@]}" | sort -n -u)
  if [ -n "${SSH_CONNECTION:-}" ]; then
    CURRENT_SSH_PORT=$(printf '%s\n' "$SSH_CONNECTION" | awk '{ print $4 }')
    validate_port "$CURRENT_SSH_PORT" || die "SSH_CONNECTION 中的服务器端口无效：$CURRENT_SSH_PORT"
    SSH_PORTS=$(printf '%s\n%s\n' "$SSH_PORTS" "$CURRENT_SSH_PORT" | sort -n -u)
  fi
else
  SSH_PORTS=$(detect_ssh_ports)
  [ -n "$SSH_PORTS" ] || die '未检测到 SSH 端口，请使用 --ssh-port 指定'
  while IFS= read -r port; do
    validate_port "$port" || die "sshd 返回了无效端口：$port"
  done <<< "$SSH_PORTS"
fi

TCP_PORTS=$(printf '%s\n%s\n' "$SSH_PORTS" "$LISTEN_PORTS" | sed '/^$/d' | sort -n -u)
TCP_ELEMENTS=$(printf '%s\n' "$TCP_PORTS" | paste -sd, - | sed 's/,/, /g')
UDP_ELEMENTS=$(printf '%s\n' "$LISTEN_PORTS" | paste -sd, - | sed 's/,/, /g')

render_rules() {
  cat <<EOF
#!/usr/sbin/nft -f

table inet inbound_guard
flush table inet inbound_guard

table inet inbound_guard {
    set allowed_tcp_ports {
        type inet_service
        elements = { $TCP_ELEMENTS }
    }

    set allowed_udp_ports {
        type inet_service
        elements = { $UDP_ELEMENTS }
    }

    chain input {
        type filter hook input priority 0; policy drop;

        iifname "lo" accept
        ct state invalid drop
        ct state established,related accept

        ip protocol icmp icmp type echo-request drop
        meta l4proto ipv6-icmp icmpv6 type echo-request drop

        ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
        meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept

        tcp dport @allowed_tcp_ports accept
        udp dport @allowed_udp_ports accept
    }
}
EOF
}

if [ "$MODE" = dry-run ]; then
  render_rules
  exit 0
fi

[ "$(id -u)" -eq 0 ] || die '请使用 root 权限运行（使用 sudo）'
command -v nft >/dev/null 2>&1 || die '缺少 nftables'
command -v curl >/dev/null 2>&1 || die '缺少 curl'
command -v jq >/dev/null 2>&1 || die '缺少 jq'
command -v systemctl >/dev/null 2>&1 || die '缺少 systemctl'

RULE_FILE=$(mktemp)
TEMP_FILES+=("$RULE_FILE")
render_rules > "$RULE_FILE"
nft -c -f "$RULE_FILE" || die '生成的 nftables 规则校验失败，继续保留上一版规则'

apply_rules() {
  local previous_config=''
  local had_previous=0

  previous_config=$(mktemp)
  TEMP_FILES+=("$previous_config")
  if [ -e "$NFT_CONFIG" ]; then
    cp -a "$NFT_CONFIG" "$previous_config"
    had_previous=1
    if ! cmp -s "$RULE_FILE" "$NFT_CONFIG"; then
      install -m 600 "$NFT_CONFIG" /var/backups/nftables.conf-before-last-sync
    fi
  fi

  install -m 600 "$RULE_FILE" "$NFT_CONFIG"
  if ! nft -f "$NFT_CONFIG"; then
    if [ "$had_previous" -eq 1 ]; then
      cp -a "$previous_config" "$NFT_CONFIG"
    else
      rm -f "$NFT_CONFIG"
    fi
    die '应用规则失败，已恢复上一版持久化配置'
  fi
}

write_port_cache() {
  local cache_file=''
  cache_file=$(mktemp)
  TEMP_FILES+=("$cache_file")
  printf '%s\n' "$LISTEN_PORTS" > "$cache_file"
  install -m 600 "$cache_file" "$INSTALLED_PORTS"
}

mkdir -p /var/backups "$INSTALL_DIR"

if [ "$MODE" = sync ]; then
  apply_rules
  write_port_cache
  printf '已从远程源同步 %s 个放行端口。\n' "$(printf '%s\n' "$LISTEN_PORTS" | wc -l | tr -d ' ')"
  exit 0
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RULESET_BACKUP="/var/backups/nftables-before-inbound-guard-$TIMESTAMP.nft"
{
  printf 'flush ruleset\n'
  nft list ruleset
} > "$RULESET_BACKUP"

if [ -e "$NFT_CONFIG" ]; then
  install -m 600 "$NFT_CONFIG" "/var/backups/nftables.conf-before-inbound-guard-$TIMESTAMP"
fi

install -m 755 "${BASH_SOURCE[0]}" "$INSTALLED_SCRIPT"
write_port_cache

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=同步入站 nftables 端口白名单
After=nftables.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALLED_SCRIPT --sync
EOF

cat > "$TIMER_FILE" <<'EOF'
[Unit]
Description=每分钟同步入站防火墙端口白名单

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s
Persistent=true
Unit=inbound-firewall-sync.service

[Install]
WantedBy=timers.target
EOF

chmod 644 "$SERVICE_FILE" "$TIMER_FILE"
apply_rules
systemctl daemon-reload
systemctl enable nftables.service >/dev/null || die '规则已经生效，但设置 nftables 开机启动失败'
systemctl enable --now inbound-firewall-sync.timer >/dev/null || die '规则已经生效，但启用定时同步失败'

printf '防火墙和远程同步安装成功。\n'
printf '本地有效端口缓存：%s\n' "$INSTALLED_PORTS"
printf '自动同步频率：每分钟一次\n'
printf 'SSH TCP 端口：%s\n' "$(printf '%s' "$SSH_PORTS" | paste -sd, -)"
printf '放行端口（TCP 和 UDP）：%s\n' "$(printf '%s' "$LISTEN_PORTS" | paste -sd, -)"
printf '原运行时规则备份：%s\n' "$RULESET_BACKUP"
printf '请保持当前 SSH 会话不要断开，并另开一个终端测试登录。\n'
