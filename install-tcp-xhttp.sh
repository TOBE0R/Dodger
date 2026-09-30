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
#   FORCE_REINSTALL=y            переустановить поверх существующей установки (ключи и ссылки сменятся)
#   HARDEN=y|n                   при обновлении применить hardening к существующему конфигу
#   SKIP_SNI_CHECK=y             не проверять SNI на TLS 1.3 + HTTP/2
#
# Повторный запуск без FORCE_REINSTALL безопасен: обновит Xray и утилиты, пользователей не тронет.

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

start_xray() {
  log "Запускаю Xray..."
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
  health_check
  log "Xray работает и слушает порт $PORT"
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

collect_params() {
  local holder detected=''

  ask PORT "Порт" 443
  [[ $PORT =~ ^[1-9][0-9]{0,4}$ ]] && ((PORT <= 65535)) || err "Некорректный порт: $PORT"
  holder=$(ss -Htlnp "sport = :$PORT")
  if [[ -n $holder && $holder != *'"xray"'* ]]; then
    err "Порт $PORT уже занят: $(awk '{print $NF}' <<<"$holder" | sort -u | paste -sd' ')"
  fi

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
    --argjson port "$PORT" --arg sni "$SNI" --arg net "$TRANSPORT" \
    --arg pk "$PRIVATE_KEY" --arg sid "$SHORT_ID" --arg uuid "$UUID" '
    ($net == "tcp") as $tcp
    | {
        log: {loglevel: "warning", access: "none"},
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
set -Eeuo pipefail
umask 077

readonly XRAY_DIR=/usr/local/etc/xray
readonly CONFIG=$XRAY_DIR/config.json
readonly PARAMS=$XRAY_DIR/params.env
readonly BACKUP_DIR=$XRAY_DIR/backup
readonly KEEP_BACKUPS=20
readonly LOCK_FILE=/run/xrayctl.lock

# Первый VLESS-инбаунд; работает и с конфигами старой версии скрипта (без tag)
readonly JQ_DEFS='
  def ib: .inbounds | map(.protocol) | index("vless");
  def clients: .inbounds[ib].settings.clients;
'

TMP=''
LOCKED=''
CHANGED=''
trap '[[ -z $TMP ]] || rm -f -- "$TMP"' EXIT

die() { echo "Ошибка: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Использование: xrayctl <команда> [аргументы]

  list                   список пользователей
  add [имя]              добавить пользователя, показать ссылку и QR
  rm [№|имя|uuid]        удалить пользователя
  link [№|имя|uuid]      ссылка и QR для пользователя
  main                   ссылка основного пользователя
  status                 состояние сервиса
  harden                 применить рекомендуемые настройки безопасности к текущему конфигу

Без аргумента add/rm/link спросят интерактивно.
Не печатать QR: NOQR=1 xrayctl link 2
Старые команды userlist/newuser/rmuser/sharelink/mainuser работают как алиасы.
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
  q 'first(clients[] | select(.id == $id) | .email // $def)' --arg id "$1" --arg def "${2:-User}"
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

healthy() {
  local _
  sleep 2
  for _ in 1 2 3 4 5; do
    if systemctl is-active --quiet xray && [[ -n $(ss -Htln "sport = :$PORT") ]]; then return 0; fi
    sleep 1
  done
  return 1
}

# apply <jq-фильтр> [аргументы jq] — транзакционное изменение конфига:
# новый конфиг во временный файл → xray -test → бэкап → атомарная замена → рестарт → откат при сбое
apply() {
  local filter=$1 out backup
  shift
  lock
  TMP=$(mktemp --suffix=.json -p "$XRAY_DIR" .config.XXXXXX)
  jq "$@" "$JQ_DEFS $filter" "$CONFIG" > "$TMP"
  if jq -e --slurpfile old "$CONFIG" '. == $old[0]' "$TMP" >/dev/null; then
    echo "Конфиг уже в нужном состоянии, изменений нет"
    return 0
  fi
  out=$(xray run -test -config "$TMP" 2>&1) \
    || die "новый конфиг не прошёл проверку, ничего не изменено:"$'\n'"$out"
  chown --reference="$CONFIG" "$TMP"
  chmod --reference="$CONFIG" "$TMP"
  install -d -m 700 "$BACKUP_DIR"
  backup="$BACKUP_DIR/config.$(date +%Y%m%d-%H%M%S).$$.json"
  cp -p "$CONFIG" "$backup"
  mv -f "$TMP" "$CONFIG"
  TMP=''
  systemctl restart xray || true
  if ! healthy; then
    journalctl -u xray -n 20 --no-pager >&2 || true
    cp -p "$backup" "$CONFIG"
    systemctl restart xray || true
    die "Xray не поднялся с новым конфигом — восстановлен $backup"
  fi
  find "$BACKUP_DIR" -maxdepth 1 -name 'config.*.json' ! -name 'config.pre-reinstall.*' -printf '%T@ %p\n' \
    | sort -rn | tail -n +$((KEEP_BACKUPS + 1)) | cut -d' ' -f2- | xargs -r rm -f --
  CHANGED=1
}

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
  local name=${1:-} id flow=''
  local re='^[^[:space:][:cntrl:]"\\]{1,32}$'
  if [[ -z $name ]]; then
    [[ -t 0 ]] || die "укажи имя: xrayctl add <имя>"
    read -rp "Имя пользователя (без пробелов): " name
  fi
  [[ $name =~ $re ]] || die "имя: 1–32 символа, без пробелов, кавычек и обратного слэша"
  [[ ! $name =~ ^[0-9]+$ ]] || die "имя не может состоять только из цифр (путается с номером)"
  lock
  [[ -z $(resolve "$name") ]] || die "пользователь '$name' уже существует"
  id=$(xray uuid)
  if [[ $TRANSPORT == tcp ]]; then flow=xtls-rprx-vision; fi
  apply 'clients += [{id: $id, email: $email} + (if $flow == "" then {} else {flow: $flow} end)]' \
    --arg id "$id" --arg email "$name" --arg flow "$flow"
  show_link "$id" "$name" "Пользователь добавлен"
}

cmd_rm() {
  local id name
  lock
  id=$(pick "${1:-}" "Номер, имя или UUID для удаления")
  name=$(email_of "$id" "-")
  (($(q 'clients | length') > 1)) || die "нельзя удалить последнего пользователя"
  if [[ -z ${1:-} ]] && ! confirm "Удалить '$name' ($id)?"; then
    echo "Отменено"
    return 0
  fi
  apply 'clients |= map(select(.id != $id))' --arg id "$id"
  echo "Удалён: $name ($id)"
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

cmd_status() {
  local listening='нет'
  if [[ -n $(ss -Htln "sport = :$PORT") ]]; then listening='да'; fi
  echo
  echo "Версия:        $(xray version | sed -n 1p)"
  echo "Сервис:        $(systemctl is-active xray || true)"
  echo "Порт $PORT:     слушается — $listening"
  echo "Транспорт:     $TRANSPORT, SNI $SNI, fp $FINGERPRINT"
  echo "Пользователей: $(q 'clients | length')"
  echo
}

cmd_harden() {
  apply '
    .log.access = "none"
    | .inbounds[ib].sniffing = {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
    | if any(.outbounds[]; .tag == "block") then . else .outbounds += [{protocol: "blackhole", tag: "block"}] end
    | .routing.domainStrategy = "IPIfNonMatch"
    | .routing.rules = ($rules + ((.routing.rules // []) - $rules))' \
    --argjson rules '[
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
    ]'
  if [[ -n $CHANGED ]]; then
    echo "Hardening применён: приватные сети сервера и BitTorrent закрыты, access-лог выключен"
  fi
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
  list | ls)    load; cmd_list ;;
  add | new)    load; cmd_add "$@" ;;
  rm | del)     load; cmd_rm "$@" ;;
  link | share) load; cmd_link "$@" ;;
  main)         load; cmd_main ;;
  status)       load; cmd_status ;;
  harden)       load; cmd_harden ;;
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
  open_firewall
  enable_bbr
  start_xray

  printf '\n%s════════════════════════════════════%s\n' "$GREEN" "$NC"
  printf '%s       Установка завершена!%s\n' "$GREEN" "$NC"
  printf '%s════════════════════════════════════%s\n' "$GREEN" "$NC"
  printf 'Порт:       %s\nSNI:        %s\nОтпечаток:  %s\nТранспорт:  %s\nPublic key: %s\nShort ID:   %s\n' \
    "$PORT" "$SNI" "$FINGERPRINT" "$TRANSPORT" "$PUBLIC_KEY" "$SHORT_ID"
  "$CTL" main
  printf '\nУправление: %sxrayctl list | add <имя> | rm <№|имя> | link <№|имя> | main | status%s\n' "$CYAN" "$NC"
  printf 'Бэкапы конфига: %s\n' "$BACKUP_DIR"
}

upgrade() {
  log "Режим обновления: конфиг, ключи и пользователи сохраняются"
  # shellcheck source=/dev/null
  source "$PARAMS"
  SERVER_ADDR=${SERVER_ADDR:-${SERVER_IP:-}}
  write_params   # приводим params.env к новому формату (экранирование, SERVER_ADDR)
  secure_files
  install_ctl
  if [[ ${HARDEN:-} == y ]] \
    || { [[ -z ${HARDEN:-} ]] && confirm "Применить hardening (закрыть приватные сети и BitTorrent, выключить access-лог)?" y; }; then
    "$CTL" harden
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
