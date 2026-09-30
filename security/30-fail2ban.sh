#!/usr/bin/env bash
# =============================================================================
# 30-fail2ban.sh — настройка защиты от перебора паролей по SSH.
#
# Для почтовых портов защиту обеспечивает mailcow (свой контейнер netfilter),
# поэтому host-уровень fail2ban охраняет только SSH.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "fail2ban"
require_root
require_cmd fail2ban-client
load_env

MAXRETRY="${F2B_MAXRETRY:-5}"
BANTIME="${F2B_BANTIME:-86400}"
FINDTIME="${F2B_FINDTIME:-600}"
SSHP="${SSH_PORT:-$(detect_ssh_port)}"

header "Настройка fail2ban"

# --- 1. Основной конфиг -----------------------------------------------------
header "1. Общие параметры"
F2B_LOCAL=/etc/fail2ban/jail.local
backup_file "${F2B_LOCAL}" 2>/dev/null || true

cat >"${F2B_LOCAL}" <<EOF
# =============================================================================
# fail2ban jail.local. Создано security/30-fail2ban.sh
# =============================================================================

[DEFAULT]
# Срок бана в секундах (${BANTIME} = $(( BANTIME / 3600 )) ч).
bantime  = ${BANTIME}
# Окно наблюдения (за это время накапливаются попытки).
findtime = ${FINDTIME}
# Число неудачных попыток до бана.
maxretry = ${MAXRETRY}

# Бэкенд мониторинга логов. systemd быстрее, но доступен не везде.
backend = systemd

# Действие при бане: iptables-multiport закрывает порт для IP.
banaction = iptables-multiport
banaction_allports = iptables-allports

# Уведомления по почте (можно включить позже, когда почта заработает).
# destemail = ${ADMIN_EMAIL}
# sendername = Fail2Ban
# action = %(action_mwl)s

# Игнорируем локальные адреса.
ignoreip = 127.0.0.1/8 ::1

# --- Jail для SSH ---
[sshd]
enabled  = true
port     = ${SSHP}
filter   = sshd
logpath  = %(sshd_log)s
maxretry = ${MAXRETRY}
EOF

chmod 0644 "${F2B_LOCAL}"
ok "Конфигурация записана в ${F2B_LOCAL}"
info "Параметры: ${MAXRETRY} попыток за ${FINDTIME} сек → бан на ${BANTIME} сек"

# --- 2. Фильтр sshd (если устарел) -----------------------------------------
# В старых Debian фильтр sshd может не ловить все варианты ошибок.
# Проверяем и при необходимости обновляем.
header "2. Фильтр sshd"
FILTER_DIR=/etc/fail2ban/filter.d
SSHD_FILTER="${FILTER_DIR}/sshd.local"

if [[ -f "${FILTER_DIR}/sshd.conf" ]]; then
  ok "Встроенный фильтр sshd.conf найден"
  # Оставим как есть, переопределять не нужно.
else
  warn "Фильтр sshd.conf отсутствует, создаю локальный"
  cat >"${SSHD_FILTER}" <<'EOF'
# Фильтр для SSH-атак. Дополнение к встроенному.
[Definition]
failregex = ^%(__prefix_line)s(?:error: PAM: )?[aA]uthentication (?:failure|error|failed) for .* from <HOST>( via \S+)?\s*$
            ^%(__prefix_line)s(?:error: PAM: )?User not known to the underlying authentication module for .* from <HOST>\s*$
            ^%(__prefix_line)sFailed \S+ for (?P<cond_inv>invalid user )?(?P<user>(?P<cond_user>\S+)|(?(cond_inv)(?:(?! from ).)*?|[^:]+?)) from <HOST>(?: port \d+)?(?: ssh\d*)?(?(cond_user): |(?:(?:(?! from ).)*)$)
            ^%(__prefix_line)sROOT LOGIN REFUSED.* FROM <HOST>\s*$
            ^%(__prefix_line)s[iI](?:llegal|nvalid) user (?P<user>(?:\S+|(?:.*?)\S+?)?) from <HOST>(?: port \d+)?\s*$
            ^%(__prefix_line)sUser (?P<user>.+?) from <HOST> not allowed because not listed in AllowUsers\s*$
            ^%(__prefix_line)sUser (?P<user>.+?) from <HOST> not allowed because listed in DenyUsers\s*$
            ^%(__prefix_line)sUser (?P<user>.+?) from <HOST> not allowed because not in any group\s*$
            ^%(__prefix_line)srefused connect from \S+ \(<HOST>\)\s*$
            ^%(__prefix_line)sReceived disconnect from <HOST>: 11: .* \[preauth\]\s*$
            ^%(__prefix_line)sConnection (?:closed|reset) by (?:authenticating )?user \S+ <HOST> port \d+(?: \[preauth\])?\s*$
            ^%(__prefix_line)sDisconnecting: Too many authentication failures(?: for .+?)?\s+\[preauth\]\s*$
ignoreregex =
EOF
  ok "Создан ${SSHD_FILTER}"
fi

# --- 3. Перезапуск ----------------------------------------------------------
header "3. Применение"
systemctl enable fail2ban >/dev/null 2>&1

if systemctl is-active --quiet fail2ban; then
  info "Перезагружаю fail2ban"
  systemctl restart fail2ban
else
  info "Запускаю fail2ban"
  systemctl start fail2ban
fi

sleep 2
if systemctl is-active --quiet fail2ban; then
  ok "Служба fail2ban запущена"
else
  err "fail2ban не запустился. Диагностика: journalctl -u fail2ban -n 50 --no-pager"
  exit 1
fi

# --- 4. Проверка jail -------------------------------------------------------
header "4. Состояние jail"
sleep 1
if fail2ban-client status sshd >/dev/null 2>&1; then
  ok "Jail sshd активен"
  fail2ban-client status sshd | sed 's/^/  /'
else
  warn "Jail sshd не запустился. Проверьте: fail2ban-client status"
fi

# --- Итог -------------------------------------------------------------------
header "Готово"
mark_step_done "30-fail2ban"
ok "fail2ban защищает SSH."
printf '\n'
info "Управление:"
info "  Статус всех jail     : fail2ban-client status"
info "  Статус sshd          : fail2ban-client status sshd"
info "  Разбанить IP         : fail2ban-client set sshd unbanip <IP>"
info "  Журнал               : journalctl -u fail2ban -f"
printf '\n'
info "Почтовые порты (25, 587, 993 и т.д.) защищены встроенным netfilter mailcow."
info "Список банов mailcow: веб-панель → System → Fail2ban logs"
