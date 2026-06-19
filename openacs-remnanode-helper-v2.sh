#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OpenACS Remnawave Node Helper
# Меню:
#   1) Установка Remnawave Node
#   2) Оптимизация системы
#   3) Self-Steal через Caddy
#   4) WARP через wg-quick
#   5) WARP watchdog
#   6) Показать готовый Xray outbound для WARP
#   7) Проверить WARP
#   0) Выход
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="/opt/remnanode"
CADDY_WEBROOT="/var/www/openacs"
WARP_CONF="/etc/wireguard/warp.conf"

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        echo -e "${RED}[Ошибка] Запусти скрипт от root: sudo bash $0${NC}"
        exit 1
    fi
}

pause() {
    echo
    read -n 1 -s -r -p "Нажми любую клавишу, чтобы вернуться в меню..."
    echo
}

banner() {
    clear
    echo -e "${BLUE}"
    echo "============================================================"
    echo "        OpenACS Remnawave Node Helper"
    echo "============================================================"
    echo -e "${NC}"
}

install_base_packages() {
    apt-get update
    apt-get install -y curl wget ca-certificates gnupg lsb-release apt-transport-https \
        nano git jq unzip tar zstd
}

install_node() {
    echo -e "${BLUE}=== Установка Remnawave Node ===${NC}"

    install_base_packages

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${BLUE}[Docker] Устанавливаем Docker...${NC}"
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    else
        echo -e "${GREEN}[Docker] Docker уже установлен.${NC}"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}[Ошибка] Docker Compose plugin не найден. Проверь установку Docker.${NC}"
        return 1
    fi

    local SECRET_KEY=""
    while [[ -z "${SECRET_KEY}" ]]; do
        read -rp "Введите SECRET_KEY из панели Remnawave: " SECRET_KEY
        if [[ -z "${SECRET_KEY}" ]]; then
            echo -e "${RED}SECRET_KEY обязателен.${NC}"
        fi
    done

    local DEFAULT_PORT="2222"
    local NODE_PORT=""
    read -rp "Введите NODE_PORT ноды [${DEFAULT_PORT}]: " NODE_PORT
    NODE_PORT="${NODE_PORT:-$DEFAULT_PORT}"

    mkdir -p "${INSTALL_DIR}"
    cd "${INSTALL_DIR}"

    if [ -f docker-compose.yml ]; then
        cp docker-compose.yml "docker-compose.yml.bak.$(date +%F-%H%M%S)"
        echo -e "${YELLOW}Старый docker-compose.yml сохранён в backup.${NC}"
    fi

    cat > docker-compose.yml <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY=${SECRET_KEY}
EOF

    echo -e "${BLUE}Запускаем Remnawave Node...${NC}"
    docker compose pull
    docker compose up -d

    echo -e "${GREEN}Готово. Нода запущена.${NC}"
    echo -e "${YELLOW}Проверь логи:${NC}"
    echo "cd ${INSTALL_DIR} && docker compose logs -f -t"
}

