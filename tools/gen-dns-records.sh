#!/usr/bin/env bash
# =============================================================================
# gen-dns-records.sh — генерирует полный набор DNS-записей для почтового домена.
# Выводит их в читаемом виде и сохраняет в файл dns-records-<домен>.txt
#
# Ничего не меняет в системе. Записи нужно внести у вашего DNS-провайдера.
# =============================================================================
set -Eeuo pipefail
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SELF_DIR}/lib/common.sh"
# shellcheck source=../tools/mailcow-api.sh
source "${_SELF_DIR}/tools/mailcow-api.sh"

load_env
require_vars MAIL_DOMAIN MAIL_HOSTNAME

OUT_FILE="${REPO_ROOT}/dns-records-${MAIL_DOMAIN}.txt"
IP4="$(detect_public_ip4)"
IP6=""
[[ "${ENABLE_IPV6:-no}" == "yes" ]] && IP6="$(detect_public_ip6)"

# --- Получение DKIM ---------------------------------------------------------
DKIM_VALUE=""
DKIM_SELECTOR="dkim"
if [[ -n "${MAILCOW_API_KEY:-}" ]]; then
  DKIM_JSON="$(api_call GET "/api/v1/get/dkim/${MAIL_DOMAIN}" 2>/dev/null || echo '{}')"
  if have_cmd jq; then
    DKIM_VALUE="$(printf '%s' "${DKIM_JSON}" | jq -r '.dkim_txt // empty' 2>/dev/null || true)"
    SEL="$(printf '%s' "${DKIM_JSON}" | jq -r '.dkim_selector // empty' 2>/dev/null || true)"
    [[ -n "${SEL}" ]] && DKIM_SELECTOR="${SEL}"
  else
    DKIM_VALUE="$(printf '%s' "${DKIM_JSON}" | grep -o 'v=DKIM1[^"]*' | head -n1 || true)"
  fi
fi

# --- Формирование записей ---------------------------------------------------
DMARC_POL="${DMARC_POLICY:-none}"
DMARC_ADDR="${DMARC_RUA:-postmaster@${MAIL_DOMAIN}}"

generate_output() {
cat <<EOF
===============================================================================
DNS-записи для почтового домена ${MAIL_DOMAIN}
Сгенерировано: $(date '+%Y-%m-%d %H:%M:%S %Z')
===============================================================================

Внесите эти записи в панели управления DNS вашего домена.
Формат: ИМЯ | ТИП | ЗНАЧЕНИЕ

Многие панели требуют указывать имя без домена (@ вместо ${MAIL_DOMAIN}).
Если панель дописывает домен автоматически, вводите только поддомен.

-------------------------------------------------------------------------------
1. ОБЯЗАТЕЛЬНЫЕ ЗАПИСИ
-------------------------------------------------------------------------------

1.1. A-запись сервера (адрес почтового сервера)

    ${MAIL_HOSTNAME}.    A      ${IP4:-<IP вашего сервера>}
$(if [[ -n "${IP6}" ]]; then printf '    %s.    AAAA   %s\n' "${MAIL_HOSTNAME}" "${IP6}"; fi)

1.2. MX-запись (куда доставлять почту для домена)

    ${MAIL_DOMAIN}.      MX     10 ${MAIL_HOSTNAME}.

    Приоритет 10. Других MX-записей для этого домена быть не должно,
    иначе почта уйдёт к старому провайдеру.

1.3. SPF (кто имеет право отправлять почту от имени домена)

    ${MAIL_DOMAIN}.      TXT    "v=spf1 mx a:${MAIL_HOSTNAME} -all"

    mx      — разрешаем серверам из MX-записи
    a:...   — разрешаем адрес почтового сервера
    -all    — всё остальное отклонять (жёсткая политика)

    Если письма отправляются также через сторонний сервис (рассылки, CRM),
    добавьте его: "v=spf1 mx a:${MAIL_HOSTNAME} include:sendgrid.net -all"

    Запись SPF должна быть ТОЛЬКО ОДНА. Две записи SPF ломают проверку.

1.4. DKIM (криптографическая подпись писем)

$(if [[ -n "${DKIM_VALUE}" ]]; then
cat <<DKIMEOF
    ${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}.    TXT    "${DKIM_VALUE}"

    Значение длинное. Некоторые панели требуют разбивать его на части
    по 255 символов — обычно это делается автоматически.
    Копируйте значение целиком, без переносов строк и лишних пробелов.
DKIMEOF
else
cat <<'DKIMEOF'
    Ключ DKIM пока не получен.

    Причина: не задан MAILCOW_API_KEY в .env либо ключ ещё не создан.
    Как получить:
      1. Веб-панель → Configuration → Options → ARC/DKIM keys
      2. Домен, селектор dkim, длина 2048 бит → Add
      3. Скопируйте показанное значение в TXT-запись:
             dkim._domainkey.ВАШ_ДОМЕН    TXT    "v=DKIM1; k=rsa; p=..."
      4. Либо задайте MAILCOW_API_KEY в .env и запустите этот скрипт снова.
DKIMEOF
fi)

1.5. DMARC (что делать с письмами, не прошедшими SPF и DKIM)

    _dmarc.${MAIL_DOMAIN}.    TXT    "v=DMARC1; p=${DMARC_POL}; rua=mailto:${DMARC_ADDR}; ruf=mailto:${DMARC_ADDR}; fo=1; adkim=r; aspf=r; pct=100"

    Текущая политика: p=${DMARC_POL}
$(case "${DMARC_POL}" in
  none)       printf '    Режим наблюдения: письма не блокируются, но вы получаете отчёты.\n    Рекомендуемый старт. Через 2-4 недели переходите на quarantine.\n' ;;
  quarantine) printf '    Подозрительные письма попадают в спам у получателя.\n    Переходите на этот режим только после проверки отчётов DMARC.\n' ;;
  reject)     printf '    Жёсткий режим: письма, не прошедшие проверку, отклоняются.\n    Включайте последним, когда уверены в корректности SPF и DKIM.\n' ;;
