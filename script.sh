#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; exit 1; }

CONFIG="/usr/local/etc/xray/config.json"
PARAMS="/usr/local/etc/xray/params.env"

# ─── Вспомогательные функции ─────────────────────────────

restart_xray() {
  xray run -test -config $CONFIG || err "Конфиг невалиден"
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray && log "Xray перезапущен" || err "Xray не запустился"
}

make_link() {
  local uuid=$1
  local name=$2
  source $PARAMS
  if [[ "$TRANSPORT" == "tcp" ]]; then
    echo "vless://${uuid}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${name}"
  else
    echo "vless://${uuid}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=%2F#${name}"
  fi
}

install_commands() {
  log "Устанавливаю команды управления..."

  # userlist
  cat > /usr/local/bin/userlist <<'EOF'
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
[[ ! -f $CONFIG ]] && echo "Xray не установлен" && exit 1
echo ""
echo "Список пользователей:"
echo "────────────────────────────────────"
python3 - <<PYEOF
import json
with open("$CONFIG") as f:
    config = json.load(f)
clients = config["inbounds"][0]["settings"]["clients"]
for i, c in enumerate(clients):
    print(f"  {i+1}) {c['id']}")
print(f"\nВсего: {len(clients)}")
PYEOF
echo ""
EOF

  # mainuser
  cat > /usr/local/bin/mainuser <<'EOF'
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
PARAMS="/usr/local/etc/xray/params.env"
[[ ! -f $CONFIG ]] && echo "Xray не установлен" && exit 1
[[ ! -f $PARAMS ]] && echo "Файл параметров не найден" && exit 1
source $PARAMS

UUID=$(python3 - <<PYEOF
import json
with open("$CONFIG") as f:
    config = json.load(f)
print(config["inbounds"][0]["settings"]["clients"][0]["id"])
PYEOF
)

if [[ "$TRANSPORT" == "tcp" ]]; then
  LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#MainUser"
else
  LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=%2F#MainUser"
fi

echo ""
echo "════════════════════════════════════"
echo "        Основной пользователь"
echo "════════════════════════════════════"
echo "UUID: $UUID"
echo ""
echo "VLESS ссылка:"
echo "$LINK"
echo ""
echo "QR код:"
echo ""
qrencode -t ANSIUTF8 "$LINK"
EOF

  # newuser
  cat > /usr/local/bin/newuser <<'EOF'
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
PARAMS="/usr/local/etc/xray/params.env"
[[ ! -f $CONFIG ]] && echo "Xray не установлен" && exit 1
[[ ! -f $PARAMS ]] && echo "Файл параметров не найден" && exit 1
source $PARAMS

echo ""
read -p "Имя пользователя (для метки): " USERNAME
[[ -z "$USERNAME" ]] && USERNAME="User"

NEW_UUID=$(uuidgen)

if [[ "$TRANSPORT" == "tcp" ]]; then
  NEW_CLIENT="{\"id\": \"${NEW_UUID}\", \"flow\": \"xtls-rprx-vision\"}"
else
  NEW_CLIENT="{\"id\": \"${NEW_UUID}\"}"
fi

python3 - <<PYEOF
import json
with open("$CONFIG") as f:
    config = json.load(f)
new_client = json.loads('${NEW_CLIENT}')
config["inbounds"][0]["settings"]["clients"].append(new_client)
with open("$CONFIG", "w") as f:
    json.dump(config, f, indent=2)
PYEOF

xray run -test -config $CONFIG || { echo "Конфиг невалиден"; exit 1; }
systemctl restart xray
sleep 1

if [[ "$TRANSPORT" == "tcp" ]]; then
  LINK="vless://${NEW_UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${USERNAME}"
else
  LINK="vless://${NEW_UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=%2F#${USERNAME}"
fi

echo ""
echo "════════════════════════════════════"
echo "      Пользователь добавлен!"
echo "════════════════════════════════════"
echo "Имя:  $USERNAME"
echo "UUID: $NEW_UUID"
echo ""
echo "VLESS ссылка:"
echo "$LINK"
echo ""
echo "QR код:"
echo ""
qrencode -t ANSIUTF8 "$LINK"
EOF

  # rmuser
  cat > /usr/local/bin/rmuser <<'EOF'
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
[[ ! -f $CONFIG ]] && echo "Xray не установлен" && exit 1

echo ""
echo "Список пользователей:"
echo "────────────────────────────────────"
python3 - <<PYEOF
import json
with open("$CONFIG") as f:
    config = json.load(f)
clients = config["inbounds"][0]["settings"]["clients"]
for i, c in enumerate(clients):
    print(f"  {i+1}) {c['id']}")
PYEOF
echo ""
read -p "Введи номер пользователя для удаления: " NUM
[[ -z "$NUM" ]] && echo "Номер не введён" && exit 1

python3 - <<PYEOF
import json, sys
with open("$CONFIG") as f:
    config = json.load(f)
clients = config["inbounds"][0]["settings"]["clients"]
idx = int("$NUM") - 1
if idx < 0 or idx >= len(clients):
    print("Неверный номер")
    sys.exit(1)
removed = clients.pop(idx)
print(f"Удалён: {removed['id']}")
with open("$CONFIG", "w") as f:
    json.dump(config, f, indent=2)
PYEOF

xray run -test -config $CONFIG || { echo "Конфиг невалиден"; exit 1; }
systemctl restart xray
sleep 1
echo "Готово"
EOF

  # sharelink
  cat > /usr/local/bin/sharelink <<'EOF'
#!/bin/bash
CONFIG="/usr/local/etc/xray/config.json"
PARAMS="/usr/local/etc/xray/params.env"
[[ ! -f $CONFIG ]] && echo "Xray не установлен" && exit 1
[[ ! -f $PARAMS ]] && echo "Файл параметров не найден" && exit 1
source $PARAMS

echo ""
echo "Список пользователей:"
echo "────────────────────────────────────"
python3 - <<PYEOF
import json
with open("$CONFIG") as f:
    config = json.load(f)
clients = config["inbounds"][0]["settings"]["clients"]
for i, c in enumerate(clients):
    print(f"  {i+1}) {c['id']}")
PYEOF
echo ""
read -p "Введи номер пользователя: " NUM
[[ -z "$NUM" ]] && echo "Номер не введён" && exit 1
read -p "Имя для метки [User]: " USERNAME
USERNAME=${USERNAME:-User}

UUID=$(python3 - <<PYEOF
import json
with open("$CONFIG") as f:
    config = json.load(f)
clients = config["inbounds"][0]["settings"]["clients"]
idx = int("$NUM") - 1
print(clients[idx]["id"])
PYEOF
)

if [[ "$TRANSPORT" == "tcp" ]]; then
  LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${USERNAME}"
else
  LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=%2F#${USERNAME}"
fi

echo ""
echo "════════════════════════════════════"
echo "      Ссылка для подключения"
echo "════════════════════════════════════"
echo "VLESS ссылка:"
echo "$LINK"
echo ""
echo "QR код:"
echo ""
qrencode -t ANSIUTF8 "$LINK"
EOF

  chmod +x /usr/local/bin/userlist
  chmod +x /usr/local/bin/mainuser
  chmod +x /usr/local/bin/newuser
  chmod +x /usr/local/bin/rmuser
  chmod +x /usr/local/bin/sharelink

  log "Команды установлены"
}

