#!/usr/bin/env bash
# =============================================================================
# 10-bootstrap-os.sh — подготовка операционной системы.
# Обновляет пакеты, ставит базовые утилиты, чинит hostname, время, swap,
# убирает конфликтующие MTA и освобождает порт 53.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "bootstrap-os"
require_root
require_debian12
load_env
require_vars MAIL_HOSTNAME TZ

export DEBIAN_FRONTEND=noninteractive

header "Подготовка ОС"

# --- 1. Обновление системы --------------------------------------------------
header "1. Обновление пакетов"
info "apt-get update"
apt-get update -qq
info "Устанавливаю обновления безопасности (может занять несколько минут)"
apt-get -y -qq upgrade
ok "Система обновлена"

# --- 2. Базовые пакеты ------------------------------------------------------
header "2. Базовые утилиты"
PKGS=(
  ca-certificates curl wget gnupg lsb-release apt-transport-https
  git nano vim-tiny
  dnsutils net-tools iproute2 telnet netcat-openbsd
  jq openssl
  ufw fail2ban
  unattended-upgrades apt-listchanges
  chrony
  htop ncdu
  swaks            # отправка тестовых писем
  tzdata locales
  rsync tar gzip
  python3 python3-pip
)
info "Ставлю: ${PKGS[*]}"
apt-get install -y -qq "${PKGS[@]}"
ok "Базовые утилиты установлены"

# --- 3. Локали и часовой пояс ----------------------------------------------
header "3. Локали и часовой пояс"
if ! locale -a 2>/dev/null | grep -qi 'ru_RU.utf8'; then
  sed -i 's/^# *ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
  sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
  locale-gen >/dev/null 2>&1 || true
  ok "Локали ru_RU.UTF-8 и en_US.UTF-8 сгенерированы"
else
  ok "Локаль ru_RU.UTF-8 уже есть"
fi

if timedatectl set-timezone "${TZ}" 2>/dev/null; then
  ok "Часовой пояс: ${TZ}"
else
  warn "Не удалось установить часовой пояс «${TZ}». Проверьте значение TZ в .env"
fi

# --- 4. Синхронизация времени ----------------------------------------------
header "4. Точное время"
systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || true
timedatectl set-ntp true 2>/dev/null || true
sleep 2
if timedatectl show 2>/dev/null | grep -q 'NTPSynchronized=yes'; then
  ok "Время синхронизировано"
else
  warn "Синхронизация ещё не завершилась. Проверьте позже: timedatectl status"
fi

# --- 5. Hostname ------------------------------------------------------------
header "5. Имя хоста"
CURRENT_FQDN="$(hostname -f 2>/dev/null || hostname)"
if [[ "${CURRENT_FQDN}" == "${MAIL_HOSTNAME}" ]]; then
  ok "Имя хоста уже ${MAIL_HOSTNAME}"
else
  info "Меняю имя хоста: ${CURRENT_FQDN} → ${MAIL_HOSTNAME}"
  SHORT_NAME="${MAIL_HOSTNAME%%.*}"
  hostnamectl set-hostname "${MAIL_HOSTNAME}"

  backup_file /etc/hosts
  # Гарантируем, что FQDN резолвится локально — иначе Postfix ругается.
  if ! grep -qE "^127\.0\.1\.1[[:space:]]+${MAIL_HOSTNAME//./\\.}" /etc/hosts; then
    # Убираем старые строки 127.0.1.1 и добавляем свою.
    sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
    printf '127.0.1.1\t%s %s\n' "${MAIL_HOSTNAME}" "${SHORT_NAME}" >>/etc/hosts
  fi
  ok "Имя хоста установлено: $(hostname -f 2>/dev/null || hostname)"
fi

# --- 6. Конфликтующие MTA и веб-серверы ------------------------------------
header "6. Конфликтующее ПО"
CONFLICTS=()
for pkg in postfix exim4 exim4-base exim4-daemon-light sendmail dovecot-core apache2 nginx; do
  if dpkg -l "${pkg}" 2>/dev/null | grep -q '^ii'; then
    CONFLICTS+=("${pkg}")
  fi
done

