#!/usr/bin/env bash
# =============================================================================
# mailcow-api.sh — обёртка над REST API mailcow.
#
# Может использоваться двумя способами:
#   1) как библиотека:  source tools/mailcow-api.sh   → функция api_call
#   2) как утилита:     ./tools/mailcow-api.sh GET /api/v1/get/domain/all
#
# Требует MAILCOW_API_KEY в .env и доступ к веб-интерфейсу mailcow.
# =============================================================================
set -Eeuo pipefail

# Определяем, запущен ли файл напрямую или подключён через source.
_MCAPI_SOURCED=0
(return 0 2>/dev/null) && _MCAPI_SOURCED=1

_MCAPI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_MCAPI_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# api_call <МЕТОД> <ПУТЬ> [JSON-тело]
# Выводит тело ответа в stdout. Код возврата 0 при HTTP 2xx.
# ---------------------------------------------------------------------------
api_call() {
  local method="$1" path="$2" body="${3:-}"

  [[ -n "${MAILCOW_API_KEY:-}" ]] || die "Не задан MAILCOW_API_KEY в .env. Создайте ключ: веб-панель → Configuration → Access → API"

  local base="https://${MAIL_HOSTNAME}"
  # Локальное обращение надёжнее: работает даже если DNS ещё не распространился.
  local url="${base}${path}"

  local -a curl_args=(
    --silent --show-error
    --location
    --max-time 30
    --insecure                       # сертификат может быть ещё self-signed
    --resolve "${MAIL_HOSTNAME}:${HTTPS_PORT:-443}:127.0.0.1"
    --header "X-API-Key: ${MAILCOW_API_KEY}"
    --header "Content-Type: application/json"
    --request "${method}"
    --write-out '\n__HTTP_CODE__:%{http_code}'
  )

  if [[ -n "${body}" ]]; then
    curl_args+=(--data "${body}")
  fi

  local raw code payload
  raw="$(curl "${curl_args[@]}" "${url}" 2>&1)" || {
    err "Запрос к API не удался: ${method} ${path}"
    printf '%s\n' "${raw}" >&2
    return 1
  }

  code="$(printf '%s' "${raw}" | grep -o '__HTTP_CODE__:[0-9]*' | tail -n1 | cut -d: -f2)"
  payload="$(printf '%s' "${raw}" | sed 's/__HTTP_CODE__:[0-9]*$//')"

  log_debug "API ${method} ${path} → HTTP ${code:-?}"

  if [[ "${code}" =~ ^2 ]]; then
    printf '%s' "${payload}"
    return 0
  fi

  err "API вернул HTTP ${code:-нет ответа} на ${method} ${path}"
  case "${code}" in
    401) err "Ключ API неверен или не активен. Проверьте MAILCOW_API_KEY в .env" ;;
    403) err "Доступ запрещён. Проверьте, что в настройках ключа разрешён IP 127.0.0.1 и включён режим чтение-запись" ;;
    404) err "Эндпоинт не найден. Возможно, версия mailcow отличается" ;;
    000|"") err "Сервер недоступен. Проверьте, что контейнеры запущены: cd $(mailcow_dir) && docker compose ps" ;;
  esac
  printf '%s\n' "${payload}" >&2
  return 1
}

# ---------------------------------------------------------------------------
# api_ok <ответ> — проверяет, что mailcow отчитался об успехе.
# API отвечает массивом вида [{"type":"success","msg":[...]}]
# ---------------------------------------------------------------------------
api_ok() {
  local resp="$1"
  [[ -n "${resp}" ]] || return 1
  if have_cmd jq; then
    # Успех, если нет ни одного объекта с type != success.
    local bad
    bad="$(printf '%s' "${resp}" | jq -r '
      if type == "array" then
        [.[] | select(.type? // "success" != "success")] | length
      elif type == "object" then
        (if (.type? // "success") != "success" then 1 else 0 end)
      else 0 end' 2>/dev/null || echo 1)"
    [[ "${bad}" == "0" ]]
  else
    ! grep -qi '"type"[[:space:]]*:[[:space:]]*"\(danger\|error\)"' <<<"${resp}"
  fi
}

# ---------------------------------------------------------------------------
# api_msg <ответ> — вытаскивает человекочитаемое сообщение.
# ---------------------------------------------------------------------------
api_msg() {
  local resp="$1"
  if have_cmd jq; then
    printf '%s' "${resp}" | jq -r '
      if type == "array" then [.[] | (.msg | if type=="array" then join(" ") else tostring end)] | join("; ")
      elif type == "object" then (.msg | if type=="array" then join(" ") else tostring end)
      else tostring end' 2>/dev/null || printf '%s' "${resp}"
  else
    printf '%s' "${resp}"
  fi
}

# ---------------------------------------------------------------------------
# Режим самостоятельной утилиты
# ---------------------------------------------------------------------------
if ((_MCAPI_SOURCED == 0)); then
  load_env
  require_vars MAIL_HOSTNAME

  if (($# < 2)); then
    cat <<EOF
Использование: $0 <МЕТОД> <ПУТЬ> [JSON-тело]

Примеры:
  $0 GET  /api/v1/get/domain/all
  $0 GET  /api/v1/get/mailbox/all
  $0 GET  /api/v1/get/dkim/${MAIL_DOMAIN:-example.com}
  $0 POST /api/v1/add/mailbox '{"local_part":"ivan","domain":"${MAIL_DOMAIN:-example.com}","name":"Иван","password":"СекретныйПароль1!","password2":"СекретныйПароль1!","quota":"2048","active":"1"}'
  $0 POST /api/v1/delete/mailbox '["ivan@${MAIL_DOMAIN:-example.com}"]'

Список эндпоинтов: https://${MAIL_HOSTNAME:-mail.example.com}/api/
EOF
    exit 1
  fi

  RESP="$(api_call "$1" "$2" "${3:-}")"
  if have_cmd jq; then
    printf '%s' "${RESP}" | jq . 2>/dev/null || printf '%s\n' "${RESP}"
  else
    printf '%s\n' "${RESP}"
  fi
fi
