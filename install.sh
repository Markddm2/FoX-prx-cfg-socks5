#!/bin/bash
# set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="/home/3proxy"
CONFIG_FILE="/home/3proxy/3proxy.cfg"
SERVICE_FILE="/etc/systemd/system/3proxy.service"
PROXY_LIST_FILE="/tmp/proxy_list.txt"
BACKUP_DIR="/home/3proxy/backup"

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ОШИБКА]${NC} $1" >&2; }
warning() { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"; }
info() { echo -e "${BLUE:-}[ИНФО]${NC:-} $1"; }

random_string() { tr -dc A-Za-z0-9 </dev/urandom 2>/dev/null | head -c12; }

show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((current * width / total))
    local remaining=$((width - completed))

    printf "\r[%s%s] %d%% (%d/%d)" \
        "$(printf "%*s" $completed | tr ' ' '=')" \
        "$(printf "%*s" $remaining)" \
        $percentage $current $total
}

gen_ipv6() {
    local hex_chars=$(tr -dc '0-9a-f' < /dev/urandom 2>/dev/null | head -c 16)
    local block1="${hex_chars:0:4}"
    local block2="${hex_chars:4:4}"
    local block3="${hex_chars:8:4}"
    local block4="${hex_chars:12:4}"
    echo "$1:$block1:$block2:$block3:$block4"
}

check_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        error "Запустите от имени root (используйте sudo)"
        exit 1
    fi
}

check_system() {
    if [[ ! -f /etc/os-release ]]; then
        error "Файл /etc/os-release не найден"
        exit 1
    fi
    if ! grep -qi "ubuntu" /etc/os-release; then
        error "Поддерживается только Ubuntu. Обнаружена ОС: $(grep '^NAME=' /etc/os-release 2>/dev/null || echo 'Неизвестная')"
        exit 1
    fi

    for cmd in lsb_release df awk ping ip ss curl wget tar make; do
        command -v "$cmd" >/dev/null 2>&1 || { error "Команда $cmd не найдена"; exit 1; }
    done

    local version=$(lsb_release -rs | cut -d. -f1 2>/dev/null || echo "0")
    [[ $version -lt 20 ]] && { error "Требуется Ubuntu 20.04+"; exit 1; }

    [[ ! -f /proc/net/if_inet6 ]] && { error "IPv6 не поддерживается"; exit 1; }

    local free_space=$(df / | awk 'NR==2 {print $4}')
    [[ $free_space -lt 1048576 ]] && { error "Недостаточно места на диске (нужно >1GB)"; exit 1; }

    timeout 5 ping -c 1 8.8.8.8 >/dev/null 2>&1 || { error "Нет интернет-соединения"; exit 1; }
}

validate_ipv6_subnet() {
    local subnet="$1"
    [[ ! "$subnet" =~ ^[0-9a-fA-F:]+/[0-9]+$ ]] && return 1
    local prefix_len="${subnet##*/}"
    [[ $prefix_len -lt 48 || $prefix_len -gt 128 ]] && return 1
    return 0
}

validate_ipv4() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        error "Неверный формат IPv4 адреса: $ip"
        return 1
    fi
    local IFS='.'
    local -a octets
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if ! [[ "$octet" =~ ^[0-9]+$ ]] || [[ "$octet" -gt 255 ]] || [[ "$octet" -lt 0 ]]; then
            error "Недействительный октет в IPv4 адресе: '$octet' в '$ip'"
            return 1
        fi
    done

    if timeout 3 ping -c 1 "$ip" >/dev/null 2>&1; then
        :
    fi
    return 0
}

validate_port() {
    local port="$1"
    [[ ! "$port" =~ ^[0-9]+$ ]] && return 1
    [[ $port -lt 1024 || $port -gt 65535 ]] && return 1
    ss -tuln | grep -q ":$port " && return 1
    return 0
}