# ─── Установка ───────────────────────────────────────────

[[ $EUID -ne 0 ]] && err "Запусти от root"

log "Устанавливаю зависимости..."
apt-get update -qq
apt-get install -y -qq curl unzip uuid-runtime qrencode python3

log "Устанавливаю xray..."
bash <(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install

echo ""
echo "════════════════════════════════════"
echo "       Настройка VLESS + Reality    "
echo "════════════════════════════════════"
echo ""

read -p "Порт [443]: " PORT
PORT=${PORT:-443}

if ss -tlnp | grep -q ":${PORT} "; then
  BUSY_BY=$(ss -tlnp | grep ":${PORT} " | awk '{print $NF}')
  err "Порт ${PORT} уже занят: ${BUSY_BY}"
fi

read -p "SNI (например, www.google.com): " SNI
[[ -z "$SNI" ]] && err "SNI не может быть пустым"

log "Проверяю доступность SNI..."
if ! curl -sI --max-time 5 "https://${SNI}" > /dev/null 2>&1; then
  echo -e "${YELLOW}[!]${NC} SNI ${SNI} недоступен с этого сервера. Продолжить? [y/N]"
  read -p "" CONFIRM
  [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && err "Прерываем. Выбери другой SNI."
fi

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
cat > $CONFIG <<EOF
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

cat > $PARAMS <<EOF
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SNI=${SNI}
PORT=${PORT}
TRANSPORT=${TRANSPORT}
FINGERPRINT=${FINGERPRINT}
SERVER_IP=${SERVER_IP}
EOF

log "Валидирую конфиг..."
xray run -test -config $CONFIG || err "Конфиг невалиден"

log "Запускаю xray..."
systemctl enable xray
systemctl restart xray
sleep 2
systemctl is-active --quiet xray && log "Xray запущен успешно" || err "Xray не запустился"

install_commands

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
echo "QR код:"
echo ""
qrencode -t ANSIUTF8 "$VLESS_LINK"
echo ""
echo -e "Доступные команды:"
echo -e "  ${CYAN}userlist${NC}  — список пользователей"
echo -e "  ${CYAN}mainuser${NC}  — ссылка основного пользователя"
echo -e "  ${CYAN}newuser${NC}   — добавить пользователя"
echo -e "  ${CYAN}rmuser${NC}    — удалить пользователя"
echo -e "  ${CYAN}sharelink${NC} — ссылка для любого пользователя"
