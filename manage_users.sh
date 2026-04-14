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

[[ $EUID -ne 0 ]]  && err "Запусти от root"
[[ ! -f $CONFIG ]] && err "Конфиг не найден: $CONFIG"
[[ ! -f $PARAMS ]] && err "Файл параметров не найден: $PARAMS. Переустанови сервер."

source $PARAMS

restart_xray() {
  xray run -test -config $CONFIG || err "Конфиг невалиден"
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray && log "Xray перезапущен" || err "Xray не запустился"
}

make_link() {
  local uuid=$1
  local name=$2
  if [[ "$TRANSPORT" == "tcp" ]]; then
    echo "vless://${uuid}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${name}"
  else
    echo "vless://${uuid}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=%2F#${name}"
  fi
}

list_users() {
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

add_user() {
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
import sys
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

delete_user() {
  list_users
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

show_qr() {
  list_users
  read -p "Введи номер пользователя для QR: " NUM
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
  echo -e "VLESS ссылка:"
  echo -e "${GREEN}${LINK}${NC}"
  echo ""
  echo "QR код:"
  echo ""
  qrencode -t ANSIUTF8 "$LINK"
}

# ─── Меню ────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════"
echo "     Управление пользователями      "
echo "════════════════════════════════════"
echo "  1) Список пользователей"
echo "  2) Добавить пользователя"
echo "  3) Удалить пользователя"
echo "  4) Показать QR для пользователя"
echo "════════════════════════════════════"
read -p "Выбери действие: " ACTION

case $ACTION in
  1) list_users ;;
  2) add_user ;;
  3) delete_user ;;
  4) show_qr ;;
  *) err "Неверный выбор" ;;
esac
