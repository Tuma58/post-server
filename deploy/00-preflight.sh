#!/usr/bin/env bash
# =============================================================================
# 00-preflight.sh — проверки ДО установки.
# Ничего не меняет в системе, только читает и сообщает о проблемах.
# Запускать первым: sudo ./deploy/00-preflight.sh
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "preflight"
require_root
load_env
require_vars MAIL_DOMAIN MAIL_HOSTNAME ADMIN_EMAIL

header "Предварительная проверка сервера"
info "Домен: ${MAIL_DOMAIN}   Хост: ${MAIL_HOSTNAME}"

# --- 1. Операционная система ------------------------------------------------
header "1. Операционная система"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  check_info "Обнаружено: ${PRETTY_NAME:-неизвестно}"
  if [[ "${ID:-}" == "debian" && "${VERSION_ID%%.*}" == "12" ]]; then
    check_pass "Debian 12 — поддерживаемая версия"
  else
    check_warn "Комплект рассчитан на Debian 12, у вас «${PRETTY_NAME:-?}». Возможны отличия в пакетах."
  fi
else
  check_fail "Не удалось определить ОС (/etc/os-release недоступен)"
fi

if [[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "aarch64" ]]; then
  check_pass "Архитектура $(uname -m) поддерживается"
else
  check_fail "Архитектура $(uname -m) не поддерживается образами mailcow"
fi

# --- 2. Ресурсы -------------------------------------------------------------
header "2. Ресурсы"
MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
CPU_CORES=$(nproc)
check_info "RAM: ${MEM_MB} МБ, ядер CPU: ${CPU_CORES}"

if ((MEM_MB >= 5800)); then
  check_pass "Памяти достаточно (${MEM_MB} МБ)"
elif ((MEM_MB >= 3500)); then
  check_warn "Памяти ${MEM_MB} МБ. mailcow рекомендует 6 ГБ. Скрипт 10-bootstrap-os.sh создаст swap, а 30-install-mailcow.sh отключит полнотекстовый поиск."
else
  check_fail "Памяти всего ${MEM_MB} МБ — для mailcow критически мало. Нужно минимум 3.5 ГБ, рекомендуется 6 ГБ."
fi

if ((CPU_CORES >= 2)); then
  check_pass "Ядер CPU: ${CPU_CORES}"
else
  check_warn "Одно ядро CPU. Работать будет, но медленно (особенно антивирус и антиспам)."
fi

DISK_FREE_GB=$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')
check_info "Свободно на /: ${DISK_FREE_GB} ГБ"
if ((DISK_FREE_GB >= 30)); then
  check_pass "Дискового пространства достаточно"
elif ((DISK_FREE_GB >= 15)); then
  check_warn "Свободно ${DISK_FREE_GB} ГБ. Хватит на старт, но следите за ростом почты и бэкапов."
else
  check_fail "Свободно всего ${DISK_FREE_GB} ГБ. Нужно минимум 15 ГБ, рекомендуется 40+ ГБ."
fi

# --- 3. Сеть и публичный адрес ---------------------------------------------
header "3. Сеть"
PUB_IP4="$(detect_public_ip4)"
PUB_IP6="$(detect_public_ip6)"
if [[ -n "${PUB_IP4}" ]]; then
  check_pass "Публичный IPv4: ${PUB_IP4}"
else
  check_fail "Не удалось определить публичный IPv4. Проверьте сетевую конфигурацию и доступ в интернет."
fi
if [[ -n "${PUB_IP6}" ]]; then
  check_info "Публичный IPv6: ${PUB_IP6}"
  if [[ "${ENABLE_IPV6:-no}" == "no" ]]; then
    check_warn "У сервера есть IPv6, но в .env ENABLE_IPV6=no. Это допустимо и безопасно: почта пойдёт по IPv4."
  fi
else
  check_info "IPv6 не обнаружен"
  if [[ "${ENABLE_IPV6:-no}" == "yes" ]]; then
    check_fail "В .env ENABLE_IPV6=yes, но рабочего IPv6 нет. Поставьте ENABLE_IPV6=no."
  fi
fi

# --- 4. DNS -----------------------------------------------------------------
header "4. DNS-записи"
if have_cmd dig; then
  DIG=dig
elif have_cmd host; then
  DIG=""
  check_warn "Утилита dig не установлена, проверки DNS ограничены. Она появится после 10-bootstrap-os.sh"
else
  DIG=""
  check_warn "Нет ни dig, ни host — DNS проверить нельзя. Повторите этот скрипт после 10-bootstrap-os.sh"
fi

