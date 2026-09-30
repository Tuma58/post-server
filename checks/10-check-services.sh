#!/usr/bin/env bash
# =============================================================================
# 10-check-services.sh — проверка состояния контейнеров и служб.
# Только чтение, ничего не меняет.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "check-services"
load_env

MCDIR="$(mailcow_dir)"

header "Проверка служб и контейнеров"

# --- 1. Системные службы ----------------------------------------------------
header "1. Системные службы"
for svc in docker ufw fail2ban chrony; do
  if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 && \
     systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "${svc}.service"; then
    if systemctl is-active --quiet "${svc}"; then
      if systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
        check_pass "Служба ${svc}: работает, в автозапуске"
      else
        check_warn "Служба ${svc}: работает, но НЕ в автозапуске (systemctl enable ${svc})"
      fi
    else
      if [[ "${svc}" == "chrony" ]] && systemctl is-active --quiet chronyd 2>/dev/null; then
        check_pass "Служба chronyd: работает"
      else
        check_fail "Служба ${svc} остановлена (systemctl start ${svc})"
      fi
    fi
  else
    check_info "Служба ${svc} не установлена"
  fi
done

# Таймеры.
for timer in mailcow-backup.timer apt-daily-upgrade.timer; do
  if systemctl list-unit-files "${timer}" 2>/dev/null | grep -q "${timer}"; then
    if systemctl is-active --quiet "${timer}"; then
      NEXT="$(systemctl list-timers "${timer}" --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2, $3, $4}' || echo '?')"
      check_pass "Таймер ${timer}: активен (следующий запуск ${NEXT})"
    else
      check_warn "Таймер ${timer} не активен"
    fi
  else
    check_info "Таймер ${timer} не настроен"
  fi
done

# --- 2. Docker --------------------------------------------------------------
header "2. Docker"
if ! have_cmd docker; then
  check_fail "Docker не установлен"
  summary || true
  exit 1
fi

if docker info >/dev/null 2>&1; then
  DOCKER_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
  check_pass "Docker ${DOCKER_VER} отвечает"
else
  check_fail "Docker не отвечает на запросы (проверьте systemctl status docker)"
  summary || true
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  check_pass "Плагин compose: $(docker compose version --short 2>/dev/null || echo '?')"
else
  check_fail "Плагин docker compose недоступен"
fi

# Ротация логов Docker: без неё диск заполняется.
if [[ -f /etc/docker/daemon.json ]] && grep -q 'max-size' /etc/docker/daemon.json 2>/dev/null; then
  check_pass "Ротация логов Docker настроена"
else
  check_warn "Ротация логов Docker не настроена — журналы контейнеров будут расти без ограничений"
fi

# --- 3. Контейнеры mailcow --------------------------------------------------
header "3. Контейнеры mailcow"
if [[ ! -d "${MCDIR}" ]]; then
  check_fail "Каталог mailcow ${MCDIR} не найден"
  summary || true
  exit 1
fi

cd "${MCDIR}"

# Ожидаемые контейнеры. Некоторые отсутствуют при SKIP_*=y — это не ошибка.
EXPECTED_CORE=(
  "postfix-mailcow:приём и отправка почты"
  "dovecot-mailcow:хранение и доступ IMAP"
  "nginx-mailcow:веб-сервер"
  "mysql-mailcow:база данных"
  "redis-mailcow:кэш и очереди"
  "rspamd-mailcow:антиспам"
  "php-fpm-mailcow:веб-приложение"
  "acme-mailcow:сертификаты Let's Encrypt"
  "netfilter-mailcow:защита от перебора паролей"
  "unbound-mailcow:DNS-резолвер"
  "sogo-mailcow:веб-почта"
  "dockerapi-mailcow:управление контейнерами"
  "watchdog-mailcow:контроль состояния служб"
  "memcached-mailcow:кэш"
  "olefy-mailcow:анализ вложений Office"
)

PS_OUT="$(docker compose ps --format '{{.Name}}|{{.State}}|{{.Status}}' 2>/dev/null || true)"
if [[ -z "${PS_OUT}" ]]; then
  check_fail "docker compose ps не вернул контейнеров. Стек не запущен: cd ${MCDIR} && docker compose up -d"
  summary || true
  exit 1
fi

RUNNING_COUNT=0
TOTAL_COUNT=0
while IFS='|' read -r name state status; do
  [[ -n "${name}" ]] || continue
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  if [[ "${state}" == "running" ]]; then
    RUNNING_COUNT=$((RUNNING_COUNT + 1))
    # Проверяем health, если он есть.
    if grep -qi 'unhealthy' <<<"${status}"; then
      check_fail "${name}: работает, но состояние unhealthy (${status})"
    elif grep -qi 'starting' <<<"${status}"; then
      check_warn "${name}: ещё запускается (${status})"
    else
      check_pass "${name}: ${status}"
    fi
  else
    # Некоторые контейнеры (например, ofelia) штатно завершаются.
    check_fail "${name}: не работает (состояние ${state}, ${status})"
  fi
