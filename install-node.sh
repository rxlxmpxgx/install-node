#!/bin/bash
set -e

# ============================================
# Remnawave Node Auto-Installer + Hardening
# ============================================

# --- Ввод переменных ---
read -p "SSH порт [54333]: " SSH_PORT
SSH_PORT=${SSH_PORT:-54333}

read -p "Порт ноды (NODE_PORT) [5774]: " NODE_PORT
NODE_PORT=${NODE_PORT:-5774}

read -p "SECRET_KEY: " SECRET_KEY
if [ -z "$SECRET_KEY" ]; then echo "SECRET_KEY обязателен!"; exit 1; fi

read -p "Decoy домен (serverName для Angie): " DECOY_DOMAIN
if [ -z "$DECOY_DOMAIN" ]; then echo "Домен обязателен!"; exit 1; fi

read -p "IP панели Remnawave [150.251.138.43]: " PANEL_IP
PANEL_IP=${PANEL_IP:-150.251.138.43}

read -p "Имя админ-пользователя [adminpzfq]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-adminpzfq}

# --- Обновление системы ---
echo ">>> Обновление системы..."
apt update && apt upgrade -y && apt autoremove -y

# --- Docker ---
echo ">>> Установка Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
else
    echo "Docker уже установлен, пропускаем"
fi

# --- Директории ---
echo ">>> Создание директорий..."
mkdir -p /opt/remnanode/angie
mkdir -p /var/log/remnanode

wget -qO- https://raw.githubusercontent.com/Jolymmiles/confluence-marzban-home/main/index.html > /opt/remnanode/angie/index.html

# --- Angie ---
echo ">>> Настройка Angie..."
cat > /opt/remnanode/angie/angie.conf << EOFANGIE
user angie;
worker_processes auto;
error_log /var/log/angie/error.log notice;

events {
    worker_connections 1024;
}

http {
    log_format main '[\$time_local] \$proxy_protocol_addr "\$http_referer" "\$http_user_agent"';
    access_log /var/log/angie/access.log main;

    resolver 1.1.1.1;
    acme_client vless https://acme-v02.api.letsencrypt.org/directory;

    server {
        listen 80;
        listen [::]:80;
        server_name _;
        return 301 https://\$host\$request_uri;
    }

    server {
        listen 127.0.0.1:4123 ssl proxy_protocol;
        http2 on;

        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        server_name ${DECOY_DOMAIN};

        acme vless;
        ssl_certificate \$acme_cert_vless;
        ssl_certificate_key \$acme_cert_key_vless;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;

        location / {
            root /tmp;
            index index.html;
        }
    }
}
EOFANGIE

# --- Docker-compose ---
echo ">>> Настройка docker-compose..."
cat > /opt/remnanode/docker-compose.yml << EOFDC
services:
  angie:
    image: docker.angie.software/angie:minimal
    container_name: angie
    restart: always
    network_mode: host
    volumes:
      - ./angie/angie.conf:/etc/angie/angie.conf:ro
      - ./angie/index.html:/tmp/index.html:ro
      - angie-data:/var/lib/angie

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
      - SECRET_KEY="${SECRET_KEY}"
    volumes:
      - /var/log/remnanode:/var/log/remnanode

volumes:
  angie-data:
EOFDC

# --- Запуск контейнеров ---
echo ">>> Запуск контейнеров..."
cd /opt/remnanode && docker compose up -d

# --- Админ-пользователь ---
echo ">>> Создание админ-пользователя ${ADMIN_USER}..."
if id "$ADMIN_USER" &>/dev/null; then
    echo "Пользователь ${ADMIN_USER} уже существует, пропускаем"
else
    useradd -m -s /bin/bash "$ADMIN_USER"
    usermod -aG sudo "$ADMIN_USER"
    usermod -aG docker "$ADMIN_USER"
    passwd "$ADMIN_USER"
    mkdir -p /home/"$ADMIN_USER"/.ssh
    if [ -f /root/.ssh/authorized_keys ]; then
        cp /root/.ssh/authorized_keys /home/"$ADMIN_USER"/.ssh/authorized_keys
    fi
    chown -R "$ADMIN_USER":"$ADMIN_USER" /home/"$ADMIN_USER"/.ssh
    chmod 700 /home/"$ADMIN_USER"/.ssh
    chmod 600 /home/"$ADMIN_USER"/.ssh/authorized_keys 2>/dev/null || true
fi

# --- UFW ---
echo ">>> Настройка UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow from ${PANEL_IP} to any port ${NODE_PORT} proto tcp
ufw --force enable

# --- SSH ---
echo ">>> Настройка SSH на порт ${SSH_PORT}..."
mkdir -p /etc/systemd/system/ssh.socket.d
cat > /etc/systemd/system/ssh.socket.d/override.conf << EOFSSH
[Socket]
ListenStream=
ListenStream=0.0.0.0:${SSH_PORT}
ListenStream=[::]:${SSH_PORT}
EOFSSH
systemctl daemon-reload
systemctl restart ssh.socket

cat > /etc/ssh/sshd_config.d/hardening.conf << EOFSSHD
PermitRootLogin no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOFSSHD
sshd -t && systemctl restart ssh || echo "ОШИБКА: sshd -t не прошёл! Не закрывай сессию!"

# --- Sysctl ---
echo ">>> Sysctl hardening..."
cat > /etc/sysctl.d/99-hardening.conf << EOFSYS
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOFSYS
sysctl --system

# --- Fail2Ban ---
echo ">>> Настройка Fail2Ban..."
apt install -y fail2ban
cat > /etc/fail2ban/jail.local << EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 3600
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# --- Итого ---
echo ""
echo "============================================"
echo "  УСТАНОВКА ЗАВЕРШЕНА"
echo "============================================"
echo "  SSH порт:     ${SSH_PORT}"
echo "  Node порт:    ${NODE_PORT}"
echo "  Decoy домен:  ${DECOY_DOMAIN}"
echo "  Панель IP:    ${PANEL_IP}"
echo "  Админ:        ${ADMIN_USER}"
echo ""
echo "  ВАЖНО:"
echo "  1. НЕ закрывай текущую сессию!"
echo "  2. Открой НОВЫЙ терминал: ssh ${ADMIN_USER}@<<IP> -p ${SSH_PORT}"
echo "  3. Если Yandex Cloud — добавь порт ${SSH_PORT} в Security Group"
echo "============================================"