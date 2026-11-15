#!/usr/bin/env bash
#
# dv3.1 — установщик Xray VLESS + REALITY (TCP/Vision или XHTTP) для Debian/Ubuntu
#         с управлением пользователями в духе 3x-ui: лимиты трафика, сроки, онлайн-статус
#
# Одной командой (вопросы задаются в терминале, в том числе при запуске через пайп):
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/dv3.1.sh | sudo bash
#   wget -qO- https://raw.githubusercontent.com/<owner>/<repo>/main/dv3.1.sh | sudo bash
#
# Из скачанного файла:
#   sudo bash dv3.1.sh
#
# Без вопросов (Ansible / cloud-init / CI):
#   curl -fsSL <URL> | sudo env SNI=site.example PORT=443 TRANSPORT=xhttp FINGERPRINT=chrome ENABLE_BBR=y bash
#
# Необязательные переменные окружения:
#   XRAY_VERSION=v26.11.9        зафиксировать версию Xray (по умолчанию — последняя)
#   SERVER_ADDR=vpn.example.com  адрес в ссылках (по умолчанию — внешний IPv4)
#   API_PORT=10085               порт gRPC API Xray (слушает только 127.0.0.1)
#   TRANSPORT=tcp+xhttp          транспорты: tcp+xhttp (оба на одном порту) | tcp | xhttp
#   XHTTP_PATH=/api/v2/sync/ab12 путь XHTTP (по умолчанию генерируется правдоподобный)
#   XHTTP_MODE=stream-one        режим XHTTP в ссылках: stream-one | stream-up | packet-up | auto
#   XHTTP_EXTRA=default          пресет XHTTP Extra в ссылках: default | single | rotate | <JSON>
#   BLOCK_RU=y|n                 не выпускать VPN-трафик на российские домены и IP (по умолчанию y)
#   UPGRADE_OS=y|n               обновить систему (apt full-upgrade) перед установкой; в терминале
#                                задаётся вопрос (по умолчанию y), без терминала — только при UPGRADE_OS=y
#   FORCE_REINSTALL=y            переустановить поверх существующей установки (ключи и ссылки сменятся)
#   SKIP_SNI_CHECK=y             не проверять SNI (TLS 1.3 + HTTP/2, CDN, чужие сайты)
#   CHECK_URL=https://...        адрес для сквозной самопроверки (по умолчанию gstatic generate_204)
#
# Модули:
#   система        — обновление ОС, зависимости (ожидание занятого apt), BBR, UFW
#   Xray           — официальный установщик, VLESS + REALITY: TCP (Vision) и/или XHTTP на одном порту,
#                    проверка SNI, API на 127.0.0.1
#   xrayctl        — утилита управления (sudo xrayctl help):
#                    пользователи (add/rm/link/set/enable/disable/reset), таблица и онлайн,
#                    лимиты/сроки/ежемесячный сброс (таймер раз в минуту), транспорты (add/rm без
#                    переустановки), замер «TCP или XHTTP» (bench + dv-bench.ps1), XHTTP, блок RU,
#                    SNI, самопроверка check
#
# Повторный запуск без FORCE_REINSTALL безопасен: обновит Xray и утилиты, пользователей не тронет.
# Обновление поддерживается для серверов, поставленных версиями dv2.x и dv3.x.
#
# Безопасность API: gRPC API Xray не имеет аутентификации и слушает 127.0.0.1. Единственное, что
# не пускает через него VPN-клиентов, — правило routing «geoip:private → block» в конфиге.
# Не удаляй его: без него любой клиент сможет дойти до 127.0.0.1:API и добавлять пользователей.

set -Eeuo pipefail
umask 077

readonly XRAY_DIR=/usr/local/etc/xray
readonly CONFIG=$XRAY_DIR/config.json
readonly PARAMS=$XRAY_DIR/params.env
readonly DB=$XRAY_DIR/users.json
readonly BACKUP_DIR=$XRAY_DIR/backup
readonly CTL=/usr/local/bin/xrayctl
readonly UNIT_DIR=/etc/systemd/system
readonly INSTALLER_URL=https://github.com/XTLS/Xray-install/raw/main/install-release.sh
readonly FINGERPRINTS=(chrome firefox safari edge ios android random)
readonly TRANSPORT_CHOICES=(tcp+xhttp tcp xhttp)
readonly XHTTP_MODES=(stream-one stream-up packet-up auto)
readonly SCRIPT_VERSION=dv3.1

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

# Откуда читать ответы. При запуске `curl ... | bash` stdin — это сам скрипт, поэтому
# вопросы задаются через терминал (/dev/tty). Терминала нет (cloud-init, CI) — работаем
# без вопросов: значения берутся из переменных окружения или по умолчанию.
TTY=''
if [[ -t 0 ]]; then
  TTY=/dev/stdin
elif { : </dev/tty; } 2>/dev/null; then
  TTY=/dev/tty
fi

# ask VAR "вопрос" [default] — значение из окружения важнее; без терминала берётся default
ask() {
  local __var=$1 __prompt=$2 __def=${3:-} __val=''
  if [[ -n ${!__var:-} ]]; then return 0; fi
  if [[ -n $TTY ]]; then read -rp "$__prompt${__def:+ [$__def]}: " __val <"$TTY" || true; fi
  printf -v "$__var" '%s' "${__val:-$__def}"
}

# confirm "вопрос" [y|n] — без терминала возвращает default
confirm() {
  local def=${2:-n} hint='y/N' a=''
  if [[ $def == y ]]; then hint='Y/n'; fi
  if [[ -n $TTY ]]; then read -rp "$1 [$hint]: " a <"$TTY" || true; fi
  [[ ${a:-$def} == [yYдД]* ]]
}