done <<<"${PS_OUT}"

check_info "Контейнеров запущено: ${RUNNING_COUNT} из ${TOTAL_COUNT}"

# Ключевые контейнеры проверяем отдельно — без них почта не работает.
for entry in "${EXPECTED_CORE[@]}"; do
  cname="${entry%%:*}"
  cdesc="${entry##*:}"
  case "${cname}" in
    sogo-mailcow)
      [[ "$(mailcow_conf_get SKIP_SOGO 2>/dev/null || echo n)" == "y" ]] && continue ;;
    clamd-mailcow)
      [[ "$(mailcow_conf_get SKIP_CLAMD 2>/dev/null || echo n)" == "y" ]] && continue ;;
    solr-mailcow)
      continue ;;
  esac

  if ! grep -q "^${cname}|" <<<"${PS_OUT}"; then
    # Имя может иметь префикс проекта.
    if ! grep -q "${cname}" <<<"${PS_OUT}"; then
      check_fail "Отсутствует контейнер ${cname} (${cdesc})"
    fi
  fi
done

# --- 4. Слушающие порты -----------------------------------------------------
header "4. Порты"
if ! have_cmd ss; then
  check_warn "Утилита ss недоступна, проверка портов пропущена"
else
  declare -A PORT_DESC=(
    [25]="SMTP"
    [587]="Submission"
    [143]="IMAP"
    [993]="IMAPS"
    [4190]="ManageSieve"
    ["${HTTPS_PORT:-443}"]="HTTPS"
    ["${HTTP_PORT:-80}"]="HTTP"
  )
  [[ "${OPEN_PORT_465:-yes}" == "yes" ]] && PORT_DESC[465]="SMTPS"
  if [[ "${OPEN_POP3:-no}" == "yes" ]]; then
    PORT_DESC[110]="POP3"
    PORT_DESC[995]="POP3S"
  fi

  for port in $(printf '%s\n' "${!PORT_DESC[@]}" | sort -n); do
    if ss -Hltn "sport = :${port}" 2>/dev/null | grep -q LISTEN; then
      check_pass "Порт ${port} (${PORT_DESC[$port]}) слушается"
    else
      check_fail "Порт ${port} (${PORT_DESC[$port]}) НЕ слушается"
    fi
  done
fi

# --- 5. Ресурсы -------------------------------------------------------------
header "5. Использование ресурсов"

# Память.
MEM_TOTAL=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
MEM_AVAIL=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
MEM_USED_PCT=$(( (MEM_TOTAL - MEM_AVAIL) * 100 / MEM_TOTAL ))
check_info "Память: использовано ${MEM_USED_PCT}%, доступно ${MEM_AVAIL} МБ из ${MEM_TOTAL} МБ"
if ((MEM_USED_PCT >= 92)); then
  check_fail "Память почти исчерпана (${MEM_USED_PCT}%) — возможны падения контейнеров от OOM"
elif ((MEM_USED_PCT >= 85)); then
  check_warn "Высокое использование памяти (${MEM_USED_PCT}%)"
else
  check_pass "Памяти достаточно (использовано ${MEM_USED_PCT}%)"
fi

# Swap.
SWAP_TOTAL=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)
if ((SWAP_TOTAL > 0)); then
  SWAP_FREE=$(awk '/SwapFree/ {printf "%d", $2/1024}' /proc/meminfo)
  SWAP_USED_PCT=$(( (SWAP_TOTAL - SWAP_FREE) * 100 / SWAP_TOTAL ))
  if ((SWAP_USED_PCT >= 70)); then
    check_warn "Swap использован на ${SWAP_USED_PCT}% — серверу не хватает оперативной памяти"
  else
    check_pass "Swap: ${SWAP_TOTAL} МБ, использовано ${SWAP_USED_PCT}%"
  fi
else
  ((MEM_TOTAL < 7800)) && check_warn "Swap отсутствует при ${MEM_TOTAL} МБ RAM — риск OOM"
fi

# Диск.
DISK_USED_PCT=$(df --output=pcent / 2>/dev/null | tail -n1 | tr -dc '0-9')
DISK_FREE_GB=$(df -BG --output=avail / 2>/dev/null | tail -n1 | tr -dc '0-9')
check_info "Диск /: использовано ${DISK_USED_PCT}%, свободно ${DISK_FREE_GB} ГБ"
if ((DISK_USED_PCT >= 90)); then
  check_fail "Диск заполнен на ${DISK_USED_PCT}% — почта перестанет приниматься"
