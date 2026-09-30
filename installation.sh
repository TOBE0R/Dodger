#!/usr/bin/env bash
#
# install-xray.sh — Xray VLESS + REALITY (TCP/Vision или XHTTP) для Debian/Ubuntu
#
# Интерактивно:
#   sudo ./install-xray.sh
#
# Без вопросов (Ansible / cloud-init / CI):
#   sudo SNI=www.example.com PORT=443 TRANSPORT=tcp FINGERPRINT=chrome ENABLE_BBR=y ./install-xray.sh
#
# Необязательные переменные окружения:
#   XRAY_VERSION=v26.3.27        зафиксировать версию Xray (по умолчанию — последняя)
#   SERVER_ADDR=vpn.example.com  адрес в ссылках (по умолчанию — внешний IPv4)
#   API_PORT=10085               порт gRPC API Xray (слушает только 127.0.0.1)
#   FORCE_REINSTALL=y            переустановить поверх существующей установки (ключи и ссылки сменятся)
#   MIGRATE=y|n                  при обновлении: включить API/статистику и hardening в существующем конфиге
#   SKIP_SNI_CHECK=y             не проверять SNI на TLS 1.3 + HTTP/2
#   SKIP_ZABBIX=y                не ставить UserParameter для Zabbix agent
#
# Повторный запуск без FORCE_REINSTALL безопасен: обновит Xray и утилиты, пользователей не тронет.
#
# Безопасность API: gRPC API Xray не имеет аутентификации и слушает 127.0.0.1. Единственное, что
# не пускает через него VPN-клиентов, — правило routing «geoip:private → block» в конфиге.
# Не удаляй его: без него любой клиент сможет дойти до 127.0.0.1:API и добавлять пользователей.

set -Eeuo pipefail
umask 077

readonly XRAY_DIR=/usr/local/etc/xray
readonly CONFIG=$XRAY_DIR/config.json
readonly PARAMS=$XRAY_DIR/params.env
readonly BACKUP_DIR=$XRAY_DIR/backup
readonly CTL=/usr/local/bin/xrayctl
readonly INSTALLER_URL=https://github.com/XTLS/Xray-install/raw/main/install-release.sh
readonly FINGERPRINTS=(chrome firefox safari edge ios android random)
readonly TRANSPORTS=(tcp xhttp)
readonly ZABBIX_DIRS=(/etc/zabbix/zabbix_agentd.d /etc/zabbix/zabbix_agent2.d)
readonly ZABBIX_UNITS=(zabbix-agent zabbix-agent2)

if [[ -t 1 ]]; then
  RED=$'\e[0;31m' GREEN=$'\e[0;32m' YELLOW=$'\e[1;33m' CYAN=$'\e[0;36m' NC=$'\e[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' NC=''
fi

