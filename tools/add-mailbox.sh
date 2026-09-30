#!/usr/bin/env bash
# =============================================================================
# add-mailbox.sh — создание почтового ящика.
#
# Использование:
#   ./tools/add-mailbox.sh ivan "Иван Петров" [квота_МБ] [пароль]
#
# Если пароль не указан, генерируется автоматически и выводится на экран.
# =============================================================================
set -Eeuo pipefail
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SELF_DIR}/lib/common.sh"
# shellcheck source=../tools/mailcow-api.sh
source "${_SELF_DIR}/tools/mailcow-api.sh"

load_env
require_vars MAIL_DOMAIN MAILCOW_API_KEY

usage() {
  cat <<EOF
Создание почтового ящика.

Использование:
  $0 <локальная_часть> <Имя Фамилия> [квота_МБ] [пароль]

Примеры:
  $0 ivan "Иван Петров"
  $0 ivan "Иван Петров" 5120
  $0 ivan "Иван Петров" 5120 'НадёжныйПароль123!'

Параметры:
  локальная_часть  — то, что до @ в адресе (латиница, цифры, точка, дефис)
  Имя Фамилия      — отображаемое имя в письмах
  квота_МБ         — размер ящика в мегабайтах (по умолчанию ${FIRST_MAILBOX_QUOTA_MB:-3072})
  пароль           — если не указан, будет сгенерирован

Домен берётся из .env: ${MAIL_DOMAIN}
EOF
  exit 1
}

(($# >= 2)) || usage

LOCAL_PART="$1"
FULL_NAME="$2"
QUOTA="${3:-${FIRST_MAILBOX_QUOTA_MB:-3072}}"
PASSWORD="${4:-}"

# --- Валидация --------------------------------------------------------------
if [[ ! "${LOCAL_PART}" =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]]; then
  die "Некорректная локальная часть «${LOCAL_PART}». Допустимы строчные латинские буквы, цифры, точка, дефис, подчёркивание."
fi

if [[ ! "${QUOTA}" =~ ^[0-9]+$ ]]; then
  die "Квота должна быть числом в мегабайтах, получено «${QUOTA}»"
fi

ADDRESS="${LOCAL_PART}@${MAIL_DOMAIN}"

GENERATED=0
if [[ -z "${PASSWORD}" ]]; then
  PASSWORD="$(gen_password 18)"
  GENERATED=1
fi

if ((${#PASSWORD} < 8)); then
  die "Пароль короче 8 символов. mailcow отклонит такой пароль."
fi

header "Создание ящика ${ADDRESS}"
info "Имя: ${FULL_NAME}"
info "Квота: ${QUOTA} МБ"

# --- Проверка на существование ----------------------------------------------
EXISTING="$(api_call GET /api/v1/get/mailbox/all 2>/dev/null || echo '[]')"
if have_cmd jq; then
  if printf '%s' "${EXISTING}" | jq -e --arg m "${ADDRESS}" 'if type=="array" then any(.[]; .username == $m) else false end' >/dev/null 2>&1; then
    die "Ящик ${ADDRESS} уже существует."
  fi
fi

# --- Создание ---------------------------------------------------------------
BODY="$(cat <<EOF
{
  "local_part": "${LOCAL_PART}",
  "domain": "${MAIL_DOMAIN}",
  "name": "${FULL_NAME}",
  "quota": "${QUOTA}",
  "password": "${PASSWORD}",
  "password2": "${PASSWORD}",
  "active": "1",
  "force_pw_update": "0",
  "tls_enforce_in": "0",
  "tls_enforce_out": "0"
}
EOF
)"

RESP="$(api_call POST /api/v1/add/mailbox "${BODY}")" || die "Запрос к API не выполнен"

if api_ok "${RESP}"; then
  ok "Ящик ${ADDRESS} создан"
  printf '\n'
  printf '%s=== Данные для пользователя ===%s\n' "${C_BOLD}" "${C_RESET}"
  printf '  Адрес электронной почты : %s\n' "${ADDRESS}"
  printf '  Пароль                  : %s\n' "${PASSWORD}"
  printf '  Веб-почта               : https://%s/SOGo/\n' "${MAIL_HOSTNAME}"
  printf '\n'
  printf '  Настройки почтового клиента:\n'
  printf '    Входящая почта (IMAP) : %s, порт 993, SSL/TLS\n' "${MAIL_HOSTNAME}"
  printf '    Исходящая (SMTP)      : %s, порт 587, STARTTLS\n' "${MAIL_HOSTNAME}"
  printf '    Имя пользователя      : %s (полный адрес)\n' "${ADDRESS}"
  printf '\n'
  if ((GENERATED == 1)); then
    warn "Пароль сгенерирован автоматически. Передайте его пользователю безопасным способом."
    warn "Не отправляйте пароль в том же канале, что и логин."
  fi
  info "Подробная инструкция для пользователя: docs/USER.md"
else
  err "Не удалось создать ящик: $(api_msg "${RESP}")"
  info "Частые причины:"
  info "  - пароль не отвечает политике сложности"
  info "  - исчерпан лимит ящиков для домена (проверьте в веб-панели)"
  info "  - превышена суммарная квота домена"
  exit 1
fi
