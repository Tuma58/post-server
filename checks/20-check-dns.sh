#!/usr/bin/env bash
# =============================================================================
# 20-check-dns.sh — проверка DNS-записей почтового домена.
# Только чтение. Запросы идут к публичному DNS, чтобы видеть картину извне.
# =============================================================================
set -Eeuo pipefail
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SELF_DIR}/lib/common.sh"
# shellcheck source=../tools/mailcow-api.sh
source "${_SELF_DIR}/tools/mailcow-api.sh" 2>/dev/null || true

log_init "check-dns"
load_env
require_vars MAIL_DOMAIN MAIL_HOSTNAME
require_cmd dig

# Внешний резолвер: показывает то, что видят другие почтовые серверы,
# минуя локальный кэш.
RESOLVER="${DNS_RESOLVER:-1.1.1.1}"
DIG_OPTS=(+short +time=3 +tries=2 "@${RESOLVER}")

IP4="$(detect_public_ip4)"

header "Проверка DNS для ${MAIL_DOMAIN}"
check_info "Резолвер: ${RESOLVER}, IP сервера: ${IP4:-неизвестен}"

# --- 1. A-запись хоста ------------------------------------------------------
header "1. A-запись почтового сервера"
HOST_A="$(dig "${DIG_OPTS[@]}" A "${MAIL_HOSTNAME}" 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)"
if [[ -z "${HOST_A}" ]]; then
  check_fail "A-запись ${MAIL_HOSTNAME} отсутствует. Создайте: ${MAIL_HOSTNAME} A ${IP4:-<IP>}"
elif [[ -n "${IP4}" && "${HOST_A}" == "${IP4}" ]]; then
  check_pass "A-запись ${MAIL_HOSTNAME} → ${HOST_A}"
else
  check_fail "A-запись ${MAIL_HOSTNAME} → ${HOST_A}, но IP сервера ${IP4}. Сертификат не выпустится."
fi

if [[ "${ENABLE_IPV6:-no}" == "yes" ]]; then
  HOST_AAAA="$(dig "${DIG_OPTS[@]}" AAAA "${MAIL_HOSTNAME}" 2>/dev/null | head -n1 || true)"
  if [[ -n "${HOST_AAAA}" ]]; then
    check_pass "AAAA-запись ${MAIL_HOSTNAME} → ${HOST_AAAA}"
  else
    check_warn "ENABLE_IPV6=yes, но AAAA-записи нет"
  fi
fi

# --- 2. MX ------------------------------------------------------------------
header "2. MX-запись"
MX_ALL="$(dig "${DIG_OPTS[@]}" MX "${MAIL_DOMAIN}" 2>/dev/null || true)"
if [[ -z "${MX_ALL}" ]]; then
  check_fail "MX-запись для ${MAIL_DOMAIN} отсутствует. Почта не будет приходить. Добавьте: ${MAIL_DOMAIN} MX 10 ${MAIL_HOSTNAME}"
else
  MX_COUNT="$(printf '%s\n' "${MX_ALL}" | grep -c . || echo 0)"
  check_info "Найдено MX-записей: ${MX_COUNT}"
  printf '%s\n' "${MX_ALL}" | sed 's/^/        /'

  if grep -qi "${MAIL_HOSTNAME}" <<<"${MX_ALL}"; then
    check_pass "MX указывает на ${MAIL_HOSTNAME}"
  else
    check_fail "MX НЕ указывает на ${MAIL_HOSTNAME}. Почта уходит другому серверу."
  fi

  if ((MX_COUNT > 1)); then
    check_warn "Несколько MX-записей. Убедитесь, что лишние (от прежнего провайдера) удалены."
  fi

  # MX не должен быть CNAME — это нарушение RFC.
  MX_HOST="$(printf '%s\n' "${MX_ALL}" | head -n1 | awk '{print $2}' | sed 's/\.$//')"
  if [[ -n "${MX_HOST}" ]]; then
    MX_CNAME="$(dig "${DIG_OPTS[@]}" CNAME "${MX_HOST}" 2>/dev/null | head -n1 || true)"
    if [[ -n "${MX_CNAME}" ]]; then
      check_fail "MX указывает на CNAME (${MX_HOST} → ${MX_CNAME}). Это нарушает RFC 2181, часть серверов откажет в доставке."
    else
      check_pass "MX указывает на A-запись, а не на CNAME"
    fi
  fi
fi

