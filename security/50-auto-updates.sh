#!/usr/bin/env bash
# =============================================================================
# 50-auto-updates.sh — настройка автоматических обновлений безопасности.
#
# ВАЖНО: Docker-образы mailcow обновляет отдельный скрипт tools/update-mailcow.sh
# Здесь настраивается только хостовая ОС.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "auto-updates"
require_root
require_cmd apt-get dpkg
load_env

header "Автоматические обновления безопасности"

# --- 1. Установка пакетов ---------------------------------------------------
header "1. Установка пакетов"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq unattended-upgrades apt-listchanges >/dev/null
ok "Пакеты unattended-upgrades и apt-listchanges установлены"

# --- 2. Конфигурация unattended-upgrades -----------------------------------
header "2. Настройка автообновлений"
CONF_FILE=/etc/apt/apt.conf.d/50unattended-upgrades
backup_file "${CONF_FILE}"

cat >"${CONF_FILE}" <<EOF
// =============================================================================
// Автоматические обновления безопасности. Создано security/50-auto-updates.sh
// =============================================================================

// Репозитории, из которых устанавливать обновления автоматически.
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    // Раскомментируйте следующую строку для автоустановки всех обновлений.
    // "\${distro_id}:\${distro_codename}-updates";
};

// Список пакетов, которые НЕ обновлять автоматически.
// Docker и ядро обновляем вручную, чтобы контролировать перезагрузку.
Unattended-Upgrade::Package-Blacklist {
    "linux-image-*";
    "linux-headers-*";
    "linux-modules-*";
    "docker-ce";
    "docker-ce-cli";
    "containerd.io";
};

// Автоматически удалять ненужные зависимости.
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Автоматически удалять старые ядра (оставляет только текущее и предыдущее).
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

// Перезагружать автоматически, если требуется (например, новое ядро).
// ОСТОРОЖНО: включайте только на серверах с мониторингом доступности.
Unattended-Upgrade::Automatic-Reboot "false";

// Если авто-перезагрузка включена, делать это в заданное время.
// Unattended-Upgrade::Automatic-Reboot-Time "03:00";

// Перезагружать только если нет активных пользователей.
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";

// Отправлять отчёты на почту при ошибках (требуется рабочая локальная почта).
// После запуска mailcow раскомментируйте:
// Unattended-Upgrade::Mail "${ADMIN_EMAIL}";
// Unattended-Upgrade::MailReport "only-on-error";

// Минимальный уровень подробности логов: 0 (тихо), 1 (нормально), 2 (подробно).
Unattended-Upgrade::Verbose "0";

// Журналирование в syslog.
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";

// Сохранять dpkg-журнал с установленными обновлениями.
Unattended-Upgrade::Keep-Debs-After-Install "false";
EOF

chmod 0644 "${CONF_FILE}"
ok "Конфигурация ${CONF_FILE}"

# --- 3. Включение автоматического запуска -----------------------------------
header "3. Периодичность проверки"
PERIODIC_FILE=/etc/apt/apt.conf.d/20auto-upgrades
cat >"${PERIODIC_FILE}" <<EOF
// Частота обновления списков пакетов (ежедневно).
APT::Periodic::Update-Package-Lists "1";

// Частота автоматической установки обновлений (ежедневно).
APT::Periodic::Unattended-Upgrade "1";

// Частота очистки кэша загруженных пакетов (раз в неделю).
APT::Periodic::AutocleanInterval "7";

// Частота скачивания upgradeable-пакетов без установки (ежедневно).
APT::Periodic::Download-Upgradeable-Packages "1";
EOF

chmod 0644 "${PERIODIC_FILE}"
ok "Автообновления включены (проверка и установка ежедневно)"

# --- 4. Сухой прогон --------------------------------------------------------
header "4. Проверка"
info "Запускаю сухой прогон (проверка без установки)"
DRYRUN_OUT="$(unattended-upgrades --dry-run -d 2>&1 || true)"
if printf '%s' "${DRYRUN_OUT}" | grep -qi 'error\|fail'; then
  warn "Обнаружены ошибки в сухом прогоне:"
  printf '%s\n' "${DRYRUN_OUT}" | grep -i 'error\|fail' | sed -n '1,5p' | sed 's/^/    /' || true
  warn "Проверьте журнал: cat /var/log/unattended-upgrades/unattended-upgrades.log"
else
  ok "Сухой прогон завершён без ошибок"
fi

# Проверка таймера systemd.
if systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null; then
  ok "Таймер apt-daily-upgrade.timer активен"
  NEXT_RUN="$(systemctl list-timers apt-daily-upgrade.timer --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2, $3}' || true)"
  [[ -n "${NEXT_RUN}" ]] && info "Следующий запуск: ${NEXT_RUN}"
else
  warn "Таймер apt-daily-upgrade.timer не активен. Включение: systemctl enable apt-daily-upgrade.timer"
fi

# --- Итог -------------------------------------------------------------------
header "Готово"
mark_step_done "50-auto-updates"
ok "Автоматические обновления безопасности настроены."
printf '\n'
info "Что обновляется автоматически:"
info "  - пакеты из репозитория *-security (критические патчи)"
info "  - НЕ обновляется: ядро Linux, Docker (чтобы контролировать перезагрузки)"
printf '\n'
info "Управление:"
info "  Запуск вручную     : unattended-upgrades --dry-run  или без --dry-run"
info "  Журнал обновлений  : cat /var/log/unattended-upgrades/unattended-upgrades.log"
info "  История dpkg       : cat /var/log/apt/history.log"
info "  Статус таймера     : systemctl status apt-daily-upgrade.timer"
printf '\n'
warn "Автоперезагрузка ОТКЛЮЧЕНА. Если обновление требует перезагрузки, файл /var/run/reboot-required появится."
info "Проверка необходимости перезагрузки: [[ -f /var/run/reboot-required ]] && cat /var/run/reboot-required.pkgs"
printf '\n'
info "Обновление mailcow: sudo ./tools/update-mailcow.sh (отдельный процесс)"
