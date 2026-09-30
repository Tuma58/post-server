#!/usr/bin/env bash
# =============================================================================
# 40-sysctl.sh — параметры ядра: защита сети и настройки под нагрузку почты.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "sysctl"
require_root
load_env

SYSCTL_FILE=/etc/sysctl.d/99-mailstack-security.conf

header "Настройка параметров ядра"

backup_file "${SYSCTL_FILE}" 2>/dev/null || true

# Важно: rp_filter и ip_forward должны учитывать Docker.
# ip_forward=1 обязателен для работы контейнеров — не выключаем.
cat >"${SYSCTL_FILE}" <<'EOF'
# =============================================================================
# Параметры ядра для почтового сервера. Создано security/40-sysctl.sh
# =============================================================================

# --- Защита от сетевых атак -------------------------------------------------

# Игнорировать ICMP-запросы на широковещательные адреса (защита от smurf-атак).
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Игнорировать некорректные ICMP-ответы.
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Не принимать маршруты от source routing (подмена маршрута).
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Не принимать ICMP-редиректы (подмена шлюза).
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Не отправлять ICMP-редиректы.
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Защита от подмены адреса источника (обратная проверка маршрута).
# Значение 1 (strict) ломает асимметричную маршрутизацию, 2 (loose) безопаснее
# для серверов с несколькими интерфейсами и Docker.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Логировать пакеты с невозможными адресами.
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Защита от SYN-флуда.
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_max_syn_backlog = 4096

# Защита от TIME_WAIT-атак.
net.ipv4.tcp_rfc1337 = 1

# --- Производительность сети под почтовую нагрузку -------------------------

# Размеры буферов TCP: важно для передачи писем с вложениями.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Очередь необработанных соединений.
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 5000

# Переиспользование сокетов в TIME_WAIT (много коротких SMTP-сессий).
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# Диапазон локальных портов: больше одновременных исходящих соединений.
net.ipv4.ip_local_port_range = 10240 65535

# Keepalive: быстрее обнаруживать оборванные соединения.
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15

# Таблица отслеживания соединений: Docker и почта создают много записей.
net.netfilter.nf_conntrack_max = 262144

# --- Параметры для Docker ---------------------------------------------------

# Форвардинг обязателен для контейнерных сетей. НЕ отключать.
net.ipv4.ip_forward = 1

# Мосты Docker не должны обрабатываться iptables дважды.
net.bridge.bridge-nf-call-iptables = 1

# --- Файловая система и память ---------------------------------------------

# Максимум открытых файлов в системе (Dovecot держит много дескрипторов).
fs.file-max = 262144

# Количество наблюдателей inotify: Dovecot следит за изменениями в ящиках.
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

# Умеренное использование swap: почтовый сервер чувствителен к задержкам.
vm.swappiness = 10

# Резерв памяти, чтобы OOM-killer не убивал контейнеры базы данных.
vm.overcommit_memory = 1

# --- Защита процессов -------------------------------------------------------

# Ограничение доступа к ядерным указателям.
kernel.kptr_restrict = 1

# Запрет чтения памяти чужих процессов через ptrace.
kernel.yama.ptrace_scope = 1

# Защита hardlink и symlink от эксплуатации в /tmp.
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 1
fs.protected_regular = 2

# Отключить дампы памяти setuid-процессов.
fs.suid_dumpable = 0

# Магические комбинации SysRq (частично отключаем).
kernel.sysrq = 0

# Пространства имён пользователей нужны Docker — не отключаем.
# user.max_user_namespaces оставлен по умолчанию.
EOF

chmod 0644 "${SYSCTL_FILE}"
ok "Параметры записаны в ${SYSCTL_FILE}"

# --- Применение -------------------------------------------------------------
header "Применение"
# Некоторые параметры требуют загруженных модулей — не считаем это ошибкой.
APPLY_OUT="$(sysctl -p "${SYSCTL_FILE}" 2>&1 || true)"
FAILED_PARAMS="$(printf '%s' "${APPLY_OUT}" | grep -i 'cannot stat\|No such file' | sed 's/.*key "\([^"]*\)".*/\1/' || true)"

if [[ -n "${FAILED_PARAMS}" ]]; then
  warn "Некоторые параметры недоступны (модуль ядра не загружен):"
  printf '%s\n' "${FAILED_PARAMS}" | sed 's/^/    /'
  info "Это нормально для nf_conntrack и bridge — они появятся после старта Docker."

  # Пробуем загрузить модули и применить снова.
  modprobe nf_conntrack 2>/dev/null || true
  modprobe br_netfilter 2>/dev/null || true

  # Модули должны подгружаться при загрузке системы.
  MODULES_FILE=/etc/modules-load.d/mailstack.conf
  if [[ ! -f "${MODULES_FILE}" ]]; then
    printf 'nf_conntrack\nbr_netfilter\n' >"${MODULES_FILE}"
    ok "Модули добавлены в автозагрузку (${MODULES_FILE})"
  fi

  sysctl -p "${SYSCTL_FILE}" >/dev/null 2>&1 || true
fi

ok "Параметры ядра применены"

# --- Проверка ключевых значений --------------------------------------------
header "Проверка"
check_sysctl() {
  local key="$1" expected="$2"
  local actual
  actual="$(sysctl -n "${key}" 2>/dev/null || echo 'нет')"
  if [[ "${actual}" == "${expected}" ]]; then
    ok "${key} = ${actual}"
  elif [[ "${actual}" == "нет" ]]; then
    warn "${key} недоступен в этом ядре"
  else
    warn "${key} = ${actual} (ожидалось ${expected})"
  fi
}

check_sysctl net.ipv4.tcp_syncookies 1
check_sysctl net.ipv4.ip_forward 1
check_sysctl net.ipv4.conf.all.accept_redirects 0
check_sysctl vm.swappiness 10
check_sysctl fs.protected_symlinks 1

# Критично: если ip_forward сброшен, контейнеры потеряют сеть.
if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" != "1" ]]; then
  err "net.ipv4.ip_forward отключён — сеть Docker не будет работать."
  err "Исправление: sysctl -w net.ipv4.ip_forward=1"
  exit 1
fi

# --- Итог -------------------------------------------------------------------
header "Готово"
mark_step_done "40-sysctl"
ok "Параметры ядра настроены."
info "Проверка сети контейнеров: docker run --rm alpine ping -c1 1.1.1.1"