if [[ -n "${DIG}" ]]; then
  HOST_A="$(dig +short A "${MAIL_HOSTNAME}" 2>/dev/null | grep -E '^[0-9.]+$' | head -n1 || true)"
  if [[ -z "${HOST_A}" ]]; then
    check_fail "A-запись для ${MAIL_HOSTNAME} не найдена. Создайте её у DNS-провайдера: ${MAIL_HOSTNAME} A ${PUB_IP4:-<IP сервера>}"
  elif [[ "${HOST_A}" == "${PUB_IP4}" ]]; then
    check_pass "A-запись ${MAIL_HOSTNAME} → ${HOST_A} совпадает с IP сервера"
  else
    check_fail "A-запись ${MAIL_HOSTNAME} → ${HOST_A}, а IP сервера ${PUB_IP4}. Исправьте запись, иначе Let's Encrypt не выдаст сертификат."
  fi

  MX_REC="$(dig +short MX "${MAIL_DOMAIN}" 2>/dev/null | sort -n | head -n1 || true)"
  if [[ -z "${MX_REC}" ]]; then
    check_warn "MX-запись для ${MAIL_DOMAIN} отсутствует. Добавьте её до приёма писем: ${MAIL_DOMAIN} MX 10 ${MAIL_HOSTNAME}"
  else
    check_info "MX ${MAIL_DOMAIN}: ${MX_REC}"
    if grep -qi "${MAIL_HOSTNAME}" <<<"${MX_REC}"; then
      check_pass "MX указывает на ${MAIL_HOSTNAME}"
    else
      check_warn "MX указывает не на ${MAIL_HOSTNAME}. Если домен пока обслуживает другой провайдер — это ожидаемо, поменяете при переключении."
    fi
  fi

  # PTR (обратная запись) — критична для доставки.
  if [[ -n "${PUB_IP4}" ]]; then
    PTR="$(dig +short -x "${PUB_IP4}" 2>/dev/null | sed 's/\.$//' | head -n1 || true)"
    if [[ -z "${PTR}" ]]; then
      check_fail "PTR-запись для ${PUB_IP4} не настроена. Без неё Gmail и Outlook будут отклонять почту. Настраивается в панели VPS-провайдера (rDNS)."
    elif [[ "${PTR}" == "${MAIL_HOSTNAME}" ]]; then
      check_pass "PTR ${PUB_IP4} → ${PTR}"
    else
      check_fail "PTR ${PUB_IP4} → ${PTR}, а должно быть ${MAIL_HOSTNAME}. Исправьте rDNS в панели VPS-провайдера."
    fi
  fi

  # Проверка, что домен не в чужой SPF-политике, которая всё сломает.
  SPF="$(dig +short TXT "${MAIL_DOMAIN}" 2>/dev/null | tr -d '"' | grep -i 'v=spf1' | head -n1 || true)"
  if [[ -n "${SPF}" ]]; then
    check_info "Текущая SPF: ${SPF}"
    check_warn "SPF уже существует. После установки замените её на запись из tools/gen-dns-records.sh, иначе исходящая почта не пройдёт проверку."
  else
    check_info "SPF-запись пока отсутствует — добавим после установки"
  fi
fi

