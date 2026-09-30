#!/usr/bin/env bash
# =============================================================================
# update-mailcow.sh — безопасное обновление mailcow.
# Делает резервную копию, затем запускает штатный update.sh.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "update-mailcow"
require_root
load_env

MCDIR="$(mailcow_dir)"
[[ -d "${MCDIR}" ]] || die "mailcow не установлен в ${MCDIR}"
[[ -x "${MCDIR}/update.sh" ]] || die "Не найден ${MCDIR}/update.sh"

header "Обновление mailcow"

# --- 1. Проверка наличия обновлений -----------------------------------------
header "1. Проверка обновлений"
cd "${MCDIR}"

CURRENT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
info "Текущая версия: ${CURRENT_COMMIT}"

git fetch --quiet origin 2>/dev/null || warn "Не удалось получить информацию с origin"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo master)"
BEHIND="$(git rev-list --count "HEAD..origin/${BRANCH}" 2>/dev/null || echo 0)"

if [[ "${BEHIND}" == "0" ]]; then
  ok "Установлена последняя версия ветки ${BRANCH}"
  if ! confirm "Обновлений нет. Всё равно запустить update.sh (пересоберёт образы)?"; then
    info "Отменено."
    exit 0
  fi
else
  info "Доступно новых коммитов: ${BEHIND}"
  printf '\n'
  info "Список изменений:"
  git log --oneline --no-decorate "HEAD..origin/${BRANCH}" 2>/dev/null | head -n 20 | sed 's/^/    /' || true
  printf '\n'
fi

# --- 2. Предупреждение о простое --------------------------------------------
header "2. Простой сервиса"
warn "Во время обновления почта будет недоступна: обычно 2-10 минут."
warn "Входящие письма не потеряются — отправляющие серверы повторят доставку."
printf '\n'

# --- 3. Резервная копия -----------------------------------------------------
header "3. Резервная копия перед обновлением"
if [[ -x /usr/local/sbin/mailcow-backup ]]; then
  if confirm "Создать резервную копию перед обновлением? (настоятельно рекомендуется)"; then
    info "Создаю копию"
    if /usr/local/sbin/mailcow-backup; then
      ok "Резервная копия создана"
    else
      err "Резервное копирование не удалось."
      confirm "Продолжить обновление БЕЗ резервной копии?" || die "Отменено."
    fi
  else
    warn "Обновление без резервной копии. При проблемах откат будет затруднён."
  fi
else
  warn "Скрипт резервного копирования не настроен (deploy/50-setup-backup.sh)"
  confirm "Продолжить без резервной копии?" || die "Отменено."
fi

# --- 4. Обновление ----------------------------------------------------------
header "4. Запуск обновления"
if ! confirm "Начать обновление mailcow?"; then
  info "Отменено."
  exit 0
fi

info "Запускаю ${MCDIR}/update.sh"
printf '\n'

# --force пропускает интерактивные вопросы update.sh.
if ./update.sh --force; then
  ok "Обновление завершено"
else
  RC=$?
  err "update.sh завершился с кодом ${RC}"
  err "Состояние контейнеров: cd ${MCDIR} && docker compose ps"
  err "Журналы: cd ${MCDIR} && docker compose logs --tail 100"
  printf '\n'
  info "Откат к предыдущей версии:"
  info "    cd ${MCDIR} && git checkout ${CURRENT_COMMIT} && docker compose up -d"
  exit "${RC}"
fi

NEW_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
info "Версия после обновления: ${NEW_COMMIT}"

# --- 5. Проверка ------------------------------------------------------------
header "5. Проверка после обновления"
info "Ожидаю готовности сервисов"
sleep 15

for _ in {1..18}; do
  if curl -k -fsS --max-time 5 "https://127.0.0.1:${HTTPS_PORT:-443}/" -o /dev/null 2>/dev/null; then
    ok "Веб-интерфейс отвечает"
    break
  fi
  sleep 10
done

STOPPED="$(docker compose ps --format '{{.Name}} {{.State}}' 2>/dev/null | awk '$2!="running" {print $1}' || true)"
if [[ -n "${STOPPED}" ]]; then
  warn "Не запущены контейнеры:"
  printf '%s\n' "${STOPPED}" | sed 's/^/    /'
  info "Диагностика: docker compose logs <имя контейнера>"
else
  ok "Все контейнеры работают"
fi

# --- 6. Очистка -------------------------------------------------------------
header "6. Очистка старых образов"
DANGLING="$(docker images -f 'dangling=true' -q 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${DANGLING}" != "0" ]]; then
  info "Найдено неиспользуемых образов: ${DANGLING}"
  if confirm "Удалить их и освободить место?"; then
    FREED="$(docker image prune -f 2>/dev/null | grep 'Total reclaimed' || echo '')"
    ok "Очистка выполнена. ${FREED}"
  fi
else
  ok "Неиспользуемых образов нет"
fi

# --- Итог -------------------------------------------------------------------
header "Готово"
ok "mailcow обновлён: ${CURRENT_COMMIT} → ${NEW_COMMIT}"
printf '\n'
info "Рекомендуется запустить полную проверку: sudo ./checks/00-full-check.sh"
