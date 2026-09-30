#!/usr/bin/env bash
# =============================================================================
# 50-setup-backup.sh — настройка автоматического резервного копирования.
# Использует штатный helper-скрипт mailcow (helper-scripts/backup_and_restore.sh)
# и оборачивает его в systemd-таймер с ротацией старых копий.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "setup-backup"
require_root
load_env

MCDIR="$(mailcow_dir)"
BKDIR="${BACKUP_DIR:-/var/backups/mailcow}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
SCHEDULE="${BACKUP_SCHEDULE:-03:30}"
WRAPPER=/usr/local/sbin/mailcow-backup

header "Настройка резервного копирования"

[[ -d "${MCDIR}" ]] || die "mailcow не установлен в ${MCDIR}"
HELPER="${MCDIR}/helper-scripts/backup_and_restore.sh"
[[ -x "${HELPER}" ]] || die "Не найден ${HELPER}. Проверьте установку mailcow."

# --- 1. Каталог для бэкапов -------------------------------------------------
header "1. Каталог назначения"
mkdir -p "${BKDIR}"
chmod 0700 "${BKDIR}"
ok "Каталог ${BKDIR} создан, доступ только для root"

# Предупреждение, если бэкапы лежат на том же диске, что и данные.
BK_DEV="$(df --output=source "${BKDIR}" 2>/dev/null | tail -n1)"
MC_DEV="$(df --output=source "${MCDIR}" 2>/dev/null | tail -n1)"
if [[ "${BK_DEV}" == "${MC_DEV}" ]]; then
  warn "Бэкапы хранятся на том же диске (${BK_DEV}), что и данные."
  warn "При отказе диска вы потеряете и почту, и резервные копии."
  warn "Настройте копирование на внешнее хранилище — см. docs/ADMIN.md, раздел о бэкапах."
fi

DISK_FREE_GB=$(df -BG --output=avail "${BKDIR}" 2>/dev/null | tail -n1 | tr -dc '0-9')
info "Свободно в ${BKDIR}: ${DISK_FREE_GB} ГБ"
if ((DISK_FREE_GB < 20)); then
  warn "Менее 20 ГБ свободно. Каждый полный бэкап занимает примерно столько же, сколько данные."
fi

# --- 2. Скрипт-обёртка ------------------------------------------------------
header "2. Скрипт резервного копирования"
cat >"${WRAPPER}" <<WRAPPER_EOF
#!/usr/bin/env bash
# Автоматически создан deploy/50-setup-backup.sh
# Резервное копирование mailcow с ротацией.
set -Eeuo pipefail

MCDIR="${MCDIR}"
BKDIR="${BKDIR}"
KEEP_DAYS="${KEEP_DAYS}"
LOGFILE="/var/log/mailstack/backup-\$(date '+%Y%m%d-%H%M%S').log"

mkdir -p /var/log/mailstack "\${BKDIR}"

log() { printf '%s %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$*" | tee -a "\${LOGFILE}"; }

log "=== Начало резервного копирования ==="

FREE_MB=\$(df -BM --output=avail "\${BKDIR}" | tail -n1 | tr -dc '0-9')
if (( FREE_MB < 5120 )); then
  log "ОШИБКА: менее 5 ГБ свободно в \${BKDIR} (\${FREE_MB} МБ). Копирование отменено."
  exit 1
fi

cd "\${MCDIR}"

# Компоненты: база данных, почтовые ящики, конфигурация Rspamd, Redis, crypt-ключи.
if MAILCOW_BACKUP_LOCATION="\${BKDIR}" ./helper-scripts/backup_and_restore.sh backup all --delete-days "\${KEEP_DAYS}" >>"\${LOGFILE}" 2>&1; then
  log "Резервная копия создана успешно"
else
  RC=\$?
  log "ОШИБКА: backup_and_restore.sh завершился с кодом \${RC}"
  log "Подробности в \${LOGFILE}"
  exit "\${RC}"
fi

# Копия конфигурации mailcow и .env комплекта — они не входят в штатный бэкап.
CONF_BK="\${BKDIR}/configs-\$(date '+%Y%m%d-%H%M%S').tar.gz"
tar czf "\${CONF_BK}" \\
  -C "\${MCDIR}" mailcow.conf \\
  \$( [[ -d "\${MCDIR}/data/conf" ]] && printf '%s' "data/conf" ) \\
  2>/dev/null || true
chmod 600 "\${CONF_BK}" 2>/dev/null || true
log "Конфигурация сохранена: \${CONF_BK}"

# Ротация архивов конфигурации.
find "\${BKDIR}" -maxdepth 1 -name 'configs-*.tar.gz' -mtime "+\${KEEP_DAYS}" -delete 2>/dev/null || true

# Ротация журналов бэкапа.
find /var/log/mailstack -maxdepth 1 -name 'backup-*.log' -mtime +30 -delete 2>/dev/null || true

TOTAL_SIZE=\$(du -sh "\${BKDIR}" 2>/dev/null | cut -f1)
log "Общий размер бэкапов: \${TOTAL_SIZE}"
log "=== Резервное копирование завершено ==="
WRAPPER_EOF

chmod 0700 "${WRAPPER}"
ok "Создан ${WRAPPER}"

# --- 3. systemd-служба и таймер --------------------------------------------
header "3. Таймер systemd"
cat >/etc/systemd/system/mailcow-backup.service <<EOF
[Unit]
Description=Резервное копирование mailcow
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${WRAPPER}
# Бэкап не должен мешать работе сервера.
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=7200
EOF

cat >/etc/systemd/system/mailcow-backup.timer <<EOF
[Unit]
Description=Ежедневное резервное копирование mailcow в ${SCHEDULE}

[Timer]
OnCalendar=*-*-* ${SCHEDULE}:00
# Догнать пропущенный запуск, если сервер был выключен.
Persistent=true
# Случайная задержка, чтобы не совпадать с другими задачами.
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now mailcow-backup.timer >/dev/null 2>&1
ok "Таймер включён: ежедневно в ${SCHEDULE}, хранение ${KEEP_DAYS} дней"

NEXT_RUN="$(systemctl list-timers mailcow-backup.timer --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2, $3}' || true)"
[[ -n "${NEXT_RUN}" ]] && info "Следующий запуск: ${NEXT_RUN}"

# --- 4. Тестовый прогон -----------------------------------------------------
header "4. Проверка"
if confirm "Выполнить тестовое резервное копирование сейчас? (займёт несколько минут)"; then
  info "Запускаю ${WRAPPER}"
  if "${WRAPPER}"; then
    ok "Тестовое копирование прошло успешно"
    info "Содержимое ${BKDIR}:"
    ls -lh "${BKDIR}" 2>/dev/null | tail -n 10 | sed 's/^/    /'
  else
    err "Тестовое копирование завершилось с ошибкой. Смотрите журнал в /var/log/mailstack/"
    exit 1
  fi
else
  info "Тест пропущен. Запустить вручную: sudo ${WRAPPER}"
fi

# --- Итог -------------------------------------------------------------------
header "Готово"
mark_step_done "50-setup-backup"
ok "Резервное копирование настроено."
printf '\n'
info "Управление:"
info "  Запуск вручную      : sudo ${WRAPPER}"
info "  Статус таймера      : systemctl status mailcow-backup.timer"
info "  Журнал последнего   : ls -t /var/log/mailstack/backup-*.log | head -1"
info "  Восстановление      : sudo ./tools/restore.sh"
printf '\n'
warn "Проверьте восстановление из бэкапа хотя бы один раз. Непроверенный бэкап — это не бэкап."