# choose VAR "заголовок" вариант1 вариант2 ... — первый вариант по умолчанию
choose() {
  local __var=$1 __title=$2 __n='' __i __o
  shift 2
  local -a __opts=("$@")
  if [[ -z ${!__var:-} ]]; then
    if [[ -n $TTY ]]; then
      printf '\n%s:\n' "$__title"
      for __i in "${!__opts[@]}"; do printf '  %d) %s\n' $((__i + 1)) "${__opts[__i]}"; done
      read -rp "Выбор [1]: " __n <"$TTY" || true
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

# ─── Система ─────────────────────────────────────────────

preflight() {
  [[ $EUID -eq 0 ]] || err "Запусти от root"
  command -v apt-get >/dev/null || err "Поддерживаются только Debian/Ubuntu (нужен apt-get)"
  command -v systemctl >/dev/null || err "Нужен systemd"
}

# apt_run <аргументы apt-get> — с ожиданием, если apt занят другим процессом (на свежем VPS это
# автообновления или установка в соседнем окне). install ждёт сам (DPkg::Lock::Timeout),
# update эту опцию игнорирует — поэтому повторяем, пока блокировка не освободится (до 15 минут).
apt_run() {
  local out pid _ said=0
  for _ in $(seq 180); do
    if out=$(apt-get -o DPkg::Lock::Timeout=60 "$@" 2>&1 >/dev/null); then return 0; fi
    if [[ $out != *'Could not get lock'* && $out != *'Unable to acquire'* ]]; then
      printf '%s\n' "$out" >&2
      err "apt-get $1 завершился с ошибкой (вывод выше)"
    fi
    pid=$(grep -o 'held by process [0-9]*' <<<"$out" | grep -o '[0-9]*$' | head -n 1) || true
    if ((said == 0)); then
      warn "apt занят другим процессом${pid:+: $(ps -o etime=,cmd= -p "$pid" 2>/dev/null | sed 's/^ *//')}. Жду, пока освободится..."
    elif ((said == 24)); then
      warn "apt занят уже больше 2 минут. Если это установка в другом окне — проверь, не ждёт ли она"
      warn "ответа (на Ubuntu часто висит окно needrestart: нажми там Enter). Процессы apt не убивай через kill -9."
    fi
    said=$((said + 1))
    sleep 5
  done
  err "apt занят больше 15 минут. Посмотри: ps -ef --forest | grep -B2 -A4 [a]pt — и запусти скрипт снова"
}

# Обновление системы перед установкой: apt full-upgrade + autoremove. Изменённые руками конфиги
# пакетов сохраняются (--force-confold). Сервер сам не перезагружается — только предупреждаем.
upgrade_os() {
  local def=n n
  if [[ -n $TTY ]]; then def=y; fi
  ask UPGRADE_OS "Обновить систему перед установкой (apt full-upgrade, может занять несколько минут)? (y/n)" "$def"
  [[ $UPGRADE_OS == [yYдД]* ]] || { log "Обновление системы пропущено"; return 0; }
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  log "Обновляю списки пакетов..."
  apt_run update -qq
  n=$(apt-get -s -o Debug::NoLocking=true full-upgrade 2>/dev/null | grep -c '^Inst ') || true
  if ((n == 0)); then
    log "Система уже обновлена"
  else
    log "Обновляю систему: пакетов к обновлению — $n. Это может занять несколько минут..."
    apt_run full-upgrade -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
    apt_run autoremove -y -qq
    log "Система обновлена"
  fi
  reboot_notice
}

reboot_notice() {
  [[ -f /var/run/reboot-required ]] || return 0
  warn "После обновления системы нужна перезагрузка (обновилось ядро или системные библиотеки)."
  warn "Выполни после завершения скрипта: sudo reboot — Xray запустится сам."
}

install_deps() {
  log "Устанавливаю зависимости..."
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt_run update -qq
  apt_run install -y -qq --no-install-recommends \
    curl ca-certificates jq qrencode openssl iproute2 unzip util-linux
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

# ─── Службы systemd ──────────────────────────────────────
# 1) Таймер xray-dv раз в минуту вызывает «xrayctl tick»: переносит счётчики трафика из Xray в базу
#    пользователей, отмечает онлайн, отключает исчерпавших лимит и просроченных, делает ежемесячный
#    сброс трафика. 2) Перед остановкой Xray (рестарт, перезагрузка) systemd вызывает «xrayctl flush»,
#    чтобы не потерять трафик с последней минуты. «+» — запуск от root.
install_units() {
  local d=$UNIT_DIR/xray.service.d
  install -d -m 755 "$d"
  printf '# %s: сохранять счётчики трафика перед остановкой Xray\n[Service]\nExecStop=+%s flush\n' \
    "$SCRIPT_VERSION" "$CTL" > "$d/20-dv-traffic.conf"
  cat > "$UNIT_DIR/xray-dv.service" <<EOF
# $SCRIPT_VERSION: учёт трафика, лимиты и сроки пользователей Xray
[Unit]
Description=xrayctl tick: трафик, лимиты и сроки пользователей Xray
After=xray.service

[Service]
Type=oneshot
ExecStart=$CTL tick
EOF
  cat > "$UNIT_DIR/xray-dv.timer" <<EOF
# $SCRIPT_VERSION: раз в минуту запускает xray-dv.service
[Unit]
Description=xrayctl tick раз в минуту

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$d/20-dv-traffic.conf" "$UNIT_DIR/xray-dv.service" "$UNIT_DIR/xray-dv.timer"
  systemctl daemon-reload
  systemctl enable --now xray-dv.timer >/dev/null 2>&1 || warn "Не удалось включить таймер xray-dv.timer"
}

# Хвосты прежних версий: ключи Zabbix (dv2.0–2.3) и старые команды-алиасы (до dv3.1)
cleanup_legacy() {
  local f u n zbx=0
  for f in /etc/zabbix/zabbix_agentd.d/userparameter_xray.conf /etc/zabbix/zabbix_agent2.d/userparameter_xray.conf; do
    if [[ -f $f ]] && grep -q 'xray.unit.active' "$f"; then rm -f "$f"; zbx=1; fi
  done
  if ((zbx)); then
    for u in zabbix-agent zabbix-agent2; do
      if systemctl is-active --quiet "$u"; then systemctl restart "$u" || true; fi
    done
    log "Удалены ключи Zabbix прежних версий скрипта"
  fi
  for n in userlist mainuser newuser rmuser sharelink; do
    if [[ -L /usr/local/bin/$n && $(readlink "/usr/local/bin/$n") == "$CTL" ]]; then rm -f "/usr/local/bin/$n"; fi
  done
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

# check_port_free <порт> <название>: порт свободен или занят самим xray (переустановка)
check_port_free() {
  local holder
  [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (($1 <= 65535)) || err "Некорректный порт ($2): $1"
  holder=$(ss -Htlnp "sport = :$1")
  if [[ -n $holder && $holder != *'"xray"'* ]]; then
    err "Порт $1 ($2) уже занят: $(awk '{print $NF}' <<<"$holder" | sort -u | paste -sd' ')"
  fi
}

# Проверку SNI, генерацию пути XHTTP и пресеты Extra выполняет xrayctl — одна реализация на всё
collect_params() {
  local detected='' probs

  ask PORT "Порт" 443
  check_port_free "$PORT" "Xray"
  API_PORT=${API_PORT:-10085}
  check_port_free "$API_PORT" "API"
  [[ $API_PORT != "$PORT" ]] || err "API_PORT не может совпадать с PORT"

  # SNI: спрашиваем, пока сайт не пройдёт проверку или пользователь явно не согласится на проблемный
  while :; do
    ask SNI "SNI (чужой сайт с TLS 1.3 + HTTP/2, не за CDN: не google.com, не сайты на Cloudflare)" ""
    [[ -n $SNI ]] || err "SNI обязателен (для запуска без вопросов задай SNI=домен)"
    SNI=${SNI,,}
    [[ $SNI =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || err "Некорректный домен: $SNI"
    if [[ ${SKIP_SNI_CHECK:-n} == y ]]; then break; fi
    log "Проверяю $SNI: TLS 1.3 + HTTP/2, CDN, чужие сайты..."
    probs=$("$CTL" _sni-problems "$SNI")
    if [[ -z $probs ]]; then
      log "SNI $SNI подходит"
      break
    fi
    warn "У сайта $SNI есть проблемы:"
    sed 's/^/      - /' <<<"$probs" >&2
    if [[ -z $TTY ]]; then
      err "SNI не прошёл проверку. Выбери другой сайт или отключи проверку: SKIP_SNI_CHECK=y"
    fi
    if confirm "Всё равно использовать $SNI? (n — ввести другой)" n; then break; fi
    SNI=''
  done

  choose FINGERPRINT "TLS-отпечаток клиента (fp)" "${FINGERPRINTS[@]}"
  case ${TRANSPORT:-} in both | xhttp+tcp | 'tcp xhttp') TRANSPORT=tcp+xhttp ;; esac
  choose TRANSPORT "Транспорт (tcp+xhttp — оба на одном порту: замерь, что лучше в твоей сети, и оставь нужный)" \
    "${TRANSPORT_CHOICES[@]}"
  if [[ $TRANSPORT == *xhttp* ]]; then
    XHTTP_PATH=${XHTTP_PATH:-$("$CTL" _gen-path)}
    [[ $XHTTP_PATH =~ ^/[A-Za-z0-9._~/-]{0,120}$ && $XHTTP_PATH != *//* ]] \
      || err "Некорректный XHTTP_PATH '$XHTTP_PATH': начинается с /, только латиница, цифры и . _ ~ - /, без ? и //"
    # Сервер всегда принимает все режимы (mode: auto); здесь выбирается режим для ссылок клиентов
    choose XHTTP_MODE "Режим XHTTP в ссылках (stream-one — оптимум для REALITY без CDN, сервер принимает все)" \
      "${XHTTP_MODES[@]}"
    XHTTP_EXTRA=${XHTTP_EXTRA:-default}
    "$CTL" _extra-json "$XHTTP_EXTRA" >/dev/null || err "XHTTP_EXTRA: ожидается default | single | rotate или JSON-объект"
  fi

  ask BLOCK_RU "Не выпускать VPN-трафик на российские сайты и IP (.ru/.su/.рф, RU-сервисы, geoip:ru)? (y/n)" y
  if [[ $BLOCK_RU == [yYдД]* ]]; then BLOCK_RU=y; else BLOCK_RU=n; fi

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

# Перед переустановкой: конфиг и базу пользователей — в бэкап, базу — убрать (ключи будут новые)
backup_old() {
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  install -d -m 700 "$BACKUP_DIR"
  if [[ -s $CONFIG ]]; then cp -p "$CONFIG" "$BACKUP_DIR/config.pre-reinstall.$ts.json"; log "Предыдущий конфиг сохранён в $BACKUP_DIR"; fi
  if [[ -s $DB ]]; then mv -f "$DB" "$BACKUP_DIR/users.pre-reinstall.$ts.json"; fi
  rm -f "$XRAY_DIR/traffic.json"
}

write_config() {
  local tmp out ru='[]' t=false x=false
  if [[ $TRANSPORT == *tcp* ]]; then t=true; fi
  if [[ $TRANSPORT == *xhttp* ]]; then x=true; fi
  log "Записываю конфиг..."
  if [[ $BLOCK_RU == y ]]; then ru=$("$CTL" _ru-rules); fi
  # суффикс .json обязателен: по расширению xray определяет формат файла
  tmp=$(mktemp --suffix=.json -p "$XRAY_DIR" .config.XXXXXX)
  TMP_FILES+=("$tmp")
  # Базовый конфиг с TCP-инбаундом; набор транспортов собирает xrayctl _render — та же функция,
  # что и в «xrayctl transport add/rm»
  jq -n \
    --argjson port "$PORT" --argjson api "$API_PORT" --arg sni "$SNI" \
    --arg pk "$PRIVATE_KEY" --arg sid "$SHORT_ID" --arg uuid "$UUID" \
    --argjson ru "$ru" '
    {
        log: {loglevel: "warning", access: "none"},
        # gRPC API напрямую на loopback + статистика трафика и онлайна по пользователям
        stats: {},
        api: {tag: "api", listen: "127.0.0.1:\($api)", services: ["HandlerService", "StatsService"]},
        policy: {
          levels: {"0": {statsUserUplink: true, statsUserDownlink: true, statsUserOnline: true}},
          system: {statsInboundUplink: true, statsInboundDownlink: true}
        },
        inbounds: [{
          tag: "vless-in",
          listen: "0.0.0.0",
          port: $port,
          protocol: "vless",
          settings: {clients: [{id: $uuid, email: "main"}], decryption: "none"},
          streamSettings: {
            network: "tcp",
            security: "reality",
            realitySettings: {
              show: false,
              dest: "\($sni):443",
              serverNames: [$sni],
              privateKey: $pk,
              shortIds: [$sid]
            }
          },
          sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}
        }],
        outbounds: [
          {protocol: "freedom", tag: "direct"},
          {protocol: "blackhole", tag: "block"}
        ],
        routing: {
          domainStrategy: "IPIfNonMatch",
          rules: ([{type: "field", ip: ["geoip:private"], outboundTag: "block"}]
            + $ru
            + [{type: "field", protocol: ["bittorrent"], outboundTag: "block"}])
        }
      }' | "$CTL" _render "$t" "$x" "${XHTTP_PATH:-/}" > "$tmp"
  out=$(xray run -test -config "$tmp" 2>&1) || err "Сгенерированный конфиг невалиден:"$'\n'"$out"
  chmod 640 "$tmp"
  chown "root:$(xray_group)" "$tmp"
  mv -f "$tmp" "$CONFIG"
}

# Значения экранируются через %q, поэтому последующий `source` безопасен
write_params() {
  local tmp k
  local -a keys=(SERVER_ADDR PORT SNI TRANSPORT FINGERPRINT PUBLIC_KEY SHORT_ID)
  if [[ $TRANSPORT == *xhttp* ]]; then keys+=(XHTTP_PATH XHTTP_MODE XHTTP_EXTRA); fi
  tmp=$(mktemp -p "$XRAY_DIR")
  TMP_FILES+=("$tmp")
  {
    echo "# Сгенерировано $SCRIPT_VERSION $(date -Is). Читается xrayctl."
    for k in "${keys[@]}"; do
      [[ -n ${!k:-} ]] || err "Параметр $k пуст"
      printf '%s=%q\n' "$k" "${!k}"
    done
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$PARAMS"
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
  local out
  log "Запускаю Xray..."
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
  health_check
  log "Xray работает и слушает порт $PORT"
  out=$(xray api inboundusercount -s "127.0.0.1:$API_PORT" -t 5 -tag=vless-in 2>&1) \
    || err "API Xray не отвечает на 127.0.0.1:$API_PORT:"$'\n'"$out"
  log "API Xray отвечает (127.0.0.1:$API_PORT), статистика по пользователям включена"
}

# ─── Утилита управления xrayctl ──────────────────────────

install_ctl() {
  local tmp
  tmp=$(mktemp)
  TMP_FILES+=("$tmp")
  cat > "$tmp" <<'XRAYCTL'
#!/usr/bin/env bash
# xrayctl — управление сервером Xray VLESS + REALITY (ставится установщиком dv3.1)
#
# Пользователи хранятся в базе users.json (лимит, срок, трафик, статус). В конфиге Xray — только
# включённые; включение и отключение идут «на лету» через gRPC API (xray api adu/rmu), без
# перезапуска Xray. Таймер xray-dv раз в минуту вызывает «xrayctl tick»: учёт трафика, онлайн,
# автоотключение по лимиту и сроку, ежемесячный сброс.
set -Eeuo pipefail
umask 077
export LC_ALL=C.UTF-8   # длина строк считается в символах, а не в байтах (выравнивание кириллицы)

readonly XRAY_DIR=/usr/local/etc/xray
readonly CONFIG=$XRAY_DIR/config.json
readonly PARAMS=$XRAY_DIR/params.env
readonly DB=$XRAY_DIR/users.json
readonly LEGACY_TRAFFIC=$XRAY_DIR/traffic.json   # учёт трафика dv2.4 — переносится в users.json
readonly BACKUP_DIR=$XRAY_DIR/backup
readonly KEEP_BACKUPS=20
readonly LOCK_FILE=/run/xrayctl.lock
readonly SCRIPT_VERSION=dv3.1
readonly ACTIVITY_BYTES=32768   # трафик за минуту, с которого пользователь считается активным
# Блок RU — два правила: в Xray условия domain и ip внутри ОДНОГО правила складываются через «И»
readonly RU_RULES='[
  {"type": "field", "ruleTag": "block-ru-domain", "outboundTag": "block",
   "domain": ["geosite:category-ru", "domain:ru", "domain:su", "domain:xn--p1ai"]},
  {"type": "field", "ruleTag": "block-ru-ip", "outboundTag": "block", "ip": ["geoip:ru"]}
]'
readonly XHTTP_MODES=(stream-one stream-up packet-up auto)
readonly XHTTP_PRESETS=(default single rotate)

# Инбаунды VLESS. Внешний — всегда «vless-in» (порт, REALITY). Схемы:
#   только tcp:   vless-in = TCP + REALITY + Vision
#   только xhttp: vless-in = XHTTP + REALITY
#   tcp + xhttp:  vless-in = TCP + REALITY + Vision; всё, что после REALITY не VLESS (то есть HTTP/2
#                 от XHTTP-клиента), уходит через fallback в «vless-xhttp» на сокете @vless-xhttp
#                 (PROXY protocol передаёт настоящий IP клиента). Ссылки при смене схемы не меняются.
readonly JQ_DEFS='
  def rin: .inbounds | map(.tag) | index("vless-in");
  def xin: (.inbounds | map(.tag) | index("vless-xhttp"))
           // (if .inbounds[rin].streamSettings.network == "xhttp" then rin else null end);
  def clients: .inbounds[rin].settings.clients;
'
# Пользователи во всех VLESS-инбаундах: в TCP — с flow Vision, в XHTTP — без
readonly CLIENTS_JQ='
  def set_clients($u):
    .inbounds |= map(if .protocol == "vless" then
      .settings.clients = (if .streamSettings.network == "xhttp" then $u else $u | map(. + {flow: "xtls-rprx-vision"}) end)
      else . end);
'
# Пересобрать VLESS-инбаунды под набор транспортов, сохранив порт, REALITY, сниффинг и пользователей
readonly RENDER_JQ='
  def render($tcp; $xhttp; $path):
    (.inbounds[rin]) as $r
    | {tag: "vless-in", listen: "0.0.0.0", port: $r.port, protocol: "vless", sniffing: $r.sniffing,
       settings: {clients: [], decryption: "none"}} as $base
    | {security: "reality", realitySettings: $r.streamSettings.realitySettings} as $sec
    | .inbounds = [.inbounds[] | select(.protocol != "vless")] + (
        if $tcp and $xhttp then
          [ ($base + {streamSettings: ({network: "tcp"} + $sec)}
             | .settings.fallbacks = [{dest: "@vless-xhttp", xver: 1}]),
            ({tag: "vless-xhttp", listen: "@vless-xhttp", protocol: "vless", sniffing: $r.sniffing,
              settings: {clients: [], decryption: "none"},
              streamSettings: {network: "xhttp", xhttpSettings: {path: $path, mode: "auto"},
                               sockopt: {acceptProxyProtocol: true}}}) ]
        elif $tcp then [$base + {streamSettings: ({network: "tcp"} + $sec)}]
        else [$base + {streamSettings: ({network: "xhttp"} + $sec + {xhttpSettings: {path: $path, mode: "auto"}})}]
        end)
    | set_clients($r.settings.clients | map({id, email}));
'

# Правила лимитов, применяются ко всем пользователям базы (tick и после любых изменений):
#  - ежемесячный сброс трафика в день reset_day;
#  - отключённые автоматически (лимит/срок) снова включаются, если причина ушла
#    (сброс, новый лимит, продление); отключённые вручную — только командой enable;
#  - исчерпан лимит → выкл (quota), истёк срок → выкл (expired).
readonly POLICY_JQ='
  def policy($now; $month; $day):
    .users |= map(
      (if .reset_day > 0 and $day >= .reset_day and .last_reset != $month
         then .up = 0 | .down = 0 | .last_reset = $month else . end)
      | (if (.enabled | not) and (.reason == "quota" or .reason == "expired")
           then .enabled = true | .reason = "" else . end)
      | (if .enabled and .quota > 0 and (.up + .down) >= .quota
           then .enabled = false | .reason = "quota" else . end)
      | (if .enabled and .expire > 0 and $now >= .expire
           then .enabled = false | .reason = "expired" else . end));
'

# Таблица пользователей в духе 3x-ui
readonly TABLE_JQ='
  def human:
    if . >= 1099511627776 then (. / 1099511627776 * 100 | round / 100 | tostring) + " ТБ"
    elif . >= 1073741824 then (. / 1073741824 * 100 | round / 100 | tostring) + " ГБ"
    elif . >= 1048576    then (. / 1048576 * 100 | round / 100 | tostring) + " МБ"
    elif . >= 1024       then (. / 1024 * 100 | round / 100 | tostring) + " КБ"
    else tostring + " Б" end;
  def pad($n): . + (reduce range(0; ([$n - length, 0] | max)) as $_ (""; . + " "));
  def table:
    . as $t
    | ($t | transpose | map(map(length) | max)) as $w
    | $t[] | [range(0; length) as $i | .[$i] | pad($w[$i])] | join("  ") | sub(" +$"; "");
  def ago:
    if . == 0 then "—"
    else ($now - .) as $d
      | if $d < 120 then "сейчас"
        elif $d < 3600 then "\($d / 60 | floor) мин назад"
        elif $d < 86400 then "\($d / 3600 | floor) ч назад"
        else "\($d / 86400 | floor) дн. назад" end
    end;
  def status:
    if .enabled then
      (if $on[.name] then "● онлайн" + (($on[.name] | length) as $k | if $k > 1 then " (\($k) IP)" else "" end)
       else "вкл" end)
    else "выкл: " + ({quota: "лимит", expired: "срок", manual: "вручную"}[.reason] // .reason) end;
  def usage:
    (.up + .down) as $t
    | ($t | human) + " / "
      + (if .quota > 0 then (.quota | human) + " (\([($t * 100 / .quota | floor), 100] | min)%)" else "∞" end)
      + (if .reset_day > 0 then " ↻\(.reset_day)" else "" end);
  def term:
    if .expire == 0 then "∞"
    else (.expire | strflocaltime("%d.%m.%Y")) as $dt
      | if .expire > $now then "до \($dt) (\((.expire - $now + 86399) / 86400 | floor) дн.)" else "истёк \($dt)" end
    end;
'

TMPS=()
LOCKED=''
CHANGED=0
RESTARTED=0
BACKUP=''
API=''
TAG=''
CHECK_PID=''
cleanup() {
  if [[ -n $CHECK_PID ]]; then kill "$CHECK_PID" 2>/dev/null || true; fi
  if ((${#TMPS[@]})); then rm -f -- "${TMPS[@]}"; fi
}
trap cleanup EXIT

die() { echo "Ошибка: $*" >&2; exit 1; }

kv() {  # kv <ключ> <значение> — строка «ключ: значение» с выравниванием по символам
  local pad=$((18 - ${#1}))
  printf '%s%*s %s\n' "$1" "$((pad > 0 ? pad : 0))" '' "$2"
}

usage() {
  cat <<EOF
Использование: sudo xrayctl <команда> [аргументы]
Пользователь задаётся номером из таблицы, именем или UUID.

Пользователи
  list                          таблица: статус, онлайн, трафик, лимит, срок, последняя активность
  add <имя> [опции]             добавить (без перезапуска Xray) и показать ссылку с QR
        --limit 50G               лимит трафика (отдача + загрузка), 0 — без лимита
        --days 30 | --expire ДАТА срок: дней от сегодня или дата ГГГГ-ММ-ДД (включительно)
        --reset-day 1             обнулять трафик каждый месяц этого числа (1–28)
  set <польз> limit <50G|0>     изменить лимит
  set <польз> expire <ДАТА|+30|0>  срок: дата, продлить на N дней (+30) или бессрочно (0)
  set <польз> days <N>          срок: N дней от сегодня
  set <польз> reset-day <1–28|0>  ежемесячный сброс трафика
  enable <польз> | disable <польз>  включить / отключить вручную
  reset <польз>|--all           обнулить трафик (вернёт отключённых за лимит)
  online                        кто подключён сейчас и с каких IP
  link <польз> | main           ссылки и QR (по одной на каждый включённый транспорт)
  rm [-k] <польз>               удалить; -k — ещё и оборвать его открытые сессии (рестарт)

Сервер
  status                        состояние: Xray, порт, транспорты, API, таймер
  transport [add|rm tcp|xhttp]  транспорты: TCP (Vision) и/или XHTTP на одном порту, без переустановки
  bench [польз]                 ссылки для замера «что лучше для моей сети» (dv-bench.ps1 на Windows)
  check                         самопроверка: подключиться ссылкой, как клиент, и выйти в интернет
  xhttp                         режим и Extra XHTTP, тестовые ссылки, путь (xrayctl xhttp help)
  sni [домен]                   проверить SNI или сменить его без переустановки
  ru [on|off]                   не выпускать VPN-трафик на российские домены и IP
  restart                       перезапустить Xray с проверкой (сбросит все сессии)
  version                       версия установщика и Xray

Лимиты и сроки проверяются раз в минуту (таймер xray-dv). Отключённый пользователь не может
открыть новое соединение; уже открытые доживают до закрытия — оборвать: xrayctl restart.
Не печатать QR: NOQR=1 xrayctl link 2
EOF
}

# ─── Загрузка и база ─────────────────────────────────────

load() {
  [[ $EUID -eq 0 ]] || die "запусти от root (sudo xrayctl ...)"
  [[ -f $CONFIG ]] || die "не найден $CONFIG — Xray не установлен"
  [[ -f $PARAMS ]] || die "не найден $PARAMS"
  # shellcheck source=/dev/null
  source "$PARAMS"
  local v
  for v in SERVER_ADDR PORT SNI TRANSPORT FINGERPRINT PUBLIC_KEY SHORT_ID; do
    [[ -n ${!v:-} ]] || die "в $PARAMS не задан $v — установка слишком старая, переустанови: FORCE_REINSTALL=y"
  done
  [[ $(q 'rin != null') == true ]] || die "в $CONFIG нет инбаунда vless-in — установка слишком старая, переустанови: FORCE_REINSTALL=y"
  load_transports
  API=$(q '.api.listen // empty')
  TAG=vless-in
  ensure_db
}

# Включённые транспорты определяются по самому конфигу — единственный источник правды
TRANSPORTS=()
HAS_TCP=0
HAS_XHTTP=0
load_transports() {
  TRANSPORTS=()
  HAS_TCP=0
  HAS_XHTTP=0
  if [[ $(q '.inbounds[rin].streamSettings.network // "tcp"') =~ ^(tcp|raw)$ ]]; then HAS_TCP=1; TRANSPORTS+=(tcp); fi
  if [[ $(q 'xin != null') == true ]]; then
    HAS_XHTTP=1
    TRANSPORTS+=(xhttp)
    XHTTP_PATH=${XHTTP_PATH:-$(q '.inbounds[xin].streamSettings.xhttpSettings.path // "/"')}
    XHTTP_MODE=${XHTTP_MODE:-stream-one}
    XHTTP_EXTRA=${XHTTP_EXTRA:-default}
  fi
  VLESS_TAGS=()
  mapfile -t VLESS_TAGS < <(q '.inbounds[] | select(.protocol == "vless") | .tag')
}

q() {  # q <jq-фильтр> [аргументы jq] — запрос к конфигу
  local filter=$1
  shift
  jq -r "$@" "$JQ_DEFS $filter" "$CONFIG"
}

dbq() {  # dbq <jq-фильтр> [аргументы jq] — запрос к базе пользователей
  local filter=$1
  shift
  jq -r "$@" "$filter" "$DB"
}

# db_write <jq-фильтр> [аргументы jq] — атомарное изменение базы под отдельной короткой блокировкой
# (её берёт и «flush» из ExecStop, поэтому она не может совпадать с блокировкой конфига)
db_write() {
  local filter=$1
  shift
  (
    flock -w 15 8 || exit 1
    tmp=$(mktemp -p "$XRAY_DIR" .users.XXXXXX)
    if jq "$@" "$filter" "$DB" > "$tmp"; then chmod 600 "$tmp"; mv -f "$tmp" "$DB"; else rm -f "$tmp"; exit 1; fi
  ) 8>"$XRAY_DIR/.users.lock" || die "не удалось записать $DB"
}

# База создаётся из конфига: при установке и при обновлении с dv2.x (с переносом трафика из traffic.json)
ensure_db() {
  [[ -s $DB ]] && return 0
  [[ $(q '[clients[] | select((.email // "") == "")] | length') == 0 ]] \
    || die "у пользователей в конфиге нет имён — установка слишком старая, переустанови: FORCE_REINSTALL=y"
  local legacy='{}'
  if [[ -s $LEGACY_TRAFFIC ]]; then legacy=$(jq -c . "$LEGACY_TRAFFIC" 2>/dev/null || echo '{}'); fi
  (
    flock -w 15 8 || exit 1
    [[ -s $DB ]] && exit 0
    tmp=$(mktemp -p "$XRAY_DIR" .users.XXXXXX)
    q '{since: ($l.since // (now | strflocaltime("%Y-%m-%d"))),
        users: [clients[] | {name: .email, id,
          up: ($l.users[.email].up // 0), down: ($l.users[.email].down // 0),
          quota: 0, expire: 0, enabled: true, reason: "", reset_day: 0, last_reset: "",
          created: (now | floor), last_online: 0}]}' -c --argjson l "$legacy" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$DB"
  ) 8>"$XRAY_DIR/.users.lock" || die "не удалось создать $DB"
  rm -f "$LEGACY_TRAFFIC"
}

lock() {
  if [[ -n $LOCKED ]]; then return 0; fi
  exec 9>"$LOCK_FILE"
  flock -w 30 9 || die "конфиг сейчас меняет другой процесс"
  LOCKED=1
}

lock_try() {  # для таймера: если занято командой пользователя — пропустить эту минуту
  exec 9>"$LOCK_FILE"
  flock -n 9 || return 1
  LOCKED=1
}

confirm() {
  local a=''
  read -rp "$1 [y/N]: " a || true
  [[ $a == [yYдД]* ]]
}

set_param() {  # set_param <ключ> <значение> — атомарно обновить params.env
  local tmp
  tmp=$(mktemp -p "$XRAY_DIR")
  TMPS+=("$tmp")
  grep -v "^$1=" "$PARAMS" > "$tmp" || true
  printf '%s=%q\n' "$1" "$2" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$PARAMS"
}

# ─── Пользователи: поиск и ссылки ────────────────────────

resolve() {  # resolve <№|имя|uuid> → имя (пусто, если нет)
  dbq '.users as $u
       | if ($k | test("^[0-9]+$"))
         then ($k | tonumber) as $n | select($n >= 1 and $n <= ($u | length)) | $u[$n - 1].name
         else first($u[] | select(.name == $k or .id == $k) | .name)
         end // empty' --arg k "$1"
}

pick() {  # pick "<аргумент>" "<подсказка>" → имя; без аргумента спрашивает интерактивно
  local key=$1 name
  if [[ -z $key ]]; then
    [[ -t 0 ]] || die "не указан пользователь"
    cmd_list >&2
    read -rp "$2: " key
  fi
  name=$(resolve "$key")
  [[ -n $name ]] || die "пользователь '$key' не найден"
  printf '%s\n' "$name"
}

user_field() { dbq 'first(.users[] | select(.name == $n)) | .[$f]' --arg n "$1" --arg f "$2"; }

main_user() {  # основной пользователь: main, иначе первый
  dbq 'first(.users[] | select(.name == "main")).name // .users[0].name // empty'
}

urlencode() { jq -rn --arg s "$1" '$s | @uri'; }

make_link() {  # make_link <uuid> <метка> <tcp|xhttp> [режим XHTTP] [пресет|JSON Extra]
  local host=$SERVER_ADDR query mode=${4:-${XHTTP_MODE:-}} extra
  if [[ $host == *:* ]]; then host="[$host]"; fi   # IPv6
  query="encryption=none&security=reality&sni=$SNI&fp=$FINGERPRINT&pbk=$PUBLIC_KEY&sid=$SHORT_ID"
  if [[ $3 == tcp ]]; then
    query+="&flow=xtls-rprx-vision&type=tcp"
  else
    query+="&type=xhttp&path=$(urlencode "$XHTTP_PATH")&mode=$mode"
    extra=$(extra_json "${5:-$XHTTP_EXTRA}")
    if [[ -n $extra ]]; then query+="&extra=$(urlencode "$extra")"; fi
  fi
  printf 'vless://%s@%s:%s?%s#%s\n' "$1" "$host" "$PORT" "$query" "$(urlencode "$2")"
}

tr_title() { if [[ $1 == tcp ]]; then echo "TCP (Vision)"; else echo "XHTTP ($XHTTP_MODE, Extra: $(extra_label "$XHTTP_EXTRA"))"; fi; }

show_link() {  # show_link <имя> <заголовок> — ссылка и QR на каждый включённый транспорт
  local id link tr label
  id=$(user_field "$1" id)
  printf '\n════════════════════════════════════\n  %s\n════════════════════════════════════\n' "$2"
  users_table "$1"
  printf '\nUUID: %s\n' "$id"
  if [[ $(user_field "$1" enabled) != true ]]; then
    printf '\nВнимание: пользователь отключён — ссылки заработают после включения (xrayctl enable %s).\n' "$1"
  fi
  for tr in "${TRANSPORTS[@]}"; do
    label=$1
    if ((${#TRANSPORTS[@]} > 1)); then label="$1 · $tr"; fi
    link=$(make_link "$id" "$label" "$tr")
    printf '\n%s:\n%s\n\n' "$(tr_title "$tr")" "$link"
    if [[ ${NOQR:-0} != 1 ]]; then qrencode -t ANSIUTF8 "$link"; fi
  done
}

# ─── Ввод размеров и дат ─────────────────────────────────

parse_size() {  # 50G, 1.5T, 500M, 50 (ГБ), 0 → байты
  local v=${1^^} num u p
  case $v in 0 | NONE | - | ∞) echo 0; return 0 ;; esac
  [[ $v =~ ^([0-9]+([.,][0-9]+)?)[[:space:]]*([KMGT]?)I?B?$ ]] \
    || die "размер '$1': например 50G, 500M, 1.5T или 0 (без лимита)"
  num=${BASH_REMATCH[1]/,/.}
  u=${BASH_REMATCH[3]}
  case $u in K) p=1 ;; M) p=2 ;; T) p=4 ;; *) p=3 ;; esac
  awk -v n="$num" -v p="$p" 'BEGIN { printf "%.0f\n", n * 1024 ^ p }'
}

parse_expire() {  # parse_expire <ДАТА|+N|0> [текущий срок] → epoch конца дня (0 — бессрочно)
  local v=$1 cur=${2:-0} now n base
  now=$(date +%s)
  case $v in
    0 | none | - | ∞) echo 0 ;;
    +[0-9]*)
      n=${v#+}; n=${n%d}
      [[ $n =~ ^[0-9]+$ ]] || die "продление: +N (дней), например +30"
      base=$((cur > now ? cur : now))
      echo $((base + n * 86400))
      ;;
    [0-9][0-9].[0-9][0-9].[0-9][0-9][0-9][0-9])
      date -d "${v:6:4}-${v:3:2}-${v:0:2} 23:59:59" +%s 2>/dev/null || die "дата '$v' некорректна" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
      date -d "$v 23:59:59" +%s 2>/dev/null || die "дата '$v' некорректна" ;;
    *) die "срок '$v': дата ГГГГ-ММ-ДД или ДД.ММ.ГГГГ, продление +N или 0 (бессрочно)" ;;
  esac
}

parse_days() {
  [[ $1 =~ ^[0-9]+$ ]] || die "дней: целое число"
  echo $(($(date +%s) + $1 * 86400))
}

parse_reset_day() {
  [[ $1 =~ ^[0-9]+$ ]] && (($1 <= 28)) || die "день сброса: 1–28 (0 — не сбрасывать)"
  echo "$1"
}

# ─── Состояние сервиса и API ─────────────────────────────

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

# ─── Изменение конфига ───────────────────────────────────

# apply_config <jq-фильтр> [аргументы jq] — только конфиг на диске, без рестарта:
# новый конфиг во временный файл → xray -test → бэкап → атомарная замена.
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
  traffic_flush
  systemctl restart xray || true
  RESTARTED=1
  if healthy; then return 0; fi
  journalctl -u xray -n 20 --no-pager >&2 || true
  if [[ -n $BACKUP ]]; then
    cp -p "$BACKUP" "$CONFIG"
    systemctl restart xray || true
    die "Xray не поднялся с новым конфигом — восстановлен $BACKUP"
  fi
  die "Xray не поднялся"
}

# ВАЖНО: `xray api adu/rmu` возвращают код 0 даже при провале («Added 0 user(s)»),
# поэтому результат всегда проверяется отдельным запросом inbounduser.
runtime_user() { xray api inbounduser -s "$API" -t 5 -tag="$2" -email="$1" 2>/dev/null; }  # <имя> <тег>

runtime_add() {  # runtime_add <имя> — во все VLESS-инбаунды (в TCP — с flow Vision)
  local f id tag flow
  [[ -n $API ]] || return 1
  id=$(user_field "$1" id)
  for tag in "${VLESS_TAGS[@]}"; do
    flow=$(q '.inbounds[] | select(.tag == $t) | if .streamSettings.network == "xhttp" then "" else "xtls-rprx-vision" end' --arg t "$tag")
    f=$(mktemp)
    TMPS+=("$f")
    # port нужен только парсеру xray (адреса/порты adu не использует)
    jq -n --arg tag "$tag" --argjson port "$PORT" --arg id "$id" --arg email "$1" --arg flow "$flow" '
      {inbounds: [{tag: $tag, port: $port, protocol: "vless",
        settings: {clients: [{id: $id, email: $email} + (if $flow == "" then {} else {flow: $flow} end)],
                   decryption: "none"}}]}' > "$f"
    xray api adu -s "$API" -t 5 "$f" >/dev/null 2>&1 || true
    runtime_user "$1" "$tag" | jq -e --arg id "$id" '.users[0].account.id == $id' >/dev/null || return 1
  done
}

runtime_rm() {  # runtime_rm <имя> — из всех VLESS-инбаундов
  local out tag
  [[ -n $API ]] || return 1
  for tag in "${VLESS_TAGS[@]}"; do
    xray api rmu -s "$API" -t 5 -tag="$tag" "$1" >/dev/null 2>&1 || true
    out=$(runtime_user "$1" "$tag") || return 1
    jq -e '(.users[0].email // "") == ""' <<<"$out" >/dev/null || return 1
  done
}

# apply_users — привести конфиг и работающий Xray к списку включённых пользователей из базы.
# Новые включённые добавляются, остальные убираются через API; не вышло — рестарт (если Xray запущен).
apply_users() {
  local before after n fail=0
  lock
  before=$(q '[clients[].email] | sort | .[]')
  apply_config "$CLIENTS_JQ set_clients(\$u)" --argjson u "$(dbq '[.users[] | select(.enabled) | {id, email: .name}]' -c)"
  ((CHANGED)) || return 0
  after=$(q '[clients[].email] | sort | .[]')
  while read -r n; do
    if [[ -n $n ]] && ! runtime_add "$n"; then fail=1; fi
  done < <(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
  while read -r n; do
    if [[ -n $n ]] && ! runtime_rm "$n"; then fail=1; fi
  done < <(comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
  if ((fail)) && systemctl is-active --quiet xray; then
    echo "API не применил изменения — перезапускаю Xray" >&2
    restart_or_rollback
  fi
}

# evaluate — применить правила лимитов/сроков/сброса к базе и синхронизировать Xray.
# Печатает, кто включился или отключился.
evaluate() {
  local before after
  before=$(dbq '[.users[] | {name, enabled}]' -c)
  db_write "$POLICY_JQ policy(\$now; \$month; \$day)" \
    --argjson now "$(date +%s)" --arg month "$(date +%Y-%m)" --argjson day "$(date +%-d)"
  after=$(dbq '[.users[] | {name, enabled, reason}]' -c)
  jq -rn --argjson b "$before" --argjson a "$after" '
    ($b | map({(.name): .enabled}) | add // {}) as $was
    | $a[] | select($was[.name] != null and $was[.name] != .enabled)
    | if .enabled then "\(.name): снова включён"
      else "\(.name): отключён — " + ({quota: "исчерпан лимит трафика", expired: "истёк срок"}[.reason] // .reason) end'
  apply_users
}

# ─── Трафик и онлайн ─────────────────────────────────────
# Счётчики Xray живут в памяти и обнуляются при его перезапуске, поэтому они забираются со сбросом
# и копятся в базе: каждую минуту (таймер), при показе таблицы, перед рестартом и остановкой Xray.

traffic_flush() {  # никогда не завершается ошибкой
  local raw
  api_up || return 0
  raw=$(xray api statsquery -s "$API" -t 5 -pattern 'user>>>' -reset 2>/dev/null) || return 0
  [[ -n $raw ]] || return 0
  ( db_write '
      (reduce ($s.stat[]? | (.name | split(">>>")) as $p | select($p[0] == "user" and $p[2] == "traffic")
         | {n: $p[1], d: (if $p[3] == "uplink" then "up" else "down" end), v: ((.value // 0) | tonumber)}) as $e
         ({}; .[$e.n][$e.d] += $e.v)) as $d
      | .users |= map(($d[.name] // {}) as $x
          | .up += ($x.up // 0) | .down += ($x.down // 0)
          | if (($x.up // 0) + ($x.down // 0)) >= $act then .last_online = $now else . end)' \
      --argjson s "$raw" --argjson now "$(date +%s)" --argjson act "$ACTIVITY_BYTES" ) || true
}

online_json() {  # {"имя": {"ip": время_последней_активности, ...}, ...} — по данным Xray
  local names n ips out='{}'
  api_up || { echo '{}'; return 0; }
  names=$(xray api statsgetallonlineusers -s "$API" -t 5 2>/dev/null | jq -r '.users[]? | split(">>>")[1]') || true
  for n in $names; do
    ips=$(xray api statsonlineiplist -s "$API" -t 5 -email "$n" 2>/dev/null | jq -c '.ips // {}') || ips=''
    if [[ -z $ips || $ips == '{}' ]]; then continue; fi
    out=$(jq -c --arg n "$n" --argjson i "$ips" '.[$n] = $i' <<<"$out")
  done
  echo "$out"
}

users_table() {  # users_table [имя] — таблица всех пользователей или одного
  local on=${ONLINE:-}
  if [[ -z $on ]]; then on='{}'; fi
  jq -r --argjson on "$on" --argjson now "$(date +%s)" --arg only "${1:-}" "$TABLE_JQ"'
    .users | to_entries | map(.value + {n: (.key + 1)})
    | (if $only != "" then map(select(.name == $only)) else . end) as $rows
    | [["#", "ИМЯ", "СТАТУС", "↑ ОТДАЧА", "↓ ЗАГРУЗКА", "ТРАФИК / ЛИМИТ", "СРОК", "АКТИВНОСТЬ"]]
      + [$rows[] | [(.n | tostring), .name, status, (.up | human), (.down | human), usage, term,
                    (if $on[.name] then "сейчас" else (.last_online | ago) end)]]
      + (if $only == "" then
           [["", "ИТОГО", "\([$rows[] | select(.enabled)] | length) из \($rows | length) вкл",
             ($rows | map(.up) | add // 0 | human), ($rows | map(.down) | add // 0 | human),
             ($rows | map(.up + .down) | add // 0 | human), "", ""]]
         else [] end)
    | table' "$DB"
}

# ─── Команды: пользователи ───────────────────────────────

cmd_list() {
  local live=1
  api_up || live=0
  traffic_flush
  ONLINE=$(online_json)
  echo
  users_table
  echo
  echo "Учёт трафика с $(dbq '.since'). ↻N — сброс трафика каждый месяц N-го числа. Помощь: xrayctl help"
  if ((live == 0)); then echo "Внимание: Xray сейчас не отвечает — показаны сохранённые данные."; fi
  echo
}

cmd_add() {
  local name='' limit=0 expire=0 rday=0 now
  # 1–32 символа; без пробелов, кавычек, '\', '>' (разделитель имён статистики) и '-' в начале
  local re='^[^[:space:][:cntrl:]"\\>-][^[:space:][:cntrl:]"\\>]{0,31}$'
  while (($#)); do
    case $1 in
      --limit) limit=$(parse_size "${2:-}"); shift 2 ;;
      --days) expire=$(parse_days "${2:-}"); shift 2 ;;
      --expire) expire=$(parse_expire "${2:-}"); shift 2 ;;
      --reset-day) rday=$(parse_reset_day "${2:-}"); shift 2 ;;
      -*) die "неизвестная опция $1 (xrayctl help)" ;;
      *) [[ -z $name ]] || die "лишний аргумент: $1"; name=$1; shift ;;
    esac
  done
  if [[ -z $name ]]; then
    [[ -t 0 ]] || die "укажи имя: xrayctl add <имя>"
    read -rp "Имя пользователя (без пробелов): " name
  fi
  [[ $name =~ $re ]] || die "имя: 1–32 символа, без пробелов, кавычек, '\\', '>' и без '-' в начале"
  [[ ! $name =~ ^[0-9]+$ ]] || die "имя не может состоять только из цифр (путается с номером)"
  lock
  [[ -z $(resolve "$name") ]] || die "пользователь '$name' уже существует"
  now=$(date +%s)
  db_write '.users += [{name: $n, id: $id, up: 0, down: 0, quota: $q, expire: $e, enabled: true, reason: "",
                        reset_day: $r, last_reset: (if $r > 0 then $m else "" end), created: $now, last_online: 0}]' \
    --arg n "$name" --arg id "$(xray uuid)" --argjson q "$limit" --argjson e "$expire" --argjson r "$rday" \
    --arg m "$(date +%Y-%m)" --argjson now "$now"
  RESTARTED=0
  evaluate >/dev/null
  if ((RESTARTED)); then show_link "$name" "Пользователь добавлен, Xray перезапущен"
  else show_link "$name" "Пользователь добавлен без перезапуска Xray"; fi
}

cmd_rm() {
  local key='' kick=0 a name
  for a in "$@"; do
    case $a in
      -k | --kick) kick=1 ;;
      *) key=$a ;;
    esac
  done
  lock
  name=$(pick "$key" "Номер, имя или UUID для удаления")
  (($(dbq '.users | length') > 1)) || die "нельзя удалить последнего пользователя"
  if [[ -z $key ]] && ! confirm "Удалить '$name'?"; then
    echo "Отменено"
    return 0
  fi
  traffic_flush
  db_write '.users |= map(select(.name != $n))' --arg n "$name"
  apply_users
  if ((kick)); then
    restart_or_rollback
    echo "Удалён: $name. Xray перезапущен — все открытые сессии сброшены."
  else
    echo "Удалён: $name. Новые подключения отклоняются; уже открытые сессии доживут до закрытия"
    echo "(оборвать сейчас: xrayctl restart — сбросит сессии всех пользователей)."
  fi
}

cmd_set() {
  local name field=${2:-} value=${3:-} v
  [[ -n ${1:-} && -n $field && -n $value ]] || die "использование: xrayctl set <польз> limit|expire|days|reset-day <значение>"
  lock
  name=$(pick "$1" "")
  case $field in
    limit) v=$(parse_size "$value"); db_write '(.users[] | select(.name == $n)).quota = $v' --arg n "$name" --argjson v "$v" ;;
    expire) v=$(parse_expire "$value" "$(user_field "$name" expire)")
            db_write '(.users[] | select(.name == $n)).expire = $v' --arg n "$name" --argjson v "$v" ;;
    days) v=$(parse_days "$value"); db_write '(.users[] | select(.name == $n)).expire = $v' --arg n "$name" --argjson v "$v" ;;
    reset-day) v=$(parse_reset_day "$value")
               db_write '(.users[] | select(.name == $n)) |= (.reset_day = $v | .last_reset = (if $v > 0 then $m else "" end))' \
                 --arg n "$name" --argjson v "$v" --arg m "$(date +%Y-%m)" ;;
    *) die "поле: limit | expire | days | reset-day" ;;
  esac
  evaluate
  ONLINE=$(online_json)
  echo
  users_table "$name"
  echo
}

cmd_enable() {
  local name reason
  lock
  name=$(pick "${1:-}" "Номер, имя или UUID")
  db_write '(.users[] | select(.name == $n)) |= (if .enabled then . else .enabled = true | .reason = "" end)' --arg n "$name"
  evaluate >/dev/null
  if [[ $(user_field "$name" enabled) == true ]]; then
    echo "$name включён."
  else
    reason=$(user_field "$name" reason)
    case $reason in
      quota) die "$name не включён: исчерпан лимит. Увеличь лимит (xrayctl set $name limit ...) или обнули трафик (xrayctl reset $name)" ;;
      expired) die "$name не включён: истёк срок. Продли: xrayctl set $name expire +30" ;;
      *) die "$name не включён ($reason)" ;;
    esac
  fi
}

cmd_disable() {
  local name
  lock
  name=$(pick "${1:-}" "Номер, имя или UUID")
  db_write '(.users[] | select(.name == $n)) |= (.enabled = false | .reason = "manual")' --arg n "$name"
  evaluate >/dev/null
  echo "$name отключён вручную. Новые подключения отклоняются; включить: xrayctl enable $name"
}

cmd_reset() {
  local name
  [[ -n ${1:-} ]] || die "использование: xrayctl reset <польз> | --all"
  lock
  traffic_flush
  if [[ $1 == --all ]]; then
    db_write '.users |= map(.up = 0 | .down = 0) | .since = (now | strflocaltime("%Y-%m-%d"))'
    echo "Трафик всех пользователей обнулён, учёт начат заново."
  else
    name=$(pick "$1" "")
    db_write '(.users[] | select(.name == $n)) |= (.up = 0 | .down = 0)' --arg n "$name"
    echo "Трафик $name обнулён."
  fi
  evaluate
}

cmd_online() {
  local on
  on=$(online_json)
  echo
  if [[ $on == '{}' ]]; then
    if api_up; then echo "Сейчас никто не подключён."; else echo "Xray не отвечает."; fi
    echo
    return 0
  fi
  jq -r --argjson on '{}' --argjson now "$(date +%s)" "$TABLE_JQ"'
    [["ИМЯ", "IP", "ПОСЛЕДНЯЯ АКТИВНОСТЬ"]]
    + [to_entries[] | .key as $n | .value | to_entries[] | [$n, .key, (.value | ago)]]
    | table' <<<"$on"
  echo
}

cmd_link() {
  local name
  name=$(pick "${1:-}" "Номер, имя или UUID")
  ONLINE=$(online_json)
  show_link "$name" "Ссылка для подключения"
}

cmd_main() {
  local name
  name=$(main_user)
  [[ -n $name ]] || die "нет пользователей"
  ONLINE=$(online_json)
  show_link "$name" "Основной пользователь"
}

# tick — раз в минуту из таймера xray-dv: трафик, онлайн, лимиты, сроки, ежемесячный сброс
cmd_tick() {
  local on
  lock_try || return 0
  traffic_flush
  on=$(online_json)
  if [[ $on != '{}' ]]; then
    db_write '.users |= map(if $on[.name] then .last_online = $now else . end)' \
      --argjson on "$on" --argjson now "$(date +%s)"
  fi
  evaluate
}

# ─── Команды: сервер ─────────────────────────────────────

cmd_status() {
  local unit port_state rc=0 api_state timer
  unit=$(systemctl is-active xray 2>/dev/null || true)
  [[ $unit == active ]] || rc=1
  if port_listening; then port_state='слушается'; else port_state='НЕ слушается'; rc=1; fi
  if api_up; then api_state="отвечает ($API)"; else api_state="НЕ отвечает (${API:-не настроен})"; fi
  timer=$(systemctl is-active xray-dv.timer 2>/dev/null || true)
  echo
  kv 'Версия:' "$SCRIPT_VERSION, $(xray version | sed -n 1p)"
  kv 'Unit xray:' "${unit:-неизвестно}"
  kv "Порт $PORT:" "$port_state"
  kv 'API:' "$api_state"
  kv 'Таймер лимитов:' "${timer:-неизвестно}$([[ $timer == active ]] || echo ' — лимиты и сроки не проверяются!')"
  kv 'Транспорты:' "${TRANSPORTS[*]} на порту $PORT, SNI $SNI, fp $FINGERPRINT"
  kv 'Пользователей:' "$(dbq '"\([.users[] | select(.enabled)] | length) включено из \(.users | length)"')"
  echo
  return "$rc"
}

# ─── Самопроверка ────────────────────────────────────────
# Поднимает временный клиент Xray с параметрами ссылки включённого пользователя (main или первого),
# подключается к своему же порту через REALITY и открывает адрес — тот же путь, что проходит телефон.
# Подключение идёт с 127.0.0.1: Xray не считает его онлайном, а трафик мал — активностью не считается.

chk() {  # chk <ok|fail|warn> <что> <подробности>
  local mark pad=$((18 - ${#2}))   # ширина в символах, а не байтах (кириллица)
  case $1 in ok) mark='[ OK ]' ;; fail) mark='[FAIL]' ;; *) mark='[ !! ]' ;; esac
  printf '  %s %s%*s %s\n' "$mark" "$2" "$((pad > 0 ? pad : 0))" '' "$3"
}

free_port() {
  local p _
  for _ in $(seq 50); do
    p=$(shuf -i 20000-60000 -n 1)
    if ! ss -Htln "sport = :$p" | grep -q .; then printf '%s\n' "$p"; return 0; fi
  done
  return 1
}

probe_user() {  # включённый пользователь для проверок: main, иначе первый включённый
  dbq '(first(.users[] | select(.enabled and .name == "main")) // first(.users[] | select(.enabled)) // {}).name // empty'
}

# probe_link <tcp|xhttp> <режим XHTTP|''> <пресет|JSON Extra> <url> → PROBE_CODE (000 — не прошло), лог в PROBE_LOG
PROBE_LOG=''
PROBE_CODE=''
probe_link() {
  local net=$1 mode=$2 extra url=$4 name id ccfg lp code flow='' _
  PROBE_CODE=000
  PROBE_LOG=$(mktemp)
  TMPS+=("$PROBE_LOG")
  name=$(probe_user)
  if [[ -z $name ]]; then echo "нет включённых пользователей" > "$PROBE_LOG"; return 0; fi
  id=$(user_field "$name" id)
  extra=$(extra_json "$3")
  if [[ $net == tcp ]]; then flow=xtls-rprx-vision; fi
  lp=$(free_port) || return 0
  ccfg=$(mktemp --suffix=.json)
  TMPS+=("$ccfg")
  jq -n --argjson lp "$lp" --argjson port "$PORT" --arg id "$id" --arg flow "$flow" --arg net "$net" \
    --arg sni "$SNI" --arg fp "$FINGERPRINT" --arg pbk "$PUBLIC_KEY" --arg sid "$SHORT_ID" \
    --arg xpath "${XHTTP_PATH:-/}" --arg mode "$mode" --arg extra "$extra" '
    {log: {loglevel: "warning"},
     inbounds: [{listen: "127.0.0.1", port: $lp, protocol: "socks", settings: {udp: false}}],
     outbounds: [{protocol: "vless",
       settings: {vnext: [{address: "127.0.0.1", port: $port,
         users: [{id: $id, encryption: "none"} + (if $flow == "" then {} else {flow: $flow} end)]}]},
       streamSettings: ({network: $net, security: "reality",
         realitySettings: {serverName: $sni, fingerprint: $fp, publicKey: $pbk, shortId: $sid, spiderX: ""}}
         + (if $net == "xhttp" then
              {xhttpSettings: ({path: $xpath, mode: $mode}
                + (if $extra == "" then {} else {extra: ($extra | fromjson)} end))}
            else {} end))}]}' > "$ccfg"
  xray run -config "$ccfg" > "$PROBE_LOG" 2>&1 &
  CHECK_PID=$!
  for _ in $(seq 50); do
    if ss -Htln "sport = :$lp" | grep -q .; then break; fi
    sleep 0.1
  done
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --noproxy '' -x "socks5h://127.0.0.1:$lp" "$url" 2>/dev/null) || true
  kill "$CHECK_PID" 2>/dev/null || true
  wait "$CHECK_PID" 2>/dev/null || true
  CHECK_PID=''
  PROBE_CODE=${code:-000}
}

xmode() { if [[ ${XHTTP_MODE:-stream-one} == auto ]]; then echo stream-one; else echo "$XHTTP_MODE"; fi; }  # auto с REALITY = stream-one

probe_first() {  # probe_first <url> — проверка через первый включённый транспорт (с настройками ссылок)
  if ((HAS_TCP)); then probe_link tcp '' default "$1"; else probe_link xhttp "$(xmode)" "${XHTTP_EXTRA:-default}" "$1"; fi
}

cmd_check() {
  local url=${CHECK_URL:-https://www.gstatic.com/generate_204}
  local ip_url=${IP_CHECK_URL:-https://api.ipify.org}
  local rc=0 pub addr_ip v code='' direct errs errs_log='' who

  echo
  echo "Самопроверка: $SERVER_ADDR:$PORT, ${TRANSPORTS[*]}, SNI $SNI"
  echo "────────────────────────────────────────────────────────"

  if systemctl is-active --quiet xray; then chk ok "Сервис xray" "запущен"
  else chk fail "Сервис xray" "не запущен — journalctl -u xray -n 50"; rc=1; fi
  if port_listening; then chk ok "Порт $PORT" "слушается"
  else chk fail "Порт $PORT" "не слушается"; rc=1; fi
  if systemctl is-active --quiet xray-dv.timer; then chk ok "Таймер лимитов" "работает (учёт трафика, лимиты, сроки)"
  else chk warn "Таймер лимитов" "не работает — трафик копится, но лимиты и сроки не проверяются"; fi

  # Адрес в ссылках должен совпадать с внешним IP сервера (типичная беда после смены IP)
  pub=$(curl -4 -fsS --max-time 6 "$ip_url" 2>/dev/null | tr -d '[:space:]') || pub=''
  if [[ $SERVER_ADDR =~ ^[0-9.]+$ ]]; then addr_ip=$SERVER_ADDR
  else addr_ip=$(getent ahostsv4 "$SERVER_ADDR" 2>/dev/null | awk 'NR == 1 {print $1}'); fi
  if [[ -z $pub ]]; then chk warn "Адрес в ссылках" "$SERVER_ADDR (внешний IP узнать не удалось)"
  elif [[ $pub == "$addr_ip" ]]; then chk ok "Адрес в ссылках" "$SERVER_ADDR = внешний IP сервера"
  else
    if [[ $addr_ip == "$SERVER_ADDR" ]]; then addr_ip=''; fi
    chk fail "Адрес в ссылках" "$SERVER_ADDR${addr_ip:+ ($addr_ip)}, а внешний IP сервера $pub"
    echo "         Исправить: sed -i 's/^SERVER_ADDR=.*/SERVER_ADDR=$pub/' $PARAMS и выдать ссылки заново"
    rc=1
  fi

  # Параметры ссылок (params.env) должны совпадать с конфигом сервера
  local priv derived bad=()
  priv=$(q '.inbounds[rin].streamSettings.realitySettings.privateKey // empty')
  derived=$(xray x25519 -i "$priv" 2>/dev/null \
    | awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}' | tr -d '[:space:]') || derived=''
  if [[ $derived != "$PUBLIC_KEY" ]]; then bad+=("pbk не от privateKey сервера"); fi
  if [[ $(q '[.inbounds[rin].streamSettings.realitySettings.shortIds[]?] | any(. == $s)' --arg s "$SHORT_ID") != true ]]; then
    bad+=("shortId $SHORT_ID нет в конфиге")
  fi
  if [[ $(q '[.inbounds[rin].streamSettings.realitySettings.serverNames[]?] | any(. == $s)' --arg s "$SNI") != true ]]; then
    bad+=("SNI $SNI нет в serverNames")
  fi
  if [[ $(q '.inbounds[rin].port') != "$PORT" ]]; then bad+=("порт в конфиге не $PORT"); fi
  if ((HAS_XHTTP)) && [[ $(q '.inbounds[xin].streamSettings.xhttpSettings.path // "/"') != "$XHTTP_PATH" ]]; then
    bad+=("путь XHTTP в конфиге не $XHTTP_PATH")
  fi
  if [[ $(jq -n --argjson c "$(q '[.inbounds[] | select(.protocol == "vless") | .settings.clients[] | {email, id}] | unique | sort_by(.email)' -c)" \
          --argjson d "$(dbq '[.users[] | select(.enabled) | {email: .name, id}] | sort_by(.email)' -c)" '$c == $d') != true ]]; then
    bad+=("пользователи в конфиге не совпадают с базой (исправится в течение минуты таймером)")
  fi
  if ((${#bad[@]} == 0)); then chk ok "Параметры ссылок" "совпадают с конфигом сервера"
  else
    chk fail "Параметры ссылок" "$(IFS=';'; echo "${bad[*]}" | sed 's/;/; /g')"
    rc=1
  fi

  # REALITY на каждое подключение ходит на этот сайт — он должен быть доступен с сервера
  v=$(sni_problems "$SNI" | grep -v 'перенаправляет' | paste -sd';' | sed 's/;/; /g') || true
  if [[ -z $v ]]; then chk ok "SNI-сайт" "$SNI отвечает по TLS 1.3 + HTTP/2, без CDN"
  elif [[ $v == *'REALITY с ним работать не будет'* ]]; then
    chk fail "SNI-сайт" "$SNI недоступен с сервера или без TLS 1.3/HTTP/2 — смени: xrayctl sni <домен>"; rc=1
  else chk warn "SNI-сайт" "$SNI работает, но плох для маскировки: $v. Сменить: xrayctl sni <домен>"; fi

  # Сквозной тест: каждый включённый транспорт; для XHTTP — все три режима (сервер обязан принимать любой)
  who=$(probe_user)
  local tr m label ok_list=() bad_list=()
  if [[ -z $who ]]; then
    chk warn "Сквозной тест" "пропущен: нет включённых пользователей"
  else
    for tr in "${TRANSPORTS[@]}"; do
      if [[ $tr == tcp ]]; then
        probe_link tcp '' default "$url"
        if [[ $PROBE_CODE != 000 ]]; then ok_list+=(tcp); code=$PROBE_CODE; else bad_list+=(tcp); errs_log=$PROBE_LOG; fi
      else
        for m in stream-one stream-up packet-up; do
          probe_link xhttp "$m" "${XHTTP_EXTRA:-default}" "$url"
          label="xhttp:$m"
          if [[ $m == "$(xmode)" ]]; then label+="*"; fi
          if [[ $PROBE_CODE != 000 ]]; then ok_list+=("$label"); code=$PROBE_CODE; else bad_list+=("$label"); errs_log=$PROBE_LOG; fi
        done
      fi
    done
    if ((${#bad_list[@]} == 0)); then
      chk ok "Сквозной тест" "${ok_list[*]} → $url: HTTP $code$( ((HAS_XHTTP)) && echo " (* — режим в ссылках, Extra: $(extra_label "$XHTTP_EXTRA"))")"
      if ru_enabled; then ru_check || rc=1
      else chk warn "Блок RU" "выключен — VPN пускает на российские сайты и IP (включить: xrayctl ru on)"; fi
    else
      rc=1
      direct=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null) || true
      if [[ ${direct:-000} == 000 ]]; then
        chk fail "Сквозной тест" "у самого сервера нет доступа к $url — проверь DNS и интернет на сервере"
      else
        chk fail "Сквозной тест" "не проходят: ${bad_list[*]}${ok_list[*]:+; работают: ${ok_list[*]}}"
        errs=$(grep -E '\[(Warning|Error)\]|failed' "$errs_log" | grep -v 'core: Xray .* started' | tail -n 5) || true
        if [[ -n $errs ]]; then echo "         Ошибки временного клиента:"; sed 's/^/           /' <<<"$errs"; fi
        echo "         Лог сервера: journalctl -u xray -n 30 --no-pager"
      fi
    fi
  fi

  echo
  if ((rc == 0)); then
    echo "  Сервер и ссылки исправны. Если клиент всё равно показывает -1:"
    echo "   1) удали в клиенте старый профиль и импортируй ссылку заново (xrayctl link <имя>);"
    echo "   2) проверь, доходит ли до порта с твоего устройства. Windows PowerShell:"
    echo "      Test-NetConnection $SERVER_ADDR -Port $PORT   (TcpTestSucceeded должно быть True)"
    echo "      False — порт закрыт по пути: фаервол хостера или блокировка провайдера."
  fi
  echo
  return "$rc"
}

# ─── XHTTP ───────────────────────────────────────────────
# Режим и Extra — настройки КЛИЕНТА: уходят в ссылку (mode=, extra=). Сервер слушает с mode: auto
# и принимает любой режим, поэтому их смена не требует ни рестарта, ни правки конфига.

extra_json() {  # extra_json <пресет|JSON> → компактный JSON для xhttpSettings.extra (пусто для default)
  case $1 in
    default) ;;
    # Одно соединение на всё, переоткрывается раз в 30–50 минут: как одна открытая вкладка браузера
    single) printf '%s\n' '{"xmux":{"maxConnections":1,"hMaxRequestTimes":"600-900","hMaxReusableSecs":"1800-3000"}}' ;;
    # Смена соединений каждые 1–2 минуты: для сетей, где «замораживают» долгие соединения
    rotate) printf '%s\n' '{"xmux":{"maxConnections":"2-4","cMaxReuseTimes":"16-32","hMaxRequestTimes":"64-128","hMaxReusableSecs":"60-120"}}' ;;
    *) jq -ce 'if type == "object" then . else error("не объект") end' <<<"$1" 2>/dev/null \
         || die "Extra: ожидается пресет (${XHTTP_PRESETS[*]}) или JSON-объект" ;;
  esac
}

is_xhttp_mode() {
  local m
  for m in "${XHTTP_MODES[@]}"; do
    if [[ $1 == "$m" ]]; then return 0; fi
  done
  return 1
}

extra_label() {  # имя пресета или «custom»
  local p
  for p in "${XHTTP_PRESETS[@]}"; do
    if [[ $1 == "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  done
  printf 'custom\n'
}

# Правдоподобный путь XHTTP — как у API обычного веб-приложения, например /api/v2/events/3fa9c1d27b.
gen_xhttp_path() {
  local -a pre=(api api/v1 api/v2 api/v3 v1 v2 rest/v1 internal/api app/api)
  local -a word=(events sync telemetry collect messages updates stream realtime metrics analytics feed notifications)
  local p=${pre[RANDOM % ${#pre[@]}]} w=${word[RANDOM % ${#word[@]}]} id
  id=$(openssl rand -hex 5)
  case $((RANDOM % 3)) in
    0) printf '/%s/%s/%s\n' "$p" "$w" "$id" ;;
    1) printf '/%s/%s/%s\n' "$p" "$id" "$w" ;;
    *) printf '/%s/%s-%s\n' "$p" "$w" "$id" ;;
  esac
}

xhttp_help() {
  cat <<EOF
Использование: xrayctl xhttp <команда>

  show                       текущие настройки и описание режимов и пресетов (по умолчанию)
  set <режим> [пресет|JSON]  режим и Extra для НОВЫХ ссылок; сервер не перезапускается
  links [польз]              9 тестовых ссылок: 3 режима × 3 пресета — для замера на клиенте
  path [random|/свой/путь]   сменить путь XHTTP на сервере (рестарт; ВСЕ ссылки нужно выдать заново)

Режимы: ${XHTTP_MODES[*]}    Пресеты Extra: ${XHTTP_PRESETS[*]} или свой JSON
Пример: xrayctl xhttp set stream-up rotate
EOF
}

xhttp_show() {
  local extra
  extra=$(extra_json "$XHTTP_EXTRA")
  echo
  kv 'Путь:' "$XHTTP_PATH"
  kv 'Режим в ссылках:' "$XHTTP_MODE (сервер принимает все режимы)"
  kv 'Extra в ссылках:' "$(extra_label "$XHTTP_EXTRA")${extra:+  $extra}"
  cat <<'EOF'

Режимы (выбирает клиент, сервер принимает любой):
  stream-one  один HTTP-запрос на соединение, данные в обе стороны. Меньше всего запросов и задержка;
              Xray в режиме auto с REALITY выбирает именно его. Начинать стоит с него.
  stream-up   отдельный запрос на отдачу (POST) и на загрузку (GET). Пробовать, если stream-one
              рвётся или медленно грузит.
  packet-up   отдача пачками коротких POST-запросов. Самый совместимый, но отдача медленнее.

Пресеты Extra (мультиплексирование xmux на клиенте; пустое поле Extra в клиенте = default):
  default     встроенные в Xray: до 3 соединений, каждое живёт 30–50 минут
  single      одно соединение на всё, 30–50 минут: меньше рукопожатий, как одна вкладка браузера
  rotate      2–4 соединения, смена каждые 1–2 минуты: если провайдер «замораживает» долгие соединения

Как выбрать под свою сеть — замерить с устройства, где работает клиент:
  1) sudo xrayctl xhttp links > xhttp-test.txt   — 9 ссылок «режим × пресет»
  2) на Windows: dv-bench.ps1 или импорт всех ссылок в v2rayN → тест задержки и скорости
  3) sudo xrayctl xhttp set <лучший режим> <лучший пресет>  и выдать ссылки заново

EOF
}

xhttp_set() {
  local mode=${1:-} preset=${2:-$XHTTP_EXTRA} m
  [[ -n $mode ]] || die "использование: xrayctl xhttp set <режим> [пресет|JSON]"
  is_xhttp_mode "$mode" || die "неизвестный режим '$mode' (допустимо: ${XHTTP_MODES[*]})"
  extra_json "$preset" >/dev/null
  lock
  m=$mode
  if [[ $m == auto ]]; then m=stream-one; fi   # auto с REALITY = stream-one
  echo "Проверяю $mode + $(extra_label "$preset") через туннель на этом сервере..."
  probe_link xhttp "$m" "$preset" "${CHECK_URL:-https://www.gstatic.com/generate_204}"
  if [[ $PROBE_CODE == 000 ]]; then
    grep -E '\[(Warning|Error)\]|failed|нет включённых' "$PROBE_LOG" | tail -n 5 >&2 || true
    die "с этими настройками подключиться не удалось — ничего не изменено"
  fi
  set_param XHTTP_MODE "$mode"
  set_param XHTTP_EXTRA "$preset"
  echo "Готово: новые ссылки будут с mode=$mode, Extra: $(extra_label "$preset")."
  echo "Уже выданные ссылки продолжают работать со своими настройками. Обновить ссылку: xrayctl link <имя>"
}

xhttp_links() {
  local name id m p
  name=$(pick "${1:-$(main_user)}" "Номер, имя или UUID")
  id=$(user_field "$name" id)
  for m in stream-one stream-up packet-up; do
    for p in "${XHTTP_PRESETS[@]}"; do
      make_link "$id" "$name · $m · $p" xhttp "$m" "$p"
    done
  done
  cat >&2 <<EOF

Выше 9 тестовых ссылок для «$name» (все рабочие, сервер принимает любой режим).
Замерь их на клиенте: dv-bench.ps1 или импорт в v2rayN (Ctrl+V) → тест задержки и скорости.
Лучший вариант закрепи: sudo xrayctl xhttp set <режим> <пресет>
EOF
}

xhttp_path() {
  local new=${1:-} yes=${2:-}
  if [[ -z $new ]]; then
    echo "Текущий путь: $XHTTP_PATH"
    echo "Сменить: xrayctl xhttp path random  или  xrayctl xhttp path /свой/путь"
    return 0
  fi
  if [[ $new == random ]]; then new=$(gen_xhttp_path); fi
  [[ $new =~ ^/[A-Za-z0-9._~/-]{0,120}$ && $new != *//* ]] \
    || die "путь: начинается с /, только латиница, цифры и . _ ~ - /, без ? и //"
  if [[ $new == "$XHTTP_PATH" ]]; then echo "Путь уже $new"; return 0; fi
  echo "Новый путь: $new (было: $XHTTP_PATH)"
  echo "ВНИМАНИЕ: Xray перезапустится, а ВСЕ выданные ссылки перестанут работать — их нужно выдать заново."
  if [[ $yes != -y ]]; then
    [[ -t 0 ]] || die "без терминала добавь подтверждение: xrayctl xhttp path $new -y"
    confirm "Продолжить?" || { echo "Отменено"; return 0; }
  fi
  apply_config '.inbounds[xin].streamSettings.xhttpSettings.path = $p' --arg p "$new"
  restart_or_rollback
  set_param XHTTP_PATH "$new"
  echo "Путь изменён. Новые ссылки: xrayctl link <имя> (или xrayctl main)"
}

cmd_xhttp() {
  local sub=${1:-show}
  shift || true
  ((HAS_XHTTP)) || die "XHTTP не включён. Включить рядом с TCP: sudo xrayctl transport add xhttp"
  case $sub in
    show) xhttp_show ;;
    set) xhttp_set "$@" ;;
    links) xhttp_links "$@" ;;
    path) xhttp_path "$@" ;;
    help | -h | --help) xhttp_help ;;
    *) xhttp_help >&2; exit 1 ;;
  esac
}

# ─── Блок RU ─────────────────────────────────────────────

ru_enabled() {
  [[ $(q '[.routing.rules[]? | select((.ruleTag // "") | startswith("block-ru"))] | length') -gt 0 ]]
}

ru_client_hint() {
  cat <<'EOF'
На клиенте пусти российские адреса напрямую, иначе они не откроются совсем:
  v2rayN: Настройки → Настройки маршрутизации → в своём наборе правил добавь правило
    исходящее (outboundTag): direct
    Domain: geosite:category-ru, domain:ru, domain:su, domain:xn--p1ai
    IP:     geoip:ru
  и подними его выше правила «всё остальное через прокси».
EOF
}

# ru_check — российский домен и российский IP должны открываться с сервера напрямую, но не через туннель
ru_check() {
  local dom=${RU_CHECK_DOMAIN:-ya.ru} ip=${RU_CHECK_IP:-} d1 d2='' t1 t2=000 leaks=()
  if [[ -z $ip ]]; then ip=$(getent ahostsv4 "$dom" 2>/dev/null | awk 'NR == 1 {print $1}'); fi
  d1=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$dom" 2>/dev/null) || true
  probe_first "https://$dom"
  t1=$PROBE_CODE
  if [[ -n $ip ]]; then
    d2=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$ip/" 2>/dev/null) || true
    probe_first "http://$ip/"
    t2=$PROBE_CODE
  fi
  if [[ $t1 != 000 ]]; then leaks+=("$dom"); fi
  if [[ $t2 != 000 ]]; then leaks+=("$ip"); fi
  if ((${#leaks[@]})); then
    chk fail "Блок RU" "через туннель открывается: ${leaks[*]} — проверь xrayctl ru и геобазы Xray"
    return 1
  fi
  if [[ ${d1:-000} == 000 && ${d2:-000} == 000 ]]; then
    chk warn "Блок RU" "включён, но проверить нельзя: $dom${ip:+ и $ip} недоступны и напрямую"
  else
    chk ok "Блок RU" "$dom (домен) и ${ip:-—} (IP РФ) через туннель закрыты, напрямую с сервера открыты"
  fi
}

cmd_ru() {
  case ${1:-status} in
    status)
      echo
      if ru_enabled; then
        echo "Блок RU: включён. VPN-клиенты не попадут на .ru/.su/.рф и другие зоны РФ,"
        echo "российские сервисы на других доменах (geosite:category-ru) и российские IP (geoip:ru)."
      else
        echo "Блок RU: выключен. Включить: sudo xrayctl ru on"
      fi
      echo
      ru_client_hint
      echo
      ;;
    on)
      apply_config '
        .routing.domainStrategy = "IPIfNonMatch"
        | if any(.outbounds[]?; .tag == "block") then . else .outbounds += [{protocol: "blackhole", tag: "block"}] end
        | .routing.rules = (
            ((.routing.rules // []) | map(select((.ruleTag // "") | startswith("block-ru") | not))) as $r
            | [$r[] | select(.ip == ["geoip:private"])] + $ru + [$r[] | select(.ip != ["geoip:private"])])' \
        --argjson ru "$RU_RULES"
      if ((CHANGED)); then
        echo "Перезапускаю Xray (активные сессии переподключатся)..."
        restart_or_rollback
        echo "Блок RU включён."
      else
        echo "Блок RU уже включён."
      fi
      echo
      ru_client_hint
      ;;
    off)
      apply_config '.routing.rules |= map(select((.ruleTag // "") | startswith("block-ru") | not))'
      if ((CHANGED)); then
        echo "Перезапускаю Xray (активные сессии переподключатся)..."
        restart_or_rollback
        echo "Блок RU выключен: российские сайты и IP снова доступны через VPN."
      else
        echo "Блок RU уже выключен."
      fi
      ;;
    *) die "использование: xrayctl ru [status|on|off]" ;;
  esac
}

# ─── SNI ─────────────────────────────────────────────────

# sni_problems <домен> — чем сайт плох как маскировка для REALITY. Печатает по строке на проблему;
# пустой вывод — сайт подходит. Проверяется: TLS 1.3 + HTTP/2, перенаправление на другое имя,
# CDN (по заголовкам ответа и владельцу IP) и главное — отвечает ли адрес сайта за ЧУЖИЕ домены
# с настоящим сертификатом. Сайт за CDN делает это всегда, и тогда сервер REALITY отдаёт любому
# проверяющему тысячи посторонних сайтов — так его легко вычислить.
sni_problems() {
  local d=$1 out ver code redir rhost hdr ip org cdn='cloudflare|akamai|fastly|cloudfront|amazon|google|microsoft|azure|edgecast|edgio|cdn77|bunny|keycdn|stackpath|incapsula|imperva|gcore|g-core|ddos-guard|qrator|limelight|cachefly'
  out=$(curl -s -D - -o /dev/null --max-time 10 --tlsv1.3 --http2 \
    -w 'x-probe-ver: %{http_version}\nx-probe-code: %{http_code}\nx-probe-redir: %{redirect_url}\n' "https://$d" 2>/dev/null | tr -d '\r') || true
  ver=$(sed -n 's/^x-probe-ver: //p' <<<"$out")
  code=$(sed -n 's/^x-probe-code: //p' <<<"$out")
  redir=$(sed -n 's/^x-probe-redir: //p' <<<"$out")
  if [[ $ver != 2 ]]; then
    echo "недоступен с сервера или не отдаёт TLS 1.3 + HTTP/2 — REALITY с ним работать не будет"
    return 0
  fi
  if [[ $code == 3* && -n $redir ]]; then
    rhost=$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"$redir")
    if [[ -n $rhost && ${rhost,,} != "$d" ]]; then
      echo "перенаправляет на ${rhost,,} — настоящие посетители ходят туда; лучше взять это имя"
    fi
  fi
  hdr=$(grep -iE -m1 "^(server: .*($cdn)|cf-ray:|x-amz-cf-id:|x-served-by: *cache-|x-akamai|x-fastly|x-cdn:|via: .*(cloudfront|akamai|varnish))" <<<"$out") || true
  ip=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR == 1 {print $1}')
  org=''
  if [[ -n $ip ]]; then org=$(curl -s --max-time 6 "${SNI_ORG_URL:-https://ipinfo.io}/$ip/org" 2>/dev/null | head -n 1) || true; fi
  if [[ -n $hdr ]] || grep -qiE "$cdn" <<<"$org"; then
    echo "стоит за CDN${org:+ (адрес $ip: $org)}${hdr:+ [${hdr:0:60}]}"
  fi
  if [[ -n $ip ]] && curl -s -o /dev/null --max-time 8 --resolve "${SNI_PROBE_NAME:-example.com}:443:$ip" \
    "https://${SNI_PROBE_NAME:-example.com}/" 2>/dev/null; then
    echo "его адрес отвечает за чужие сайты с настоящим сертификатом (проверено на ${SNI_PROBE_NAME:-example.com})"
  fi
}

cmd_sni() {
  local new=${1:-} yes=${2:-} probs old=$SNI
  if [[ -z $new ]]; then
    echo
    echo "Текущий SNI: $SNI"
    probs=$(sni_problems "$SNI")
    if [[ -z $probs ]]; then echo "Проверка: подходит (TLS 1.3 + HTTP/2, без CDN, чужие сайты не отдаёт)"
    else echo "Проблемы:"; sed 's/^/  - /' <<<"$probs"; fi
    echo
    echo "Сменить без переустановки (ключи и пользователи сохранятся): sudo xrayctl sni <домен>"
    echo
    return 0
  fi
  new=${new,,}
  [[ $new =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || die "некорректный домен: $new"
  if [[ $new == "$SNI" ]]; then echo "SNI уже $new"; return 0; fi
  echo "Проверяю $new..."
  probs=$(sni_problems "$new")
  if [[ -n $probs ]]; then
    echo "У сайта $new есть проблемы:"
    sed 's/^/  - /' <<<"$probs"
    [[ $probs != *'REALITY с ним работать не будет'* ]] || die "этот сайт использовать нельзя — ничего не изменено"
  else
    echo "Сайт подходит: TLS 1.3 + HTTP/2, без CDN, чужие сайты не отдаёт."
  fi
  echo "ВНИМАНИЕ: Xray перезапустится. Ключи и пользователи сохранятся, но SNI входит в ссылку:"
  echo "уже выданные ссылки перестанут работать, пока в клиенте не сменить SNI на $new (или не импортировать новую ссылку)."
  if [[ $yes != -y ]]; then
    [[ -t 0 ]] || die "без терминала добавь подтверждение: xrayctl sni $new -y"
    confirm "Сменить SNI $SNI → $new?" || { echo "Отменено"; return 0; }
  fi
  apply_config '.inbounds[rin].streamSettings.realitySettings |= (.dest = "\($s):443" | .serverNames = [$s])' --arg s "$new"
  restart_or_rollback
  set_param SNI "$new"
  SNI=$new
  # Сквозная проверка с новым SNI; не прошла — возвращаем всё как было
  probe_first "${CHECK_URL:-https://www.gstatic.com/generate_204}"
  if [[ $PROBE_CODE == 000 ]]; then
    cp -p "$BACKUP" "$CONFIG"
    set_param SNI "$old"
    systemctl restart xray || true
    die "с SNI $new подключиться через туннель не удалось — возвращён прежний SNI $old"
  fi
  echo "Готово: SNI теперь $new, проверка через туннель прошла."
  echo "Новые ссылки: sudo xrayctl link <имя>  (или xrayctl main). Полная проверка: sudo xrayctl check"
}

# ─── Транспорты: TCP (Vision) и XHTTP на одном порту ─────

transport_help() {
  cat <<'EOF'
Использование: xrayctl transport [show | add tcp|xhttp | rm tcp|xhttp [-y]]

Оба транспорта работают на одном порту с одними ключами REALITY: TCP-инбаунд принимает VLESS+Vision,
а XHTTP-трафик (HTTP/2 после REALITY) передаёт XHTTP-инбаунду. Добавление и удаление транспорта —
один перезапуск Xray; ссылки оставшегося транспорта при этом не меняются.

Что выбрать — замерить из своей сети: sudo xrayctl bench (ссылки) → dv-bench.ps1 на Windows.
EOF
}

cmd_transport() {
  local sub=${1:-show} tr=${2:-} yes=${3:-} t=$HAS_TCP x=$HAS_XHTTP path=${XHTTP_PATH:-} m
  case $sub in
    show)
      echo
      kv 'Включены:' "${TRANSPORTS[*]} (порт $PORT)"
      if ((HAS_XHTTP)); then kv 'XHTTP:' "путь $XHTTP_PATH, режим в ссылках $XHTTP_MODE, Extra $(extra_label "$XHTTP_EXTRA")"; fi
      echo
      transport_help
      echo
      return 0
      ;;
    add | rm) ;;
    help | -h | --help) transport_help; return 0 ;;
    *) transport_help >&2; exit 1 ;;
  esac
  [[ $tr == tcp || $tr == xhttp ]] || die "транспорт: tcp или xhttp"
  if [[ $sub == add ]]; then
    if [[ $tr == tcp ]]; then t=1; else x=1; fi
  else
    if [[ $tr == tcp ]]; then t=0; else x=0; fi
  fi
  if ((t == HAS_TCP && x == HAS_XHTTP)); then echo "Ничего не меняется: включены ${TRANSPORTS[*]}"; return 0; fi
  ((t + x > 0)) || die "нельзя отключить последний транспорт"
  if [[ $sub == rm ]]; then
    echo "ВНИМАНИЕ: ссылки $tr у всех пользователей перестанут работать."
    if [[ $yes != -y ]]; then
      [[ -t 0 ]] || die "без терминала добавь подтверждение: xrayctl transport rm $tr -y"
      confirm "Отключить $tr?" || { echo "Отменено"; return 0; }
    fi
  fi
  lock
  if ((x)) && [[ -z $path || $path == / && $HAS_XHTTP == 0 ]]; then path=$(gen_xhttp_path); fi
  apply_config "$CLIENTS_JQ $RENDER_JQ render(\$t; \$x; \$p) | set_clients(\$u)" \
    --argjson t "$( ((t)) && echo true || echo false)" --argjson x "$( ((x)) && echo true || echo false)" \
    --arg p "${path:-/}" --argjson u "$(dbq '[.users[] | select(.enabled) | {id, email: .name}]' -c)"
  echo "Перезапускаю Xray (активные сессии переподключатся)..."
  restart_or_rollback
  if ((x)); then
    set_param XHTTP_PATH "$path"
    XHTTP_PATH=$path
    XHTTP_MODE=${XHTTP_MODE:-stream-one}
    XHTTP_EXTRA=${XHTTP_EXTRA:-default}
    set_param XHTTP_MODE "$XHTTP_MODE"
    set_param XHTTP_EXTRA "$XHTTP_EXTRA"
  fi
  load_transports
  set_param TRANSPORT "$(IFS=+; echo "${TRANSPORTS[*]}")"
  # Проверить через туннель каждый оставшийся транспорт; не прошло — вернуть прежний конфиг
  for m in "${TRANSPORTS[@]}"; do
    if [[ $m == tcp ]]; then probe_link tcp '' default "${CHECK_URL:-https://www.gstatic.com/generate_204}"
    else probe_link xhttp "$(xmode)" "${XHTTP_EXTRA:-default}" "${CHECK_URL:-https://www.gstatic.com/generate_204}"; fi
    if [[ $PROBE_CODE == 000 && -n $(probe_user) ]]; then
      cp -p "$BACKUP" "$CONFIG"
      systemctl restart xray || true
      load_transports
      set_param TRANSPORT "$(IFS=+; echo "${TRANSPORTS[*]}")"
      die "после изменения не проходит $m через туннель — возвращён прежний конфиг"
    fi
  done
  echo "Готово: включены ${TRANSPORTS[*]} на порту $PORT, проверка через туннель прошла."
  if [[ $sub == add ]]; then
    echo "Ссылки уже выданного транспорта не изменились. Новые ссылки $tr: sudo xrayctl link <имя>"
    if ((${#TRANSPORTS[@]} > 1)); then echo "Сравнить в своей сети: sudo xrayctl bench → dv-bench.ps1"; fi
  fi
}

# bench — ссылки для замера на клиенте: TCP и XHTTP (3 режима × 3 пресета Extra).
# Скорость, задержку и «заморозки» видно только из сети пользователя: замер с сервера ничего не скажет
# о провайдере между ним и клиентом.
cmd_bench() {
  local name id m p n=0
  name=$(pick "${1:-$(main_user)}" "Номер, имя или UUID")
  id=$(user_field "$name" id)
  if ((HAS_TCP)); then make_link "$id" "$name · tcp" tcp; n=$((n + 1)); fi
  if ((HAS_XHTTP)); then
    for m in stream-one stream-up packet-up; do
      for p in "${XHTTP_PRESETS[@]}"; do
        make_link "$id" "$name · xhttp · $m · $p" xhttp "$m" "$p"
        n=$((n + 1))
      done
    done
  fi
  {
    echo
    echo "Выше $n ссылок для замера «$name»: все рабочие, отличаются только транспортом и настройками."
    echo "Скопируй их и на Windows запусти: powershell -ExecutionPolicy Bypass -File .\\dv-bench.ps1"
    echo "Скрипт замерит каждую из твоей сети (пинг, скорость, обрывы и «заморозки» соединения)"
    echo "и скажет, что ставить: TCP или XHTTP и с какими настройками — с готовыми командами."
    if ((${#TRANSPORTS[@]} == 1)); then
      echo
      echo "Сейчас включён только ${TRANSPORTS[0]}. Чтобы сравнить, добавь второй: sudo xrayctl transport add $([[ ${TRANSPORTS[0]} == tcp ]] && echo xhttp || echo tcp)"
    fi
  } >&2
}

cmd_restart() {
  lock
  BACKUP=''
  restart_or_rollback
  echo "Xray перезапущен, активные сессии сброшены."
}

# Вызывается установщиком при обновлении: база пользователей (из traffic.json dv2.4) и
# онлайн-статистика в конфиге (statsUserOnline, нужен один рестарт)
cmd_upgrade_config() {
  [[ -n $API && -n $TAG ]] || die "в конфиге нет API — установка слишком старая, переустанови: FORCE_REINSTALL=y"
  apply_config '.stats //= {} | .policy.levels["0"] += {statsUserUplink: true, statsUserDownlink: true, statsUserOnline: true}'
  if ((CHANGED)); then
    echo "Включаю онлайн-статистику пользователей (перезапуск Xray, сессии переподключатся)..."
    restart_or_rollback
  fi
  evaluate >/dev/null
}

cmd=${1:-help}
shift || true
case $cmd in
  list | ls | stats)
    load
    if [[ ${1:-} == --reset ]]; then cmd_reset --all; else cmd_list; fi ;;
  add)             load; cmd_add "$@" ;;
  rm | del)        load; cmd_rm "$@" ;;
  set)             load; cmd_set "$@" ;;
  enable)          load; cmd_enable "$@" ;;
  disable)         load; cmd_disable "$@" ;;
  reset)           load; cmd_reset "$@" ;;
  online)          load; cmd_online ;;
  link | share)    load; cmd_link "$@" ;;
  main)            load; cmd_main ;;
  status)          load; cmd_status ;;
  check | test)    load; cmd_check ;;
  xhttp)           load; cmd_xhttp "$@" ;;
  ru)              load; cmd_ru "$@" ;;
  sni)             load; cmd_sni "$@" ;;
  restart)         load; cmd_restart ;;
  transport)       load; cmd_transport "$@" ;;
  bench)           load; cmd_bench "$@" ;;
  version | -V | --version) echo "$SCRIPT_VERSION, $(xray version 2>/dev/null | sed -n 1p)" ;;
  help | -h | --help) usage ;;
  # служебные: таймер, ExecStop и установщик
  tick)            load; cmd_tick ;;
  flush)           load; traffic_flush ;;
  _upgrade-config) load; cmd_upgrade_config ;;
  _sni-problems)   sni_problems "${1:?}" ;;
  _gen-path)       gen_xhttp_path ;;
  _ru-rules)       printf '%s\n' "$RU_RULES" ;;
  _render)         jq "$JQ_DEFS $CLIENTS_JQ $RENDER_JQ render(\$t; \$x; \$p)" \
                     --argjson t "${1:?}" --argjson x "${2:?}" --arg p "${3:-/}" ;;   # конфиг: stdin → stdout
  _extra-json)     extra_json "${1:?}" ;;
  *) usage >&2; exit 1 ;;
