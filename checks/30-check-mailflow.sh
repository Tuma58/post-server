#!/usr/bin/env bash
# =============================================================================
# 30-check-mailflow.sh — проверка доставки почты: SMTP, IMAP, сертификат.
# Только чтение и пробные подключения, ничего не меняет.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "check-mailflow"
load_env
require_vars MAIL_HOSTNAME
require_cmd openssl nc

IP4="$(detect_public_ip4)"

header "Проверка почтового потока"

# --- 1. SMTP (приём почты) --------------------------------------------------
header "1. SMTP (порт 25, приём от других серверов)"
if tcp_probe "${IP4:-127.0.0.1}" 25 8; then
  check_pass "Порт 25 доступен"

  # Проверяем баннер и поддержку TLS.
  SMTP_BANNER="$(timeout 8 bash -c "exec 3<>/dev/tcp/${IP4:-127.0.0.1}/25; cat <&3 & sleep 1; echo QUIT >&3; wait" 2>/dev/null || true)"
  if [[ -n "${SMTP_BANNER}" ]]; then
    if grep -qi '220.*ESMTP' <<<"${SMTP_BANNER}"; then
      check_pass "SMTP-баннер корректен"
    else
      check_warn "Баннер не содержит ESMTP: ${SMTP_BANNER}"
    fi

    # Проверяем STARTTLS.
    EHLO_OUT="$(timeout 8 bash -c "exec 3<>/dev/tcp/${IP4:-127.0.0.1}/25; sleep 1; echo EHLO check >&3; sleep 2; cat <&3 & sleep 1; echo QUIT >&3; wait" 2>/dev/null || true)"
    if grep -qi 'STARTTLS' <<<"${EHLO_OUT}"; then
      check_pass "STARTTLS поддерживается на порту 25"
    else
      check_fail "STARTTLS не объявлен — входящая почта не будет шифроваться"
    fi
  fi
else
  check_fail "Порт 25 недоступен извне — почта от других серверов не дойдёт"
fi

# --- 2. Submission (отправка клиентами) -------------------------------------
header "2. Submission (порты 587 и 465, отправка клиентами)"
for port in 587 465; do
  [[ "${port}" == "465" && "${OPEN_PORT_465:-yes}" != "yes" ]] && continue

  if tcp_probe "${IP4:-127.0.0.1}" "${port}" 8; then
    check_pass "Порт ${port} доступен"
  else
    check_fail "Порт ${port} недоступен извне — клиенты не смогут отправлять почту"
  fi
done

# --- 3. IMAP ----------------------------------------------------------------
header "3. IMAP (порты 143 и 993, чтение почты)"
for port in 143 993; do
  if tcp_probe "${IP4:-127.0.0.1}" "${port}" 8; then
    check_pass "Порт ${port} доступен"

    if [[ "${port}" == "993" ]]; then
      # Проверяем TLS и сертификат.
      CERT_INFO="$(timeout 8 openssl s_client -connect "${IP4}:993" -servername "${MAIL_HOSTNAME}" </dev/null 2>/dev/null | openssl x509 -noout -text 2>/dev/null || true)"
      if [[ -n "${CERT_INFO}" ]]; then
        check_pass "Сертификат на IMAPS получен"
        CERT_CN="$(printf '%s' "${CERT_INFO}" | grep 'Subject:.*CN' | grep -oE 'CN[[:space:]]*=[[:space:]]*[^,]+' | cut -d= -f2- | tr -d ' ' || true)"
        if [[ "${CERT_CN}" == "${MAIL_HOSTNAME}" ]] || grep -q "DNS:${MAIL_HOSTNAME}" <<<"${CERT_INFO}"; then
          check_pass "Сертификат выдан на ${MAIL_HOSTNAME}"
        else
          check_warn "Сертификат выдан на «${CERT_CN:-?}», а не на ${MAIL_HOSTNAME}"
        fi

        CERT_END="$(printf '%s' "${CERT_INFO}" | grep 'Not After' | sed 's/.*Not After : //' || true)"
        if [[ -n "${CERT_END}" ]]; then
          check_info "Сертификат действует до: ${CERT_END}"
        fi
      else
        check_warn "Не удалось получить сертификат на порту 993"
      fi
    fi
  else
    check_fail "Порт ${port} недоступен"
  fi
done

# --- 4. HTTPS (веб-почта и панель) ------------------------------------------
header "4. HTTPS (веб-интерфейс)"
HP="${HTTPS_PORT:-443}"
if tcp_probe "${IP4:-127.0.0.1}" "${HP}" 8; then
  check_pass "Порт ${HP} доступен"

  # Проверяем сертификат.
  CERT_OUT="$(timeout 8 openssl s_client -connect "${IP4}:${HP}" -servername "${MAIL_HOSTNAME}" </dev/null 2>/dev/null || true)"
  if printf '%s' "${CERT_OUT}" | grep -q 'Verify return code: 0 (ok)'; then
    check_pass "Сертификат HTTPS валиден"
  elif grep -q 'self signed certificate' <<<"${CERT_OUT}"; then
    check_warn "Сертификат самоподписанный — Let's Encrypt ещё не выпустился либо не прошла проверка домена"
  else
    check_warn "Сертификат HTTPS не прошёл проверку. Смотрите: openssl s_client -connect ${IP4}:${HP} -servername ${MAIL_HOSTNAME}"
  fi

  # Проверяем HTTP→HTTPS редирект.
  HTTP_REDIR="$(curl -fsS -I --max-time 6 "http://${IP4}:${HTTP_PORT:-80}/" 2>/dev/null | grep -i '^Location:' | head -n1 || true)"
  if grep -qi 'https://' <<<"${HTTP_REDIR}"; then
    check_pass "HTTP редиректит на HTTPS"
  else
    check_warn "HTTP не редиректит на HTTPS"
  fi
else
  check_fail "Порт ${HP} недоступен — веб-интерфейс не работает"
fi

# --- 5. Тест отправки письма ------------------------------------------------
header "5. Тест отправки через SMTP"
check_info "Для полной проверки отправьте письмо на https://www.mail-tester.com/"
check_info "Команда: echo 'Test mail' | mail -s 'Test' test-<случайный>@mail-tester.com"
check_info "Оценка покажет SPF/DKIM/DMARC, репутацию IP, содержимое и заголовки."

# Если есть утилита swaks, можно сделать быструю локальную проверку.
if have_cmd swaks && [[ -n "${FIRST_MAILBOX_LOCAL:-}" ]]; then
  TESTBOX="${FIRST_MAILBOX_LOCAL}@${MAIL_DOMAIN}"
  check_info "Попытка локальной отправки на ${TESTBOX} (требует логин, пропускаю автотест)"
  # swaks -tls -s "${MAIL_HOSTNAME}" -p 587 -au "${TESTBOX}" -ap "..." -f ... -t ...
fi

# --- 6. Тест получения письма -----------------------------------------------
header "6. Тест получения"
check_info "Для проверки входящей почты отправьте письмо с внешнего адреса (Gmail, Yandex) на ${FIRST_MAILBOX_LOCAL:-admin}@${MAIL_DOMAIN}"
check_info "Если письмо не дошло, смотрите очередь: docker compose exec postfix-mailcow postqueue -p"
check_info "и журналы:  docker compose logs postfix-mailcow | grep <адрес отправителя>"

# --- Итог -------------------------------------------------------------------
# summary возвращает 1 при наличии провалов. Снимаем ERR-trap, чтобы не
# печатать лишнее сообщение о сбое, и выходим с корректным кодом.
trap - ERR
summary || exit 1
