#!/usr/bin/env bash
# =============================================================================
# 20-firewall.sh — настройка межсетевого экрана (ufw + правила для Docker).
#
# Важная деталь: Docker вставляет свои правила в таблицу nat ДО цепочек ufw,
# поэтому «ufw deny» не закрывает порты, опубликованные контейнерами.
# Для контейнеров используется отдельная цепочка DOCKER-USER.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "firewall"
require_root
require_cmd ufw iptables
load_env

SSHP="${SSH_PORT:-$(detect_ssh_port)}"

header "Настройка межсетевого экрана"

# --- 1. Предохранитель по SSH -----------------------------------------------
header "1. Проверка порта SSH"
ACTUAL_SSH_PORT="$(detect_ssh_port)"
if [[ "${SSHP}" != "${ACTUAL_SSH_PORT}" ]]; then
  warn "В .env SSH_PORT=${SSHP}, а sshd слушает ${ACTUAL_SSH_PORT}."
  warn "Открою оба порта, чтобы не потерять доступ."
  SSH_PORTS=("${SSHP}" "${ACTUAL_SSH_PORT}")
else
  SSH_PORTS=("${SSHP}")
fi
ok "Порты SSH к открытию: ${SSH_PORTS[*]}"

# --- 2. Базовая политика ----------------------------------------------------
header "2. Базовые правила ufw"
# Сбрасываем только если явно подтверждено — reset рвёт активные правила.
if ufw status 2>/dev/null | grep -q 'Status: active'; then
  info "ufw уже активен, правила будут дополнены"
else
  info "ufw неактивен, настраиваю с нуля"
fi

ufw --force default deny incoming >/dev/null
ufw --force default allow outgoing >/dev/null
ufw --force default deny routed >/dev/null 2>&1 || true
ok "Политика: входящие — запрет, исходящие — разрешение"

# --- 3. SSH -----------------------------------------------------------------
header "3. Доступ по SSH"
for p in "${SSH_PORTS[@]}"; do
  if [[ -n "${SSH_ALLOWED_IPS:-}" ]]; then
    # Ограничиваем SSH списком адресов.
    IFS=',' read -ra IPS <<<"${SSH_ALLOWED_IPS}"
    for ip in "${IPS[@]}"; do
      ip="$(printf '%s' "${ip}" | tr -d ' ')"
      [[ -n "${ip}" ]] || continue
      ufw allow from "${ip}" to any port "${p}" proto tcp comment "SSH from ${ip}" >/dev/null
      ok "SSH порт ${p} разрешён для ${ip}"
    done
    warn "SSH ограничен адресами: ${SSH_ALLOWED_IPS}"
    warn "При смене вашего IP доступ пропадёт. Держите доступ к консоли VPS через панель провайдера."
  else
    # limit вместо allow: ufw сам режет брутфорс (6 попыток за 30 секунд).
    ufw limit "${p}/tcp" comment 'SSH (rate limited)' >/dev/null
    ok "SSH порт ${p} разрешён с ограничением частоты подключений"
  fi
done

# --- 4. Почтовые порты ------------------------------------------------------
header "4. Почтовые порты"
# Эти порты должны быть доступны из интернета — иначе почта не работает.
declare -A MAIL_PORTS=(
  [25]="SMTP — приём почты от других серверов"
  [587]="Submission — отправка почты клиентами (STARTTLS)"
  [143]="IMAP — чтение почты (STARTTLS)"
  [993]="IMAPS — чтение почты (TLS)"
  [4190]="ManageSieve — правила фильтрации"
)

[[ "${OPEN_PORT_465:-yes}" == "yes" ]] && MAIL_PORTS[465]="SMTPS — отправка почты клиентами (TLS)"
if [[ "${OPEN_POP3:-no}" == "yes" ]]; then
  MAIL_PORTS[110]="POP3 — чтение почты (STARTTLS)"
  MAIL_PORTS[995]="POP3S — чтение почты (TLS)"
fi

for port in $(printf '%s\n' "${!MAIL_PORTS[@]}" | sort -n); do
  ufw allow "${port}/tcp" comment "${MAIL_PORTS[$port]}" >/dev/null
  ok "${port}/tcp — ${MAIL_PORTS[$port]}"
done

# --- 5. Веб-порты -----------------------------------------------------------
header "5. Веб-интерфейс"
HP="${HTTP_PORT:-80}"
HSP="${HTTPS_PORT:-443}"
# Порт 80 нужен Let's Encrypt для проверки домена — закрывать нельзя.
ufw allow "${HP}/tcp" comment 'HTTP — проверка Let'\''s Encrypt и редирект на HTTPS' >/dev/null
ok "${HP}/tcp — HTTP (нужен для выпуска сертификатов)"
ufw allow "${HSP}/tcp" comment 'HTTPS — веб-почта и панель администратора' >/dev/null
ok "${HSP}/tcp — HTTPS"

# --- 6. Включение -----------------------------------------------------------
header "6. Активация"
if ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw reload >/dev/null
  ok "Правила ufw перезагружены"
else
  warn "Сейчас будет включён межсетевой экран."
  warn "Порты SSH (${SSH_PORTS[*]}) уже разрешены, текущая сессия не прервётся."
  if confirm "Включить ufw?"; then
    ufw --force enable >/dev/null
    ok "ufw включён"
  else
    info "ufw не включён. Правила сохранены и применятся при ручном включении: ufw enable"
  fi
fi

systemctl enable ufw >/dev/null 2>&1 || true