esac
XRAYCTL
  install -m 755 -o root -g root "$tmp" "$CTL"
}

# ─── Сценарии ────────────────────────────────────────────

fresh_install() {
  log "Устанавливаю xrayctl..."
  install_ctl
  collect_params
  gen_keys
  backup_old
  write_config
  write_params
  secure_files
  "$CTL" list >/dev/null   # создаёт базу пользователей из конфига
  install_units
  open_firewall
  enable_bbr
  start_xray
  "$CTL" check || warn "Самопроверка нашла проблемы — подробности выше"

  printf '\n%s════════════════════════════════════%s\n' "$GREEN" "$NC"
  printf '%s       Установка завершена!%s\n' "$GREEN" "$NC"
  printf '%s════════════════════════════════════%s\n' "$GREEN" "$NC"
  printf 'Порт:       %s\nAPI:        127.0.0.1:%s (только loopback)\nSNI:        %s\nОтпечаток:  %s\nТранспорт:  %s\n' \
    "$PORT" "$API_PORT" "$SNI" "$FINGERPRINT" "$TRANSPORT"
  if [[ $TRANSPORT == tcp+xhttp ]]; then
    printf '%sЧто лучше в твоей сети — TCP или XHTTP:%s sudo xrayctl bench → dv-bench.ps1 на Windows\n' "$CYAN" "$NC"
  fi
  if [[ $TRANSPORT == *xhttp* ]]; then
    printf 'XHTTP:      путь %s, режим в ссылках %s, Extra %s (подобрать: sudo xrayctl xhttp)\n' \
      "$XHTTP_PATH" "$XHTTP_MODE" "$XHTTP_EXTRA"
  fi
  "$CTL" main
  if [[ $BLOCK_RU == y ]]; then
    printf '%sБлок RU включён:%s российские сайты и IP через этот сервер не откроются —\n' "$YELLOW" "$NC"
    printf 'пусти их на клиенте напрямую (подробности: sudo xrayctl ru).\n'
  fi
  printf '\n%sВАЖНО:%s это новая установка с новыми ключами. Старые профили этого сервера в клиентах\n' "$YELLOW" "$NC"
  printf 'работать не будут — удали их и импортируй ссылку или QR выше.\n'
  printf '\nПользователи с лимитами: %ssudo xrayctl add anna --limit 50G --days 30%s   Все команды: %ssudo xrayctl help%s\n' \
    "$CYAN" "$NC" "$CYAN" "$NC"
  reboot_notice
}

