#!/usr/bin/env bash
# =============================================================================
# 40-check-security.sh — аудит безопасности.
# Проверяет открытый релей, SSH, firewall, TLS, права на файлы.
# Только чтение, ничего не меняет.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "check-security"
load_env
require_vars MAIL_HOSTNAME MAIL_DOMAIN

IP4="$(detect_public_ip4)"
MCDIR="$(mailcow_dir)"

header "Аудит безопасности"

# --- 1. Открытый релей (критично) -------------------------------------------
header "1. Проверка на открытый релей"
check_info "Открытый релей = ваш сервер рассылает чужой спам и попадает в чёрные списки"

if [[ -n "${IP4}" ]] && have_cmd swaks; then
  # Пробуем отправить письмо с чужого адреса на чужой адрес без аутентификации.
  RELAY_OUT="$(timeout 20 swaks --server "${IP4}" --port 25 \
    --from "relay-test@example.org" \
    --to "relay-target@example.net" \
    --helo "relay-check.invalid" \
    --quit-after RCPT 2>&1 || true)"

  if grep -qE '^<-  ?(550|554|553|450|451)' <<<"${RELAY_OUT}"; then
    check_pass "Релей закрыт: сервер отклонил пересылку для чужого домена"
  elif grep -qE '^<-  ?250' <<<"${RELAY_OUT}"; then
    check_fail "КРИТИЧНО: сервер принял письмо для чужого домена без аутентификации — это открытый релей. Немедленно проверьте настройки Postfix (mynetworks, smtpd_recipient_restrictions)."
  else
    check_warn "Результат проверки релея неоднозначен. Проверьте вручную на https://mxtoolbox.com/diagnostic.aspx"
  fi
else
  check_warn "Утилита swaks недоступна или IP неизвестен. Проверьте релей вручную: https://mxtoolbox.com/diagnostic.aspx"
fi

# --- 2. SMTP AUTH только по TLS ---------------------------------------------
header "2. Аутентификация SMTP"
if [[ -n "${IP4}" ]]; then
  # AUTH не должен предлагаться до STARTTLS.
  EHLO_PLAIN="$(timeout 8 bash -c "exec 3<>/dev/tcp/${IP4}/25; sleep 1; echo 'EHLO check.invalid' >&3; sleep 2; timeout 2 cat <&3; echo QUIT >&3" 2>/dev/null || true)"
  if grep -qi '250[- ]AUTH' <<<"${EHLO_PLAIN}"; then
    check_fail "AUTH предлагается по незашифрованному соединению — пароли могут быть перехвачены"
  else
    check_pass "AUTH не предлагается до установки TLS"
  fi
fi

# --- 3. TLS-конфигурация ----------------------------------------------------
header "3. Настройки TLS"
if have_cmd openssl && [[ -n "${IP4}" ]]; then
  # Устаревшие протоколы должны быть отключены.
  for proto in ssl3 tls1 tls1_1; do
    PROTO_OUT="$(timeout 8 openssl s_client -connect "${IP4}:${HTTPS_PORT:-443}" -"${proto}" </dev/null 2>&1 || true)"
    if grep -qE 'Cipher is (NONE|0000)|no peer certificate|handshake failure|alert|unsupported protocol|wrong version' <<<"${PROTO_OUT}"; then
      check_pass "Протокол ${proto} отключён"
    elif grep -q 'Verify return code' <<<"${PROTO_OUT}"; then
      check_fail "Устаревший протокол ${proto} включён — уязвим к известным атакам"
    else
      check_info "Протокол ${proto}: результат неоднозначен (вероятно, отключён)"
    fi
  done

  # TLS 1.2 и 1.3 должны работать.
  for proto in tls1_2 tls1_3; do
    PROTO_OUT="$(timeout 8 openssl s_client -connect "${IP4}:${HTTPS_PORT:-443}" -"${proto}" </dev/null 2>&1 || true)"
    if grep -q 'Verify return code' <<<"${PROTO_OUT}"; then
      check_pass "Протокол ${proto} поддерживается"
    else
      [[ "${proto}" == "tls1_3" ]] && check_warn "TLS 1.3 не поддерживается (не критично)" || check_fail "TLS 1.2 не работает"
    fi
  done
