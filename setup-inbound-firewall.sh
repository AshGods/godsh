#!/bin/bash
set -Eeuo pipefail

umask 077

INSTALL_DIR=/etc/inbound-firewall
INSTALLED_SCRIPT=/usr/local/sbin/inbound-firewall-sync
INSTALLED_PORTS=$INSTALL_DIR/ports.conf
SSH_PORTS_FILE=$INSTALL_DIR/ssh-ports.conf
RULE_CONFIG=$INSTALL_DIR/rules.nft
SERVICE_FILE=/etc/systemd/system/inbound-firewall-sync.service
TIMER_FILE=/etc/systemd/system/inbound-firewall-sync.timer
LOAD_SERVICE_FILE=/etc/systemd/system/inbound-firewall-load.service
MAX_PORT_FILE_BYTES=65536
MAX_ALLOWED_PORTS=1024

PORTS_URL='https://raw.githubusercontent.com/AshGods/godsh/refs/heads/main/inbound-firewall-ports.conf'
SCRIPT_URL='https://raw.githubusercontent.com/AshGods/godsh/refs/heads/main/setup-inbound-firewall.sh'

usage() {
  cat <<'EOF'
用法：
  sudo ./setup-inbound-firewall.sh
  curl -fsSL https://raw.githubusercontent.com/AshGods/godsh/refs/heads/main/setup-inbound-firewall.sh | sudo bash
  ./setup-inbound-firewall.sh --dry-run --ports-file FILE --ssh-port PORT
  sudo /usr/local/sbin/inbound-firewall-sync --sync
  sudo /usr/local/sbin/inbound-firewall-sync --load

systemd 定时器每分钟下载一次固定的 PORTS_URL，校验成功后更新本地缓存，
并以原子方式应用新增和删除的端口。

远程文件必须每行写一个端口，允许空行和以 # 开头的注释。每个端口都会
同时放行 TCP 和 UDP。

选项：
  --ports-file FILE  仅在预览模式下使用本地端口文件。
  --dry-run          输出生成的规则，但不应用。
  --sync             立即下载并同步，供 systemd 调用。
  --load             从本地缓存加载规则，供开机服务调用。
  --ssh-port PORT    指定 SSH 端口，可重复使用；否则自动检测。
  --ssh-ports-file FILE
                     仅在预览模式下读取持久化 SSH 端口，供测试使用。
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
SSH_PORTS_SOURCE=''
SSH_PORT_ARGS=()
TEMP_FILES=()
TEMP_DIRS=()
INSTALL_ROLLBACK_ARMED=0
INSTALL_COMMITTED=0
RULESET_BACKUP=''
STATE_BACKUP=''
LOAD_WAS_ENABLED='disabled'
TIMER_WAS_ENABLED='disabled'

cleanup() {
  local status=$?

  if [ "$status" -ne 0 ] && [ "$INSTALL_ROLLBACK_ARMED" -eq 1 ] && \
      [ "$INSTALL_COMMITTED" -eq 0 ]; then
    printf '安装未完成，正在恢复原防火墙和服务状态……\n' >&2
    if [ -n "$RULESET_BACKUP" ] && [ -r "$RULESET_BACKUP" ]; then
      nft -f "$RULESET_BACKUP" >/dev/null 2>&1 || true
    fi
    systemctl disable --now inbound-firewall-sync.timer >/dev/null 2>&1 || true
    systemctl disable inbound-firewall-load.service >/dev/null 2>&1 || true
    rm -rf "$INSTALL_DIR"
    rm -f "$INSTALLED_SCRIPT" "$SERVICE_FILE" "$TIMER_FILE" "$LOAD_SERVICE_FILE"
    if [ -n "$STATE_BACKUP" ] && [ -d "$STATE_BACKUP" ]; then
      [ ! -e "$STATE_BACKUP/install-dir" ] || cp -a "$STATE_BACKUP/install-dir" "$INSTALL_DIR"
      [ ! -e "$STATE_BACKUP/installed-script" ] || cp -a "$STATE_BACKUP/installed-script" "$INSTALLED_SCRIPT"
      [ ! -e "$STATE_BACKUP/sync.service" ] || cp -a "$STATE_BACKUP/sync.service" "$SERVICE_FILE"
      [ ! -e "$STATE_BACKUP/sync.timer" ] || cp -a "$STATE_BACKUP/sync.timer" "$TIMER_FILE"
      [ ! -e "$STATE_BACKUP/load.service" ] || cp -a "$STATE_BACKUP/load.service" "$LOAD_SERVICE_FILE"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ "$LOAD_WAS_ENABLED" = enabled ]; then
      systemctl enable inbound-firewall-load.service >/dev/null 2>&1 || true
    fi
    if [ "$TIMER_WAS_ENABLED" = enabled ]; then
      systemctl enable --now inbound-firewall-sync.timer >/dev/null 2>&1 || true
    fi
    printf '已尝试恢复安装前状态。\n' >&2
  fi

  if [ "${#TEMP_FILES[@]}" -gt 0 ]; then
    rm -f "${TEMP_FILES[@]}"
  fi
  if [ "${#TEMP_DIRS[@]}" -gt 0 ]; then
    rm -rf "${TEMP_DIRS[@]}"
  fi

  return "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

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
    --load)
      [ "$MODE" = install ] || die '只能选择一种运行模式'
      MODE=load
      shift
      ;;
    --ports-file)
      [ "$#" -ge 2 ] || die '--ports-file 后面必须提供文件路径'
      PORTS_FILE=$2
      shift 2
      ;;
    --ssh-ports-file)
      [ "$#" -ge 2 ] || die '--ssh-ports-file 后面必须提供文件路径'
      SSH_PORTS_SOURCE=$2
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

