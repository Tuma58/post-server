#!/usr/bin/env bash
# =============================================================================
# 40-postinstall.sh — настройка после установки:
# создаёт почтовый домен, первый ящик, DKIM-ключ и выводит DNS-записи.
#
# Требует MAILCOW_API_KEY в .env (создаётся в веб-панели).
# Скрипт идемпотентен: повторный запуск не ломает уже созданное.
# =============================================================================
set -Eeuo pipefail
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SELF_DIR}/lib/common.sh"
# shellcheck source=../tools/mailcow-api.sh
source "${_SELF_DIR}/tools/mailcow-api.sh"

log_init "postinstall"
require_root
require_cmd curl docker
load_env
require_vars MAIL_DOMAIN MAIL_HOSTNAME ADMIN_EMAIL

CREDS_FILE=/root/mailstack-credentials.txt

header "Настройка после установки"

# --- 1. Проверка готовности стека ------------------------------------------
header "1. Проверка стека mailcow"
MCDIR="$(mailcow_dir)"
[[ -d "${MCDIR}" ]] || die "mailcow не установлен. Выполните deploy/30-install-mailcow.sh"

if ! curl -k -fsS --max-time 10 "https://127.0.0.1:${HTTPS_PORT:-443}/" -o /dev/null 2>/dev/null; then
  err "Веб-интерфейс mailcow не отвечает на https://127.0.0.1:${HTTPS_PORT:-443}/"
  info "Проверьте контейнеры: cd ${MCDIR} && docker compose ps"
  exit 1
fi
ok "Веб-интерфейс отвечает"

# --- 2. Наличие API-ключа ---------------------------------------------------
header "2. Ключ API"
if [[ -z "${MAILCOW_API_KEY:-}" ]]; then
  err "В .env не задан MAILCOW_API_KEY."
  printf '\n'
  info "Как получить ключ (2 минуты):"
  info "  1. Откройте https://${MAIL_HOSTNAME}/"
  info "     Если DNS ещё не настроен, пробросьте порт со своей машины:"
  info "       ssh -L 8443:127.0.0.1:443 root@<IP сервера>"
  info "     и откройте https://127.0.0.1:8443/"
  info "  2. Войдите: логин admin, пароль moohoo"
  info "  3. СМЕНИТЕ пароль администратора (System → Administrator)"
  info "  4. Configuration → Access → API:"
  info "       - создайте ключ «Read-Write»"
  info "       - в поле разрешённых IP укажите 127.0.0.1"
  info "       - активируйте ключ галочкой"
  info "  5. Скопируйте ключ в .env:  MAILCOW_API_KEY=<ключ>"
  info "  6. Запустите этот скрипт снова: sudo ./deploy/40-postinstall.sh"
  printf '\n'
  exit 1
fi

# Проверяем ключ живым запросом.
if ! DOMAINS_JSON="$(api_call GET /api/v1/get/domain/all 2>/dev/null)"; then
  die "Ключ API не работает. Проверьте, что он активен и разрешён для 127.0.0.1"
fi
ok "Ключ API действителен"

# --- 3. Почтовый домен ------------------------------------------------------
header "3. Почтовый домен ${MAIL_DOMAIN}"
DOMAIN_EXISTS=0
if have_cmd jq; then
  if printf '%s' "${DOMAINS_JSON}" | jq -e --arg d "${MAIL_DOMAIN}" 'if type=="array" then any(.[]; .domain_name == $d) else false end' >/dev/null 2>&1; then
    DOMAIN_EXISTS=1
  fi
else
  grep -q "\"${MAIL_DOMAIN}\"" <<<"${DOMAINS_JSON}" && DOMAIN_EXISTS=1
fi

if ((DOMAIN_EXISTS == 1)); then
  ok "Домен ${MAIL_DOMAIN} уже добавлен"