fi

# --- 4. SSH -----------------------------------------------------------------
header "4. Конфигурация SSH"
if have_cmd sshd; then
  SSHD_EFF="$(sshd -T 2>/dev/null || true)"
  if [[ -z "${SSHD_EFF}" ]]; then
    check_warn "Не удалось получить действующую конфигурацию sshd"
  else
    # awk сам ограничивает вывод первой строкой: конвейер с head вызывал бы
    # SIGPIPE у grep, а под set -e это прервало бы скрипт при подстановке команды.
    get_sshd() { awk -v k="$1" 'tolower($1)==tolower(k) {print $2; exit}' <<<"${SSHD_EFF}"; }

    PRL="$(get_sshd permitrootlogin)"
    case "${PRL}" in
      no)                check_pass "Вход root по SSH запрещён" ;;
      prohibit-password) check_pass "Вход root разрешён только по ключу" ;;
      yes)               check_fail "Вход root разрешён с паролем — основная цель брутфорса. Установите SSH_DISABLE_ROOT=yes" ;;
      *)                 check_warn "PermitRootLogin = ${PRL:-?}" ;;
    esac

    PA="$(get_sshd passwordauthentication)"
    if [[ "${PA}" == "no" ]]; then
      check_pass "Аутентификация по паролю отключена"
    else
      check_warn "Аутентификация по паролю включена. Надёжнее только ключи (SSH_DISABLE_PASSWORD=yes)"
    fi

    MAT="$(get_sshd maxauthtries)"
    if [[ -n "${MAT}" ]] && ((MAT <= 4)); then
      check_pass "MaxAuthTries = ${MAT}"
    else
      check_warn "MaxAuthTries = ${MAT:-?}, рекомендуется 3"
    fi

    PEP="$(get_sshd permitemptypasswords)"
    [[ "${PEP}" == "no" ]] && check_pass "Пустые пароли запрещены" || check_fail "Разрешены пустые пароли"

    X11="$(get_sshd x11forwarding)"
    [[ "${X11}" == "no" ]] && check_pass "X11Forwarding отключён" || check_warn "X11Forwarding включён, для сервера не нужен"

    SSH_PORT_EFF="$(get_sshd port)"
    check_info "SSH слушает порт ${SSH_PORT_EFF:-22}"
    [[ "${SSH_PORT_EFF:-22}" == "22" ]] && check_info "Порт 22 стандартный — будет много попыток подбора. Смена порта уменьшает шум, но не заменяет защиту."
  fi
fi

# --- 5. Firewall ------------------------------------------------------------
header "5. Межсетевой экран"
if have_cmd ufw; then
  if ufw status 2>/dev/null | grep -q 'Status: active'; then
    check_pass "ufw активен"

    # Политика по умолчанию для входящих должна быть deny.
    if ufw status verbose 2>/dev/null | grep -qi 'Default: deny (incoming)'; then
      check_pass "Политика входящих: запрет по умолчанию"
    else
      check_fail "Политика входящих не «deny». Проверьте: ufw status verbose"
    fi

    # Подсчёт открытых портов.
    OPEN_RULES="$(ufw status numbered 2>/dev/null | grep -cE '^\[[0-9]+\].*ALLOW' || echo 0)"
    check_info "Разрешающих правил: ${OPEN_RULES}"
  else
    check_fail "ufw не активен — сервер открыт для всех подключений. Запустите security/20-firewall.sh"
  fi
else
  check_warn "ufw не установлен"
fi

# Правила DOCKER-USER.
if have_cmd iptables; then
  if iptables -L DOCKER-USER -n 2>/dev/null | grep -q 'mailstack'; then
    check_pass "Правила DOCKER-USER применены"
  else
    check_warn "Правила DOCKER-USER отсутствуют. Порты контейнеров не фильтруются. Запустите security/20-firewall.sh"
  fi

  # Проверяем, что netfilter mailcow работает.
  if iptables -L DOCKER-USER -n 2>/dev/null | grep -qi 'MAILCOW'; then
    check_pass "Цепочка netfilter mailcow активна (защита почтовых портов)"
  else
    check_warn "Цепочка mailcow в DOCKER-USER не найдена. Проверьте: docker compose logs netfilter-mailcow"
  fi
