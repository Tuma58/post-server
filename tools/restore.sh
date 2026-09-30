#!/usr/bin/env bash
# =============================================================================
# restore.sh — восстановление из резервной копии.
#
# ОПАСНАЯ ОПЕРАЦИЯ: перезаписывает текущие данные почтового сервера.
# Требует явного подтверждения на каждом шаге.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "restore"
require_root
load_env

MCDIR="$(mailcow_dir)"
BKDIR="${BACKUP_DIR:-/var/backups/mailcow}"
HELPER="${MCDIR}/helper-scripts/backup_and_restore.sh"

header "Восстановление из резервной копии"

[[ -d "${MCDIR}" ]] || die "mailcow не установлен в ${MCDIR}"
[[ -x "${HELPER}" ]] || die "Не найден ${HELPER}"
[[ -d "${BKDIR}" ]] || die "Каталог резервных копий ${BKDIR} не существует"

printf '\n'
warn "═══════════════════════════════════════════════════════════════════"
warn " ВНИМАНИЕ: восстановление ПЕРЕЗАПИШЕТ текущие данные сервера."
warn " Все письма, полученные после создания выбранной копии, будут"
warn " потеряны, если их нет в этой копии."
warn "═══════════════════════════════════════════════════════════════════"
printf '\n'

# --- 1. Список доступных копий ---------------------------------------------
header "1. Доступные резервные копии"
mapfile -t BACKUPS < <(find "${BKDIR}" -maxdepth 1 -type d -name 'mailcow-*' -printf '%T@|%p\n' 2>/dev/null | sort -rn | cut -d'|' -f2)

if ((${#BACKUPS[@]} == 0)); then
  die "Резервных копий в ${BKDIR} не найдено."
fi

info "Найдено копий: ${#BACKUPS[@]}"
printf '\n'
for i in "${!BACKUPS[@]}"; do
  B="${BACKUPS[$i]}"
  BDATE="$(stat -c '%y' "${B}" 2>/dev/null | cut -d. -f1)"
  BSIZE="$(du -sh "${B}" 2>/dev/null | cut -f1)"
  # Что входит в копию.
  COMPONENTS=""
  [[ -f "${B}/backup_mysql.gz" || -f "${B}/mysql.gz" ]] && COMPONENTS="${COMPONENTS} база"
  ls "${B}"/backup_vmail* >/dev/null 2>&1 && COMPONENTS="${COMPONENTS} письма"
  ls "${B}"/backup_rspamd* >/dev/null 2>&1 && COMPONENTS="${COMPONENTS} rspamd"
  ls "${B}"/backup_redis* >/dev/null 2>&1 && COMPONENTS="${COMPONENTS} redis"
  ls "${B}"/backup_crypt* >/dev/null 2>&1 && COMPONENTS="${COMPONENTS} ключи"

  printf '  %s[%d]%s %s\n' "${C_BOLD}" "$((i + 1))" "${C_RESET}" "$(basename "${B}")"
  printf '      Дата   : %s\n' "${BDATE}"
  printf '      Размер : %s\n' "${BSIZE}"
  printf '      Состав :%s\n' "${COMPONENTS:- неизвестно}"
  printf '\n'
done

# --- 2. Выбор копии ---------------------------------------------------------
if [[ -n "${ASSUME_YES:-}" ]]; then
  die "Восстановление не поддерживает автоматический режим. Запустите без ASSUME_YES."
fi

read -r -p "Номер копии для восстановления (1-${#BACKUPS[@]}, Enter для отмены): " CHOICE
[[ -n "${CHOICE}" ]] || { info "Отменено."; exit 0; }
[[ "${CHOICE}" =~ ^[0-9]+$ ]] || die "Введите число."
((CHOICE >= 1 && CHOICE <= ${#BACKUPS[@]})) || die "Номер вне диапазона."

SELECTED="${BACKUPS[$((CHOICE - 1))]}"
info "Выбрана копия: $(basename "${SELECTED}")"

# --- 3. Страховочная копия текущего состояния ------------------------------
header "2. Страховочная копия текущего состояния"
warn "Перед восстановлением настоятельно рекомендуется сделать копию текущих данных."
if confirm "Создать страховочную копию сейчас? (рекомендуется)"; then
  if [[ -x /usr/local/sbin/mailcow-backup ]]; then
    info "Запускаю резервное копирование"
    /usr/local/sbin/mailcow-backup || warn "Страховочная копия завершилась с ошибкой"
    ok "Страховочная копия создана"
  else
    warn "Скрипт /usr/local/sbin/mailcow-backup не найден, пропускаю"
  fi
else
  warn "Продолжаю без страховочной копии. Откат будет невозможен."
fi

# --- 4. Подтверждение -------------------------------------------------------
header "3. Подтверждение"
printf '\n'
warn "Будет восстановлена копия от: $(stat -c '%y' "${SELECTED}" | cut -d. -f1)"
warn "Текущие данные будут ПЕРЕЗАПИСАНЫ."
printf '\n'
read -r -p "Для подтверждения введите слово ВОССТАНОВИТЬ: " CONFIRM_WORD
if [[ "${CONFIRM_WORD}" != "ВОССТАНОВИТЬ" ]]; then
  info "Отменено (подтверждение не получено)."
  exit 0
fi

# --- 5. Восстановление ------------------------------------------------------
header "4. Восстановление"
info "Запускаю штатный helper mailcow. Он спросит, какие компоненты восстанавливать."
printf '\n'

cd "${MCDIR}"
if MAILCOW_BACKUP_LOCATION="${BKDIR}" "${HELPER}" restore; then
  ok "Восстановление завершено"
else
  RC=$?
  err "Восстановление завершилось с кодом ${RC}"
  err "Проверьте состояние: cd ${MCDIR} && docker compose ps"
  exit "${RC}"
fi

# --- 6. Перезапуск и проверка ----------------------------------------------
header "5. Перезапуск стека"
info "Перезапускаю контейнеры"
docker compose down
sleep 3
docker compose up -d
ok "Контейнеры запущены"

info "Ожидаю готовности веб-интерфейса (до 3 минут)"
for _ in {1..18}; do
  if curl -k -fsS --max-time 5 "https://127.0.0.1:${HTTPS_PORT:-443}/" -o /dev/null 2>/dev/null; then
    ok "Веб-интерфейс отвечает"
    break
  fi
  sleep 10
done

# --- Итог -------------------------------------------------------------------
header "Готово"
ok "Восстановление выполнено."
printf '\n'
info "Обязательно проверьте:"
info "  1. sudo ./checks/00-full-check.sh"
info "  2. Вход в веб-панель: https://${MAIL_HOSTNAME}/"
info "  3. Наличие писем в ящиках через веб-почту"
info "  4. Отправку и получение тестового письма"
printf '\n'
warn "Если DKIM-ключи восстановлены из копии, сверьте TXT-запись в DNS:"
warn "    sudo ./checks/20-check-dns.sh"