optimize_system() {
    echo -e "${BLUE}=== Оптимизация системы ===${NC}"

    install_base_packages

    echo -e "${BLUE}[1/6] Отключение IPv6...${NC}"
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    echo -e "${BLUE}[2/6] BBR и сетевые параметры...${NC}"
    modprobe tcp_bbr 2>/dev/null || true

    cat > /etc/modules-load.d/tcp_bbr.conf <<'EOF'
tcp_bbr
EOF

    cat > /etc/sysctl.d/99-openacs-network.conf <<'EOF'
# Network
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535

# TCP
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1

# IP
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_forward = 1

# Filesystem
fs.file-max = 2097152
EOF

    echo -e "${BLUE}[3/6] Лимиты дескрипторов...${NC}"
    cat > /etc/security/limits.d/99-openacs.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d

    cat > /etc/systemd/system.conf.d/99-openacs-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

    cat > /etc/systemd/user.conf.d/99-openacs-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

    echo -e "${BLUE}[4/6] Отключение ненужных сервисов...${NC}"
    systemctl disable --now multipathd.socket 2>/dev/null || true
    systemctl mask multipathd.service multipathd.socket 2>/dev/null || true

    for svc in snapd apport whoopsie multipathd ubuntu-advantage-tools ua-timer.service ModemManager avahi-daemon bluetooth cups; do
        systemctl disable --now "$svc" 2>/dev/null || true
    done

    echo -e "${BLUE}[5/6] Применение sysctl...${NC}"
    sysctl --system

    echo -e "${BLUE}[6/6] Перезапуск systemd manager...${NC}"
    systemctl daemon-reexec

    echo -e "${GREEN}Оптимизация применена.${NC}"
    echo -e "${YELLOW}Текущий congestion control:${NC}"
    sysctl net.ipv4.tcp_congestion_control || true
}

install_caddy_repo() {
    if command -v caddy >/dev/null 2>&1; then
        echo -e "${GREEN}[Caddy] Уже установлен.${NC}"
        return
    fi

    install_base_packages

    echo -e "${BLUE}[Caddy] Установка официального репозитория...${NC}"

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list

    apt-get update
    apt-get install -y caddy
}

setup_selfsteal_caddy() {
    echo -e "${BLUE}=== Self-Steal через Caddy ===${NC}"

    local NODE_DOMAIN=""
    while [[ -z "${NODE_DOMAIN}" ]]; do
        read -rp "Введите домен ноды, например it-node.openacs.space: " NODE_DOMAIN
        if [[ -z "${NODE_DOMAIN}" ]]; then
            echo -e "${RED}Домен обязателен.${NC}"
        fi
    done

    install_caddy_repo

    mkdir -p "${CADDY_WEBROOT}"

    cat > "${CADDY_WEBROOT}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>OpenACS</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background: #050816;
      color: #ffffff;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    .card {
      max-width: 640px;
      padding: 40px;
      border-radius: 24px;
      background: rgba(255,255,255,.06);
      box-shadow: 0 0 60px rgba(88, 166, 255, .18);
      text-align: center;
    }
    h1 { margin: 0 0 12px; font-size: 44px; }
    p { opacity: .78; font-size: 18px; }
  </style>
</head>
<body>
  <div class="card">
    <h1>OpenACS</h1>
    <p>Your internet. Your rules.</p>
  </div>
</body>
</html>
EOF

    chown -R caddy:caddy "${CADDY_WEBROOT}"

    if [ -f /etc/caddy/Caddyfile ]; then
        cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%F-%H%M%S)"
    fi

    cat > /etc/caddy/Caddyfile <<EOF
https://${NODE_DOMAIN}:8443 {
    bind 127.0.0.1

    root * ${CADDY_WEBROOT}
    file_server
}
EOF

    caddy fmt --overwrite /etc/caddy/Caddyfile

    systemctl enable --now caddy
    systemctl reload caddy

    echo -e "${GREEN}Caddy Self-Steal настроен.${NC}"
    echo
    echo -e "${YELLOW}В RemnaWave/Xray inbound используй:${NC}"
    echo "\"target\": \"127.0.0.1:8443\""
    echo "\"serverNames\": [\"${NODE_DOMAIN}\"]"
    echo "\"xhttpSettings.host\": \"${NODE_DOMAIN}\""
    echo
    echo -e "${YELLOW}Проверка локально:${NC}"
    echo "curl -kI --resolve ${NODE_DOMAIN}:8443:127.0.0.1 https://${NODE_DOMAIN}:8443"
}