if ((${#CONFLICTS[@]} == 0)); then
  ok "Конфликтующих пакетов нет"
else
  warn "Найдены пакеты, которые займут порты mailcow: ${CONFLICTS[*]}"
  warn "Это НЕОБРАТИМАЯ операция: пакеты и их конфигурации будут удалены."
  if confirm "Удалить пакеты ${CONFLICTS[*]}?"; then
    for svc in postfix exim4 sendmail dovecot apache2 nginx; do
      systemctl disable --now "${svc}" >/dev/null 2>&1 || true
    done
    apt-get purge -y -qq "${CONFLICTS[@]}"
    apt-get autoremove -y -qq
    ok "Конфликтующие пакеты удалены"
  else
    die "Без удаления конфликтующих пакетов mailcow не запустится. Освободите порты вручную и повторите."
  fi
fi

# --- 7. Порт 53 и systemd-resolved -----------------------------------------
header "7. Порт 53 (DNS)"
# mailcow поднимает собственный unbound на 127.0.0.1:53 внутри Docker-сети,
# но systemd-resolved в режиме stub может конфликтовать при host-сети.
if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
  RESOLVED_CONF=/etc/systemd/resolved.conf.d/mailstack.conf
  mkdir -p /etc/systemd/resolved.conf.d
  if [[ ! -f "${RESOLVED_CONF}" ]]; then
    cat >"${RESOLVED_CONF}" <<'EOF'
# Настройка mailstack: не слушать 53 на внешних интерфейсах,
# чтобы не конфликтовать с DNS-резолвером mailcow.
[Resolve]
DNSStubListener=no
EOF
    # /etc/resolv.conf должен указывать на реальные серверы.
    if [[ -L /etc/resolv.conf ]] && readlink /etc/resolv.conf | grep -q 'stub-resolv.conf'; then
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi
    systemctl restart systemd-resolved
    ok "systemd-resolved больше не слушает 53 на внешних интерфейсах"
  else
    ok "systemd-resolved уже настроен"
  fi
else
  ok "systemd-resolved не активен — настройка не нужна"
fi

# Контрольная проверка, что DNS на хосте всё ещё работает.
if getent hosts deb.debian.org >/dev/null 2>&1; then
  ok "Разрешение имён на хосте работает"
else
  err "DNS на хосте сломался после правки resolved. Проверьте /etc/resolv.conf"
  err "Быстрый откат: echo 'nameserver 1.1.1.1' > /etc/resolv.conf"
  exit 1
fi

# --- 8. Swap ----------------------------------------------------------------
header "8. Файл подкачки"
MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
SWAP_MB=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)
info "RAM: ${MEM_MB} МБ, swap: ${SWAP_MB} МБ"

# Для mailcow при малом RAM swap спасает от OOM-killer.
if ((SWAP_MB >= 1024)); then
  ok "Swap уже настроен (${SWAP_MB} МБ)"
elif ((MEM_MB >= 7800)); then
  ok "Памяти достаточно, swap не требуется"
else
  SWAP_SIZE_GB=2
  ((MEM_MB < 4000)) && SWAP_SIZE_GB=4
  SWAPFILE=/swapfile
  if [[ -f "${SWAPFILE}" ]]; then
    warn "${SWAPFILE} уже существует, пропускаю создание"
  else
    info "Создаю swap-файл ${SWAP_SIZE_GB} ГБ"
    if fallocate -l "${SWAP_SIZE_GB}G" "${SWAPFILE}" 2>/dev/null; then
      :
    else
      dd if=/dev/zero of="${SWAPFILE}" bs=1M count=$((SWAP_SIZE_GB * 1024)) status=none
    fi
    chmod 600 "${SWAPFILE}"
    mkswap "${SWAPFILE}" >/dev/null
    swapon "${SWAPFILE}"
    if ! grep -q "^${SWAPFILE}" /etc/fstab; then
      printf '%s none swap sw 0 0\n' "${SWAPFILE}" >>/etc/fstab
    fi
    ok "Swap ${SWAP_SIZE_GB} ГБ создан и подключён"
  fi
  # Для почтового сервера умеренная агрессивность swap.
  if ! grep -q 'vm.swappiness' /etc/sysctl.d/99-mailstack-swap.conf 2>/dev/null; then
    echo 'vm.swappiness=10' >/etc/sysctl.d/99-mailstack-swap.conf
    sysctl -q -p /etc/sysctl.d/99-mailstack-swap.conf || true
  fi
fi

# --- 9. Лимиты файловых дескрипторов ---------------------------------------
header "9. Системные лимиты"
LIMITS_FILE=/etc/security/limits.d/99-mailstack.conf
if [[ ! -f "${LIMITS_FILE}" ]]; then
  cat >"${LIMITS_FILE}" <<'EOF'
# Повышенные лимиты для почтового сервера с Docker.
*       soft    nofile  65535
*       hard    nofile  65535
root    soft    nofile  65535
root    hard    nofile  65535
EOF
  ok "Лимиты nofile повышены до 65535 (применятся после перелогина)"
else
  ok "Лимиты уже настроены"
fi

# --- 10. Каталоги комплекта -------------------------------------------------
header "10. Служебные каталоги"
mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${BACKUP_DIR:-/var/backups/mailcow}"
chmod 0750 "${LOG_DIR}" "${STATE_DIR}"
chmod 0700 "${BACKUP_DIR:-/var/backups/mailcow}"
ok "Созданы ${LOG_DIR}, ${STATE_DIR}, ${BACKUP_DIR:-/var/backups/mailcow}"

# --- Итог -------------------------------------------------------------------
header "Готово"
mark_step_done "10-bootstrap-os"
ok "ОС подготовлена."
info "Следующий шаг: sudo ./deploy/20-install-docker.sh"
if [[ -n "$(needrestart -b 2>/dev/null | grep -c 'KSTA: [^1]' || true)" ]] && [[ -f /var/run/reboot-required ]]; then
  warn "Обновления требуют перезагрузки. Рекомендуется: reboot, затем продолжить установку."
fi