check_port_range() {
    local start_port="$1"
    local count="$2"
    local max_port=$((start_port + count * 2 - 1))
    [[ $max_port -gt 65535 ]] && return 1
    local listening_ports=$(ss -tuln | awk '{print $4}' | grep -o ':[0-9]*$' | cut -d: -f2 | sort -n)
    for ((i=0; i<count; i++)); do
        local socks_port=$((start_port + i))
        local http_port=$((start_port + count + i))
        if echo "$listening_ports" | grep -q "^$socks_port$" || echo "$listening_ports" | grep -q "^$http_port$"; then
            return 1
        fi
    done
    return 0
}

get_user_input() {
    log "Начинаем настройку..."

    echo ""
    log "Выберите целевую операционную систему (сетевой отпечаток TCP/IP & TTL):"
    echo -e "  ${YELLOW}1)${NC} Windows          (TTL / Hop Limit = 128) [Рекомендуется для профилей Windows]"
    echo -e "  ${YELLOW}2)${NC} macOS            (TTL / Hop Limit = 64, стек Darwin) [Для профилей Mac / Safari]"
    echo -e "  ${YELLOW}3)${NC} Linux / Android  (TTL / Hop Limit = 64, нативный стек Linux) [Для моб. ферм / Linux]"
    while true; do
        read -p "Ваш выбор [1-3] (по умолчанию 1): " OS_OPT
        OS_OPT=${OS_OPT:-1}
        case "$OS_OPT" in
            1)
                TARGET_OS_NAME="Windows"
                TARGET_TTL=128
                TARGET_TCP_TS=0
                break
                ;;
            2)
                TARGET_OS_NAME="macOS"
                TARGET_TTL=64
                TARGET_TCP_TS=1
                break
                ;;
            3)
                TARGET_OS_NAME="Linux / Android"
                TARGET_TTL=64
                TARGET_TCP_TS=1
                break
                ;;
            *)
                error "Пожалуйста, введите 1, 2 или 3"
                ;;
        esac
    done
    log "Выбран сетевой отпечаток: ${GREEN}$TARGET_OS_NAME${NC} (TTL/Hop Limit = $TARGET_TTL)"
    echo ""

    while true; do
        echo -n "IPv6 подсеть (например, 2001:db8::/64): "
        read IPV6_SUBNET
        if validate_ipv6_subnet "$IPV6_SUBNET"; then
            break
        else
            error "Неверный формат IPv6 подсети"
        fi
    done

    while true; do
        echo -n "Внешний IPv4 адрес сервера: "
        read EXTERNAL_IPV4
        if validate_ipv4 "$EXTERNAL_IPV4"; then
            break
        else
            error "Неверный IPv4 адрес или адрес недоступен"
        fi
    done

    while true; do
        echo -n "Количество прокси (1-5000): "
        read PROXY_COUNT
        if [[ "$PROXY_COUNT" =~ ^[0-9]+$ ]] && [[ $PROXY_COUNT -ge 1 && $PROXY_COUNT -le 5000 ]]; then
            break
        else
            error "Введите число от 1 до 5000"
        fi
    done

    while true; do
        echo -n "Начальный порт для прокси (10000-40000): "
        read START_PORT
        local max_port=$((START_PORT + PROXY_COUNT - 1))
        if validate_port "$START_PORT" && [[ $START_PORT -ge 10000 && $START_PORT -le 40000 ]]; then
            if [[ $max_port -le 65535 ]]; then
                break
            else
                error "Недостаточно портов. Максимальный порт будет: $max_port"
            fi
        else
            error "Неверный порт или порт занят"
        fi
    done

    log "Настройка завершена"
}

create_backup() {
    if [[ -f "$CONFIG_FILE" ]]; then
        mkdir -p "$BACKUP_DIR" || return 1
        local backup_filename="3proxy.cfg.$(date +%Y%m%d_%H%M%S)"
        local backup_path="$BACKUP_DIR/$backup_filename"
        cp "$CONFIG_FILE" "$backup_path" || return 1
    fi
    return 0
}