install_wgcf() {
    if command -v wgcf >/dev/null 2>&1; then
        echo -e "${GREEN}[wgcf] Уже установлен.${NC}"
        return
    fi

    echo -e "${BLUE}[wgcf] Скачиваем актуальный бинарник...${NC}"
    local api_url="https://api.github.com/repos/ViRb3/wgcf/releases/latest"
    local download_url=""

    download_url="$(curl -fsSL "${api_url}" | jq -r '.assets[] | select(.name | test("linux_amd64$")) | .browser_download_url' | head -n1)"

    if [[ -z "${download_url}" || "${download_url}" == "null" ]]; then
        echo -e "${RED}Не удалось найти wgcf linux_amd64 asset.${NC}"
        echo "Скачай wgcf вручную и положи в /usr/local/bin/wgcf"
        return 1
    fi

    wget -O /usr/local/bin/wgcf "${download_url}"
    chmod +x /usr/local/bin/wgcf
}

setup_warp_wgquick() {
    echo -e "${BLUE}=== WARP через wg-quick ===${NC}"

    install_base_packages
    apt-get install -y wireguard resolvconf

    install_wgcf

    cd /root

    if [ ! -f /root/wgcf-profile.conf ]; then
        echo -e "${YELLOW}WARP профиль не найден. Регистрируем новый wgcf аккаунт...${NC}"
        wgcf register
        wgcf generate
    else
        echo -e "${GREEN}Найден существующий /root/wgcf-profile.conf.${NC}"
        read -rp "Использовать его? [Y/n]: " use_existing
        use_existing="${use_existing:-Y}"
        if [[ ! "${use_existing}" =~ ^[YyДд]$ ]]; then
            mv /root/wgcf-account.toml "/root/wgcf-account.toml.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
            mv /root/wgcf-profile.conf "/root/wgcf-profile.conf.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
            wgcf register
            wgcf generate
        fi
    fi

    if [ ! -f /root/wgcf-profile.conf ]; then
        echo -e "${RED}wgcf-profile.conf не создан.${NC}"
        return 1
    fi

    mkdir -p /etc/wireguard
    cp /root/wgcf-profile.conf "${WARP_CONF}"
    chmod 600 "${WARP_CONF}"

    # IPv4-only, потому что в оптимизации мы отключаем IPv6.
    sed -i '/^Address =/ s/, *2606:[^ ]*\/128//g' "${WARP_CONF}"
    sed -i '/^Address =/ s/2606:[^, ]*\/128, *//g' "${WARP_CONF}"
    sed -i '/^DNS =/ s/, *2606:[^, ]*//g' "${WARP_CONF}"
    sed -i '/^AllowedIPs =/c\AllowedIPs = 0.0.0.0/0' "${WARP_CONF}"

    # Table=off нужен, чтобы wg-quick не уводил default route сервера в WARP.
    if ! grep -q '^Table = off' "${WARP_CONF}"; then
        if grep -q '^MTU =' "${WARP_CONF}"; then
            sed -i '/^MTU =/a Table = off' "${WARP_CONF}"
        else
            sed -i '/^\[Interface\]/a Table = off' "${WARP_CONF}"
        fi
    fi

    # Endpoint лучше фиксировать IP.
    sed -i 's#^Endpoint = .*#Endpoint = 162.159.192.1:2408#g' "${WARP_CONF}"

    # Keepalive нужен, чтобы WARP не "засыпал" через 15-30 минут простоя/NAT.
    if ! grep -q '^PersistentKeepalive =' "${WARP_CONF}"; then
        sed -i '/^Endpoint =/a PersistentKeepalive = 25' "${WARP_CONF}"
    else
        sed -i 's/^PersistentKeepalive = .*/PersistentKeepalive = 15/g' "${WARP_CONF}"
    fi

    wg-quick down warp 2>/dev/null || true
    wg-quick up warp

    systemctl enable wg-quick@warp

    # Watchdog автоматически перезапустит WARP, если trace через warp перестал возвращать warp=on.
    install_warp_watchdog

    echo -e "${GREEN}WARP поднят через wg-quick.${NC}"
    wg show
    echo
    echo -e "${YELLOW}Проверка:${NC}"
    echo "curl --interface warp -4 https://www.cloudflare.com/cdn-cgi/trace"
    echo
    echo -e "${YELLOW}В RemnaWave/Xray используй outbound из пункта меню 6.${NC}"
}