log()  { printf '%s[+]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
err()  { printf '%s[-]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

TMP_FILES=()
cleanup() { if ((${#TMP_FILES[@]})); then rm -f -- "${TMP_FILES[@]}"; fi; }
trap cleanup EXIT
trap 'err "Сбой в строке $LINENO: $BASH_COMMAND"' ERR

# ─── Ввод ────────────────────────────────────────────────

# ask VAR "вопрос" [default] — значение из окружения важнее; без TTY берётся default
ask() {
  local __var=$1 __prompt=$2 __def=${3:-} __val=''
  if [[ -n ${!__var:-} ]]; then return 0; fi
  if [[ -t 0 ]]; then read -rp "$__prompt${__def:+ [$__def]}: " __val || true; fi
  printf -v "$__var" '%s' "${__val:-$__def}"
}

# confirm "вопрос" [y|n] — без TTY возвращает default
confirm() {
  local def=${2:-n} hint='y/N' a=''
  if [[ $def == y ]]; then hint='Y/n'; fi
  if [[ -t 0 ]]; then read -rp "$1 [$hint]: " a || true; fi
  [[ ${a:-$def} == [yYдД]* ]]
}

# choose VAR "заголовок" вариант1 вариант2 ... — первый вариант по умолчанию
choose() {
  local __var=$1 __title=$2 __n='' __i __o
  shift 2
  local -a __opts=("$@")
  if [[ -z ${!__var:-} ]]; then
    if [[ -t 0 ]]; then
      printf '\n%s:\n' "$__title"
      for __i in "${!__opts[@]}"; do printf '  %d) %s\n' $((__i + 1)) "${__opts[__i]}"; done
      read -rp "Выбор [1]: " __n || true
    fi
    __n=${__n:-1}
    [[ $__n =~ ^[1-9][0-9]*$ ]] && ((__n <= ${#__opts[@]})) || err "$__title: неверный выбор '$__n'"
    printf -v "$__var" '%s' "${__opts[__n - 1]}"
  fi
  for __o in "${__opts[@]}"; do
    if [[ $__o == "${!__var}" ]]; then return 0; fi
  done
  err "$__title: недопустимое значение '${!__var}' (допустимо: ${__opts[*]})"
}

# ─── Системное ───────────────────────────────────────────

preflight() {
  [[ $EUID -eq 0 ]] || err "Запусти от root"
  command -v apt-get >/dev/null || err "Поддерживаются только Debian/Ubuntu (нужен apt-get)"
  command -v systemctl >/dev/null || err "Нужен systemd"
}

install_deps() {
  log "Устанавливаю зависимости..."
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    curl ca-certificates jq qrencode openssl iproute2 unzip util-linux >/dev/null
}

install_xray() {
  local installer
  local -a args=(install)
  installer=$(mktemp)
  TMP_FILES+=("$installer")
  log "Скачиваю официальный установщик Xray..."
  curl -fsSL --retry 3 --max-time 60 -o "$installer" "$INSTALLER_URL" \
    || err "Не удалось скачать $INSTALLER_URL"
  if [[ -n ${XRAY_VERSION:-} ]]; then args+=(--version "$XRAY_VERSION"); fi
  log "Устанавливаю Xray ${XRAY_VERSION:-(последняя версия)}..."
  bash "$installer" "${args[@]}" || err "Официальный установщик Xray завершился с ошибкой"
  command -v xray >/dev/null || err "Бинарник xray не найден после установки"
  log "$(xray version | sed -n 1p)"
}

# Группа пользователя, от которого systemd запускает xray (по умолчанию nobody → nogroup)
xray_group() {
  local user
  user=$(systemctl show -p User --value xray 2>/dev/null || true)
  id -gn "${user:-root}"
}

# Конфиг содержит приватный ключ и UUID всех пользователей — не должен быть world-readable
secure_files() {
  chown "root:$(xray_group)" "$CONFIG"
  chmod 640 "$CONFIG"
  chown root:root "$PARAMS"
  chmod 600 "$PARAMS"
}

backup_config() {
  [[ -s $CONFIG ]] || return 0
  local dst
  install -d -m 700 "$BACKUP_DIR"
  dst="$BACKUP_DIR/config.pre-reinstall.$(date +%Y%m%d-%H%M%S).json"
  cp -p "$CONFIG" "$dst"
  log "Предыдущий конфиг сохранён: $dst"
}

health_check() {
  local _
  sleep 2
  for _ in 1 2 3 4 5; do
    if systemctl is-active --quiet xray && [[ -n $(ss -Htln "sport = :$PORT") ]]; then return 0; fi
    sleep 1
  done
  journalctl -u xray -n 30 --no-pager >&2 || true
  err "Xray не запустился или не слушает порт $PORT (лог выше)"
}

api_check() {
  local out
  out=$(xray api inboundusercount -s "127.0.0.1:$API_PORT" -t 5 -tag=vless-in 2>&1) \
    || err "API Xray не отвечает на 127.0.0.1:$API_PORT:"$'\n'"$out"
  log "API Xray отвечает (127.0.0.1:$API_PORT), статистика по пользователям включена"
}

start_xray() {
  log "Запускаю Xray..."
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
  health_check
  log "Xray работает и слушает порт $PORT"
  api_check
}

open_firewall() {
  if command -v ufw >/dev/null && [[ $(ufw status 2>/dev/null) == "Status: active"* ]]; then
    ufw allow "$PORT/tcp" comment 'xray' >/dev/null || warn "Не удалось открыть порт в UFW"
    log "UFW: открыт $PORT/tcp"
  else
    warn "UFW не активен. Если используешь фаервол хостера или nftables — открой $PORT/tcp там."
  fi
}

enable_bbr() {
  ask ENABLE_BBR "Включить TCP BBR (y/n)" y
  [[ $ENABLE_BBR == [yY]* ]] || return 0
  if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; then
    log "BBR уже включён"
    return 0
  fi
  modprobe tcp_bbr 2>/dev/null || true
  if [[ $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) != *bbr* ]]; then
    warn "Ядро не поддерживает BBR — пропускаю"
    return 0
  fi
  printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > /etc/sysctl.d/99-xray-bbr.conf
  sysctl -q -p /etc/sysctl.d/99-xray-bbr.conf
  log "BBR включён"
}

# ─── Мониторинг (Zabbix agent) ───────────────────────────

# Две проверки: unit активен и порт слушается. Порт зашивается в файл при установке/обновлении.
# Абсолютные пути: у агента укороченный PATH. Все права — обычного пользователя zabbix.
install_zabbix() {
  local d u ss_bin sc_bin conf found=0
  [[ ${SKIP_ZABBIX:-n} != y ]] || return 0
  ss_bin=$(command -v ss) sc_bin=$(command -v systemctl)
  conf=$(printf '%s\n' \
    "# Управляется install-xray.sh (порт Xray: $PORT). Перезаписывается при обновлении." \
    "UserParameter=xray.unit.active,$sc_bin is-active --quiet xray && echo 1 || echo 0" \
    "UserParameter=xray.port.listen,$ss_bin -Htln 'sport = :$PORT' | grep -q . && echo 1 || echo 0")
  for d in "${ZABBIX_DIRS[@]}"; do
    [[ -d $d ]] || continue
    printf '%s\n' "$conf" > "$d/userparameter_xray.conf"
    chown root:root "$d/userparameter_xray.conf"
    chmod 644 "$d/userparameter_xray.conf"
    found=1
  done
  if ((!found)); then
    warn "Zabbix agent не найден — пропускаю. Для ручной настройки добавь в конфиг агента:"
    printf '%s\n' "$conf" | sed 1d >&2
    return 0
  fi
  for u in "${ZABBIX_UNITS[@]}"; do
    if systemctl is-active --quiet "$u"; then
      systemctl restart "$u" && log "Перезапущен $u (подхватил ключи xray.*)"
    fi
  done
  log "Zabbix: ключи xray.unit.active и xray.port.listen (шаблон: zabbix_template_xray.yaml)"
}

# ─── Параметры и ключи ───────────────────────────────────

detect_ip() {
  local src ip
  for src in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 5 "$src" 2>/dev/null | tr -d '[:space:]') || continue
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

# REALITY требует от маскировочного сайта TLS 1.3 и HTTP/2
check_sni() {
  local v
  v=$(curl -so /dev/null --max-time 8 --tlsv1.3 --http2 -w '%{http_version}' "https://$1") || return 1
  [[ $v == 2 ]]
}

# check_port_free <порт> <название>: порт свободен или занят самим xray (переустановка)
check_port_free() {
  local holder
  [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (($1 <= 65535)) || err "Некорректный порт ($2): $1"
  holder=$(ss -Htlnp "sport = :$1")
  if [[ -n $holder && $holder != *'"xray"'* ]]; then
    err "Порт $1 ($2) уже занят: $(awk '{print $NF}' <<<"$holder" | sort -u | paste -sd' ')"
  fi
}

collect_params() {
  local detected=''

  ask PORT "Порт" 443
  check_port_free "$PORT" "Xray"
  API_PORT=${API_PORT:-10085}
  check_port_free "$API_PORT" "API"
  [[ $API_PORT != "$PORT" ]] || err "API_PORT не может совпадать с PORT"

  ask SNI "SNI (чужой домен с TLS 1.3 + HTTP/2, не google.com)" ""
  [[ -n $SNI ]] || err "SNI обязателен (для запуска без вопросов задай SNI=домен)"
  SNI=${SNI,,}
  [[ $SNI =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || err "Некорректный домен: $SNI"
  if [[ ${SKIP_SNI_CHECK:-n} != y ]]; then
    log "Проверяю $SNI: TLS 1.3 + HTTP/2..."
    if ! check_sni "$SNI"; then
      warn "$SNI недоступен с сервера или не отдаёт TLS 1.3 + HTTP/2 — REALITY с ним работать не будет"
      confirm "Всё равно продолжить?" n || err "Прервано. Выбери другой SNI."
    fi
  fi

  choose FINGERPRINT "TLS-отпечаток клиента (fp)" "${FINGERPRINTS[@]}"
  choose TRANSPORT "Транспорт" "${TRANSPORTS[@]}"

  if [[ -z ${SERVER_ADDR:-} ]]; then
    detected=$(detect_ip) || warn "Не удалось определить внешний IPv4"
    ask SERVER_ADDR "Адрес сервера в ссылках (IP или домен)" "$detected"
  fi
  [[ $SERVER_ADDR =~ ^[A-Za-z0-9.:-]+$ ]] || err "Некорректный адрес сервера: '$SERVER_ADDR'"
}

gen_keys() {
  local out
  log "Генерирую ключи..."
  out=$(xray x25519)
  # Формат вывода менялся между версиями Xray ("Private key:" → "PrivateKey:",
  # "Public key:" → "Password (PublicKey):"), поэтому ищем по меткам, а не по номеру строки
  PRIVATE_KEY=$(awk -F': *' 'tolower($1) ~ /private/        {print $2; exit}' <<<"$out" | tr -d '[:space:]')
  PUBLIC_KEY=$(awk -F': *'  'tolower($1) ~ /public|password/ {print $2; exit}' <<<"$out" | tr -d '[:space:]')
  [[ $PRIVATE_KEY =~ ^[A-Za-z0-9_-]{43}$ && $PUBLIC_KEY =~ ^[A-Za-z0-9_-]{43}$ ]] \
    || err "Не удалось разобрать вывод 'xray x25519':"$'\n'"$out"
  UUID=$(xray uuid)
  SHORT_ID=$(openssl rand -hex 8)
}

# ─── Конфиг ──────────────────────────────────────────────

write_config() {
  local tmp out
  log "Записываю конфиг..."
  # суффикс .json обязателен: по расширению xray определяет формат файла
  tmp=$(mktemp --suffix=.json -p "$XRAY_DIR" .config.XXXXXX)
  TMP_FILES+=("$tmp")
  jq -n \
    --argjson port "$PORT" --argjson api "$API_PORT" --arg sni "$SNI" --arg net "$TRANSPORT" \
    --arg pk "$PRIVATE_KEY" --arg sid "$SHORT_ID" --arg uuid "$UUID" '
    ($net == "tcp") as $tcp
    | {
        log: {loglevel: "warning", access: "none"},
        # gRPC API напрямую на loopback (без dokodemo-inbound и routing-правила) + статистика
        stats: {},
        api: {tag: "api", listen: "127.0.0.1:\($api)", services: ["HandlerService", "StatsService"]},
        policy: {
          levels: {"0": {statsUserUplink: true, statsUserDownlink: true}},
          system: {statsInboundUplink: true, statsInboundDownlink: true}
        },
        inbounds: [{
          tag: "vless-in",
          listen: "0.0.0.0",
          port: $port,
          protocol: "vless",
          settings: {
            clients: [{id: $uuid, email: "main"} + (if $tcp then {flow: "xtls-rprx-vision"} else {} end)],
            decryption: "none"
          },
          streamSettings: ({
            network: $net,
            security: "reality",
            realitySettings: {
              show: false,
              dest: "\($sni):443",
              serverNames: [$sni],
              privateKey: $pk,
              shortIds: [$sid]
            }
          } + (if $tcp then {} else {xhttpSettings: {path: "/", mode: "auto"}} end)),
          sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
        }],
        outbounds: [
          {protocol: "freedom", tag: "direct"},
          {protocol: "blackhole", tag: "block"}
        ],
        routing: {
          domainStrategy: "IPIfNonMatch",
          rules: [
            {type: "field", ip: ["geoip:private"], outboundTag: "block"},
            {type: "field", protocol: ["bittorrent"], outboundTag: "block"}
          ]
        }
      }' > "$tmp"
  out=$(xray run -test -config "$tmp" 2>&1) || err "Сгенерированный конфиг невалиден:"$'\n'"$out"
  chmod 640 "$tmp"
  chown "root:$(xray_group)" "$tmp"
  mv -f "$tmp" "$CONFIG"
}

# Значения экранируются через %q, поэтому последующий `source` безопасен
write_params() {
  local tmp k
  tmp=$(mktemp -p "$XRAY_DIR")
  TMP_FILES+=("$tmp")
  {
    echo "# Сгенерировано install-xray.sh $(date -Is). Читается xrayctl."
    for k in SERVER_ADDR PORT SNI TRANSPORT FINGERPRINT PUBLIC_KEY SHORT_ID; do
      [[ -n ${!k:-} ]] || err "Параметр $k пуст"
      printf '%s=%q\n' "$k" "${!k}"
    done
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$PARAMS"
}

# ─── Утилита управления ──────────────────────────────────

install_ctl() {
  local tmp n
  log "Устанавливаю xrayctl..."
  tmp=$(mktemp)
  TMP_FILES+=("$tmp")
  cat > "$tmp" <<'XRAYCTL'
#!/usr/bin/env bash
# xrayctl — управление пользователями VLESS + REALITY (ставится install-xray.sh)
#
# Пользователи добавляются и удаляются «на лету» через gRPC API Xray (xray api adu/rmu),
# без перезапуска и без обрыва чужих сессий. Конфиг на диске обновляется в любом случае,
# поэтому после рестарта/ребута всё на месте. Если API недоступен — откат на обычный рестарт.
set -Eeuo pipefail
umask 077
export LC_ALL=C.UTF-8   # длина строк считается в символах, а не в байтах (выравнивание кириллицы)

readonly XRAY_DIR=/usr/local/etc/xray
readonly CONFIG=$XRAY_DIR/config.json
readonly PARAMS=$XRAY_DIR/params.env
readonly BACKUP_DIR=$XRAY_DIR/backup
readonly KEEP_BACKUPS=20
readonly LOCK_FILE=/run/xrayctl.lock

# Первый VLESS-инбаунд; работает и с конфигами старых версий скрипта
readonly JQ_DEFS='
  def ib: .inbounds | map(.protocol) | index("vless");
  def clients: .inbounds[ib].settings.clients;
'

TMPS=()
LOCKED=''
CHANGED=0
BACKUP=''
API=''
TAG=''
trap 'if ((${#TMPS[@]})); then rm -f -- "${TMPS[@]}"; fi' EXIT

die() { echo "Ошибка: $*" >&2; exit 1; }

kv() {  # kv <ключ> <значение> — строка «ключ: значение» с выравниванием по символам
  local pad=$((18 - ${#1}))
  printf '%s%*s %s\n' "$1" "$((pad > 0 ? pad : 0))" '' "$2"
}

usage() {
  cat <<EOF
Использование: xrayctl <команда> [аргументы]

  list                   список пользователей
  add [имя]              добавить пользователя (без перезапуска Xray), показать ссылку и QR
  rm [-k] [№|имя|uuid]   удалить пользователя; -k — ещё и оборвать его активные сессии (рестарт)
  link [№|имя|uuid]      ссылка и QR для пользователя
  main                   ссылка основного пользователя
  stats [--reset]        трафик по пользователям с момента запуска Xray (--reset обнуляет счётчики)
  status                 состояние: unit, порт, API (код возврата 1, если unit или порт не в порядке)
  restart                перезапустить Xray с проверкой (сбросит все активные сессии)
  migrate                включить в существующем конфиге API, статистику и hardening (один рестарт)

Без аргумента add/rm/link спросят интерактивно. Не печатать QR: NOQR=1 xrayctl link 2
Старые команды userlist/newuser/rmuser/sharelink/mainuser работают как алиасы; harden = migrate.
EOF
}

load() {
  [[ $EUID -eq 0 ]] || die "запусти от root (sudo xrayctl ...)"
  [[ -f $CONFIG ]] || die "не найден $CONFIG — Xray не установлен"
  [[ -f $PARAMS ]] || die "не найден $PARAMS"
  # shellcheck source=/dev/null
  source "$PARAMS"
  SERVER_ADDR=${SERVER_ADDR:-${SERVER_IP:-}}   # совместимость со старым params.env
  local v
  for v in SERVER_ADDR PORT SNI TRANSPORT FINGERPRINT PUBLIC_KEY SHORT_ID; do
    [[ -n ${!v:-} ]] || die "в $PARAMS не задан $v"
  done
  jq -e "$JQ_DEFS ib != null" "$CONFIG" >/dev/null || die "в $CONFIG нет VLESS-инбаунда"
  load_api
}

# Адрес API и тег инбаунда берутся из самого конфига — единственный источник правды
load_api() {
  API=$(q '.api.listen // empty')
  TAG=$(q '.inbounds[ib].tag // empty')
}

# q <jq-фильтр> [аргументы jq] — запрос к конфигу
q() {
  local filter=$1
  shift
  jq -r "$@" "$JQ_DEFS $filter" "$CONFIG"
}

lock() {
  if [[ -n $LOCKED ]]; then return 0; fi
  exec 9>"$LOCK_FILE"
  flock -w 30 9 || die "конфиг сейчас меняет другой процесс"
  LOCKED=1
}

confirm() {
  local a=''
  read -rp "$1 [y/N]: " a || true
  [[ $a == [yYдД]* ]]
}

# resolve <№|имя|uuid> → UUID (пусто, если не найден)
resolve() {
  q '[clients[]] as $c
     | if ($k | test("^[0-9]+$"))
       then ($k | tonumber) as $n | select($n >= 1 and $n <= ($c | length)) | $c[$n - 1].id
       else first($c[] | select(.id == $k or .email == $k) | .id)
       end' --arg k "$1"
}

email_of() {
  q 'first(clients[] | select(.id == $id) | .email // $def)' --arg id "$1" --arg def "${2-User}"
}

# pick "<аргумент>" "<подсказка>" → UUID; без аргумента спрашивает интерактивно
pick() {
  local key=$1 id
  if [[ -z $key ]]; then
    [[ -t 0 ]] || die "не указан пользователь"
    cmd_list >&2
    read -rp "$2: " key
  fi
  id=$(resolve "$key")
  [[ -n $id ]] || die "пользователь '$key' не найден"
  printf '%s\n' "$id"
}

urlencode() { jq -rn --arg s "$1" '$s | @uri'; }

make_link() {  # make_link <uuid> <метка>
  local host=$SERVER_ADDR query
  if [[ $host == *:* ]]; then host="[$host]"; fi   # IPv6
  query="encryption=none&security=reality&sni=$SNI&fp=$FINGERPRINT&pbk=$PUBLIC_KEY&sid=$SHORT_ID"
  if [[ $TRANSPORT == tcp ]]; then
    query+="&flow=xtls-rprx-vision&type=tcp"
  else
    query+="&type=xhttp&path=%2F"
  fi
  printf 'vless://%s@%s:%s?%s#%s\n' "$1" "$host" "$PORT" "$query" "$(urlencode "$2")"
}

show_link() {  # show_link <uuid> <метка> <заголовок>
  local link
  link=$(make_link "$1" "$2")
  printf '\n════════════════════════════════════\n  %s\n════════════════════════════════════\n' "$3"
  printf 'Имя:  %s\nUUID: %s\n\nVLESS-ссылка:\n%s\n\n' "$2" "$1" "$link"
  if [[ ${NOQR:-0} != 1 ]]; then qrencode -t ANSIUTF8 "$link"; fi
}

# ─── Состояние сервиса ───────────────────────────────────

port_listening() { [[ -n $(ss -Htln "sport = :$PORT") ]]; }

healthy() {
  local _
  sleep 2
  for _ in 1 2 3 4 5; do
    if systemctl is-active --quiet xray && port_listening; then return 0; fi
    sleep 1
  done
  return 1
}

api_up() {
  [[ -n $API && -n $TAG ]] || return 1
  xray api inboundusercount -s "$API" -t 3 -tag="$TAG" >/dev/null 2>&1
}

api_count() {
  xray api inboundusercount -s "$API" -t 3 -tag="$TAG" 2>/dev/null | jq -r '.count // 0'
}

# ─── Изменение конфига ───────────────────────────────────

# apply_config <jq-фильтр> [аргументы jq] — только конфиг на диске, без рестарта:
# новый конфиг во временный файл → xray -test → бэкап → атомарная замена.
# CHANGED=1, если что-то изменилось; BACKUP — путь к копии прежнего конфига.
apply_config() {
  local filter=$1 newcfg out
  shift
  lock
  CHANGED=0
  newcfg=$(mktemp --suffix=.json -p "$XRAY_DIR" .config.XXXXXX)
  TMPS+=("$newcfg")
  jq "$@" "$JQ_DEFS $filter" "$CONFIG" > "$newcfg"
  if jq -e --slurpfile old "$CONFIG" '. == $old[0]' "$newcfg" >/dev/null; then return 0; fi
  out=$(xray run -test -config "$newcfg" 2>&1) \
    || die "новый конфиг не прошёл проверку, ничего не изменено:"$'\n'"$out"
  chown --reference="$CONFIG" "$newcfg"
  chmod --reference="$CONFIG" "$newcfg"
  install -d -m 700 "$BACKUP_DIR"
  BACKUP="$BACKUP_DIR/config.$(date +%Y%m%d-%H%M%S).$$.json"
  cp -p "$CONFIG" "$BACKUP"
  mv -f "$newcfg" "$CONFIG"
  CHANGED=1
  find "$BACKUP_DIR" -maxdepth 1 -name 'config.*.json' ! -name 'config.pre-reinstall.*' -printf '%T@ %p\n' \
    | sort -rn | tail -n +$((KEEP_BACKUPS + 1)) | cut -d' ' -f2- | xargs -r rm -f --
}

# Рестарт с проверкой; если Xray не поднялся — возвращаем прежний конфиг и падаем
restart_or_rollback() {
  systemctl restart xray || true
  if healthy; then return 0; fi
  journalctl -u xray -n 20 --no-pager >&2 || true
  if [[ -n $BACKUP ]]; then
    cp -p "$BACKUP" "$CONFIG"
    systemctl restart xray || true
    die "Xray не поднялся с новым конфигом — восстановлен $BACKUP"
  fi
  die "Xray не поднялся"
}

# ─── Горячее обновление пользователей через API ──────────
# ВАЖНО: `xray api adu/rmu` возвращают код 0 даже при провале («Added 0 user(s)»),
# поэтому результат всегда проверяется отдельным запросом inbounduser.

runtime_user() {  # runtime_user <email> → JSON ответа inbounduser
  xray api inbounduser -s "$API" -t 5 -tag="$TAG" -email="$1" 2>/dev/null
}

runtime_add() {  # runtime_add <uuid> <email> <flow|''>
  local f
  [[ -n $API && -n $TAG ]] || return 1
  f=$(mktemp)
  TMPS+=("$f")
  # port нужен только парсеру xray (адреса/порты adu не использует)
  jq -n --arg tag "$TAG" --argjson port "$PORT" --arg id "$1" --arg email "$2" --arg flow "$3" '
    {inbounds: [{tag: $tag, port: $port, protocol: "vless",
      settings: {clients: [{id: $id, email: $email} + (if $flow == "" then {} else {flow: $flow} end)],
                 decryption: "none"}}]}' > "$f"
  xray api adu -s "$API" -t 5 "$f" >/dev/null 2>&1 || true
  runtime_user "$2" | jq -e --arg id "$1" '.users[0].account.id == $id' >/dev/null
}

runtime_rm() {  # runtime_rm <email>
  local out
  [[ -n $API && -n $TAG && -n ${1:-} ]] || return 1
  xray api rmu -s "$API" -t 5 -tag="$TAG" "$1" >/dev/null 2>&1 || true
  out=$(runtime_user "$1") || return 1
  jq -e '(.users[0].email // "") == ""' <<<"$out" >/dev/null
}

# ─── Команды ─────────────────────────────────────────────

cmd_list() {
  local n id email
  echo
  printf '  %-3s  %-36s  %s\n' '#' 'UUID' 'Имя'
  while IFS=$'\t' read -r n id email; do
    printf '  %-3s  %-36s  %s\n' "$n" "$id" "$email"
  done < <(q 'clients | to_entries[] | [(.key + 1 | tostring), .value.id, (.value.email // "-")] | @tsv')
  printf '\n  Всего: %s\n\n' "$(q 'clients | length')"
}

cmd_add() {
  local name=${1:-} id flow='' how
  # 1–32 символа; без пробелов, кавычек, '\', '>' (разделитель имён статистики) и '-' в начале
  local re='^[^[:space:][:cntrl:]"\\>-][^[:space:][:cntrl:]"\\>]{0,31}$'
  if [[ -z $name ]]; then
    [[ -t 0 ]] || die "укажи имя: xrayctl add <имя>"
    read -rp "Имя пользователя (без пробелов): " name
  fi
  [[ $name =~ $re ]] || die "имя: 1–32 символа, без пробелов, кавычек, '\\', '>' и без '-' в начале"
  [[ ! $name =~ ^[0-9]+$ ]] || die "имя не может состоять только из цифр (путается с номером)"
  lock
  [[ -z $(resolve "$name") ]] || die "пользователь '$name' уже существует"
  id=$(xray uuid)
  if [[ $TRANSPORT == tcp ]]; then flow=xtls-rprx-vision; fi
  apply_config 'clients += [{id: $id, email: $email} + (if $flow == "" then {} else {flow: $flow} end)]' \
    --arg id "$id" --arg email "$name" --arg flow "$flow"
  if runtime_add "$id" "$name" "$flow"; then
    how="добавлен без перезапуска Xray"
  else
    echo "API не принял пользователя — перезапускаю Xray" >&2
    restart_or_rollback
    how="добавлен, Xray перезапущен"
  fi
  show_link "$id" "$name" "Пользователь $how"
}

cmd_rm() {
  local key='' kick=0 a id name
  for a in "$@"; do
    case $a in
      -k | --kick) kick=1 ;;
      *) key=$a ;;
    esac
  done
  lock
  id=$(pick "$key" "Номер, имя или UUID для удаления")
  name=$(email_of "$id" "")
  (($(q 'clients | length') > 1)) || die "нельзя удалить последнего пользователя"
  if [[ -z $key ]] && ! confirm "Удалить '${name:-$id}' ($id)?"; then
    echo "Отменено"
    return 0
  fi
  apply_config 'clients |= map(select(.id != $id))' --arg id "$id"
  if ((kick)); then
    restart_or_rollback
    echo "Удалён: ${name:-$id}. Xray перезапущен — все активные сессии сброшены."
  elif runtime_rm "$name"; then
    echo "Удалён без перезапуска: ${name:-$id}"
    echo "Внимание: новые подключения отклоняются, но уже открытые сессии работают до своего закрытия."
    echo "Оборвать их сейчас: xrayctl restart (сбросит сессии ВСЕХ пользователей)."
  else
    echo "API недоступен или у пользователя нет имени (старый формат) — перезапускаю Xray" >&2
    restart_or_rollback
    echo "Удалён: ${name:-$id}. Xray перезапущен."
  fi
}

cmd_link() {
  local id label
  id=$(pick "${1:-}" "Номер, имя или UUID")
  label=${2:-$(email_of "$id")}
  show_link "$id" "$label" "Ссылка для подключения"
}

cmd_main() {
  local id
  id=$(resolve main)
  if [[ -z $id ]]; then id=$(resolve 1); fi
  show_link "$id" "$(email_of "$id" MainUser)" "Основной пользователь"
}

cmd_stats() {
  local reset=() raw users
  case ${1:-} in
    -r | --reset) reset=(-reset) ;;
    '') ;;
    *) die "использование: xrayctl stats [--reset]" ;;
  esac
  [[ -n $API ]] || die "API не включён в конфиге — выполни: xrayctl migrate"
  raw=$(xray api statsquery -s "$API" -t 5 -pattern '>>>traffic>>>' ${reset[@]+"${reset[@]}"} 2>&1) \
    || die "API не отвечает: $raw"
  users=$(q '[clients[] | .email // .id]')
  echo
  jq -r --argjson users "$users" '
    def human:
      if . >= 1099511627776 then (. / 1099511627776 * 100 | round / 100 | tostring) + " TiB"
      elif . >= 1073741824 then (. / 1073741824 * 100 | round / 100 | tostring) + " GiB"
      elif . >= 1048576    then (. / 1048576 * 100 | round / 100 | tostring) + " MiB"
      elif . >= 1024       then (. / 1024 * 100 | round / 100 | tostring) + " KiB"
      else tostring + " B" end;
    def pad($n): . + (reduce range(0; ([$n - length, 0] | max)) as $_ (""; . + " "));
    def table:
      . as $t
      | ($t | transpose | map(map(length) | max)) as $w
      | $t[] | [range(0; length) as $i | .[$i] | pad($w[$i])] | join("  ");
    def total($s; $u; $d): [$s[] | select(.k == "user" and .n == $u and .d == $d) | .v] | add // 0;
    ([.stat[]? | (.name | split(">>>")) as $p
       | {k: $p[0], n: $p[1], d: $p[3], v: ((.value // 0) | tonumber)}]) as $s
    | ($users
       | map({u: ., up: total($s; .; "uplink"), down: total($s; .; "downlink")} | . + {sum: (.up + .down)})
       | sort_by(-.sum)) as $rows
    | ([["ПОЛЬЗОВАТЕЛЬ", "UPLOAD", "DOWNLOAD", "ВСЕГО"]]
        + [$rows[] | [.u, (.up | human), (.down | human), (.sum | human)]]
        + [["ИТОГО", ($rows | map(.up) | add // 0 | human), ($rows | map(.down) | add // 0 | human),
            ($rows | map(.sum) | add // 0 | human)]]) | table' <<<"$raw"
  echo
  if [[ ${reset[0]:-} == -reset ]]; then
    echo "Счётчики обнулены."
  else
    echo "Счётчики копятся с момента запуска Xray и обнуляются при его рестарте."
  fi
  echo
}

cmd_status() {
  local unit port_state rc=0 api_state cfg_n rt_n=''
  unit=$(systemctl is-active xray 2>/dev/null || true)
  [[ $unit == active ]] || rc=1
  if port_listening; then port_state='слушается'; else port_state='НЕ слушается'; rc=1; fi
  cfg_n=$(q 'clients | length')
  if api_up; then
    rt_n=$(api_count)
    api_state="отвечает ($API)"
  elif [[ -n $API ]]; then
    api_state="НЕ отвечает ($API)"
  else
    api_state='не включён — xrayctl migrate'
  fi
  echo
  kv 'Версия:' "$(xray version | sed -n 1p)"
  kv 'Unit xray:' "${unit:-неизвестно}"
  kv "Порт $PORT:" "$port_state"
  kv 'API:' "$api_state"
  kv 'Транспорт:' "$TRANSPORT, SNI $SNI, fp $FINGERPRINT"
  kv 'Пользователей:' "$cfg_n"
  if [[ -n $rt_n && $rt_n != "$cfg_n" ]]; then
    echo "Внимание: в работающем Xray пользователей $rt_n, в конфиге $cfg_n — выполни xrayctl restart"
  fi
  echo
  return "$rc"
}

cmd_restart() {
  lock
  BACKUP=''
  restart_or_rollback
  echo "Xray перезапущен, активные сессии сброшены."
}

# Приводит существующий конфиг к актуальному виду: имена (email) у всех пользователей,
# gRPC API на loopback, статистика по пользователям, блокировка приватных сетей и BitTorrent.
cmd_migrate() {
  local listen holder port=${API_PORT:-10085}
  listen=$(q '.api.listen // empty')
  if [[ -z $listen ]]; then
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) || die "некорректный API_PORT: $port"
    [[ $port != "$PORT" ]] || die "API_PORT совпадает с портом Xray"
    holder=$(ss -Htlnp "sport = :$port")
    if [[ -n $holder && $holder != *'"xray"'* ]]; then die "порт $port под API уже занят: задай другой через API_PORT=..."; fi
    listen="127.0.0.1:$port"
  fi
  apply_config '
    .inbounds[ib].tag //= "vless-in"
    | .inbounds[ib].settings.clients |= (
        . as $all
        | to_entries
        | map(.value + (
            if ((.value.email // "") | length) > 0 then {}
            else {email: (if .key == 0 and (($all | map(.email // "") | index("main")) == null)
                          then "main" else "user-" + .value.id[0:8] end)}
            end)))
    | .stats //= {}
    | .api = {tag: "api", listen: (.api.listen // $listen), services: ["HandlerService", "StatsService"]}
    | .policy.levels["0"].statsUserUplink = true
    | .policy.levels["0"].statsUserDownlink = true
    | .policy.system.statsInboundUplink = true
    | .policy.system.statsInboundDownlink = true
    | .log.access = "none"
    | .inbounds[ib].sniffing = {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
    | if any(.outbounds[]?; .tag == "block") then . else .outbounds += [{protocol: "blackhole", tag: "block"}] end
    | .routing.domainStrategy = "IPIfNonMatch"
    | .routing.rules = ($rules + ((.routing.rules // []) - $rules))' \
    --arg listen "$listen" \
    --argjson rules '[
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
    ]'
  load_api
  if ((CHANGED)) || ! api_up; then
    echo "Перезапускаю Xray (один раз, активные сессии переподключатся)..."
    restart_or_rollback
  else
    echo "Конфиг уже в нужном состоянии, перезапуск не нужен."
  fi
  api_up || die "API не отвечает на $API после миграции"
  echo "Готово: API $API, статистика по пользователям включена, приватные сети и BitTorrent закрыты."
}

case ${0##*/} in
  userlist)  set -- list "$@" ;;
  newuser)   set -- add "$@" ;;
  rmuser)    set -- rm "$@" ;;
  sharelink) set -- link "$@" ;;
  mainuser)  set -- main "$@" ;;
esac

cmd=${1:-help}
shift || true
case $cmd in
  list | ls)       load; cmd_list ;;
  add | new)       load; cmd_add "$@" ;;
  rm | del)        load; cmd_rm "$@" ;;
  link | share)    load; cmd_link "$@" ;;
  main)            load; cmd_main ;;
  stats)           load; cmd_stats "$@" ;;
  status)          load; cmd_status ;;
  restart)         load; cmd_restart ;;
  migrate | harden) load; cmd_migrate ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 1 ;;
esac
XRAYCTL
  install -m 755 -o root -g root "$tmp" "$CTL"
  for n in userlist mainuser newuser rmuser sharelink; do
    ln -sfn "$CTL" "/usr/local/bin/$n"
  done
}

# ─── Сценарии ────────────────────────────────────────────

fresh_install() {
  collect_params
  gen_keys
  backup_config
  write_config
  write_params
  secure_files
  install_ctl
  install_zabbix
  open_firewall
  enable_bbr
  start_xray

  printf '\n%s════════════════════════════════════%s\n' "$GREEN" "$NC"
  printf '%s       Установка завершена!%s\n' "$GREEN" "$NC"
  printf '%s════════════════════════════════════%s\n' "$GREEN" "$NC"
  printf 'Порт:       %s\nAPI:        127.0.0.1:%s (только loopback)\nSNI:        %s\nОтпечаток:  %s\nТранспорт:  %s\nPublic key: %s\nShort ID:   %s\n' \
    "$PORT" "$API_PORT" "$SNI" "$FINGERPRINT" "$TRANSPORT" "$PUBLIC_KEY" "$SHORT_ID"
  "$CTL" main
  printf '\nУправление: %sxrayctl list | add <имя> | rm [-k] <№|имя> | link <№|имя> | main | stats | status%s\n' "$CYAN" "$NC"
  printf 'Бэкапы конфига: %s\n' "$BACKUP_DIR"
}

upgrade() {
  local mig=${MIGRATE:-${HARDEN:-}}
  log "Режим обновления: конфиг, ключи и пользователи сохраняются"
  # shellcheck source=/dev/null
  source "$PARAMS"
  SERVER_ADDR=${SERVER_ADDR:-${SERVER_IP:-}}
  write_params   # приводим params.env к новому формату (экранирование, SERVER_ADDR)
  secure_files
  install_ctl
  install_zabbix
  if [[ -z $mig && -t 0 ]]; then
    confirm "Включить API управления, статистику трафика и hardening? Нужен один перезапуск Xray — сессии переподключатся" y \
      && mig=y || mig=n
  fi
  if [[ $mig == y ]]; then
    "$CTL" migrate
  else
    warn "Миграция конфига пропущена. Без неё add/rm делают рестарт Xray, а статистики нет. Позже: xrayctl migrate"
  fi
  systemctl enable xray >/dev/null 2>&1
  systemctl is-active --quiet xray || systemctl start xray
  health_check
  "$CTL" status
  log "Обновление завершено"
}

main() {
  local mode=install
  preflight
  if [[ -f $CONFIG && -f $PARAMS ]]; then
    if [[ ${FORCE_REINSTALL:-n} == y ]]; then
      mode=install
    elif [[ -t 0 ]]; then
      warn "Xray уже установлен этим скриптом."
      if confirm "Переустановить с нуля? Новые ключи — ВСЕ текущие ссылки перестанут работать" n; then
        mode=install
      else
        mode=upgrade
      fi
    else
      mode=upgrade
    fi
  fi

  install_deps
  install_xray

  if [[ $mode == upgrade ]]; then
    upgrade
  else
    fresh_install
  fi
}

main "$@"
