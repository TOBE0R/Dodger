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

# ─── Команды ─────────────────────────────────────────────

userlist() {
  [[ ! -f $CONFIG ]] && err "Xray не установлен"
  echo ""
  echo -e "${CYAN}Список пользователей:${NC}"
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
}

mainuser() {
  [[ ! -f $CONFIG ]] && err "Xray не установлен"
  [[ ! -f $PARAMS ]] && err "Файл параметров не найден, переустанови сервер"
  source $PARAMS

  UUID=$(python3 - <<PYEOF
import json
with open("$CONFIG") as f:
    config = json.load(f)
print(config["inbounds"][0]["settings"]["clients"][0]["id"])
PYEOF
)

  LINK=$(make_link "$UUID" "MainUser")

  echo ""
  echo "════════════════════════════════════"
  echo -e "${CYAN}        Основной пользователь${NC}"
  echo "════════════════════════════════════"
  echo -e "UUID: ${YELLOW}${UUID}${NC}"
  echo ""
  echo -e "VLESS ссылка:"
  echo -e "${GREEN}${LINK}${NC}"
  echo ""
  echo "QR код:"
  echo ""
  qrencode -t ANSIUTF8 "$LINK"
}

newuser() {
  [[ ! -f $CONFIG ]] && err "Xray не установлен"
  [[ ! -f $PARAMS ]] && err "Файл параметров не найден, переустанови сервер"
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

  restart_xray

  LINK=$(make_link "$NEW_UUID" "$USERNAME")

  echo ""
  echo "════════════════════════════════════"
  echo -e "${GREEN}   Пользователь добавлен!${NC}"
  echo "════════════════════════════════════"
  echo -e "Имя:  ${YELLOW}${USERNAME}${NC}"
  echo -e "UUID: ${YELLOW}${NEW_UUID}${NC}"
  echo ""
  echo -e "VLESS ссылка:"
  echo -e "${GREEN}${LINK}${NC}"
  echo ""
  echo "QR код:"
  echo ""
  qrencode -t ANSIUTF8 "$LINK"
}

rmuser() {
  [[ ! -f $CONFIG ]] && err "Xray не установлен"
  userlist
  read -p "Введи номер пользователя для удаления: " NUM
  [[ -z "$NUM" ]] && err "Номер не введён"

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

  restart_xray
  log "Пользователь удалён"
}

sharelink() {
  [[ ! -f $CONFIG ]] && err "Xray не установлен"
  [[ ! -f $PARAMS ]] && err "Файл параметров не найден, переустанови сервер"
  userlist
  read -p "Введи номер пользователя: " NUM
  [[ -z "$NUM" ]] && err "Номер не введён"
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

  LINK=$(make_link "$UUID" "$USERNAME")

  echo ""
  echo "════════════════════════════════════"
  echo -e "${CYAN}      Ссылка для подключения${NC}"
  echo "════════════════════════════════════"
  echo -e "VLESS ссылка:"
  echo -e "${GREEN}${LINK}${NC}"
  echo ""
  echo "QR код:"
  echo ""
  qrencode -t ANSIUTF8 "$LINK"
}

menu() {
  echo ""
  echo "════════════════════════════════════"
  echo -e "${CYAN}         Управление Xray${NC}"
  echo "════════════════════════════════════"
  echo "  1) userlist  — список пользователей"
  echo "  2) mainuser  — ссылка основного пользователя"
  echo "  3) newuser   — добавить пользователя"
  echo "  4) rmuser    — удалить пользователя"
  echo "  5) sharelink — ссылка для любого пользователя"
  echo "  6) Выход"
  echo "════════════════════════════════════"
  read -p "Выбери действие: " ACTION
  case $ACTION in
    1) userlist ;;
    2) mainuser ;;
    3) newuser ;;
    4) rmuser ;;
    5) sharelink ;;
    6) exit 0 ;;
    *) err "Неверный выбор" ;;
  esac
}

# ─── Установка ───────────────────────────────────────────

install() {
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

  # Проверяем что порт свободен
  if ss -tlnp | grep -q ":${PORT} " ; then
    BUSY_BY=$(ss -tlnp | grep ":${PORT} " | awk '{print $NF}')
    err "Порт ${PORT} уже занят: ${BUSY_BY}. Останови процесс или выбери другой порт."
  fi

  read -p "SNI (например, www.google.com): " SNI
  [[ -z "$SNI" ]] && err "SNI не может быть пустым"

  # Проверяем доступность SNI
  log "Проверяю доступность SNI..."
  if ! curl -sI --max-time 5 "https://${SNI}" > /dev/null 2>&1; then
    echo -e "${YELLOW}[!]${NC} SNI ${SNI} недоступен с этого сервера. Продолжить всё равно? [y/N]"
    read -p "" CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && err "Прерываем установку. Выбери другой SNI."
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

  # Копируем скрипт глобально
  cp "$0" /usr/local/bin/xray-manage
  chmod +x /usr/local/bin/xray-manage

  # Алиасы
  cat >> /etc/bash.bashrc <<'BASHEOF'

# xray management
alias menu='xray-manage menu'
alias userlist='xray-manage userlist'
alias mainuser='xray-manage mainuser'
alias newuser='xray-manage newuser'
alias rmuser='xray-manage rmuser'
alias sharelink='xray-manage sharelink'
BASHEOF

  source /etc/bash.bashrc

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
  echo -e "  ${CYAN}menu${NC}      — интерактивное меню"
  echo -e "  ${CYAN}userlist${NC}  — список пользователей"
  echo -e "  ${CYAN}mainuser${NC}  — ссылка основного пользователя"
  echo -e "  ${CYAN}newuser${NC}   — добавить пользователя"
  echo -e "  ${CYAN}rmuser${NC}    — удалить пользователя"
  echo -e "  ${CYAN}sharelink${NC} — ссылка для любого пользователя"
  echo ""
  echo -e "${YELLOW}Выполни 'source /etc/bash.bashrc' чтобы команды заработали сразу${NC}"
}

# ─── Точка входа ─────────────────────────────────────────

case "${1:-}" in
  install)   install ;;
  userlist)  userlist ;;
  mainuser)  mainuser ;;
  newuser)   newuser ;;
  rmuser)    rmuser ;;
  sharelink) sharelink ;;
  menu)      menu ;;
  "")        menu ;;
  *) echo -e "Использование: xray-manage [install|userlist|mainuser|newuser|rmuser|sharelink|menu]" ;;
esac