elif ((DISK_USED_PCT >= 80)); then
  check_warn "Диск заполнен на ${DISK_USED_PCT}% — пора чистить или расширять"
else
  check_pass "Дискового пространства достаточно (${DISK_USED_PCT}%)"
fi

# Объём данных mailcow.
if [[ -d "${MCDIR}" ]]; then
  VOL_SIZE="$(docker system df --format '{{.Type}} {{.Size}}' 2>/dev/null | awk '/Local Volumes/ {print $3}' || true)"
  [[ -n "${VOL_SIZE}" ]] && check_info "Данные в volume Docker: ${VOL_SIZE}"
fi

# Средняя нагрузка.
LOAD1=$(awk '{print $1}' /proc/loadavg)
CPU_CORES=$(nproc)
LOAD_PCT=$(awk -v l="${LOAD1}" -v c="${CPU_CORES}" 'BEGIN {printf "%d", l/c*100}')
if ((LOAD_PCT >= 200)); then
  check_warn "Высокая нагрузка: LA ${LOAD1} при ${CPU_CORES} ядрах"
else
  check_pass "Нагрузка в норме: LA ${LOAD1} при ${CPU_CORES} ядрах"
fi

# --- 6. Журналы на ошибки ---------------------------------------------------
header "6. Журналы контейнеров"
# Смотрим последние строки ключевых контейнеров на явные ошибки.
for c in postfix-mailcow dovecot-mailcow mysql-mailcow rspamd-mailcow acme-mailcow; do
  if ! grep -q "${c}" <<<"${PS_OUT}"; then
    continue
  fi
  LOGS="$(docker compose logs --tail 200 --no-log-prefix "${c%%-mailcow}" 2>/dev/null || docker logs --tail 200 "${c}" 2>&1 || true)"
  [[ -n "${LOGS}" ]] || continue

  ERR_COUNT="$(printf '%s' "${LOGS}" | grep -ciE '\b(fatal|panic|emergency)\b' || true)"
  if [[ "${ERR_COUNT}" =~ ^[0-9]+$ ]] && ((ERR_COUNT > 0)); then
    check_fail "${c}: ${ERR_COUNT} критических записей в последних 200 строках журнала"
    printf '%s' "${LOGS}" | grep -iE '\b(fatal|panic|emergency)\b' | tail -n2 | sed 's/^/        /'
  else
    check_pass "${c}: критических ошибок в журнале нет"
  fi
done

# Watchdog сообщает о проблемах сервисов.
if grep -q watchdog <<<"${PS_OUT}"; then
  WD_LOGS="$(docker compose logs --tail 100 watchdog-mailcow 2>/dev/null || true)"
  WD_ERR="$(printf '%s' "${WD_LOGS}" | grep -ci 'undefined\|critical\|failed' || true)"
  if [[ "${WD_ERR}" =~ ^[0-9]+$ ]] && ((WD_ERR > 3)); then
    check_warn "watchdog сообщает о проблемах (${WD_ERR} записей). Подробнее: docker compose logs watchdog-mailcow"
  fi
fi

# --- 7. Очередь почты -------------------------------------------------------
header "7. Очередь Postfix"
if grep -q postfix <<<"${PS_OUT}"; then
  QUEUE_OUT="$(docker compose exec -T postfix-mailcow postqueue -p 2>/dev/null || true)"
  if [[ -z "${QUEUE_OUT}" ]]; then
    check_warn "Не удалось получить очередь. Проверьте вручную: docker compose exec postfix-mailcow postqueue -p"
  elif grep -q 'Mail queue is empty' <<<"${QUEUE_OUT}"; then
    check_pass "Очередь отправки пуста"
  else
    Q_COUNT="$(printf '%s' "${QUEUE_OUT}" | grep -cE '^[0-9A-F]{10,}' || echo 0)"
    if ((Q_COUNT > 50)); then
      check_fail "В очереди ${Q_COUNT} писем — есть проблемы с доставкой"
    elif ((Q_COUNT > 5)); then
      check_warn "В очереди ${Q_COUNT} писем. Обычно это временные сбои у получателей."
    else
      check_pass "В очереди ${Q_COUNT} писем (норма)"
    fi
    printf '%s' "${QUEUE_OUT}" | tail -n 5 | sed 's/^/        /'
  fi
fi

# --- Итог -------------------------------------------------------------------
# summary возвращает 1 при наличии провалов. Снимаем ERR-trap, чтобы не
# печатать лишнее сообщение о сбое, и выходим с корректным кодом.
trap - ERR
summary || exit 1
