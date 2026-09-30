#!/usr/bin/env bash
# =============================================================================
# 10-harden-ssh.sh — усиление защиты SSH.
#
# ОСТОРОЖНО: неверная настройка приводит к потере доступа к серверу.
# Скрипт проверяет конфигурацию перед применением и НЕ рвёт текущую сессию.
# Держите открытым второе SSH-подключение до завершения проверки.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "harden-ssh"
require_root
load_env

SSHD_CONF=/etc/ssh/sshd_config
DROPIN_DIR=/etc/ssh/sshd_config.d
DROPIN="${DROPIN_DIR}/99-mailstack-hardening.conf"

NEW_PORT="${SSH_PORT:-22}"
ALLOW_USER="${SSH_ALLOW_USER:-}"
DISABLE_ROOT="${SSH_DISABLE_ROOT:-no}"
DISABLE_PASS="${SSH_DISABLE_PASSWORD:-no}"

header "Усиление защиты SSH"
warn "Перед продолжением откройте ВТОРОЕ SSH-подключение к серверу и не закрывайте его."
warn "Если что-то пойдёт не так, через него вы сможете откатить изменения."
printf '\n'

# --- 1. Предохранители ------------------------------------------------------
header "1. Проверка предусловий"

CURRENT_PORT="$(detect_ssh_port)"
info "Текущий порт SSH: ${CURRENT_PORT}, целевой: ${NEW_PORT}"

# Проверка: есть ли кому зайти, если отключим root.
if [[ "${DISABLE_ROOT}" == "yes" ]]; then
  [[ -n "${ALLOW_USER}" ]] || die "SSH_DISABLE_ROOT=yes требует заданного SSH_ALLOW_USER в .env"
  id "${ALLOW_USER}" >/dev/null 2>&1 || die "Пользователь «${ALLOW_USER}» не существует. Создайте: adduser ${ALLOW_USER} && usermod -aG sudo ${ALLOW_USER}"

  USER_HOME="$(getent passwd "${ALLOW_USER}" | cut -d: -f6)"
  AUTH_KEYS="${USER_HOME}/.ssh/authorized_keys"
  [[ -s "${AUTH_KEYS}" ]] || die "У пользователя «${ALLOW_USER}» нет SSH-ключей в ${AUTH_KEYS}. Добавьте публичный ключ, иначе доступ будет потерян."

  KEY_COUNT="$(grep -cE '^(ssh-|ecdsa-|sk-)' "${AUTH_KEYS}" 2>/dev/null || echo 0)"
  ok "У «${ALLOW_USER}» найдено ключей: ${KEY_COUNT}"

  # Проверка sudo.
  if id -nG "${ALLOW_USER}" 2>/dev/null | grep -qw sudo; then
    ok "Пользователь «${ALLOW_USER}» входит в группу sudo"
  else
    warn "Пользователь «${ALLOW_USER}» НЕ в группе sudo. Он не сможет администрировать сервер."
    if confirm "Добавить ${ALLOW_USER} в группу sudo?"; then
      usermod -aG sudo "${ALLOW_USER}"
      ok "Добавлен в sudo"
    else
      die "Без sudo отключать root-доступ нельзя. Отмена."
    fi
  fi
fi

# Проверка: не отрежем ли себя отключением паролей.
if [[ "${DISABLE_PASS}" == "yes" ]]; then
  ROOT_KEYS=/root/.ssh/authorized_keys
  HAS_ANY_KEY=0
  [[ -s "${ROOT_KEYS}" ]] && HAS_ANY_KEY=1
  if [[ -n "${ALLOW_USER}" ]]; then
    UH="$(getent passwd "${ALLOW_USER}" 2>/dev/null | cut -d: -f6 || true)"
    [[ -n "${UH}" && -s "${UH}/.ssh/authorized_keys" ]] && HAS_ANY_KEY=1
  fi
  if ((HAS_ANY_KEY == 0)); then
    die "SSH_DISABLE_PASSWORD=yes, но ни у root, ни у ${ALLOW_USER:-—} нет authorized_keys. Вы потеряете доступ. Добавьте ключ и повторите."
  fi
  ok "Ключи для входа найдены — отключение паролей безопасно"
fi

# --- 2. Резервная копия -----------------------------------------------------
header "2. Резервное копирование конфигурации"
backup_file "${SSHD_CONF}"
mkdir -p "${DROPIN_DIR}"
[[ -f "${DROPIN}" ]] && backup_file "${DROPIN}"
ok "Копия сохранена"

# Убедимся, что sshd_config подключает каталог drop-in.
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "${SSHD_CONF}"; then
  warn "sshd_config не подключает sshd_config.d — добавляю Include в начало файла"
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "${SSHD_CONF}"
fi

# --- 3. Формирование конфигурации ------------------------------------------
header "3. Новая конфигурация"

# Список разрешённых пользователей.
ALLOW_LINE=""
if [[ -n "${ALLOW_USER}" ]]; then
  if [[ "${DISABLE_ROOT}" == "yes" ]]; then
    ALLOW_LINE="AllowUsers ${ALLOW_USER}"
  else
    ALLOW_LINE="AllowUsers root ${ALLOW_USER}"
  fi
fi

ROOT_LOGIN="yes"
[[ "${DISABLE_ROOT}" == "yes" ]] && ROOT_LOGIN="no"
# Если root оставляем, то только по ключу.
[[ "${ROOT_LOGIN}" == "yes" && "${DISABLE_PASS}" == "yes" ]] && ROOT_LOGIN="prohibit-password"

PASS_AUTH="yes"
KBD_AUTH="yes"
if [[ "${DISABLE_PASS}" == "yes" ]]; then
  PASS_AUTH="no"
  KBD_AUTH="no"