install_dependencies() {
    log "Проверка и установка зависимостей... (≈ 1 минута)"
    export DEBIAN_FRONTEND=noninteractive

    if ! apt-get update -qq >/dev/null 2>&1; then
        error "Не удалось обновить список пакетов"
        exit 1
    fi

    local critical_packages="make build-essential wget curl"
    if ! apt-get install -y $critical_packages >/dev/null 2>&1; then
        error "Не удалось установить критически важные пакеты: $critical_packages"
        exit 1
    fi

    local packages="git net-tools iproute2 iptables ufw systemd openssl pwgen jq libarchive-tools lsb-release ca-certificates"
    local missing_packages=()
    for pkg in $packages; do
        if ! dpkg -l "$pkg" >/dev/null 2>&1; then
            missing_packages+=("$pkg")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log "Все дополнительные зависимости уже установлены"
    else
        if ! apt-get install -y "${missing_packages[@]}" >/dev/null 2>&1; then
            error "Не удалось установить зависимости: ${missing_packages[*]}"
            error "Попробуйте выполнить вручную: apt-get install -y ${missing_packages[*]}"
            exit 1
        fi
    fi
}

install_3proxy() {
    log "Установка 3proxy... (≈ 1 минута)"
    if ! mkdir -p "$SCRIPT_DIR" "$BACKUP_DIR"; then
        error "Не удалось создать директории"
        exit 1
    fi
    cd /tmp || { error "Не удалось перейти в /tmp"; exit 1; }
    rm -rf 3proxy-* 3proxy.*.tar.gz 2>/dev/null || true

    local specific_version_url="https://github.com/3proxy/3proxy/archive/refs/tags/0.9.5.tar.gz"
    if ! timeout 60 wget -qO "3proxy-0.9.5.tar.gz" "$specific_version_url" >/dev/null 2>&1; then
        error "Не удалось скачать 3proxy v0.9.5 с $specific_version_url"
        exit 1
    fi

    if ! tar -xzf "3proxy-0.9.5.tar.gz" >/dev/null 2>&1; then
        error "Не удалось распаковать 3proxy-0.9.5.tar.gz"
        exit 1
    fi

    local proxy_dir="3proxy-0.9.5"
    if [[ ! -d "$proxy_dir" ]]; then
        proxy_dir=$(find . -maxdepth 1 -type d -name "3proxy-*" | head -1)
        [[ -z "$proxy_dir" || ! -d "$proxy_dir" ]] && { error "Директория 3proxy не найдена после распаковки"; exit 1; }
    fi
    cd "$proxy_dir" || { error "Не удалось перейти в директорию $proxy_dir"; exit 1; }
    make -f Makefile.Linux >/dev/null 2>&1 || { error "Не удалось скомпилировать 3proxy"; exit 1; }
    [[ ! -f "bin/3proxy" ]] && { error "Бинарный файл 3proxy не был создан"; exit 1; }
    cp bin/3proxy "$SCRIPT_DIR/" || { error "Не удалось скопировать бинарный файл"; exit 1; }
    chmod 755 "$SCRIPT_DIR/3proxy"
    chown root:root "$SCRIPT_DIR/3proxy"
}

