#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && err "Запусти от root"

log "Устанавливаю зависимости..."
apt-get update -qq
apt-get install -y -qq curl unzip uuid-runtime qrencode

log "Устанавливаю xray..."
bash <(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install

echo ""
echo "════════════════════════════════════"
echo "       Настройка VLESS + Reality    "
echo "════════════════════════════════════"
echo ""

read -p "Порт [443]: " PORT
PORT=${PORT:-443}

read -p "SNI (например, www.google.com): " SNI
[[ -z "$SNI" ]] && err "SNI не может быть пустым"

echo ""
echo "Доступные отпечатки:"
echo "  1) chrome"
echo "  2) firefox"
echo "  3) safari"
echo "  4) edge"
echo "  5) ios"
echo "  6) android"
echo "  7) random"
read -p "Выбери отпечаток [1]: " FP_CHOICE
case $FP_CHOICE in
  2) FINGERPRINT="firefox" ;;
  3) FINGERPRINT="safari" ;;
  4) FINGERPRINT="edge" ;;
  5) FINGERPRINT="ios" ;;
  6) FINGERPRINT="android" ;;
  7) FINGERPRINT="random" ;;
  *) FINGERPRINT="chrome" ;;
esac

echo ""
echo "Транспортный протокол:"
echo "  1) tcp"
echo "  2) xhttp"
read -p "Выбери транспорт [1]: " TR_CHOICE
case $TR_CHOICE in
  2) TRANSPORT="xhttp" ;;
  *) TRANSPORT="tcp" ;;
esac

log "Генерирую ключи..."
UUID=$(uuidgen)

KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | awk 'NR==1{print $NF}')
PUBLIC_KEY=$(echo "$KEYS"  | awk 'NR==2{print $NF}')

[[ -z "$PRIVATE_KEY" ]] && err "Не удалось получить приватный ключ. Вывод:\n$KEYS"
[[ -z "$PUBLIC_KEY"  ]] && err "Не удалось получить публичный ключ. Вывод:\n$KEYS"

SHORT_ID=$(openssl rand -hex 8)
SERVER_IP=$(curl -s https://api.ipify.org)

log "Ключи сгенерированы"
echo -e "  Private key: ${YELLOW}${PRIVATE_KEY}${NC}"
echo -e "  Public key:  ${YELLOW}${PUBLIC_KEY}${NC}"
echo -e "  Short ID:    ${YELLOW}${SHORT_ID}${NC}"

if [[ "$TRANSPORT" == "xhttp" ]]; then
  CLIENT_BLOCK='{"id": "'"${UUID}"'"}'
  STREAM_SETTINGS=$(cat <<EOF
{
  "network": "xhttp",
  "security": "reality",
  "realitySettings": {
    "show": false,
    "dest": "${SNI}:443",
    "serverNames": ["${SNI}"],
    "privateKey": "${PRIVATE_KEY}",
    "shortIds": ["${SHORT_ID}"]
  },
  "xhttpSettings": {
    "path": "/",
    "mode": "auto"
  }
}
EOF
)
  VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=%2F#MyServer"
else
  CLIENT_BLOCK='{"id": "'"${UUID}"'", "flow": "xtls-rprx-vision"}'
  STREAM_SETTINGS=$(cat <<EOF
{
  "network": "tcp",
  "security": "reality",
  "realitySettings": {
    "show": false,
    "dest": "${SNI}:443",
    "serverNames": ["${SNI}"],
    "privateKey": "${PRIVATE_KEY}",
    "shortIds": ["${SHORT_ID}"]
  },
  "tcpSettings": {}
}
EOF
)
  VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#MyServer"
fi

log "Записываю конфиг..."
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ ${CLIENT_BLOCK} ],
        "decryption": "none"
      },
      "streamSettings": ${STREAM_SETTINGS},
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

# Сохраняем параметры для скрипта управления пользователями
cat > /usr/local/etc/xray/params.env <<EOF
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SNI=${SNI}
PORT=${PORT}
TRANSPORT=${TRANSPORT}
FINGERPRINT=${FINGERPRINT}
SERVER_IP=${SERVER_IP}
EOF

log "Валидирую конфиг..."
xray run -test -config /usr/local/etc/xray/config.json || err "Конфиг невалиден"

log "Запускаю xray..."
systemctl enable xray
systemctl restart xray
sleep 2

systemctl is-active --quiet xray && log "Xray запущен успешно" || err "Xray не запустился: journalctl -u xray -f"

echo ""
echo "════════════════════════════════════"
echo -e "${GREEN}       Установка завершена!${NC}"
echo "════════════════════════════════════"
echo ""
echo -e "UUID:        ${YELLOW}${UUID}${NC}"
echo -e "Порт:        ${YELLOW}${PORT}${NC}"
echo -e "SNI:         ${YELLOW}${SNI}${NC}"
echo -e "Отпечаток:   ${YELLOW}${FINGERPRINT}${NC}"
echo -e "Транспорт:   ${YELLOW}${TRANSPORT}${NC}"
echo -e "Public key:  ${YELLOW}${PUBLIC_KEY}${NC}"
echo -e "Short ID:    ${YELLOW}${SHORT_ID}${NC}"
echo ""
echo -e "VLESS ссылка:"
echo -e "${GREEN}${VLESS_LINK}${NC}"
echo ""
qrencode -t ANSIUTF8 "${VLESS_LINK}"
echo ""
echo "Перезапуск:  systemctl restart xray"
echo "Логи:        journalctl -u xray -f"
echo "Конфиг:      nano /usr/local/etc/xray/config.json"