# --- 5. Занятые порты -------------------------------------------------------
header "5. Порты на сервере"
if have_cmd ss; then
  # Порты, нужные mailcow.
  NEEDED_PORTS=(25 143 465 587 993 4190 "${HTTP_PORT:-80}" "${HTTPS_PORT:-443}")
  [[ "${OPEN_POP3:-no}" == "yes" ]] && NEEDED_PORTS+=(110 995)
  BUSY=()
  for p in "${NEEDED_PORTS[@]}"; do
    if ss -Hltn "sport = :${p}" 2>/dev/null | grep -q LISTEN; then
      OWNER="$(ss -Hltnp "sport = :${p}" 2>/dev/null | grep -oP 'users:\(\("\K[^"]+' | head -n1 || echo '?')"
      BUSY+=("${p} (${OWNER})")
    fi
  done
  if ((${#BUSY[@]} == 0)); then
    check_pass "Все нужные порты свободны"
  else
    check_fail "Порты уже заняты: ${BUSY[*]}. Освободите их — mailcow не сможет подняться. Обычные виновники: apache2, nginx, exim4, postfix."
  fi
else
  check_warn "Утилита ss недоступна, проверку портов пропускаю"
fi

# --- 6. Конфликтующее ПО ----------------------------------------------------
header "6. Конфликтующее ПО"
CONFLICTS=()
for pkg in postfix exim4 sendmail dovecot-core apache2 nginx named bind9; do
  if dpkg -l "${pkg}" 2>/dev/null | grep -q '^ii'; then
    CONFLICTS+=("${pkg}")
  fi
done
if ((${#CONFLICTS[@]} == 0)); then
  check_pass "Конфликтующих пакетов не найдено"
else
  check_fail "Установлены пакеты, занимающие порты mailcow: ${CONFLICTS[*]}. Скрипт 10-bootstrap-os.sh предложит их удалить."
fi

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  if ss -Hltn 'sport = :53' 2>/dev/null | grep -q '0.0.0.0:53\|\*:53'; then
    check_fail "systemd-resolved слушает 53 на всех интерфейсах — конфликт с unbound в mailcow. Исправит 10-bootstrap-os.sh"
  else
    check_pass "systemd-resolved не мешает (слушает только локально)"
  fi
fi

# --- 7. Исходящий порт 25 ---------------------------------------------------
header "7. Исходящий SMTP (порт 25)"
check_info "Проверяю, не блокирует ли провайдер исходящие соединения на 25 порт"
if tcp_probe "alt1.aspmx.l.google.com" 25 8; then
  check_pass "Исходящий порт 25 открыт — отправка писем возможна"
else
  check_fail "Исходящие соединения на порт 25 заблокированы. Почти все VPS-провайдеры блокируют его по умолчанию. Напишите в поддержку с просьбой разблокировать (обычно делают после подтверждения целей). Без этого сервер не сможет отправлять почту."
fi

# --- 8. Время ---------------------------------------------------------------
header "8. Синхронизация времени"
if timedatectl show 2>/dev/null | grep -q 'NTPSynchronized=yes'; then
  check_pass "Время синхронизировано по NTP"
else
  check_warn "Время не синхронизировано. Расхождение часов ломает TLS и DKIM. Исправит 10-bootstrap-os.sh"
fi

# --- 9. Виртуализация -------------------------------------------------------
header "9. Окружение"
VIRT="$(systemd-detect-virt 2>/dev/null || echo unknown)"
check_info "Тип виртуализации: ${VIRT}"
case "${VIRT}" in
  openvz|lxc|lxc-libvirt)
    check_fail "Контейнерная виртуализация «${VIRT}» несовместима с Docker в mailcow. Нужен KVM или выделенный сервер."
    ;;
  kvm|qemu|vmware|xen|microsoft|amazon|none)
    check_pass "Виртуализация «${VIRT}» подходит для Docker"
    ;;
  *)
    check_warn "Неизвестный тип виртуализации «${VIRT}». Убедитесь, что это не OpenVZ/LXC."
    ;;
esac

# --- 10. Конфигурация .env --------------------------------------------------
header "10. Файл .env"
if [[ "${MAIL_HOSTNAME}" == "${MAIL_DOMAIN}" ]]; then
  check_fail "MAIL_HOSTNAME и MAIL_DOMAIN совпадают. Имя сервера должно быть поддоменом, например mail.${MAIL_DOMAIN}"
else
  check_pass "MAIL_HOSTNAME отличается от MAIL_DOMAIN"
fi

if [[ "${MAIL_HOSTNAME}" == *.*.* || "${MAIL_HOSTNAME}" == *.* ]]; then
  check_pass "MAIL_HOSTNAME выглядит как FQDN"
else
  check_fail "MAIL_HOSTNAME «${MAIL_HOSTNAME}» не похож на полное доменное имя"
fi

if [[ "${MAIL_DOMAIN}" == "example.com" || "${MAIL_HOSTNAME}" == "mail.example.com" ]]; then
  check_fail "В .env остались значения-заглушки example.com. Укажите свой домен."
fi

if [[ "${SSH_DISABLE_ROOT:-no}" == "yes" ]]; then
  SSH_USER="${SSH_ALLOW_USER:-}"
  if [[ -z "${SSH_USER}" ]]; then
    check_fail "SSH_DISABLE_ROOT=yes, но SSH_ALLOW_USER не задан. Вы потеряете доступ к серверу."
  elif ! id "${SSH_USER}" >/dev/null 2>&1; then
    check_fail "SSH_DISABLE_ROOT=yes, но пользователь «${SSH_USER}» не существует. Создайте его и положите SSH-ключ."
  elif [[ ! -s "/home/${SSH_USER}/.ssh/authorized_keys" ]]; then
    check_fail "У пользователя «${SSH_USER}» пустой authorized_keys. Добавьте публичный ключ до запуска security/10-harden-ssh.sh"
  else
    check_pass "Пользователь «${SSH_USER}» существует и имеет SSH-ключ"
  fi
fi

# --- Итог -------------------------------------------------------------------
if summary; then
  ok "Сервер готов. Следующий шаг: sudo ./deploy/10-bootstrap-os.sh"
  mark_step_done "00-preflight"
  exit 0
else
  err "Устраните провалы выше и запустите проверку повторно. Продолжать установку нельзя."
  exit 1
fi