install_warp_watchdog() {
    echo -e "${BLUE}=== Установка WARP watchdog ===${NC}"

    cat > /usr/local/bin/warp-watchdog.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

IFACE="warp"
TEST_URL="https://www.cloudflare.com/cdn-cgi/trace"

if ! ip link show "$IFACE" >/dev/null 2>&1; then
    systemctl restart wg-quick@warp
    exit 0
fi

if ! curl --interface "$IFACE" -4 --max-time 8 -fsS "$TEST_URL" | grep -q "warp=on"; then
    systemctl restart wg-quick@warp
fi
EOF

    chmod +x /usr/local/bin/warp-watchdog.sh

    cat > /etc/systemd/system/warp-watchdog.service <<'EOF'
[Unit]
Description=WARP Watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-watchdog.sh
EOF

    cat > /etc/systemd/system/warp-watchdog.timer <<'EOF'
[Unit]
Description=Run WARP Watchdog every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Unit=warp-watchdog.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now warp-watchdog.timer

    echo -e "${GREEN}WARP watchdog установлен и включён.${NC}"
    systemctl list-timers | grep warp || true
}

check_warp_status() {
    echo -e "${BLUE}=== Проверка WARP ===${NC}"
    echo
    echo -e "${YELLOW}[wg show]${NC}"
    wg show || true
    echo
    echo -e "${YELLOW}[Cloudflare trace через интерфейс warp]${NC}"
    curl --interface warp -4 --max-time 10 https://www.cloudflare.com/cdn-cgi/trace || true
    echo
}

show_warp_outbound() {
    cat <<'EOF'

Добавь в server outbounds RemnaWave/Xray:

{
  "tag": "WARP",
  "protocol": "freedom",
  "settings": {
    "domainStrategy": "ForceIPv4"
  },
  "streamSettings": {
    "sockopt": {
      "interface": "warp"
    }
  }
}

Пример routing:

{
  "type": "field",
  "domain": [
    "geosite:youtube",
    "domain:youtube.com",
    "domain:googlevideo.com",
    "domain:ytimg.com",
    "domain:youtu.be"
  ],
  "outboundTag": "DIRECT"
},
{
  "type": "field",
  "domain": [
    "regexp:.*\\.ru$",
    "regexp:.*\\.xn--p1ai$",
    "domain:vk.com"
  ],
  "outboundTag": "DIRECT"
},
{
  "type": "field",
  "network": "tcp,udp",
  "outboundTag": "WARP"
}

Проверка:
  wg show
  curl --interface warp -4 https://www.cloudflare.com/cdn-cgi/trace

EOF
}

main_menu() {
    require_root

    while true; do
        banner
        echo -e "${GREEN}Выбери действие:${NC}"
        echo "1) Установить Remnawave Node"
        echo "2) Оптимизация системы: IPv6 off, BBR, sysctl, лимиты, сервисы"
        echo "3) Настроить Self-Steal через Caddy"
        echo "4) Установить и поднять WARP через wg-quick"
        echo "5) Установить/переустановить WARP watchdog"
        echo "6) Показать Xray outbound/routing для WARP"
        echo "7) Проверить WARP"
        echo "0) Выход"
        echo
        read -rp "Ваш выбор: " choice

        case "${choice}" in
            1) install_node; pause ;;
            2) optimize_system; pause ;;
            3) setup_selfsteal_caddy; pause ;;
            4) setup_warp_wgquick; pause ;;
            5) install_warp_watchdog; pause ;;
            6) show_warp_outbound; pause ;;
            7) check_warp_status; pause ;;
            0) echo -e "${YELLOW}Выход.${NC}"; exit 0 ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

main_menu