else
  info "Добавляю домен ${MAIL_DOMAIN}"
  # Квота домена: 20 ящиков × 3 ГБ с запасом.
  DOMAIN_BODY="$(cat <<EOF
{
  "domain": "${MAIL_DOMAIN}",
  "description": "Основной почтовый домен",
  "aliases": "100",
  "mailboxes": "25",
  "defquota": "${FIRST_MAILBOX_QUOTA_MB:-3072}",
  "maxquota": "10240",
  "quota": "76800",
  "active": "1",
  "rl_value": "",
  "rl_frame": "s",
  "backupmx": "0",
  "relay_all_recipients": "0",
  "gal": "1"
}
EOF
)"
  RESP="$(api_call POST /api/v1/add/domain "${DOMAIN_BODY}")" || die "Не удалось создать домен"
  if api_ok "${RESP}"; then
    ok "Домен ${MAIL_DOMAIN} создан (до 25 ящиков, общая квота 75 ГБ)"
  else
    warn "Ответ API: $(api_msg "${RESP}")"
    # Домен мог существовать — не считаем фатальным.
  fi
fi

# --- 4. Первый почтовый ящик -----------------------------------------------
header "4. Первый почтовый ящик"
MBOX_LOCAL="${FIRST_MAILBOX_LOCAL:-admin}"
MBOX_ADDR="${MBOX_LOCAL}@${MAIL_DOMAIN}"

MBOXES_JSON="$(api_call GET /api/v1/get/mailbox/all 2>/dev/null || echo '[]')"
MBOX_EXISTS=0
if have_cmd jq; then
  if printf '%s' "${MBOXES_JSON}" | jq -e --arg m "${MBOX_ADDR}" 'if type=="array" then any(.[]; .username == $m) else false end' >/dev/null 2>&1; then
    MBOX_EXISTS=1
  fi
else
  grep -q "\"${MBOX_ADDR}\"" <<<"${MBOXES_JSON}" && MBOX_EXISTS=1
fi

if ((MBOX_EXISTS == 1)); then
  ok "Ящик ${MBOX_ADDR} уже существует"
else
  MBOX_PASS="${FIRST_MAILBOX_PASSWORD:-}"
  if [[ -z "${MBOX_PASS}" ]]; then
    MBOX_PASS="$(gen_password 20)"
    GENERATED_PASS=1
  fi

  info "Создаю ящик ${MBOX_ADDR}"
  MBOX_BODY="$(cat <<EOF
{
  "local_part": "${MBOX_LOCAL}",
  "domain": "${MAIL_DOMAIN}",
  "name": "${FIRST_MAILBOX_NAME:-Администратор}",
  "quota": "${FIRST_MAILBOX_QUOTA_MB:-3072}",
  "password": "${MBOX_PASS}",
  "password2": "${MBOX_PASS}",
  "active": "1",
  "force_pw_update": "0",
  "tls_enforce_in": "0",
  "tls_enforce_out": "0"
}
EOF
)"
  RESP="$(api_call POST /api/v1/add/mailbox "${MBOX_BODY}")" || die "Не удалось создать ящик"
  if api_ok "${RESP}"; then
    ok "Ящик ${MBOX_ADDR} создан (квота ${FIRST_MAILBOX_QUOTA_MB:-3072} МБ)"

    # Сохраняем учётные данные в защищённый файл.
    touch "${CREDS_FILE}"
    chmod 600 "${CREDS_FILE}"
    {
      printf '=== Учётные данные почтового сервера ===\n'
      printf 'Создано: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
      printf 'Веб-панель администратора: https://%s/\n' "${MAIL_HOSTNAME}"
      printf 'Веб-почта (SOGo):          https://%s/SOGo/\n\n' "${MAIL_HOSTNAME}"
      printf 'Почтовый ящик: %s\n' "${MBOX_ADDR}"
      printf 'Пароль:        %s\n\n' "${MBOX_PASS}"
      printf 'ВНИМАНИЕ: удалите этот файл после переноса паролей в менеджер паролей.\n'
    } >>"${CREDS_FILE}"
    ok "Учётные данные записаны в ${CREDS_FILE} (права 600)"
    if [[ -n "${GENERATED_PASS:-}" ]]; then
      warn "Пароль ящика сгенерирован автоматически, смотрите ${CREDS_FILE}"
    fi
  else
    warn "Ответ API: $(api_msg "${RESP}")"
    warn "Частая причина: пароль не прошёл политику сложности. Задайте FIRST_MAILBOX_PASSWORD в .env"
  fi