fi

cat >"${DROPIN}" <<EOF
# =============================================================================
# Настройки безопасности SSH. Создано security/10-harden-ssh.sh
# Файл перезаписывается при повторном запуске скрипта.
# Для собственных правок создайте отдельный файл в /etc/ssh/sshd_config.d/
# =============================================================================

# --- Порт ---
Port ${NEW_PORT}

# --- Протокол и адреса ---
AddressFamily $( [[ "${ENABLE_IPV6:-no}" == "yes" ]] && echo any || echo inet )

# --- Аутентификация ---
PermitRootLogin ${ROOT_LOGIN}
PasswordAuthentication ${PASS_AUTH}
KbdInteractiveAuthentication ${KBD_AUTH}
PubkeyAuthentication yes
AuthenticationMethods publickey$( [[ "${PASS_AUTH}" == "yes" ]] && echo ',password' || true )
PermitEmptyPasswords no
MaxAuthTries 3
MaxSessions 6
LoginGraceTime 30

# Отключаем устаревшие и небезопасные методы.
HostbasedAuthentication no
IgnoreRhosts yes
GSSAPIAuthentication no
KerberosAuthentication no

${ALLOW_LINE}

# --- Криптография: только современные алгоритмы ---
# Убраны алгоритмы с известными слабостями (CBC, SHA-1, DSA, 1024-битный DH).
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256
PubkeyAcceptedAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256,sk-ssh-ed25519@openssh.com

# --- Ограничение возможностей сессии ---
# Проброс портов оставлен: используется для доступа к веб-панели через SSH-туннель.
AllowTcpForwarding yes
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no

# --- Сессии ---
# Разрыв неактивных сессий: 3 проверки по 300 секунд = 15 минут.
ClientAliveInterval 300
ClientAliveCountMax 3
TCPKeepAlive yes

# --- Прочее ---
UseDNS no
Compression no
PrintLastLog yes
Banner none
LogLevel VERBOSE
StrictModes yes
EOF

chmod 0600 "${DROPIN}"
ok "Конфигурация записана в ${DROPIN}"

# --- 4. Проверка синтаксиса -------------------------------------------------
header "4. Проверка синтаксиса"
if sshd -t 2>/dev/null; then
  ok "Синтаксис корректен"
else
  err "Конфигурация sshd содержит ошибки:"
  sshd -t 2>&1 | sed 's/^/    /' || true
  err "Удаляю ${DROPIN}, чтобы не сломать доступ"
  rm -f "${DROPIN}"
  exit 1
fi

# --- 5. Firewall для нового порта ------------------------------------------
header "5. Порт в firewall"
if [[ "${NEW_PORT}" != "${CURRENT_PORT}" ]]; then
  warn "Порт SSH меняется с ${CURRENT_PORT} на ${NEW_PORT}"
  if have_cmd ufw; then
    ufw allow "${NEW_PORT}/tcp" comment 'SSH mailstack' >/dev/null 2>&1 || true
    ok "Порт ${NEW_PORT}/tcp разрешён в ufw"
  else
    warn "ufw не установлен. Убедитесь, что порт ${NEW_PORT} открыт, иначе потеряете доступ."
    confirm "Порт ${NEW_PORT} точно открыт в firewall провайдера?" || die "Отмена. Откройте порт и повторите."
  fi
fi

# --- 6. Применение ----------------------------------------------------------
header "6. Перезапуск sshd"
info "Текущие SSH-сессии НЕ разрываются при перезагрузке конфигурации."
if ! confirm "Применить новую конфигурацию SSH?"; then
  rm -f "${DROPIN}"
  info "Отменено, изменения откатаны."
  exit 0
fi

systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh
sleep 2

if systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; then
  ok "Служба SSH работает"
else
  err "Служба SSH не запустилась. Восстанавливаю предыдущую конфигурацию."
  rm -f "${DROPIN}"
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  exit 1
fi

# --- 7. Контрольная проверка -----------------------------------------------
header "7. Проверка доступности"
sleep 1
if ss -Hltn "sport = :${NEW_PORT}" 2>/dev/null | grep -q LISTEN; then
  ok "sshd слушает порт ${NEW_PORT}"
else
  err "sshd НЕ слушает порт ${NEW_PORT}. Не закрывайте текущую сессию!"
  err "Откат: rm -f ${DROPIN} && systemctl reload ssh"
  exit 1
fi

# --- Итог -------------------------------------------------------------------
header "Готово"
mark_step_done "10-harden-ssh"
ok "SSH защищён."
printf '\n'
info "Применённые настройки:"
info "  Порт                    : ${NEW_PORT}"
info "  Вход root               : ${ROOT_LOGIN}"
info "  Вход по паролю          : ${PASS_AUTH}"
[[ -n "${ALLOW_LINE}" ]] && info "  Разрешены пользователи  : ${ALLOW_LINE#AllowUsers }"
info "  Попыток входа           : 3"
info "  Таймаут неактивности    : 15 минут"
printf '\n'
warn "ПРОВЕРЬТЕ ПРЯМО СЕЙЧАС, не закрывая текущую сессию, новое подключение:"
if [[ -n "${ALLOW_USER}" && "${DISABLE_ROOT}" == "yes" ]]; then
  info "    ssh -p ${NEW_PORT} ${ALLOW_USER}@$(detect_public_ip4)"
else
  info "    ssh -p ${NEW_PORT} root@$(detect_public_ip4)"
fi
printf '\n'
info "Если подключиться не удалось, в текущей сессии выполните:"
info "    rm -f ${DROPIN} && systemctl reload ssh"