# --- 3. PTR (обратная запись) ----------------------------------------------
header "3. PTR-запись (rDNS)"
if [[ -z "${IP4}" ]]; then
  check_warn "IP сервера неизвестен, проверка PTR пропущена"
else
  PTR="$(dig "${DIG_OPTS[@]}" -x "${IP4}" 2>/dev/null | sed 's/\.$//' | head -n1 || true)"
  if [[ -z "${PTR}" ]]; then
    check_fail "PTR-запись для ${IP4} отсутствует. Gmail, Outlook и Яндекс будут отклонять почту. Настройте rDNS в панели VPS-провайдера."
  elif [[ "${PTR}" == "${MAIL_HOSTNAME}" ]]; then
    check_pass "PTR ${IP4} → ${PTR}"
    # Прямая и обратная записи должны совпадать (FCrDNS).
    PTR_FORWARD="$(dig "${DIG_OPTS[@]}" A "${PTR}" 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)"
    if [[ "${PTR_FORWARD}" == "${IP4}" ]]; then
      check_pass "Прямая и обратная записи согласованы (FCrDNS пройден)"
    else
      check_fail "PTR указывает на ${PTR}, но A-запись этого имени → ${PTR_FORWARD:-нет}. Проверка FCrDNS не пройдена."
    fi
  else
    check_fail "PTR ${IP4} → ${PTR}, а должно быть ${MAIL_HOSTNAME}. Исправьте rDNS у провайдера VPS."
  fi
fi

# --- 4. SPF -----------------------------------------------------------------
header "4. SPF"
TXT_ALL="$(dig "${DIG_OPTS[@]}" TXT "${MAIL_DOMAIN}" 2>/dev/null | tr -d '"' || true)"
SPF_RECORDS="$(printf '%s\n' "${TXT_ALL}" | grep -i 'v=spf1' || true)"
SPF_COUNT="$(printf '%s\n' "${SPF_RECORDS}" | grep -c 'v=spf1' || echo 0)"

if ((SPF_COUNT == 0)); then
  check_fail "SPF-запись отсутствует. Письма будут помечаться как спам. Добавьте TXT: \"v=spf1 mx a:${MAIL_HOSTNAME} -all\""
elif ((SPF_COUNT > 1)); then
  check_fail "Найдено ${SPF_COUNT} SPF-записей. Допустима ТОЛЬКО ОДНА, иначе проверка завершается ошибкой permerror."
  printf '%s\n' "${SPF_RECORDS}" | sed 's/^/        /'
else
  check_pass "SPF-запись найдена (одна, как и должно быть)"
  check_info "${SPF_RECORDS}"

  # Разбор политики.
  if grep -q '\-all' <<<"${SPF_RECORDS}"; then
    check_pass "Политика -all (жёсткая): подделка адреса отклоняется"
  elif grep -q '~all' <<<"${SPF_RECORDS}"; then
    check_warn "Политика ~all (мягкая): письма помечаются, но принимаются. Для продакшена рекомендуется -all"
  elif grep -q '?all' <<<"${SPF_RECORDS}"; then
    check_fail "Политика ?all (нейтральная) не защищает от подделки. Замените на -all"
  elif grep -q '+all' <<<"${SPF_RECORDS}"; then
    check_fail "Политика +all разрешает отправку от вашего имени ЛЮБОМУ серверу. Немедленно исправьте на -all"
  fi

  # Сервер должен попадать в SPF.
  if grep -qE "(mx|a:${MAIL_HOSTNAME//./\\.}|ip4:${IP4//./\\.})" <<<"${SPF_RECORDS}"; then
    check_pass "Почтовый сервер входит в SPF"
  else
    check_fail "SPF не включает ваш сервер. Добавьте mx или a:${MAIL_HOSTNAME}"
  fi

  # Лимит DNS-запросов: не более 10 include/a/mx/ptr/exists.
  LOOKUPS="$(grep -oE '(include:|a:|mx:|ptr:|exists:|redirect=)' <<<"${SPF_RECORDS}" | wc -l | tr -d ' ')"
  # mx и a без двоеточия тоже считаются.
  grep -qE '(^| )mx( |$)' <<<"${SPF_RECORDS}" && LOOKUPS=$((LOOKUPS + 1))
  grep -qE '(^| )a( |$)' <<<"${SPF_RECORDS}" && LOOKUPS=$((LOOKUPS + 1))
  if ((LOOKUPS > 10)); then
    check_fail "SPF содержит ${LOOKUPS} DNS-запросов, лимит 10. Проверка вернёт permerror."
  else
    check_pass "DNS-запросов в SPF: ${LOOKUPS} из 10 допустимых"
  fi