if [ "$MODE" != dry-run ] && [ -n "$SSH_PORTS_SOURCE" ]; then
  die '--ssh-ports-file 只能与 --dry-run 一起使用'
fi

if [ "$MODE" = install ]; then
  [ "$(id -u)" -eq 0 ] || die '请使用 root 权限运行（使用 sudo）'
  validate_url "$PORTS_URL" || die 'PORTS_URL 必须使用 HTTPS'
  command -v apt-get >/dev/null 2>&1 || die '此安装脚本需要 Debian 的 apt-get'
  printf '正在更新软件包索引……\n'
  apt-get update
  printf '正在安装 nftables 和 curl……\n'
  DEBIAN_FRONTEND=noninteractive apt-get install -y nftables curl
elif [ "$MODE" = sync ]; then
  [ "$(id -u)" -eq 0 ] || die '同步操作必须使用 root 权限运行'
  command -v curl >/dev/null 2>&1 || die '缺少 curl，继续保留上一版规则'
  validate_url "$PORTS_URL" || die 'PORTS_URL 必须使用 HTTPS，继续保留上一版规则'
elif [ "$MODE" = load ]; then
  [ "$(id -u)" -eq 0 ] || die '开机加载必须使用 root 权限运行'
  PORTS_FILE=$INSTALLED_PORTS
else
  [ -n "$PORTS_FILE" ] || die '--dry-run 必须同时提供 --ports-file FILE'
fi

if [ "$MODE" = install ] || [ "$MODE" = sync ]; then
  DOWNLOAD_FILE=$(mktemp)
  TEMP_FILES+=("$DOWNLOAD_FILE")
  if ! curl --fail --silent --show-error --location \
      --proto '=https' --proto-redir '=https' \
      --connect-timeout 10 --max-time 30 \
      --max-filesize "$MAX_PORT_FILE_BYTES" \
      --output "$DOWNLOAD_FILE" "$PORTS_URL"; then
    die '远程文件下载失败，继续保留上一版规则和本地缓存'
  fi
  PORTS_FILE=$DOWNLOAD_FILE
fi

[ -r "$PORTS_FILE" ] || die "无法读取端口源文件：$PORTS_FILE"
[ "$(wc -c < "$PORTS_FILE" | tr -d ' ')" -le "$MAX_PORT_FILE_BYTES" ] || \
  die "端口文件超过 ${MAX_PORT_FILE_BYTES} 字节，拒绝处理"

