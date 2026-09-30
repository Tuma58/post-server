#!/usr/bin/env bash
# lib/common.sh — общая библиотека для всех скриптов комплекта.
# Подключается через:  source "$(dirname "$0")/../lib/common.sh"
# Не предназначена для самостоятельного запуска.

# ---------------------------------------------------------------------------
# Строгий режим
# ---------------------------------------------------------------------------
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Пути
# ---------------------------------------------------------------------------
# REPO_ROOT определяется относительно этого файла, чтобы скрипты можно было
# запускать из любого каталога.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LIB_DIR}/.." && pwd)"
export LIB_DIR REPO_ROOT

LOG_DIR="${LOG_DIR:-/var/log/mailstack}"
STATE_DIR="${STATE_DIR:-/var/lib/mailstack}"

# ---------------------------------------------------------------------------
# Цвета (отключаются, если вывод не в терминал или задано NO_COLOR)
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
else
  C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_DIM=''
fi

# ---------------------------------------------------------------------------
# Счётчики результатов проверок
# ---------------------------------------------------------------------------
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0
FAILED_ITEMS=()
WARNED_ITEMS=()

# ---------------------------------------------------------------------------
# Логирование
# ---------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Файл журнала: если каталог недоступен для записи, пишем только в stdout.
_log_file() {
  if [[ -n "${MAILSTACK_LOG_FILE:-}" ]]; then
    printf '%s' "${MAILSTACK_LOG_FILE}"
    return 0
  fi
  return 1
}

_write_log() {
  local line="$1"
  local f
  if f="$(_log_file)"; then
    printf '%s\n' "${line}" >>"${f}" 2>/dev/null || true
  fi
}

log_init() {
  # log_init <имя-скрипта>
  local name="${1:-mailstack}"
  if mkdir -p "${LOG_DIR}" 2>/dev/null && [[ -w "${LOG_DIR}" ]]; then
    MAILSTACK_LOG_FILE="${LOG_DIR}/${name}-$(date '+%Y%m%d-%H%M%S').log"
    export MAILSTACK_LOG_FILE
    : >"${MAILSTACK_LOG_FILE}"
    chmod 0640 "${MAILSTACK_LOG_FILE}" 2>/dev/null || true
    log_debug "Журнал: ${MAILSTACK_LOG_FILE}"
  fi
}

info()  { local m="$*"; printf '%s[ИНФО]%s  %s\n'  "${C_BLUE}"   "${C_RESET}" "${m}"; _write_log "$(_ts) [ИНФО]  ${m}"; }
ok()    { local m="$*"; printf '%s[ OK ]%s  %s\n'  "${C_GREEN}"  "${C_RESET}" "${m}"; _write_log "$(_ts) [OK]    ${m}"; }
warn()  { local m="$*"; printf '%s[ПРЕД]%s  %s\n'  "${C_YELLOW}" "${C_RESET}" "${m}" >&2; _write_log "$(_ts) [ПРЕД]  ${m}"; }
err()   { local m="$*"; printf '%s[ОШИБ]%s  %s\n'  "${C_RED}"    "${C_RESET}" "${m}" >&2; _write_log "$(_ts) [ОШИБ]  ${m}"; }
log_debug() {
  [[ -n "${DEBUG:-}" ]] || { _write_log "$(_ts) [ОТЛ]   $*"; return 0; }
  local m="$*"; printf '%s[ ОТЛ]  %s%s\n' "${C_DIM}" "${m}" "${C_RESET}"; _write_log "$(_ts) [ОТЛ]   ${m}"
}

die() { err "$*"; exit 1; }

header() {
  local title="$*"
  printf '\n%s=== %s ===%s\n' "${C_BOLD}" "${title}" "${C_RESET}"
  _write_log "$(_ts) ===== ${title} ====="
}

# ---------------------------------------------------------------------------
# Результаты проверок (используются в checks/*.sh)
# ---------------------------------------------------------------------------
check_pass() {
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
  printf '  %s✔%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"
  _write_log "$(_ts) [ПРОШЛА] $*"
}

check_fail() {
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
  FAILED_ITEMS+=("$*")
  printf '  %s✘%s %s\n' "${C_RED}" "${C_RESET}" "$*"
  _write_log "$(_ts) [ПРОВАЛ] $*"
}