optimize_system() {
    log "Оптимизация системы... (≈ 1 минута)"

    if ! grep -q "3proxy limits" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf << 'EOF'

# 3proxy limits
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nproc 1048576
root hard nproc 1048576
EOF
    fi

    SYSTEMD_CONF="/etc/systemd/system.conf"
    if ! grep -q "DefaultLimitNOFILE" "$SYSTEMD_CONF" 2>/dev/null; then
        echo "" >> "$SYSTEMD_CONF"
        echo "# 3proxy limits" >> "$SYSTEMD_CONF"
        echo "DefaultLimitDATA=infinity" >> "$SYSTEMD_CONF"
        echo "DefaultLimitSTACK=infinity" >> "$SYSTEMD_CONF"
        echo "DefaultLimitCORE=infinity" >> "$SYSTEMD_CONF"
        echo "DefaultLimitRSS=infinity" >> "$SYSTEMD_CONF"
        echo "DefaultLimitNOFILE=1048576" >> "$SYSTEMD_CONF"
        echo "DefaultLimitAS=infinity" >> "$SYSTEMD_CONF"
        echo "DefaultLimitNPROC=1048576" >> "$SYSTEMD_CONF"
        echo "DefaultLimitMEMLOCK=infinity" >> "$SYSTEMD_CONF"
    fi

    cat > /etc/sysctl.d/99-3proxy.conf << EOF
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 65536 268435456
net.ipv4.tcp_wmem = 4096 65536 268435456
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 60000
net.ipv4.tcp_max_tw_buckets = 4000000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_default_ttl = $TARGET_TTL
net.ipv6.conf.all.hop_limit = $TARGET_TTL
net.ipv6.conf.default.hop_limit = $TARGET_TTL
net.ipv4.tcp_timestamps = $TARGET_TCP_TS
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.route.flush = 1
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.conf.default.log_martians = 0
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv6.icmp.echo_ignore_all = 1
net.ipv6.conf.all.proxy_ndp = 1
net.ipv6.conf.default.proxy_ndp = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.ip_nonlocal_bind = 1
vm.swappiness = 5
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
vm.max_map_count = 1048576
fs.file-max = 4000000
kernel.pid_max = 1048576
EOF

        if ! sysctl -p /etc/sysctl.d/99-3proxy.conf >/dev/null 2>&1; then
        warning "Некоторые параметры ядра не применились"
    fi
    sysctl -w net.ipv4.ip_default_ttl="$TARGET_TTL" >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.hop_limit="$TARGET_TTL" >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.hop_limit="$TARGET_TTL" >/dev/null 2>&1 || true

    systemctl disable --now snapd bluetooth cups avahi-daemon >/dev/null 2>&1 || true
}

detect_network_interface() {
    NETWORK_INTERFACE=$(ip route | grep default | head -1 | awk '{print $5}' 2>/dev/null)
    [[ -z "$NETWORK_INTERFACE" ]] && NETWORK_INTERFACE=$(ip link show | grep -E "^[0-9]+: (eth|ens|enp|venet)" | head -1 | cut -d: -f2 | tr -d ' ')
    [[ -z "$NETWORK_INTERFACE" ]] && { error "Не удалось определить сетевой интерфейс"; exit 1; }

    if ! ip link show "$NETWORK_INTERFACE" >/dev/null 2>&1; then
        error "Сетевой интерфейс $NETWORK_INTERFACE не найден"
        exit 1
    fi

    log "Сетевой интерфейс: $NETWORK_INTERFACE"
}