# --- 7. Правила для Docker (цепочка DOCKER-USER) ---------------------------
header "7. Правила для контейнеров Docker"
info "Порты, опубликованные контейнерами, обходят ufw."
info "Для их фильтрации используется цепочка DOCKER-USER."

DOCKER_RULES=/usr/local/sbin/mailstack-docker-firewall
cat >"${DOCKER_RULES}" <<'DFW_EOF'
#!/usr/bin/env bash
# Правила iptables для цепочки DOCKER-USER.
# Создано security/20-firewall.sh. Применяется systemd-службой при старте Docker.
#
# Логика: mailcow сам управляет банами через свой контейнер netfilter,
# который вставляет правила в начало DOCKER-USER. Здесь добавляются только
# базовые защитные правила в конец цепочки, не конфликтующие с mailcow.
set -Eeuo pipefail

CHAIN=DOCKER-USER
COMMENT_TAG="mailstack"

# Ждём появления цепочки (Docker создаёт её при старте).
for _ in {1..30}; do
  iptables -L "${CHAIN}" -n >/dev/null 2>&1 && break
  sleep 1
done
iptables -L "${CHAIN}" -n >/dev/null 2>&1 || { echo "Цепочка ${CHAIN} не найдена"; exit 0; }

# Удаляем ранее добавленные нами правила (идемпотентность).
while iptables -L "${CHAIN}" -n --line-numbers 2>/dev/null | grep -q "${COMMENT_TAG}"; do
  LINE="$(iptables -L "${CHAIN}" -n --line-numbers | grep "${COMMENT_TAG}" | head -n1 | awk '{print $1}')"
  [[ -n "${LINE}" ]] || break
  iptables -D "${CHAIN}" "${LINE}" 2>/dev/null || break
done

# 1. Защита от SYN-флуда на SMTP: не более 30 новых соединений в минуту с адреса.
iptables -A "${CHAIN}" -p tcp --dport 25 -m conntrack --ctstate NEW \
  -m hashlimit --hashlimit-above 30/min --hashlimit-burst 20 \
  --hashlimit-mode srcip --hashlimit-name smtp_flood \
  -m comment --comment "mailstack: ограничение частоты SMTP" -j DROP 2>/dev/null || true

# 2. Защита от перебора паролей на submission: 20 новых соединений в минуту.
for P in 587 465 143 993; do
  iptables -A "${CHAIN}" -p tcp --dport "${P}" -m conntrack --ctstate NEW \
    -m hashlimit --hashlimit-above 20/min --hashlimit-burst 15 \
    --hashlimit-mode srcip --hashlimit-name "mail_${P}" \
    -m comment --comment "mailstack: ограничение частоты порта ${P}" -j DROP 2>/dev/null || true
done

# 3. Отбрасываем некорректные пакеты.
iptables -A "${CHAIN}" -p tcp ! --syn -m conntrack --ctstate NEW \
  -m comment --comment "mailstack: пакет без SYN в новом соединении" -j DROP 2>/dev/null || true
iptables -A "${CHAIN}" -p tcp --tcp-flags ALL NONE \
  -m comment --comment "mailstack: NULL-скан" -j DROP 2>/dev/null || true
iptables -A "${CHAIN}" -p tcp --tcp-flags ALL ALL \
  -m comment --comment "mailstack: XMAS-скан" -j DROP 2>/dev/null || true

echo "Правила ${CHAIN} применены"
DFW_EOF

chmod 0700 "${DOCKER_RULES}"
ok "Создан ${DOCKER_RULES}"

cat >/etc/systemd/system/mailstack-docker-firewall.service <<EOF
[Unit]
Description=Правила iptables DOCKER-USER для почтового сервера
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${DOCKER_RULES}

[Install]
WantedBy=multi-user.target docker.service
EOF

systemctl daemon-reload
systemctl enable mailstack-docker-firewall.service >/dev/null 2>&1

if systemctl is-active --quiet docker; then
  if systemctl start mailstack-docker-firewall.service 2>/dev/null; then
    ok "Правила DOCKER-USER применены"
  else
    warn "Не удалось применить правила DOCKER-USER. Проверьте: journalctl -u mailstack-docker-firewall"
  fi
else
  info "Docker не запущен, правила применятся при его старте"
fi

# --- 8. Защита от IP-спуфинга и лишнего трафика ----------------------------
header "8. Дополнительные правила"
# Запрещаем ответы ICMP на широковещательные запросы и прочее — в sysctl.
info "Сетевые параметры ядра настраивает security/40-sysctl.sh"

# --- 9. Итоговое состояние --------------------------------------------------
header "9. Текущие правила"
ufw status numbered 2>/dev/null | sed 's/^/  /' || true

printf '\n'
info "Правила DOCKER-USER:"
iptables -L DOCKER-USER -n 2>/dev/null | head -n 20 | sed 's/^/  /' || info "  (цепочка появится после старта Docker)"

# --- Итог -------------------------------------------------------------------
header "Готово"
mark_step_done "20-firewall"
ok "Межсетевой экран настроен."
printf '\n'
info "Управление:"
info "  Состояние       : ufw status verbose"
info "  Отключить       : ufw disable"
info "  Удалить правило : ufw status numbered  затем  ufw delete <номер>"
printf '\n'
warn "Порты 25, 587, 993, 443 открыты для всего интернета — так должен работать почтовый сервер."
warn "Защиту от перебора паролей обеспечивают mailcow (свой netfilter) и fail2ban для SSH."