check_warn() {
  CHECKS_WARNED=$((CHECKS_WARNED + 1))
  WARNED_ITEMS+=("$*")
  printf '  %s!%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"
  _write_log "$(_ts) [ВНИМАНИЕ] $*"
}

check_info() {
  printf '  %s·%s %s\n' "${C_DIM}" "${C_RESET}" "$*"
  _write_log "$(_ts) [ЗАМЕТКА] $*"
}

# Итоговая сводка. Код возврата: 0 — нет провалов, 1 — есть провалы.
summary() {
  local total=$((CHECKS_PASSED + CHECKS_FAILED + CHECKS_WARNED))
  printf '\n%s--- Итог ---%s\n' "${C_BOLD}" "${C_RESET}"
  printf '  Всего проверок : %d\n' "${total}"
  printf '  %sПройдено%s       : %d\n' "${C_GREEN}"  "${C_RESET}" "${CHECKS_PASSED}"
  printf '  %sПредупреждений%s : %d\n' "${C_YELLOW}" "${C_RESET}" "${CHECKS_WARNED}"
  printf '  %sПровалов%s       : %d\n' "${C_RED}"    "${C_RESET}" "${CHECKS_FAILED}"

  if ((${#WARNED_ITEMS[@]} > 0)); then
    printf '\n%sПредупреждения:%s\n' "${C_YELLOW}" "${C_RESET}"
    local i
    for i in "${WARNED_ITEMS[@]}"; do printf '  - %s\n' "${i}"; done
  fi

  if ((${#FAILED_ITEMS[@]} > 0)); then
    printf '\n%sПровалы:%s\n' "${C_RED}" "${C_RESET}"
    local i
    for i in "${FAILED_ITEMS[@]}"; do printf '  - %s\n' "${i}"; done
    printf '\n%sРезультат: ЕСТЬ ПРОБЛЕМЫ%s\n' "${C_RED}" "${C_RESET}"
    return 1
  fi

  printf '\n%sРезультат: ВСЁ В ПОРЯДКЕ%s\n' "${C_GREEN}" "${C_RESET}"
  return 0
}

# ---------------------------------------------------------------------------
# Предусловия
# ---------------------------------------------------------------------------
require_root() {
  [[ ${EUID} -eq 0 ]] || die "Скрипт требует прав root. Запустите через sudo."
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || die "Не найдена утилита «${c}». Установите её и повторите."
  done
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_debian12() {
  [[ -r /etc/os-release ]] || die "Не найден /etc/os-release — ОС не определяется."
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "debian" ]]; then
    warn "Ожидается Debian, обнаружено «${ID:-неизвестно}». Скрипты могут работать некорректно."
    return 0
  fi
  local major="${VERSION_ID%%.*}"
  if [[ "${major}" != "12" ]]; then
    warn "Ожидается Debian 12, обнаружено «${VERSION_ID:-неизвестно}»."
  fi
}

# ---------------------------------------------------------------------------
# Конфигурация (.env)
# ---------------------------------------------------------------------------
# Загружает .env из корня репозитория. Формат: KEY=value, строки с # — комментарии.
load_env() {
  local env_file="${1:-${REPO_ROOT}/.env}"
  [[ -f "${env_file}" ]] || die "Не найден файл конфигурации «${env_file}». Скопируйте .env.example в .env и заполните."

  # Проверка прав: .env содержит пароли.
  local perms
  perms="$(stat -c '%a' "${env_file}" 2>/dev/null || stat -f '%A' "${env_file}" 2>/dev/null || echo '600')"
  if [[ "${perms}" != "600" && "${perms}" != "400" ]]; then
    warn ".env имеет права ${perms}. Рекомендуется 600: chmod 600 ${env_file}"
  fi

  set -a
  # shellcheck disable=SC1090
  . "${env_file}"
  set +a
  ENV_FILE_USED="${env_file}"
  export ENV_FILE_USED
  log_debug "Загружена конфигурация ${env_file}"
}

require_vars() {
  local v missing=()
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || missing+=("${v}")
  done
  if ((${#missing[@]} > 0)); then
    die "В .env не заданы обязательные параметры: ${missing[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Утилиты
# ---------------------------------------------------------------------------
confirm() {
  # confirm "Вопрос?"  → 0 если да. Автоответ «да» при ASSUME_YES=1.
  local prompt="${1:-Продолжить?}"
  if [[ -n "${ASSUME_YES:-}" ]]; then
    info "${prompt} → да (ASSUME_YES)"
    return 0
  fi
  local reply
  read -r -p "${prompt} [y/N] " reply || true
  [[ "${reply}" =~ ^([yY]|[dD]|[дД])$ ]]
}

backup_file() {
  # Делает резервную копию файла перед правкой.
  local f="$1"
  [[ -f "${f}" ]] || return 0
  local bak="${f}.mailstack-bak-$(date '+%Y%m%d-%H%M%S')"
  cp -a "${f}" "${bak}"
  log_debug "Резервная копия: ${bak}"
}

gen_password() {
  # gen_password [длина] — безопасный пароль без неоднозначных символов.
  local len="${1:-24}"
  # tr | head вызывает SIGPIPE → код 141. Это норма, глушим ERR-trap для этой строки.
  ( LC_ALL=C tr -dc 'A-Za-z0-9!#%*+-=?@^_' </dev/urandom | head -c "${len}" ) 2>/dev/null || true
  printf '\n'
}

# Публичный IPv4 сервера. Сначала локальные интерфейсы, затем внешний сервис.
detect_public_ip4() {
  local ip=""
  if have_cmd curl; then
    ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    [[ -z "${ip}" ]] && ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "${ip}" ]] && have_cmd ip; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
  fi
  printf '%s' "${ip}"
}

detect_public_ip6() {
  local ip=""
  if have_cmd curl; then
    ip="$(curl -6 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  fi
  printf '%s' "${ip}"
}

# Порт SSH из sshd_config (по умолчанию 22).
detect_ssh_port() {
  local p=""
  if [[ -r /etc/ssh/sshd_config ]]; then
    p="$(awk '/^[[:space:]]*Port[[:space:]]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
  fi
  printf '%s' "${p:-22}"
}

# TCP-проверка без внешних зависимостей.
tcp_probe() {
  # tcp_probe <хост> <порт> [таймаут]
  local host="$1" port="$2" timeout="${3:-5}"
  timeout "${timeout}" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

# Путь установки mailcow.
mailcow_dir() {
  printf '%s' "${MAILCOW_DIR:-/opt/mailcow-dockerized}"
}

# Обёртка docker compose (v2 plugin), выполняется в каталоге mailcow.
mailcow_compose() {
  local dir
  dir="$(mailcow_dir)"
  [[ -d "${dir}" ]] || die "Каталог mailcow «${dir}» не найден. Сначала выполните deploy/30-install-mailcow.sh"
  ( cd "${dir}" && docker compose "$@" )
}

# Чтение переменной из mailcow.conf.
mailcow_conf_get() {
  local key="$1" dir
  dir="$(mailcow_dir)"
  [[ -r "${dir}/mailcow.conf" ]] || return 1
  awk -F= -v k="${key}" '$1==k {sub(/^[^=]*=/,""); print; exit}' "${dir}/mailcow.conf"
}

# ---------------------------------------------------------------------------
# Обработка ошибок
# ---------------------------------------------------------------------------
_on_err() {
  local code=$? line=${1:-?}
  err "Сбой на строке ${line} (код ${code}) в ${BASH_SOURCE[1]:-скрипте}."
  if [[ -n "${MAILSTACK_LOG_FILE:-}" ]]; then
    err "Подробности в журнале: ${MAILSTACK_LOG_FILE}"
  fi
}
trap '_on_err ${LINENO}' ERR

# Пометка успешного прохождения шага (для идемпотентности).
mark_step_done() {
  local step="$1"
  mkdir -p "${STATE_DIR}" 2>/dev/null || return 0
  date '+%Y-%m-%dT%H:%M:%S%z' >"${STATE_DIR}/${step}.done" 2>/dev/null || true
}

is_step_done() {
  [[ -f "${STATE_DIR}/$1.done" ]]
}