configure_ipv6() {
    local ipv6_base="${IPV6_SUBNET%/*}"
    local prefix_len="${IPV6_SUBNET##*/}"
    ipv6_base="${ipv6_base%::}"

    if [[ -z "$NETWORK_INTERFACE" || -z "$IPV6_SUBNET" || -z "$ipv6_base" || -z "$prefix_len" ]]; then
        error "Одна из ключевых переменных пуста: NETWORK_INTERFACE=$NETWORK_INTERFACE, IPV6_SUBNET=$IPV6_SUBNET, ipv6_base=$ipv6_base, prefix_len=$prefix_len"
        exit 1
    fi

    IPV6_ADDRESSES=()
    local success=0
    local failed=0

    for ((i=0; i<PROXY_COUNT; i++)); do
        local ipv6_addr
        local cmd_output
        local last_error=""
        ipv6_addr=$(gen_ipv6 "$ipv6_base")
        if cmd_output=$(ip -6 addr add "${ipv6_addr}/${prefix_len}" dev "$NETWORK_INTERFACE" 2>&1 >/dev/null); then
            IPV6_ADDRESSES+=("$ipv6_addr")
            success=$((success+1))
        else
            last_error="$cmd_output"
            failed=$((failed+1))
            warning "Ошибка добавления IPv6 адреса $ipv6_addr: $cmd_output"
        fi
        if [ "$PROXY_COUNT" -gt 100 ]; then show_progress "$success" "$PROXY_COUNT"; fi
    done

    [[ "$PROXY_COUNT" -gt 100 ]] && echo ""

    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || warning "Не удалось включить IPv6 forwarding"

    log "IPv6 настроен: $success из $PROXY_COUNT адресов (неудачно: $failed)"

    if [[ $success -eq 0 ]]; then
        error "Не удалось настроить ни одного IPv6 адреса"
        exit 1
    fi

    local success_rate=$((success * 100 / PROXY_COUNT))
    if [[ $success_rate -lt 80 ]]; then
        warning "Низкий процент успешных IPv6 адресов: $success_rate%"
    fi
}

generate_auth() {
    log "Генерация аутентификации..."
    PROXY_CREDENTIALS=()

    for ((i=0; i<PROXY_COUNT; i++)); do
        local user="user$(printf "%04d" $i)"
        local pass=$(random_string)
        PROXY_CREDENTIALS+=("$user:$pass")
    done
}

generate_3proxy_config() {
    log "Генерация конфигурации..."
    create_backup
    mkdir -p "$(dirname "$CONFIG_FILE")" || { error "Не удалось создать директорию для конфигурации"; exit 1; }

    cat > "$CONFIG_FILE" << 'EOF'
timeouts 1 5 30 60 180 1800 15 60
flush
log /var/log/3proxy.log D
logformat "- +_L%t.%. %N.%p %E"
rotate 1
maxconn 5000
stacksize 65536
nserver 8.8.8.8
nserver 1.1.1.1
nscache 65536
nscache6 65535

auth strong
EOF

    local users_line="users "
    for cred in "${PROXY_CREDENTIALS[@]}"; do
        local user="${cred%:*}"
        local pass="${cred#*:}"
        users_line+="$user:CL:$pass "
    done
    echo "$users_line" >> "$CONFIG_FILE"
    echo "" >> "$CONFIG_FILE"

    for cred in "${PROXY_CREDENTIALS[@]}"; do
        local user="${cred%:*}"
        echo "allow $user" >> "$CONFIG_FILE"
    done
    echo "" >> "$CONFIG_FILE"

    for ((i=0; i<PROXY_COUNT; i++)); do
        local ipv6_addr="${IPV6_ADDRESSES[$i]:-}"
        [[ -z "$ipv6_addr" || -z "$EXTERNAL_IPV4" ]] && continue
        local auto_port=$((START_PORT + i))
        echo "socks -p$auto_port -n -a -s0 -64 -i$EXTERNAL_IPV4 -e$ipv6_addr" >> "$CONFIG_FILE"
    done
}