fi

# --- 5. DKIM-ключ -----------------------------------------------------------
header "5. DKIM-ключ"
DKIM_JSON="$(api_call GET "/api/v1/get/dkim/${MAIL_DOMAIN}" 2>/dev/null || echo '{}')"
DKIM_PRESENT=0
if have_cmd jq; then
  if printf '%s' "${DKIM_JSON}" | jq -e '.dkim_txt? // empty | length > 0' >/dev/null 2>&1; then
    DKIM_PRESENT=1
  fi
else
  grep -q 'dkim_txt' <<<"${DKIM_JSON}" && grep -q 'v=DKIM1' <<<"${DKIM_JSON}" && DKIM_PRESENT=1
fi

if ((DKIM_PRESENT == 1)); then
  ok "DKIM-ключ для ${MAIL_DOMAIN} уже существует"
else
  info "Генерирую DKIM-ключ 2048 бит"
  DKIM_BODY="$(cat <<EOF
{
  "domains": "${MAIL_DOMAIN}",
  "dkim_selector": "dkim",
  "key_size": "2048"
}
EOF
)"
  RESP="$(api_call POST /api/v1/add/dkim "${DKIM_BODY}")" || warn "Не удалось создать DKIM через API"
  if api_ok "${RESP:-}"; then
    ok "DKIM-ключ создан (селектор dkim, 2048 бит)"
  else
    warn "Ответ API: $(api_msg "${RESP:-}")"
    warn "Создайте ключ вручную: веб-панель → Configuration → Options → ARC/DKIM keys"
  fi
fi

# --- 6. Проверка созданного -------------------------------------------------
header "6. Контрольная проверка"
FINAL_DOMAINS="$(api_call GET /api/v1/get/domain/all 2>/dev/null || echo '[]')"
FINAL_MBOXES="$(api_call GET /api/v1/get/mailbox/all 2>/dev/null || echo '[]')"

if have_cmd jq; then
  D_COUNT="$(printf '%s' "${FINAL_DOMAINS}" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
  M_COUNT="$(printf '%s' "${FINAL_MBOXES}" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
  info "Домены: ${D_COUNT}, ящики: ${M_COUNT}"
  if [[ "${M_COUNT}" != "0" ]]; then
    printf '%s' "${FINAL_MBOXES}" | jq -r 'if type=="array" then .[] | "    \(.username)  квота \(.quota // 0 | tonumber / 1048576 | floor) МБ  активен: \(if (.active|tostring)=="1" then "да" else "нет" end)" else empty end' 2>/dev/null || true
  fi
fi

# --- 7. DNS-записи ----------------------------------------------------------
header "7. DNS-записи для домена"
info "Полный набор записей генерирует отдельный скрипт:"
info "    sudo ./tools/gen-dns-records.sh"
printf '\n'
warn "Пока DNS-записи (SPF, DKIM, DMARC, MX, PTR) не настроены, письма будут"
warn "попадать в спам или отклоняться. Это обязательный шаг."

# --- Итог -------------------------------------------------------------------
header "Готово"
mark_step_done "40-postinstall"
ok "Первичная настройка завершена."
printf '\n'
info "Дальнейшие шаги по порядку:"
info "  1. sudo ./tools/gen-dns-records.sh      — получить DNS-записи и внести их у регистратора"
info "  2. sudo ./security/00-harden-all.sh     — применить настройки безопасности"
info "  3. sudo ./checks/00-full-check.sh       — полная проверка после установки"