esac)

1.6. PTR (обратная запись, rDNS) — НЕ настраивается в DNS домена

    ${IP4:-<IP сервера>}   →   ${MAIL_HOSTNAME}

    Эта запись настраивается В ПАНЕЛИ ХОСТИНГА VPS, раздел «rDNS» или
    «Reverse DNS». Без корректной PTR-записи Gmail, Outlook и Яндекс
    будут отклонять вашу почту. Это самая частая причина недоставки.

-------------------------------------------------------------------------------
2. РЕКОМЕНДУЕМЫЕ ЗАПИСИ
-------------------------------------------------------------------------------

2.1. Автонастройка почтовых клиентов

    autodiscover.${MAIL_DOMAIN}.    CNAME    ${MAIL_HOSTNAME}.
    autoconfig.${MAIL_DOMAIN}.      CNAME    ${MAIL_HOSTNAME}.

    Позволяет Outlook и Thunderbird настраиваться автоматически:
    пользователь вводит только адрес и пароль.

2.2. SRV-записи (подсказки клиентам о портах)

    _imaps._tcp.${MAIL_DOMAIN}.       SRV    0 1 993 ${MAIL_HOSTNAME}.
    _submission._tcp.${MAIL_DOMAIN}.  SRV    0 1 587 ${MAIL_HOSTNAME}.
    _submissions._tcp.${MAIL_DOMAIN}. SRV    0 1 465 ${MAIL_HOSTNAME}.
    _sieve._tcp.${MAIL_DOMAIN}.       SRV    0 1 4190 ${MAIL_HOSTNAME}.
    _autodiscover._tcp.${MAIL_DOMAIN}. SRV   0 1 443 ${MAIL_HOSTNAME}.

2.3. MTA-STS (требовать шифрование при доставке вам)

    _mta-sts.${MAIL_DOMAIN}.    TXT    "v=STSv1; id=$(date '+%Y%m%d')000000"
    _smtp._tls.${MAIL_DOMAIN}.  TXT    "v=TLSRPTv1; rua=mailto:${DMARC_ADDR}"

    Дополнительно нужно опубликовать файл политики по адресу
    https://mta-sts.${MAIL_DOMAIN}/.well-known/mta-sts.txt
    Требуется отдельная A-запись mta-sts.${MAIL_DOMAIN} и веб-сервер.
    Настраивайте это только после того, как всё остальное заработает.

-------------------------------------------------------------------------------
3. ЗАПИСИ, КОТОРЫЕ НУЖНО УДАЛИТЬ
-------------------------------------------------------------------------------

Проверьте и уберите, если остались от прежнего провайдера:
  - лишние MX-записи, указывающие на другие серверы
  - вторую SPF-запись (допустима только одна)
  - старые DKIM-селекторы прежнего провайдера
  - A-записи mail.${MAIL_DOMAIN}, указывающие на чужой IP

-------------------------------------------------------------------------------
4. ПРОВЕРКА ПОСЛЕ ВНЕСЕНИЯ
-------------------------------------------------------------------------------

Записи распространяются от 5 минут до 48 часов (обычно 15-30 минут).

Локальная проверка:
    sudo ./checks/20-check-dns.sh

Ручная проверка:
    dig +short MX ${MAIL_DOMAIN}
    dig +short TXT ${MAIL_DOMAIN}
    dig +short TXT ${DKIM_SELECTOR}._domainkey.${MAIL_DOMAIN}
    dig +short TXT _dmarc.${MAIL_DOMAIN}
    dig +short -x ${IP4:-IP}

Внешние сервисы:
    https://www.mail-tester.com/          — общая оценка, отправьте письмо
    https://mxtoolbox.com/SuperTool.aspx  — проверка всех записей
    https://dmarcian.com/dmarc-inspector/ — разбор DMARC
    https://multirbl.valli.org/           — проверка IP в чёрных списках

===============================================================================
EOF
}

# --- Вывод ------------------------------------------------------------------
generate_output | tee "${OUT_FILE}"

printf '\n'
ok "Записи сохранены в ${OUT_FILE}"

if [[ -z "${IP4}" ]]; then
  warn "Не удалось определить публичный IPv4 — подставьте адрес сервера вручную."
fi
if [[ -z "${DKIM_VALUE}" ]]; then
  warn "DKIM-запись не заполнена. Задайте MAILCOW_API_KEY в .env и запустите скрипт повторно."
fi