configure_firewall() {
    log "Настройка firewall и сетевого стека ($TARGET_OS_NAME)..."

    # Применяем правила mangle для TTL / Hop Limit
    if command -v iptables >/dev/null 2>&1; then
        iptables -t mangle -F || true
        iptables -t mangle -A POSTROUTING -j TTL --ttl-set "$TARGET_TTL" || true
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t mangle -F || true
        ip6tables -t mangle -A POSTROUTING -j HL --hl-set "$TARGET_TTL" || true
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw --force reset >/dev/null 2>&1 || true
        ufw default deny incoming >/dev/null 2>&1 || true
        ufw default allow outgoing >/dev/null 2>&1 || true
        ufw allow ssh >/dev/null 2>&1 || true

        local ports=""
        for ((i=0; i<PROXY_COUNT; i++)); do
            ports+="$((START_PORT + i)),"
        done

        ports="${ports%,}"
        if [ -n "$ports" ]; then
            ufw allow $ports/tcp >/dev/null 2>&1 || true
        fi

        ufw --force enable >/dev/null 2>&1 || true

    elif command -v iptables >/dev/null 2>&1; then
        iptables -F || true
        iptables -X || true
        iptables -t nat -F || true
        iptables -t nat -X || true
        iptables -P INPUT DROP || true
        iptables -P FORWARD ACCEPT || true
        iptables -P OUTPUT ACCEPT || true
        iptables -A INPUT -i lo -j ACCEPT || true
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT || true
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT || true

        local ipt_ports=""
        for ((i=0; i<PROXY_COUNT; i++)); do
            ipt_ports+="$((START_PORT + i)) "
        done
        for port in $ipt_ports; do
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT || true
        done

        mkdir -p /etc/iptables 2>/dev/null || true
        iptables-save > /etc/iptables/rules.v4 || true

        if command -v ip6tables >/dev/null 2>&1; then
            ip6tables -F || true
            ip6tables -X || true
            ip6tables -P INPUT DROP || true
            ip6tables -P FORWARD ACCEPT || true
            ip6tables -P OUTPUT ACCEPT || true
            ip6tables -A INPUT -i lo -j ACCEPT || true
            ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT || true
            ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT || true
            ip6tables-save > /etc/iptables/rules.v6 || true
        fi
    fi
}

create_systemd_service() {
    log "Создание сервиса и скрипта авто-привязки IP..."

    cat > "/home/3proxy/bind_ips.sh" << 'EOF'
#!/bin/bash
CONFIG_FILE="/home/3proxy/3proxy.cfg"
IFACE=$(ip route | grep default | head -1 | awk '{print $5}' 2>/dev/null)
[[ -z "$IFACE" ]] && IFACE=$(ip link show | grep -E "^[0-9]+: (eth|ens|enp|venet)" | head -1 | cut -d: -f2 | tr -d ' ')

if [[ -f "$CONFIG_FILE" && -n "$IFACE" ]]; then
    awk -F"-e" '{print $2}' "$CONFIG_FILE" | awk '{print $1}' | grep ":" | while read -r ip; do
        ip -6 addr add "$ip/64" dev "$IFACE" 2>/dev/null || true
    done
fi
EOF
    cat >> "/home/3proxy/bind_ips.sh" << EOF

# Поддержание сетевого отпечатка Hop Limit при авто-привязке
sysctl -w net.ipv6.conf.all.hop_limit=$TARGET_TTL >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_default_ttl=$TARGET_TTL >/dev/null 2>&1 || true
ip6tables -t mangle -C POSTROUTING -s "$IPV6_SUBNET" -j HL --hl-set $TARGET_TTL 2>/dev/null || ip6tables -t mangle -A POSTROUTING -s "$IPV6_SUBNET" -j HL --hl-set $TARGET_TTL 2>/dev/null || true
iptables -t mangle -C POSTROUTING -j TTL --ttl-set $TARGET_TTL 2>/dev/null || iptables -t mangle -A POSTROUTING -j TTL --ttl-set $TARGET_TTL 2>/dev/null || true
exit 0
EOF
    chmod +x /home/3proxy/bind_ips.sh

    cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=3proxy прокси сервер
After=network.target network-online.target
Wants=network.target network-online.target

[Service]
Type=simple
ExecStartPre=-/bin/bash /home/3proxy/bind_ips.sh
ExecStart=/home/3proxy/3proxy /home/3proxy/3proxy.cfg
WorkingDirectory=/home/3proxy
Restart=always
RestartSec=5
User=root
Group=root
LimitNOFILE=1048576
LimitNPROC=1048576

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/cron.d/3proxy_bind << 'EOF'
*/5 * * * * root /bin/bash /home/3proxy/bind_ips.sh >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/3proxy_bind

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable 3proxy >/dev/null 2>&1
}