fi

# --- 5. DKIM ----------------------------------------------------------------
header "5. DKIM"
# Селектор берём из mailcow, если доступен API, иначе перебираем типичные.
DKIM_SELECTOR="dkim"
if [[ -n "${MAILCOW_API_KEY:-}" ]] && declare -F api_call >/dev/null 2>&1; then
  DK_JSON="$(api_call GET "/api/v1/get/dkim/${MAIL_DOMAIN}" 2>/dev/null || echo '{}')"
  if have_cmd jq; then
    SEL="$(printf '%s' "${DK_JSON}" | jq -r '.dkim_selector // empty' 2>/dev/null || true)"
    [[ -n "${SEL}" ]] && DKIM_SELECTOR="${SEL}"
    LOCAL_DKIM="$(printf '%s' "${DK_JSON}" | jq -r '.dkim_txt // empty' 2>/dev/null || true)"
  fi
fi

DKIM_PUBLISHED="$(dig "${DIG_OPTS[@]}" TXT "${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}" 2>/dev/null | tr -d '"' | tr -d ' ' || true)"

if [[ -z "${DKIM_PUBLISHED}" ]]; then
  check_fail "DKIM-запись ${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN} не опубликована. Письма не будут подписаны — высокий риск попадания в спам."
  if [[ -n "${LOCAL_DKIM:-}" ]]; then
    check_info "Значение для публикации получено из mailcow, смотрите ./tools/gen-dns-records.sh"
  fi
else
  check_pass "DKIM-запись опубликована (селектор ${DKIM_SELECTOR})"

  if grep -q 'v=DKIM1' <<<"${DKIM_PUBLISHED}"; then
    check_pass "Формат записи корректен (v=DKIM1)"
  else
    check_fail "DKIM-запись не содержит v=DKIM1 — формат неверен"
  fi

  # Сверяем опубликованный ключ с ключом на сервере.
  if [[ -n "${LOCAL_DKIM:-}" ]]; then
    LOCAL_P="$(printf '%s' "${LOCAL_DKIM}" | tr -d ' "' | grep -oE 'p=[A-Za-z0-9+/=]+' | head -n1 || true)"
    PUB_P="$(printf '%s' "${DKIM_PUBLISHED}" | grep -oE 'p=[A-Za-z0-9+/=]+' | head -n1 || true)"
    if [[ -n "${LOCAL_P}" && -n "${PUB_P}" ]]; then
      if [[ "${LOCAL_P}" == "${PUB_P}" ]]; then
        check_pass "Опубликованный ключ совпадает с ключом на сервере"
      else
        check_fail "Опубликованный DKIM-ключ НЕ совпадает с ключом mailcow. Подписи не пройдут проверку. Обновите TXT-запись."
      fi
    fi
  fi

  # Длина ключа.
  KEY_B64="$(printf '%s' "${DKIM_PUBLISHED}" | grep -oE 'p=[A-Za-z0-9+/=]+' | head -n1 | cut -c3- || true)"
  if [[ -n "${KEY_B64}" ]]; then
    KEY_LEN=${#KEY_B64}
    if ((KEY_LEN > 380)); then
      check_pass "Длина ключа соответствует 2048 бит"
    elif ((KEY_LEN > 180)); then
      check_warn "Ключ похож на 1024 бита. Рекомендуется 2048 бит."
    fi
  fi
fi

# --- 6. DMARC ---------------------------------------------------------------
header "6. DMARC"
DMARC_REC="$(dig "${DIG_OPTS[@]}" TXT "_dmarc.${MAIL_DOMAIN}" 2>/dev/null | tr -d '"' || true)"
if [[ -z "${DMARC_REC}" ]]; then
  check_fail "DMARC-запись отсутствует. Добавьте TXT _dmarc.${MAIL_DOMAIN}: \"v=DMARC1; p=none; rua=mailto:${DMARC_RUA:-postmaster@${MAIL_DOMAIN}}\""
else
  check_pass "DMARC-запись найдена"
  check_info "${DMARC_REC}"

  POLICY="$(grep -oE 'p=[a-z]+' <<<"${DMARC_REC}" | head -n1 | cut -d= -f2 || true)"
  case "${POLICY}" in
    reject)     check_pass "Политика p=reject — максимальная защита от подделки домена" ;;
    quarantine) check_pass "Политика p=quarantine — подозрительные письма в спам" ;;
    none)       check_warn "Политика p=none — только наблюдение. После проверки отчётов переходите на quarantine, затем reject." ;;
    *)          check_fail "Политика DMARC не распознана: «${POLICY:-отсутствует}»" ;;
  esac

  if grep -q 'rua=' <<<"${DMARC_REC}"; then
    check_pass "Адрес для отчётов (rua) указан"
  else
    check_warn "Не указан rua — вы не будете получать отчёты DMARC и не узнаете о проблемах"
  fi