if ! LISTEN_PORTS=$(awk '
  {
    sub(/#.*/, "")
    gsub(/^[[:space:]]+|[[:space:]]+$/, "")
    if ($0 == "") next
    if ($0 !~ /^[0-9]+$/ || $0 < 1 || $0 > 65535) {
      printf "第 %d 行端口无效：%s\n", NR, $0 > "/dev/stderr"
      bad = 1
      next
    }
    print $0 + 0
    found = 1
  }
  END {
    if (!found) {
      print "端口文件中没有有效端口" > "/dev/stderr"
      bad = 1
    }
    exit bad
  }
' "$PORTS_FILE" | sort -n -u); then
  die '端口文件校验失败，继续保留上一版规则和本地缓存'
fi

LISTEN_PORT_COUNT=$(printf '%s\n' "$LISTEN_PORTS" | wc -l | tr -d ' ')
[ "$LISTEN_PORT_COUNT" -le "$MAX_ALLOWED_PORTS" ] || \
  die "放行端口数量超过上限 ${MAX_ALLOWED_PORTS}，拒绝应用"

detect_ssh_ports() {
  local sshd_bin=''
  local output=''

  if [ -x /usr/sbin/sshd ]; then
    sshd_bin=/usr/sbin/sshd
  elif command -v sshd >/dev/null 2>&1; then
    sshd_bin=$(command -v sshd)
  else
    return 1
  fi

  output=$($sshd_bin -T 2>/dev/null) || return 1
  printf '%s\n' "$output" | awk '$1 == "port" { print $2 }'
}

read_ssh_ports_file() {
  local source_file=$1

  [ -r "$source_file" ] || return 0
  awk '
    /^[[:space:]]*($|#)/ { next }
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if ($0 !~ /^[0-9]+$/ || $0 < 1 || $0 > 65535) exit 1
      print $0 + 0
    }
  ' "$source_file"
}

SSH_CANDIDATES=''
PERSISTED_SSH_PORTS=''
if [ "${#SSH_PORT_ARGS[@]}" -gt 0 ]; then
  SSH_CANDIDATES=$(printf '%s\n' "${SSH_PORT_ARGS[@]}")
fi

if [ "$MODE" = dry-run ]; then
  if [ -n "$SSH_PORTS_SOURCE" ]; then
    PERSISTED_SSH_PORTS=$(read_ssh_ports_file "$SSH_PORTS_SOURCE") || \
      die "持久化 SSH 端口文件无效：$SSH_PORTS_SOURCE"
  fi
else
  PERSISTED_SSH_PORTS=$(read_ssh_ports_file "$SSH_PORTS_FILE") || \
    die "持久化 SSH 端口文件无效：$SSH_PORTS_FILE"
fi
SSH_CANDIDATES=$(printf '%s\n%s\n' "$SSH_CANDIDATES" "$PERSISTED_SSH_PORTS")

if DETECTED_SSH_PORTS=$(detect_ssh_ports); then
  SSH_CANDIDATES=$(printf '%s\n%s\n' "$SSH_CANDIDATES" "$DETECTED_SSH_PORTS")
fi

if [ -n "${SSH_CONNECTION:-}" ]; then
  CURRENT_SSH_PORT=$(printf '%s\n' "$SSH_CONNECTION" | awk '{ print $4 }')
  validate_port "$CURRENT_SSH_PORT" || die "SSH_CONNECTION 中的服务器端口无效：$CURRENT_SSH_PORT"
  SSH_CANDIDATES=$(printf '%s\n%s\n' "$SSH_CANDIDATES" "$CURRENT_SSH_PORT")
fi

SSH_PORTS=$(printf '%s\n' "$SSH_CANDIDATES" | sed '/^$/d' | sort -n -u)
[ -n "$SSH_PORTS" ] || die '未检测到 SSH 端口，请使用 --ssh-port 指定'
while IFS= read -r port; do
  validate_port "$port" || die "检测到无效 SSH 端口：$port"
done <<< "$SSH_PORTS"

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

        ip protocol icmp icmp type echo-request drop
        meta l4proto ipv6-icmp icmpv6 type echo-request drop

        udp sport 67 udp dport 68 accept
        udp sport 547 udp dport 546 accept

        ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
        meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept

        ct state invalid drop
        ct state established,related accept

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
[ "$MODE" = load ] || command -v curl >/dev/null 2>&1 || die '缺少 curl'
command -v systemctl >/dev/null 2>&1 || die '缺少 systemctl'

RULE_FILE=$(mktemp)
TEMP_FILES+=("$RULE_FILE")
render_rules > "$RULE_FILE"
nft -c -f "$RULE_FILE" || die '生成的 nftables 规则校验失败，继续保留上一版规则'

check_firewall_conflicts() {
  local ruleset=''
  local conflicts=''

  if systemctl is-active --quiet ufw.service 2>/dev/null || \
      systemctl is-enabled --quiet ufw.service 2>/dev/null; then
    die '检测到 UFW 正在运行或已设置开机启动。请先停用 UFW，再安装本脚本'
  fi
  if systemctl is-active --quiet firewalld.service 2>/dev/null || \
      systemctl is-enabled --quiet firewalld.service 2>/dev/null; then
    die '检测到 firewalld 正在运行或已设置开机启动。请先停用 firewalld，再安装本脚本'
  fi

  local save_cmd=''
  local saved_filter=''
  for save_cmd in iptables-save ip6tables-save; do
    command -v "$save_cmd" >/dev/null 2>&1 || continue
    saved_filter=$($save_cmd -t filter 2>/dev/null || true)
    if printf '%s\n' "$saved_filter" | grep -Eq '^:INPUT DROP|^-A INPUT '; then
      die "检测到 $save_cmd 管理的入站过滤规则。为防止冲突，本脚本没有修改系统"
    fi
  done

  ruleset=$(nft list ruleset) || die '无法读取当前 nftables 规则，拒绝继续'
  conflicts=$(printf '%s\n' "$ruleset" | awk '
    /^[[:space:]]*table[[:space:]]+/ {
      family = $2
      table_name = $3
    }
    /hook[[:space:]]+input/ {
      if (!(family == "inet" && table_name == "inbound_guard")) {
        print family " " table_name
      }
    }
  ' | sort -u)

  [ -z "$conflicts" ] || die "检测到其他入站防火墙链（$conflicts）。为防止规则冲突，本脚本没有修改系统"
}

APPLY_CHANGED=0
apply_rules() {
  local force=${1:-0}
  local staged_rule=''

  if [ "$force" -ne 1 ] && [ -r "$RULE_CONFIG" ] && \
      cmp -s "$RULE_FILE" "$RULE_CONFIG" && \
      nft list table inet inbound_guard >/dev/null 2>&1; then
    APPLY_CHANGED=0
    return 0
  fi

  staged_rule=$(mktemp "$INSTALL_DIR/.rules.XXXXXX")
  TEMP_FILES+=("$staged_rule")
  install -m 600 "$RULE_FILE" "$staged_rule"
  nft -f "$staged_rule" || die '应用规则失败，继续保留上一版运行规则'
  mv -f "$staged_rule" "$RULE_CONFIG"
  chmod 600 "$RULE_CONFIG"
  APPLY_CHANGED=1
}

write_port_cache() {
  local cache_file=''
  cache_file=$(mktemp)
  TEMP_FILES+=("$cache_file")
  printf '%s\n' "$LISTEN_PORTS" > "$cache_file"
  install -m 600 "$cache_file" "$INSTALLED_PORTS"
}

write_ssh_port_cache() {
  local cache_file=''
  cache_file=$(mktemp)
  TEMP_FILES+=("$cache_file")
  printf '%s\n' "$SSH_PORTS" > "$cache_file"
  install -m 600 "$cache_file" "$SSH_PORTS_FILE"
}

install_self() {
  local source_file=${BASH_SOURCE[0]:-}
  local downloaded_script=''

  if [ -n "$source_file" ] && [ -f "$source_file" ]; then
    install -m 755 "$source_file" "$INSTALLED_SCRIPT"
    return
  fi

  downloaded_script=$(mktemp)
  TEMP_FILES+=("$downloaded_script")
  printf '正在下载用于定时同步的脚本副本……\n'
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 30 \
    --max-filesize 262144 --output "$downloaded_script" "$SCRIPT_URL" || \
    die '脚本通过标准输入运行，但无法下载用于安装的脚本副本'
  bash -n "$downloaded_script" || die '下载的脚本副本语法校验失败'
  install -m 755 "$downloaded_script" "$INSTALLED_SCRIPT"
}

mkdir -p /var/backups "$INSTALL_DIR"
check_firewall_conflicts

if [ "$MODE" = sync ]; then
  apply_rules 0
  write_port_cache
  write_ssh_port_cache
  if [ "$APPLY_CHANGED" -eq 1 ]; then
    printf '已从远程源同步并应用 %s 个放行端口。\n' "$LISTEN_PORT_COUNT"
  else
    printf '远程端口没有变化，无需重新加载规则。\n'
  fi
  exit 0
fi

if [ "$MODE" = load ]; then
  apply_rules 1
  printf '已从本地缓存加载入站防火墙规则。\n'
  exit 0
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RULESET_BACKUP="/var/backups/nftables-before-inbound-guard-$TIMESTAMP.nft"
{
  printf 'flush ruleset\n'
  nft list ruleset
} > "$RULESET_BACKUP"

STATE_BACKUP=$(mktemp -d)
TEMP_DIRS+=("$STATE_BACKUP")
[ ! -e "$INSTALL_DIR" ] || cp -a "$INSTALL_DIR" "$STATE_BACKUP/install-dir"
[ ! -e "$INSTALLED_SCRIPT" ] || cp -a "$INSTALLED_SCRIPT" "$STATE_BACKUP/installed-script"
[ ! -e "$SERVICE_FILE" ] || cp -a "$SERVICE_FILE" "$STATE_BACKUP/sync.service"
[ ! -e "$TIMER_FILE" ] || cp -a "$TIMER_FILE" "$STATE_BACKUP/sync.timer"
[ ! -e "$LOAD_SERVICE_FILE" ] || cp -a "$LOAD_SERVICE_FILE" "$STATE_BACKUP/load.service"
LOAD_WAS_ENABLED=$(systemctl is-enabled inbound-firewall-load.service 2>/dev/null || true)
TIMER_WAS_ENABLED=$(systemctl is-enabled inbound-firewall-sync.timer 2>/dev/null || true)
INSTALL_ROLLBACK_ARMED=1

install_self
write_port_cache
write_ssh_port_cache

cat > "$LOAD_SERVICE_FILE" <<EOF
[Unit]
Description=从本地缓存加载入站 nftables 白名单
DefaultDependencies=no
After=local-fs.target nftables.service
Before=network-pre.target shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStart=$INSTALLED_SCRIPT --load
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=同步入站 nftables 端口白名单
After=inbound-firewall-load.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALLED_SCRIPT --sync
EOF

cat > "$TIMER_FILE" <<'EOF'
[Unit]
Description=每分钟同步入站防火墙端口白名单

[Timer]
OnActiveSec=1min
OnUnitInactiveSec=1min
AccuracySec=5s
Unit=inbound-firewall-sync.service

[Install]
WantedBy=timers.target
EOF

chmod 644 "$LOAD_SERVICE_FILE" "$SERVICE_FILE" "$TIMER_FILE"
systemctl daemon-reload
systemctl enable inbound-firewall-load.service >/dev/null || die '设置防火墙开机加载失败'
systemctl enable inbound-firewall-sync.timer >/dev/null || die '设置定时同步失败'
apply_rules 1
systemctl restart inbound-firewall-sync.timer >/dev/null || die '启动定时同步失败'
INSTALL_COMMITTED=1
INSTALL_ROLLBACK_ARMED=0

printf '防火墙和远程同步安装成功。\n'
printf '本地有效端口缓存：%s\n' "$INSTALLED_PORTS"
printf '本地 SSH 端口缓存：%s\n' "$SSH_PORTS_FILE"
printf '独立规则文件：%s\n' "$RULE_CONFIG"
printf '自动同步频率：每分钟一次\n'
printf 'SSH TCP 端口：%s\n' "$(printf '%s' "$SSH_PORTS" | paste -sd, -)"
printf '放行端口（TCP 和 UDP）：%s\n' "$(printf '%s' "$LISTEN_PORTS" | paste -sd, -)"
printf '原运行时规则备份：%s\n' "$RULESET_BACKUP"
printf '请保持当前 SSH 会话不要断开，并另开一个终端测试登录。\n'