generate_proxy_list() {
    log "Генерация списка прокси..."

    PROXY_LIST_FILE="/tmp/${EXTERNAL_IPV4}.txt"
    local proxy_backup_file="/home/3proxy/${EXTERNAL_IPV4}.txt"

    > "$PROXY_LIST_FILE"

    for ((i=0; i<PROXY_COUNT; i++)); do
        local cred="${PROXY_CREDENTIALS[$i]}"
        local user="${cred%:*}"
        local pass="${cred#*:}"
        local ipv6_addr="${IPV6_ADDRESSES[$i]:-}"
        [[ -n "$ipv6_addr" ]] && {
            local auto_port=$((START_PORT + i))
            echo "$user:$pass@$EXTERNAL_IPV4:$auto_port" >> "$PROXY_LIST_FILE"
        }
    done

    # Сохраняем копию в /home/3proxy и симлинк в /tmp/proxy_list.txt для совместимости
    cp -f "$PROXY_LIST_FILE" "$proxy_backup_file" 2>/dev/null || true
    cp -f "$PROXY_LIST_FILE" "/tmp/proxy_list.txt" 2>/dev/null || true

    local proxy_lines=$(grep -c ":" "$PROXY_LIST_FILE" 2>/dev/null || wc -l < "$PROXY_LIST_FILE")
    log "✅ Список прокси сохранен на сервере: $PROXY_LIST_FILE (и в $proxy_backup_file)"
}

start_3proxy() {
    log "Запуск 3Proxy..."
    systemctl stop 3proxy 2>/dev/null || true
    sleep 1
    systemctl start 3proxy >/dev/null 2>&1 || { error "Не удалось запустить сервис 3proxy"; exit 1; }
    sleep 3

    if systemctl is-active --quiet 3proxy; then

        local check_count=$((PROXY_COUNT < 5 ? PROXY_COUNT : 5))
        local listening_ports=$(ss -tuln 2>/dev/null | grep "$EXTERNAL_IPV4:" | wc -l)

        if [[ $listening_ports -gt 0 ]]; then
            log "Прокси слушают на портах (активно $listening_ports портов)"
        else
            warning "Сервис запущен, но порты не прослушиваются"
            warning "Проверьте логи: journalctl -u 3proxy -n 20"
        fi
    else
        error "Сервис 3proxy не активен после запуска"
        log "Статус сервиса:"
        systemctl status 3proxy --no-pager 2>/dev/null
        log "Логи сервиса:"
        journalctl -u 3proxy -n 20 --no-pager 2>/dev/null
        log "Логи 3proxy:"
        tail -20 /var/log/3proxy.log 2>/dev/null || log "Лог файл не найден"
        exit 1
    fi
}