fi

# --- 7. Дополнительные записи ----------------------------------------------
header "7. Дополнительные записи"
for sub in autodiscover autoconfig; do
  REC="$(dig "${DIG_OPTS[@]}" "${sub}.${MAIL_DOMAIN}" 2>/dev/null | head -n1 || true)"
  if [[ -n "${REC}" ]]; then
    check_pass "${sub}.${MAIL_DOMAIN} настроен (автонастройка клиентов работает)"
  else
    check_warn "${sub}.${MAIL_DOMAIN} отсутствует — клиентам придётся вводить настройки вручную"
  fi
done

SRV_IMAPS="$(dig "${DIG_OPTS[@]}" SRV "_imaps._tcp.${MAIL_DOMAIN}" 2>/dev/null | head -n1 || true)"
if [[ -n "${SRV_IMAPS}" ]]; then
  check_pass "SRV-записи настроены"
else
  check_info "SRV-записи отсутствуют (необязательно, но упрощают настройку клиентов)"
fi

MTASTS="$(dig "${DIG_OPTS[@]}" TXT "_mta-sts.${MAIL_DOMAIN}" 2>/dev/null | tr -d '"' || true)"
if [[ -n "${MTASTS}" ]]; then
  check_pass "MTA-STS объявлен: ${MTASTS}"
  # Проверяем доступность файла политики.
  if curl -fsS --max-time 8 "https://mta-sts.${MAIL_DOMAIN}/.well-known/mta-sts.txt" >/dev/null 2>&1; then
    check_pass "Файл политики MTA-STS доступен"
  else
    check_fail "TXT-запись MTA-STS есть, но файл политики недоступен по https://mta-sts.${MAIL_DOMAIN}/.well-known/mta-sts.txt — часть серверов не сможет вам доставить почту"
  fi
else
  check_info "MTA-STS не настроен (необязательно)"
fi

# --- 8. Чёрные списки -------------------------------------------------------
header "8. Чёрные списки (DNSBL)"
if [[ -z "${IP4}" ]]; then
  check_warn "IP неизвестен, проверка DNSBL пропущена"
else
  # Обратный порядок октетов для запроса в DNSBL.
  REV_IP="$(printf '%s' "${IP4}" | awk -F. '{print $4"."$3"."$2"."$1}')"
  declare -A BLS=(
    ["zen.spamhaus.org"]="Spamhaus ZEN — самый влиятельный список"
    ["bl.spamcop.net"]="SpamCop"
    ["b.barracudacentral.org"]="Barracuda"
    ["dnsbl.sorbs.net"]="SORBS"
  )
  LISTED=0
  for bl in "${!BLS[@]}"; do
    RESULT="$(dig +short +time=3 +tries=1 "@${RESOLVER}" A "${REV_IP}.${bl}" 2>/dev/null | head -n1 || true)"
    if [[ -n "${RESULT}" ]]; then
      # Spamhaus возвращает 127.255.255.x при ошибке запроса, а не при листинге.
      if [[ "${RESULT}" =~ ^127\.255\. ]]; then
        check_info "${bl}: запрос не выполнен (ограничение публичного резолвера)"
      else
        check_fail "IP ${IP4} в чёрном списке ${bl} (${BLS[$bl]}), код ${RESULT}. Запросите удаление на сайте списка."
        LISTED=$((LISTED + 1))
      fi
    else
      check_pass "${bl}: не в списке"
    fi
  done
  if ((LISTED > 0)); then
    check_info "Полная проверка по 100+ спискам: https://multirbl.valli.org/lookup/${IP4}.html"
  fi
fi

# --- Итог -------------------------------------------------------------------
# summary возвращает 1 при наличии провалов. Снимаем ERR-trap, чтобы не
# печатать лишнее сообщение о сбое, и выходим с корректным кодом.
trap - ERR
summary || exit 1