upgrade() {
  log "Режим обновления: конфиг, ключи и пользователи сохраняются"
  # shellcheck source=/dev/null
  source "$PARAMS"
  [[ -n ${SERVER_ADDR:-} && -n ${TRANSPORT:-} ]] \
    || err "Установка слишком старая для обновления. Переустанови с нуля: FORCE_REINSTALL=y (ключи и ссылки сменятся)"
  jq -e '.api.listen' "$CONFIG" >/dev/null 2>&1 \
    || err "В конфиге нет API — установка слишком старая. Переустанови с нуля: FORCE_REINSTALL=y (ключи и ссылки сменятся)"
  TRANSPORT=$(jq -r '[.inbounds[] | select(.protocol == "vless") | .streamSettings.network
                      | if . == "xhttp" then "xhttp" else "tcp" end] | unique | join("+")' "$CONFIG")
  if [[ $TRANSPORT == *xhttp* ]]; then
    XHTTP_PATH=${XHTTP_PATH:-$(jq -r '[.inbounds[] | select(.streamSettings.network == "xhttp")][0].streamSettings.xhttpSettings.path // "/"' "$CONFIG")}
    XHTTP_MODE=${XHTTP_MODE:-stream-one}
    XHTTP_EXTRA=${XHTTP_EXTRA:-default}
  fi
  write_params
  secure_files
  install_ctl
  cleanup_legacy
  systemctl enable xray >/dev/null 2>&1
  systemctl is-active --quiet xray || systemctl start xray
  health_check
  "$CTL" _upgrade-config
  install_units
  if [[ $TRANSPORT == *xhttp* && $XHTTP_PATH == / ]]; then
    warn "XHTTP работает на пути «/». Сменить на правдоподобный: sudo xrayctl xhttp path random (старые ссылки перестанут работать)"
  fi
  # Блок RU: на уже установленных серверах — по вопросу (без терминала — включается, BLOCK_RU=n отключает)
  if [[ -z ${BLOCK_RU:-} ]]; then
    if [[ -n $TTY ]]; then
      confirm "Не выпускать VPN-трафик на российские сайты и IP (.ru/.su/.рф, RU-сервисы, geoip:ru)? Нужен перезапуск Xray" y \
        && BLOCK_RU=y || BLOCK_RU=n
    else
      BLOCK_RU=y
    fi
  fi
  if [[ $BLOCK_RU == [yYдД]* ]]; then "$CTL" ru on >/dev/null; else "$CTL" ru off >/dev/null; fi
  "$CTL" status || true
  "$CTL" check || warn "Самопроверка нашла проблемы — подробности выше"
  "$CTL" list
  reboot_notice
  log "Обновление завершено"
}

main() {
  local mode=install
  preflight
  if [[ -f $CONFIG && -f $PARAMS ]]; then
    if [[ ${FORCE_REINSTALL:-n} == y ]]; then
      mode=install
    elif [[ -n $TTY ]]; then
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

  upgrade_os
  install_deps
  install_xray

  if [[ $mode == upgrade ]]; then
    upgrade
  else
    fresh_install
  fi
}

# Вызов main — строго последней строкой. При `curl ... | bash` bash выполняет скрипт по мере
# чтения, поэтому до этой строки ничего не происходит: если скачивание оборвётся на середине,
# установка просто не начнётся, а команды внутри main уже не смогут «съесть» остаток скрипта.
main "$@"
