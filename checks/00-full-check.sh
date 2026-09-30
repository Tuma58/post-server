#!/usr/bin/env bash
# =============================================================================
# 00-full-check.sh — полная проверка после установки.
# Запускает все проверки по очереди и выводит сводный отчёт.
#
# Ничего не меняет в системе. Можно запускать регулярно.
# =============================================================================
set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SELF_DIR}/../lib/common.sh"

log_init "full-check"
load_env
require_vars MAIL_DOMAIN MAIL_HOSTNAME

REPORT_FILE="${LOG_DIR}/full-check-$(date '+%Y%m%d-%H%M%S').txt"
mkdir -p "${LOG_DIR}" 2>/dev/null || REPORT_FILE="/tmp/full-check-$(date '+%Y%m%d-%H%M%S').txt"

printf '%s\n' "${C_BOLD}"
cat <<EOF
===============================================================================
 ПОЛНАЯ ПРОВЕРКА ПОЧТОВОГО СЕРВЕРА
===============================================================================
 Домен       : ${MAIL_DOMAIN}
 Сервер      : ${MAIL_HOSTNAME}
 IP          : $(detect_public_ip4)
 Дата        : $(date '+%Y-%m-%d %H:%M:%S %Z')
 Отчёт       : ${REPORT_FILE}
===============================================================================
EOF
printf '%s\n' "${C_RESET}"

CHECKS=(
  "10-check-services.sh:Службы и контейнеры"
  "20-check-dns.sh:DNS-записи"
  "30-check-mailflow.sh:Почтовый поток и TLS"
  "40-check-security.sh:Безопасность"
)

declare -A RESULTS
TOTAL_FAILED=0

for entry in "${CHECKS[@]}"; do
  script="${entry%%:*}"
  title="${entry##*:}"
  path="${SELF_DIR}/${script}"

  printf '\n%s' "${C_BOLD}"
  printf '###############################################################################\n'
  printf '# %s\n' "${title}"
  printf '###############################################################################'
  printf '%s\n' "${C_RESET}"

  if [[ ! -f "${path}" ]]; then
    err "Скрипт ${script} не найден"
    RESULTS["${title}"]="НЕ НАЙДЕН"
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
    continue
  fi

  [[ -x "${path}" ]] || chmod +x "${path}"

  # Выполняем в подпроцессе, чтобы счётчики не смешивались.
  # Вывод дублируем в файл отчёта.
  if "${path}" 2>&1 | tee -a "${REPORT_FILE}"; then
    RESULTS["${title}"]="ПРОЙДЕНО"
  else
    RESULTS["${title}"]="ЕСТЬ ПРОБЛЕМЫ"
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
  fi
done

# --- Сводный отчёт ----------------------------------------------------------
printf '\n%s' "${C_BOLD}"
cat <<'EOF'
===============================================================================
 СВОДНЫЙ ОТЧЁТ
===============================================================================
EOF
printf '%s' "${C_RESET}"

for entry in "${CHECKS[@]}"; do
  title="${entry##*:}"
  status="${RESULTS[$title]:-?}"
  case "${status}" in
    "ПРОЙДЕНО")     printf '  %s✔%s %-32s %s\n' "${C_GREEN}" "${C_RESET}" "${title}" "${status}" ;;
    "ЕСТЬ ПРОБЛЕМЫ") printf '  %s✘%s %-32s %s\n' "${C_RED}" "${C_RESET}" "${title}" "${status}" ;;
    *)              printf '  %s!%s %-32s %s\n' "${C_YELLOW}" "${C_RESET}" "${title}" "${status}" ;;
  esac
done

printf '\n'
if ((TOTAL_FAILED == 0)); then
  printf '%s  Все проверки пройдены. Сервер готов к работе.%s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}"
  printf '\n'
  info "Что проверить дополнительно вручную:"
  info "  1. Отправьте письмо на https://www.mail-tester.com/ — цель 10/10"
  info "  2. Отправьте письмо с Gmail на ${FIRST_MAILBOX_LOCAL:-admin}@${MAIL_DOMAIN} и убедитесь, что оно дошло"
  info "  3. Ответьте на него и проверьте, что ответ не попал в спам"
  info "  4. Проверьте вход в веб-почту: https://${MAIL_HOSTNAME}/SOGo/"
  info "  5. Настройте почтовый клиент по инструкции docs/USER.md"
  printf '\n'
  info "Отчёт сохранён: ${REPORT_FILE}"
  exit 0
else
  printf '%s  Обнаружены проблемы в %d из %d блоков проверки.%s\n' "${C_RED}${C_BOLD}" "${TOTAL_FAILED}" "${#CHECKS[@]}" "${C_RESET}"
  printf '\n'
  info "Разберите провалы по порядку:"
  info "  - строки, помеченные ✘, содержат описание проблемы и способ исправления"
  info "  - типовые сценарии восстановления описаны в docs/RUNBOOK.md"
  printf '\n'
  info "Полный отчёт: ${REPORT_FILE}"
  exit 1
fi
