#!/usr/bin/env bash
# =============================================================================
# 20-install-docker.sh — установка Docker CE и плагина compose v2
# из официального репозитория Docker (версии в Debian-репозитории устарели).
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

log_init "install-docker"
require_root
load_env

export DEBIAN_FRONTEND=noninteractive

header "Установка Docker"

# --- 1. Проверка существующей установки ------------------------------------
if have_cmd docker && docker compose version >/dev/null 2>&1; then
  DOCKER_VER="$(docker --version | awk '{print $3}' | tr -d ',')"
  COMPOSE_VER="$(docker compose version --short 2>/dev/null || echo '?')"
  ok "Docker ${DOCKER_VER} и compose ${COMPOSE_VER} уже установлены"
  SKIP_INSTALL=1
else
  SKIP_INSTALL=0
fi

# --- 2. Удаление старых пакетов --------------------------------------------
if ((SKIP_INSTALL == 0)); then
  header "1. Удаление устаревших пакетов Docker"
  OLD_PKGS=()
  for p in docker.io docker-doc docker-compose podman-docker containerd runc; do
    if dpkg -l "${p}" 2>/dev/null | grep -q '^ii'; then
      OLD_PKGS+=("${p}")
    fi
  done
  if ((${#OLD_PKGS[@]} > 0)); then
    info "Удаляю устаревшие пакеты: ${OLD_PKGS[*]}"
    apt-get remove -y -qq "${OLD_PKGS[@]}" || true
    ok "Устаревшие пакеты удалены"
  else
    ok "Устаревших пакетов нет"
  fi

  # --- 3. Репозиторий Docker ------------------------------------------------
  header "2. Подключение официального репозитория Docker"
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    ok "GPG-ключ Docker загружен"
  else
    ok "GPG-ключ Docker уже на месте"
  fi

  ARCH="$(dpkg --print-architecture)"
  # shellcheck disable=SC1091
  . /etc/os-release
  CODENAME="${VERSION_CODENAME:-bookworm}"
  REPO_LINE="deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable"
  if [[ ! -f /etc/apt/sources.list.d/docker.list ]] || ! grep -qF "${REPO_LINE}" /etc/apt/sources.list.d/docker.list; then
    echo "${REPO_LINE}" >/etc/apt/sources.list.d/docker.list
    ok "Репозиторий добавлен (${CODENAME}, ${ARCH})"
  else
    ok "Репозиторий уже подключён"
  fi

  apt-get update -qq

  # --- 4. Установка ---------------------------------------------------------
  header "3. Установка пакетов Docker"
  apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
  ok "Docker установлен"
fi

# --- 5. Настройка демона ----------------------------------------------------
header "4. Настройка демона Docker"
DAEMON_JSON=/etc/docker/daemon.json
mkdir -p /etc/docker

# Ограничение логов обязательно: без него json-логи контейнеров съедают диск.
NEW_DAEMON_CONF='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  },
  "live-restore": false,
  "userland-proxy": false,
  "no-new-privileges": false,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65535,
      "Soft": 65535
    }
  }
}'

if [[ -f "${DAEMON_JSON}" ]]; then
  if have_cmd jq && jq -e '."log-opts"."max-size"' "${DAEMON_JSON}" >/dev/null 2>&1; then
    ok "daemon.json уже содержит ограничение логов, не трогаю"
  else
    backup_file "${DAEMON_JSON}"
    warn "Существующий daemon.json сохранён в резервную копию и будет заменён"
    printf '%s\n' "${NEW_DAEMON_CONF}" >"${DAEMON_JSON}"
    DAEMON_CHANGED=1
  fi
else
  printf '%s\n' "${NEW_DAEMON_CONF}" >"${DAEMON_JSON}"
  DAEMON_CHANGED=1
  ok "Создан ${DAEMON_JSON} с ротацией логов (50 МБ × 3)"
fi

# Проверка валидности JSON до перезапуска — иначе демон не поднимется.
if have_cmd jq; then
  jq -e . "${DAEMON_JSON}" >/dev/null 2>&1 || die "daemon.json содержит некорректный JSON. Проверьте ${DAEMON_JSON}"
fi

# --- 6. Запуск --------------------------------------------------------------
header "5. Запуск службы"
systemctl enable docker >/dev/null 2>&1
if [[ -n "${DAEMON_CHANGED:-}" ]]; then
  systemctl restart docker
else
  systemctl start docker 2>/dev/null || true
fi

sleep 3
if systemctl is-active --quiet docker; then
  ok "Служба docker запущена и добавлена в автозапуск"
else
  err "Служба docker не запустилась. Диагностика: journalctl -u docker -n 50 --no-pager"
  exit 1
fi

# --- 7. Проверка работоспособности -----------------------------------------
header "6. Проверка"
DOCKER_VER="$(docker --version 2>/dev/null || echo 'нет')"
COMPOSE_VER="$(docker compose version 2>/dev/null || echo 'нет')"
info "${DOCKER_VER}"
info "${COMPOSE_VER}"

if ! docker compose version >/dev/null 2>&1; then
  die "Плагин docker compose недоступен. Установите пакет docker-compose-plugin"
fi

info "Тестовый запуск контейнера hello-world"
if docker run --rm hello-world >/dev/null 2>&1; then
  ok "Docker работает корректно"
  docker image rm hello-world >/dev/null 2>&1 || true
else
  err "Не удалось запустить тестовый контейнер."
  err "Частые причины: нет доступа в интернет, блокировка registry, контейнерная виртуализация (OpenVZ/LXC)."
  exit 1
fi

# --- 8. Заметка о группе docker --------------------------------------------
header "7. Доступ без sudo (необязательно)"
info "Членство в группе docker равносильно правам root на хосте."
info "Скрипт НЕ добавляет пользователей в эту группу автоматически."
if [[ -n "${SSH_ALLOW_USER:-}" ]] && id "${SSH_ALLOW_USER}" >/dev/null 2>&1; then
  info "Если это осознанное решение, выполните вручную:"
  info "    usermod -aG docker ${SSH_ALLOW_USER}"
  info "Безопаснее оставить как есть и работать через sudo."
fi

header "Готово"
mark_step_done "20-install-docker"
ok "Docker готов."
info "Следующий шаг: sudo ./deploy/30-install-mailcow.sh"
