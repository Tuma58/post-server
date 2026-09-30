#!/usr/bin/env bash
# =============================================================================
# 00-harden-all.sh — запускает все скрипты безопасности по порядку.
#
# Порядок важен: firewall открывает порт SSH до того, как sshd на него перейдёт.
# =============================================================================
set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SELF_DIR}/../lib/common.sh"

log_init "harden-all"
require_root
load_env

header "Применение настроек безопасности"
printf '\n'
info "Будут выполнены шаги:"
info "  1. Межсетевой экран (ufw + правила Docker)"
info "  2. Защита SSH"
info "  3. fail2ban для SSH"
info "  4. Параметры ядра"
info "  5. Автоматические обновления"
printf '\n'
warn "ВАЖНО: откройте второе SSH-подключение к серверу до продолжения."
warn "Настройка SSH может ограничить доступ при ошибке в конфигурации."
printf '\n'

if ! confirm "Начать применение настроек безопасности?"; then
  info "Отменено."
  exit 0
fi

# Порядок: сначала firewall (откроет порт), потом sshd (перейдёт на него).
STEPS=(
  "20-firewall.sh"
  "10-harden-ssh.sh"
  "30-fail2ban.sh"
  "40-sysctl.sh"
  "50-auto-updates.sh"
)

FAILED_STEPS=()

for step in "${STEPS[@]}"; do
  SCRIPT="${SELF_DIR}/${step}"
  if [[ ! -x "${SCRIPT}" ]]; then
    if [[ -f "${SCRIPT}" ]]; then
      chmod +x "${SCRIPT}"
    else
      err "Скрипт ${step} не найден, пропускаю"
      FAILED_STEPS+=("${step} (не найден)")
      continue
    fi
  fi

  printf '\n'
  header "▶ ${step}"
  if "${SCRIPT}"; then
    ok "${step} выполнен"
  else
    RC=$?
    err "${step} завершился с кодом ${RC}"
    FAILED_STEPS+=("${step} (код ${RC})")

    # Сбой в настройке SSH или firewall критичен — останавливаемся.
    if [[ "${step}" == "10-harden-ssh.sh" || "${step}" == "20-firewall.sh" ]]; then
      err "Это критический шаг. Останавливаю выполнение, чтобы не потерять доступ."
      err "Проверьте доступ по SSH из другого окна и устраните проблему."
      exit "${RC}"
    fi
    info "Продолжаю со следующего шага."
  fi
done

# --- Итог -------------------------------------------------------------------
printf '\n'
header "Итог"
if ((${#FAILED_STEPS[@]} == 0)); then
  mark_step_done "00-harden-all"
  ok "Все настройки безопасности применены."
  printf '\n'
  warn "ПРОВЕРЬТЕ ДОСТУП ПО SSH ПРЯМО СЕЙЧАС, не закрывая текущую сессию:"
  info "    ssh -p ${SSH_PORT:-22} ${SSH_ALLOW_USER:-root}@$(detect_public_ip4)"
  printf '\n'
  info "Следующий шаг: sudo ./checks/00-full-check.sh"
else
  err "Часть шагов завершилась с ошибками:"
  for f in "${FAILED_STEPS[@]}"; do
    printf '    - %s\n' "${f}"
  done
  printf '\n'
  info "Запустите проблемные скрипты по отдельности для диагностики."
  exit 1
fi
