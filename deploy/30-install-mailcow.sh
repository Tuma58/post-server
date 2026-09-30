#!/usr/bin/env bash
# =============================================================================
# 30-install-mailcow.sh — установка mailcow: dockerized.
# Клонирует репозиторий, генерирует mailcow.conf по значениям из .env,
# скачивает образы и запускает стек.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "install-mailcow"
require_root
require_cmd docker git curl
load_env
require_vars MAIL_HOSTNAME MAIL_DOMAIN TZ ADMIN_EMAIL

MCDIR="$(mailcow_dir)"
BRANCH="${MAILCOW_BRANCH:-master}"

header "Установка mailcow: dockerized"
info "Каталог: ${MCDIR}"
info "Ветка:   ${BRANCH}"
info "Хост:    ${MAIL_HOSTNAME}"

if [[ "${BRANCH}" == "nightly" ]]; then
  warn "Ветка nightly предназначена для тестирования и не рекомендуется в продакшене."
  confirm "Всё равно использовать nightly?" || die "Отменено. Поставьте MAILCOW_BRANCH=master в .env"
fi

# --- 1. Проверка umask ------------------------------------------------------
# mailcow требует umask 0022, иначе права на файлах ломают контейнеры.
header "1. Проверка umask"
CUR_UMASK="$(umask)"
if [[ "${CUR_UMASK}" != "0022" && "${CUR_UMASK}" != "022" ]]; then
  warn "Текущий umask ${CUR_UMASK}, mailcow требует 0022. Устанавливаю для этой сессии."
  umask 0022
fi
ok "umask = $(umask)"

# --- 2. Клонирование --------------------------------------------------------
header "2. Получение исходников mailcow"
if [[ -d "${MCDIR}/.git" ]]; then
  ok "Репозиторий уже склонирован"
  info "Обновляю до последней версии ветки ${BRANCH}"
  ( cd "${MCDIR}" && git fetch --quiet origin && git checkout --quiet "${BRANCH}" && git pull --quiet origin "${BRANCH}" ) \
    || warn "Не удалось обновить репозиторий. Продолжаю с текущей версией."
else
  if [[ -d "${MCDIR}" ]] && [[ -n "$(ls -A "${MCDIR}" 2>/dev/null)" ]]; then
    die "Каталог ${MCDIR} существует, не пуст и не является git-репозиторием. Уберите его вручную."
  fi
  info "Клонирую https://github.com/mailcow/mailcow-dockerized"
  git clone --quiet --branch "${BRANCH}" https://github.com/mailcow/mailcow-dockerized "${MCDIR}"
  ok "Репозиторий склонирован"
fi

cd "${MCDIR}"

# --- 3. Генерация mailcow.conf ---------------------------------------------
header "3. Конфигурация mailcow.conf"
if [[ -f "${MCDIR}/mailcow.conf" ]]; then
  ok "mailcow.conf уже существует — перегенерация не нужна"
  backup_file "${MCDIR}/mailcow.conf"
else
  info "Генерирую конфигурацию для ${MAIL_HOSTNAME}"
  # generate_config.sh читает переменные окружения, если они заданы,
  # и не задаёт вопросов интерактивно.
  MAILCOW_HOSTNAME="${MAIL_HOSTNAME}" \
  MAILCOW_TZ="${TZ}" \
  MAILCOW_BRANCH="${BRANCH}" \
  ./generate_config.sh </dev/null >/dev/null 2>&1 || {
    # Если неинтерактивный режим не сработал, пробуем через подачу ответов.
    info "Повторяю генерацию с подачей ответов"
    printf '%s\n%s\n' "${MAIL_HOSTNAME}" "${TZ}" | ./generate_config.sh >/dev/null 2>&1
  }
  [[ -f "${MCDIR}/mailcow.conf" ]] || die "generate_config.sh не создал mailcow.conf. Запустите вручную: cd ${MCDIR} && ./generate_config.sh"
  ok "mailcow.conf создан"
fi

# Функция правки ключа в mailcow.conf: заменяет или добавляет.
conf_set() {
  local key="$1" val="$2" file="${MCDIR}/mailcow.conf"
  if grep -qE "^[#[:space:]]*${key}=" "${file}"; then
    # Раскомментируем и заменим значение.
    sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${val}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${val}" >>"${file}"
  fi
  log_debug "mailcow.conf: ${key}=${val}"
}

info "Применяю параметры из .env"

conf_set MAILCOW_HOSTNAME "${MAIL_HOSTNAME}"
conf_set TZ "${TZ}"

# Порты.
conf_set HTTP_PORT "${HTTP_PORT:-80}"
conf_set HTTPS_PORT "${HTTPS_PORT:-443}"
conf_set SMTP_PORT 25
conf_set SUBMISSION_PORT 587
conf_set IMAP_PORT 143
conf_set IMAPS_PORT 993
conf_set SIEVE_PORT 4190

if [[ "${OPEN_PORT_465:-yes}" == "yes" ]]; then
  conf_set SMTPS_PORT 465
fi
if [[ "${OPEN_POP3:-no}" == "yes" ]]; then
  conf_set POP_PORT 110
  conf_set POPS_PORT 995
fi

# Контакт для Let's Encrypt.
conf_set ACME_CONTACT "${ADMIN_EMAIL}"

# IPv6.
if [[ "${ENABLE_IPV6:-no}" == "yes" ]]; then
  conf_set ENABLE_IPV6 true
  ok "IPv6 включён"