fi

# --- 6. fail2ban ------------------------------------------------------------
header "6. fail2ban"
if have_cmd fail2ban-client && systemctl is-active --quiet fail2ban; then
  check_pass "fail2ban работает"
  JAILS="$(fail2ban-client status 2>/dev/null | grep 'Jail list' | cut -d: -f2 | tr -d ' ' || true)"
  check_info "Активные jail: ${JAILS:-нет}"

  if grep -q 'sshd' <<<"${JAILS}"; then
    BANNED="$(fail2ban-client status sshd 2>/dev/null | grep 'Currently banned' | grep -oE '[0-9]+' | head -n1 || echo 0)"
    TOTAL_BANNED="$(fail2ban-client status sshd 2>/dev/null | grep 'Total banned' | grep -oE '[0-9]+' | head -n1 || echo 0)"
    check_pass "Jail sshd активен (сейчас забанено ${BANNED}, всего за время работы ${TOTAL_BANNED})"
  else
    check_fail "Jail sshd не активен — SSH не защищён от перебора паролей"
  fi
else
  check_fail "fail2ban не работает. Запустите security/30-fail2ban.sh"
fi

# --- 7. Права на файлы ------------------------------------------------------
header "7. Права доступа к файлам"

check_perms() {
  local f="$1" expected="$2" desc="$3"
  [[ -e "${f}" ]] || { check_info "${desc}: файл ${f} отсутствует"; return 0; }
  local actual
  actual="$(stat -c '%a' "${f}" 2>/dev/null || echo '?')"
  if [[ "${actual}" == "${expected}" ]]; then
    check_pass "${desc}: права ${actual}"
  elif ((10#${actual:-777} <= 10#${expected})); then
    check_pass "${desc}: права ${actual} (строже требуемых ${expected})"
  else
    check_fail "${desc}: права ${actual}, должно быть ${expected} или строже. Исправление: chmod ${expected} ${f}"
  fi
}

check_perms "${REPO_ROOT}/.env" 600 "Файл .env комплекта"
check_perms "${MCDIR}/mailcow.conf" 600 "Конфигурация mailcow"
check_perms "/root/mailstack-credentials.txt" 600 "Файл с учётными данными"
check_perms "/root/.ssh/authorized_keys" 600 "Ключи SSH для root"

# Проверяем, что .env не попал в git.
if [[ -d "${REPO_ROOT}/.git" ]]; then
  if git -C "${REPO_ROOT}" ls-files --error-unmatch .env >/dev/null 2>&1; then
    check_fail "Файл .env добавлен в git — пароли попадут в историю репозитория. Удалите: git rm --cached .env"
  else
    check_pass "Файл .env не отслеживается git"
  fi
fi

# --- 8. Пароли по умолчанию -------------------------------------------------
header "8. Учётные данные по умолчанию"
check_info "Проверяю, не остался ли пароль администратора mailcow по умолчанию"
# Пробуем войти с moohoo через API логина.
LOGIN_TEST="$(curl -k -fsS --max-time 10 \
  -X POST "https://127.0.0.1:${HTTPS_PORT:-443}/" \
  -d 'login_user=admin&pass_user=moohoo' \
  -o /dev/null -w '%{http_code}' 2>/dev/null || echo '000')"

# Надёжнее проверить наличие пометки в самой панели — API этого не даёт.
# Поэтому предупреждаем всегда.
check_warn "Проверьте вручную: войдите на https://${MAIL_HOSTNAME}/ с логином admin и паролем moohoo. Если вход удался — СМЕНИТЕ ПАРОЛЬ НЕМЕДЛЕННО."

# --- 9. Обновления ---------------------------------------------------------
header "9. Состояние обновлений"
if have_cmd apt-get; then
  SEC_UPDATES="$(apt-get -s upgrade 2>/dev/null | grep -ci '^Inst.*security' || echo 0)"
  if [[ "${SEC_UPDATES}" =~ ^[0-9]+$ ]] && ((SEC_UPDATES > 0)); then
    check_fail "Доступно ${SEC_UPDATES} обновлений безопасности. Установите: apt-get update && apt-get upgrade"
  else
    check_pass "Обновления безопасности установлены"
  fi
fi

if [[ -f /var/run/reboot-required ]]; then
  check_warn "Требуется перезагрузка для применения обновлений (вероятно, новое ядро)"
  [[ -f /var/run/reboot-required.pkgs ]] && check_info "Пакеты: $(tr '\n' ' ' </var/run/reboot-required.pkgs)"
else
  check_pass "Перезагрузка не требуется"
fi

if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
  check_pass "Автоматические обновления безопасности включены"
else
  check_warn "Автообновления не настроены. Запустите security/50-auto-updates.sh"
fi

# --- 10. Резервные копии ----------------------------------------------------
header "10. Резервное копирование"
BKDIR="${BACKUP_DIR:-/var/backups/mailcow}"
if systemctl is-active --quiet mailcow-backup.timer 2>/dev/null; then
  check_pass "Таймер резервного копирования активен"

  # Свежесть последней копии.
  if [[ -d "${BKDIR}" ]]; then
    LATEST="$(find "${BKDIR}" -maxdepth 1 -type d -name 'mailcow-*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2- || true)"
    if [[ -n "${LATEST}" ]]; then
      AGE_H=$(( ( $(date +%s) - $(stat -c %Y "${LATEST}") ) / 3600 ))
      if ((AGE_H <= 30)); then
        check_pass "Последняя резервная копия создана ${AGE_H} ч назад"
      else
        check_fail "Последней копии ${AGE_H} ч ($(( AGE_H / 24 )) дн). Проверьте: journalctl -u mailcow-backup"
      fi
      check_info "Расположение: ${LATEST}"
    else
      check_fail "Резервных копий в ${BKDIR} не найдено. Запустите: sudo /usr/local/sbin/mailcow-backup"
    fi
  fi
else
  check_fail "Резервное копирование не настроено. Запустите deploy/50-setup-backup.sh"
fi

# --- 11. Прослушиваемые порты (лишние службы) -------------------------------
header "11. Лишние открытые порты"
if have_cmd ss; then
  # Ожидаемые порты.
  EXPECTED="25|80|110|143|443|465|587|993|995|4190|$(detect_ssh_port)"
  UNEXPECTED="$(ss -Hltn 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | grep -vE "^(${EXPECTED})$" || true)"

  if [[ -z "${UNEXPECTED}" ]]; then
    check_pass "Лишних портов на внешних интерфейсах нет"
  else
    # Отделяем localhost-порты — они не опасны.
    EXTERNAL_EXTRA=""
    while read -r p; do
      [[ -n "${p}" ]] || continue
      if ss -Hltn "sport = :${p}" 2>/dev/null | awk '{print $4}' | grep -qvE '^(127\.0\.0\.1|\[::1\])'; then
        OWNER="$(ss -Hltnp "sport = :${p}" 2>/dev/null | grep -oP 'users:\(\("\K[^"]+' | head -n1 || echo '?')"
        EXTERNAL_EXTRA="${EXTERNAL_EXTRA} ${p}(${OWNER})"
      fi
    done <<<"${UNEXPECTED}"

    if [[ -n "${EXTERNAL_EXTRA}" ]]; then
      check_warn "Открыты дополнительные порты на внешних интерфейсах:${EXTERNAL_EXTRA}. Убедитесь, что они нужны."
    else
      check_pass "Дополнительные порты слушаются только на localhost"
    fi
  fi
fi

# --- Итог -------------------------------------------------------------------
# summary возвращает 1 при наличии провалов. Снимаем ERR-trap, чтобы не
# печатать лишнее сообщение о сбое, и выходим с корректным кодом.
trap - ERR
summary || exit 1