test_proxy_functionality() {
    if [[ ${#IPV6_ADDRESSES[@]} -gt 0 && ${#PROXY_CREDENTIALS[@]} -gt 0 ]]; then
        local test_port=$START_PORT
        local test_cred="${PROXY_CREDENTIALS[0]}"
        local test_user="${test_cred%:*}"
        local test_pass="${test_cred#*:}"

        if timeout 10 curl -s --socks5 "$test_user:$test_pass@$EXTERNAL_IPV4:$test_port" \
           --max-time 5 http://httpbin.org/ip >/dev/null 2>&1; then
            log "✅ Прокси работает корректно"
        else
            warning "⚠️ Прокси может работать некорректно. Проверьте логи: journalctl -u 3proxy -n 20"
        fi
    fi
}

show_statistics() {
    log "=========================================="
    log "🎉 УСТАНОВКА IPv6 PROXY ЗАВЕРШЕНА! (tg: @ExFox)"
    log "=========================================="
    log "📊 Сводка:"
    log "   • Отпечаток ОС: ${GREEN}$TARGET_OS_NAME${NC} (TTL/HL = $TARGET_TTL)"
    log "   • Всего прокси: $PROXY_COUNT"
    log "   • AUTO: порты $START_PORT-$((START_PORT + PROXY_COUNT - 1))"
    log "   • IPv6 подсеть: $IPV6_SUBNET"
    log "   • Внешний IPv4: $EXTERNAL_IPV4"
    log "   • Интерфейс: $NETWORK_INTERFACE"
    log "🔧 Управление:"
    log "   • Статус: systemctl status 3proxy"
    log "   • Перезапуск: systemctl restart 3proxy"
    log "   • Логи: journalctl -u 3proxy -f"
    log "📁 Файлы:"
    log "   • Конфигурация: $CONFIG_FILE"
    log "   • Список прокси: /tmp/${EXTERNAL_IPV4}.txt (и /home/3proxy/${EXTERNAL_IPV4}.txt)"
    log "=========================================="
}

check_existing_installation() {
    if [[ -f "$SCRIPT_DIR/3proxy" ]] || systemctl is-active --quiet 3proxy 2>/dev/null; then
        systemctl stop 3proxy 2>/dev/null || true
        systemctl disable 3proxy 2>/dev/null || true
    fi
}

cleanup() {
    local exit_code=$?
    [[ $exit_code -ne 0 && -n "${INSTALLATION_STARTED:-}" ]] && {
        error "Установка не удалась"
        systemctl stop 3proxy 2>/dev/null || true
    }
}

trap cleanup EXIT

main() {
    clear
    log "=========================================="
    log "🚀 АВТОУСТАНОВЩИК IPv6 PROXY (tg: @ExFox)"
    log "=========================================="
    log "Проверка системы..."
    check_root
    check_system
    check_existing_installation

    get_user_input

    log "📋 Сводка:"
    log "   • Отпечаток ОС: ${GREEN}$TARGET_OS_NAME${NC} (TTL/HL = $TARGET_TTL)"
    log "   • IPv6: $IPV6_SUBNET"
    log "   • IPv4: $EXTERNAL_IPV4"
    log "   • Количество прокси: $PROXY_COUNT"
    log "   • Порты: $START_PORT-$((START_PORT + PROXY_COUNT - 1))"

    INSTALLATION_STARTED=1
    log "Установка..."
    install_dependencies
    install_3proxy
    optimize_system
    detect_network_interface
    configure_ipv6
    generate_auth
    generate_3proxy_config
    configure_firewall
    create_systemd_service
    start_3proxy
    test_proxy_functionality
    show_statistics
    generate_proxy_list

        END_PORT=$((START_PORT + PROXY_COUNT - 1))
    sudo ufw allow "${START_PORT}:${END_PORT}/tcp" > /dev/null 2>&1

    echo ""
    log "========================================================================"
    log "📥 КАК СКАЧАТЬ СПИСОК ПРОКСИ НА ВАШ РАБОЧИЙ СТОЛ WINDOWS:"
    log "========================================================================"
    echo -e "Откройте ${YELLOW}PowerShell${NC} или ${YELLOW}Терминал Windows${NC} на вашем ПК и выполните:"
    echo ""
    echo -e "  ${GREEN}scp root@${EXTERNAL_IPV4}:/tmp/${EXTERNAL_IPV4}.txt C:\\Users\\d4586\\Desktop\\${EXTERNAL_IPV4}.txt${NC}"
    echo ""
    echo -e "Или через переменную окружения профиля Windows:"
    echo -e "  ${BLUE}scp root@${EXTERNAL_IPV4}:/tmp/${EXTERNAL_IPV4}.txt \$env:USERPROFILE\\Desktop\\${EXTERNAL_IPV4}.txt${NC}"
    echo ""
    log "📁 Файл на сервере: /tmp/${EXTERNAL_IPV4}.txt (и сохранен в /home/3proxy/${EXTERNAL_IPV4}.txt)"
    log "========================================================================"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