else
  conf_set ENABLE_IPV6 false
  info "IPv6 отключён (ENABLE_IPV6=no в .env)"
fi

# Экономия памяти на небольших VPS: отключаем полнотекстовый поиск.
MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
if ((MEM_MB < 5800)); then
  warn "Памяти ${MEM_MB} МБ — отключаю полнотекстовый поиск (Solr/Flatcurve) для экономии ОЗУ"
  conf_set SKIP_SOLR y
  conf_set SKIP_FTS y
  info "Поиск по письмам в веб-клиенте станет медленнее, но сервер будет стабильнее"
else
  ok "Памяти достаточно, полнотекстовый поиск оставляю включённым"
fi

# Антивирус: на 20 ящиках ClamAV полезен, но требует ~1 ГБ RAM.
if ((MEM_MB < 3500)); then
  warn "Отключаю ClamAV: памяти слишком мало (${MEM_MB} МБ)"
  conf_set SKIP_CLAMD y
else
  conf_set SKIP_CLAMD n
  ok "Антивирус ClamAV включён"
fi

# Часовой пояс и прочее.
conf_set SKIP_LETS_ENCRYPT n
conf_set SKIP_IP_CHECK n

# Ограничение размера письма (в МБ) — разумное значение по умолчанию.
conf_set MAILDIR_SUB Maildir

chmod 600 "${MCDIR}/mailcow.conf"
ok "mailcow.conf настроен"

# --- 4. Загрузка образов ----------------------------------------------------
header "4. Загрузка Docker-образов"
info "Скачиваю образы (несколько ГБ, зависит от скорости сети)"
if docker compose pull --quiet 2>/dev/null; then
  ok "Образы загружены"
else
  warn "Тихая загрузка не удалась, повторяю с подробным выводом"
  docker compose pull
  ok "Образы загружены"
fi

# --- 5. Запуск --------------------------------------------------------------
header "5. Запуск стека"
info "docker compose up -d"
docker compose up -d
ok "Контейнеры запущены"

# --- 6. Ожидание готовности ------------------------------------------------
header "6. Ожидание инициализации"
info "Первый запуск создаёт базу данных и выпускает сертификат — это занимает 3-10 минут."

WAIT_MAX=600
WAITED=0
INTERVAL=15
READY=0

while ((WAITED < WAIT_MAX)); do
  TOTAL=$(docker compose ps --format '{{.Name}}' 2>/dev/null | wc -l | tr -d ' ')
  RUNNING=$(docker compose ps --status running --format '{{.Name}}' 2>/dev/null | wc -l | tr -d ' ')

  # Ключевой признак готовности — отвечает веб-интерфейс.
  if curl -k -fsS --max-time 5 "https://127.0.0.1:${HTTPS_PORT:-443}/" -o /dev/null 2>/dev/null; then
    READY=1
    break
  fi

  printf '\r  Контейнеров запущено: %s/%s, ожидание %ss...' "${RUNNING}" "${TOTAL}" "${WAITED}"
  sleep "${INTERVAL}"
  WAITED=$((WAITED + INTERVAL))
done
printf '\n'

if ((READY == 1)); then
  ok "Веб-интерфейс отвечает"
else
  warn "За ${WAIT_MAX} секунд веб-интерфейс не ответил. Это не всегда ошибка — инициализация может продолжаться."
  info "Следите за логами: cd ${MCDIR} && docker compose logs -f --tail 50"
fi

# --- 7. Состояние контейнеров ----------------------------------------------
header "7. Состояние контейнеров"
docker compose ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null || docker compose ps

STOPPED="$(docker compose ps --format '{{.Name}} {{.State}}' 2>/dev/null | awk '$2!="running" {print $1}' || true)"
if [[ -n "${STOPPED}" ]]; then
  warn "Не запущены контейнеры:"
  printf '%s\n' "${STOPPED}" | sed 's/^/    /'
  info "Диагностика конкретного контейнера: cd ${MCDIR} && docker compose logs <имя>"
else
  ok "Все контейнеры в состоянии running"
fi

# --- 8. Автозапуск ----------------------------------------------------------
header "8. Автозапуск после перезагрузки"
# mailcow использует restart: unless-stopped в своём compose-файле,
# поэтому достаточно включённой службы docker.
if systemctl is-enabled --quiet docker; then
  ok "Служба docker в автозапуске — mailcow поднимется после перезагрузки"
else
  systemctl enable docker >/dev/null 2>&1
  ok "Служба docker добавлена в автозапуск"
fi

# --- Итог -------------------------------------------------------------------
header "Готово"
mark_step_done "30-install-mailcow"
ok "mailcow установлен."
printf '\n'
info "Веб-панель: https://${MAIL_HOSTNAME}/"
info "Логин по умолчанию: admin / moohoo"
warn "СРАЗУ смените пароль администратора — учётные данные по умолчанию известны всем."
printf '\n'
info "Следующий шаг: sudo ./deploy/40-postinstall.sh"
info "Он создаст домен, первый ящик и DKIM-ключ. Перед запуском понадобится API-ключ:"
info "  1) откройте https://${MAIL_HOSTNAME}/ и войдите как admin"
info "  2) смените пароль администратора"
info "  3) Configuration → Access → API: создайте ключ на чтение и запись,"
info "     разрешите доступ с адреса 127.0.0.1 (и с вашего IP, если нужно)"
info "  4) впишите ключ в .env как MAILCOW_API_KEY"
