# Руководство администратора

Документ описывает эксплуатацию почтового сервера, развёрнутого комплектом скриптов
этого репозитория: **mailcow: dockerized** на **Debian 12**, один почтовый домен,
до 20 почтовых ящиков.

Смежные документы:

| Документ | Назначение |
|---|---|
| [PLAN.md](../PLAN.md) | План развёртывания, требования к VPS и DNS |
| [README.md](../README.md) | Быстрый старт, порядок запуска скриптов |
| [docs/USER.md](USER.md) | Инструкция для конечного пользователя (настройка клиентов) |
| [docs/RUNBOOK.md](RUNBOOK.md) | Действия при инцидентах и типовых авариях |
| [docs/SECURITY.md](SECURITY.md) | Модель угроз и настройки безопасности |

Базовые сведения о системе:

| Параметр | Значение |
|---|---|
| Каталог mailcow | `/opt/mailcow-dockerized` |
| Конфигурация mailcow | `/opt/mailcow-dockerized/mailcow.conf` |
| Конфигурация комплекта | `.env` в корне репозитория (права `600`) |
| Журналы комплекта | `/var/log/mailstack/` |
| Веб-панель администратора | `https://<MAIL_HOSTNAME>/` |
| Веб-почта SOGo | `https://<MAIL_HOSTNAME>/SOGo/` |
| Логин по умолчанию | `admin` / `moohoo` — **сменить при первом входе** |
| Каталог резервных копий | `/var/backups/mailcow` |
| Скрипт бэкапа | `/usr/local/sbin/mailcow-backup` |

Все команды `docker compose` выполняются **из каталога `/opt/mailcow-dockerized`** —
иначе compose не найдёт файл описания сервисов.

---

## 1. Обзор системы

mailcow — это набор Docker-контейнеров, работающих как единый почтовый сервер.
Управление ведётся через `docker compose`; каждый контейнер отвечает за свою задачу.

### 1.1. Компоненты стека

| Контейнер | Компонент | За что отвечает |
|---|---|---|
| `postfix-mailcow` | Postfix | MTA: приём и отправка почты по SMTP (порты 25, 465, 587), очередь писем |
| `dovecot-mailcow` | Dovecot | Хранение ящиков, доступ по IMAP (993) и POP3 (995), сортировка Sieve, квоты |
| `rspamd-mailcow` | Rspamd | Антиспам, DKIM-подпись исходящих, проверка SPF/DKIM/DMARC, байесовский фильтр |
| `sogo-mailcow` | SOGo | Веб-почта, календари и адресные книги (CalDAV/CardDAV), ActiveSync |
| `mysql-mailcow` | MariaDB | База данных: домены, ящики, алиасы, настройки, данные SOGo |
| `redis-mailcow` | Redis | Кэш и оперативные данные Rspamd (репутация, статистика, обучение) |
| `nginx-mailcow` | nginx | Обратный прокси: веб-панель, SOGo, API, терминирование TLS |
| `acme-mailcow` | acme.sh | Автоматический выпуск и продление сертификатов Let's Encrypt |
| `netfilterd-mailcow` | netfilter | Автоматическая блокировка IP при подборе паролей к почте (аналог fail2ban для SMTP/IMAP) |
| `watchdog-mailcow` | watchdog | Мониторинг живости сервисов, перезапуск зависших контейнеров, уведомления |
| `unbound-mailcow` | Unbound | Локальный рекурсивный DNS-резолвер: нужен для корректных проверок SPF/DKIM/DNSBL |
| `clamd-mailcow` | ClamAV | Антивирусная проверка вложений |
| `dockerapi-mailcow` | dockerapi | Внутренний API для управления контейнерами из веб-панели |
| `memcached-mailcow` | memcached | Вспомогательный кэш веб-интерфейса |
| `php-fpm-mailcow` | PHP-FPM | Исполнение кода веб-панели и REST API |
| `ofelia-mailcow` | Ofelia | Планировщик внутренних периодических задач mailcow |

Дополнительно на хосте (вне Docker), настроено скриптами `security/`:

| Механизм | Назначение | Скрипт настройки |
|---|---|---|
| OpenSSH (усиленная конфигурация) | Административный доступ | `security/10-harden-ssh.sh` |
| nftables/ufw | Межсетевой экран хоста | `security/20-firewall.sh` |
| fail2ban | Защита SSH от подбора пароля | `security/30-fail2ban.sh` |
| Параметры ядра (`sysctl`) | Сетевая защита хоста | `security/40-sysctl.sh` |
| unattended-upgrades | Автоматические обновления безопасности ОС | `security/50-auto-updates.sh` |
| `mailcow-backup.timer` | Ежедневное резервное копирование | `deploy/50-setup-backup.sh` |

### 1.2. Куда попадают данные

| Данные | Расположение |
|---|---|
| Письма пользователей | Docker-том `mailcow_vmail-vol-1` (через `dovecot-mailcow`) |
| База данных | Docker-том `mailcow_mysql-vol-1` |
| Сертификаты TLS | `/opt/mailcow-dockerized/data/assets/ssl/` |
| Конфигурация сервисов | `/opt/mailcow-dockerized/data/conf/` |
| Ключи DKIM | Redis (резервируются штатным бэкапом) |

---

## 2. Ежедневные операции

```bash
# Состояние всех контейнеров (главная команда «всё ли живо»)
cd /opt/mailcow-dockerized && docker compose ps

# Полная проверка системы: сервисы, DNS, доставка почты, безопасность
sudo ./checks/00-full-check.sh

# Быстрая проверка только сервисов
sudo ./checks/10-check-services.sh
```

Частые команды администратора:

| Задача | Команда |
|---|---|
| Статус контейнеров | `cd /opt/mailcow-dockerized && docker compose ps` |
| Перезапуск одного сервиса | `docker compose restart postfix-mailcow` |
| Перезапуск всего стека | `docker compose down && docker compose up -d` |
| Логи сервиса (последние 100 строк) | `docker compose logs --tail 100 postfix-mailcow` |
| Логи в реальном времени | `docker compose logs -f postfix-mailcow` |
| Очередь исходящей почты | `docker compose exec postfix-mailcow postqueue -p` |
| Свободное место | `df -h` |
| Использование памяти | `free -h` |
| Занятое место Docker | `docker system df` |
| Проверка DNS-записей | `sudo ./checks/20-check-dns.sh` |
| Проверка потока почты | `sudo ./checks/30-check-mailflow.sh` |
| Проверка безопасности | `sudo ./checks/40-check-security.sh` |
| Резервная копия вручную | `sudo /usr/local/sbin/mailcow-backup` |
| Статус таймера бэкапа | `systemctl status mailcow-backup.timer` |
| Журналы комплекта | `ls -lt /var/log/mailstack/ \| head` |

> **Предупреждение.** `docker compose down` останавливает приём почты.
> Отправляющие серверы будут повторять доставку (обычно несколько дней),
> поэтому письма не теряются, но задерживаются. Не оставляйте стек выключенным.

---

## 3. Управление почтовыми ящиками

### 3.1. Создание ящика скриптом (рекомендуемый способ)

```bash
# Синтаксис: ./tools/add-mailbox.sh <локальная_часть> "<Имя Фамилия>" [квота_МБ] [пароль]

# Ящик с квотой по умолчанию (FIRST_MAILBOX_QUOTA_MB из .env) и сгенерированным паролем
./tools/add-mailbox.sh ivan "Иван Петров"

# Ящик с квотой 5 ГБ
./tools/add-mailbox.sh ivan "Иван Петров" 5120

# Ящик с заданным паролем (пароль попадёт в историю shell — используйте осторожно)
./tools/add-mailbox.sh ivan "Иван Петров" 5120 'НадёжныйПароль123!'
```

Скрипт проверяет корректность локальной части, отсутствие дубликата,
создаёт ящик через API и выводит готовый блок с параметрами для пользователя
(адрес, пароль, адрес веб-почты, настройки IMAP/SMTP). Домен берётся из
`MAIL_DOMAIN` в `.env`.

> **Предупреждение.** Сгенерированный пароль показывается один раз.
> Передавайте его пользователю по каналу, отличному от канала передачи логина
> (например, логин — письмом, пароль — в мессенджере или по телефону).
> Подробная инструкция для пользователя — [docs/USER.md](USER.md).

### 3.2. Создание ящика через веб-панель

1. Войдите на `https://<MAIL_HOSTNAME>/` как `admin`.
2. **Mail Setup → Mailboxes → Add mailbox**.
3. Заполните: `Username` (локальная часть), `Domain`, `Full name`,
   `Quota (MiB)`, пароль дважды.
4. При необходимости включите `Force password update at next login` —
   пользователь обязан сменить пароль при первом входе.
5. **Add**.

### 3.3. Изменение квоты

Через API (квота в мегабайтах):

```bash
# Увеличить квоту ящика до 10 ГБ
./tools/mailcow-api.sh POST /api/v1/edit/mailbox \
  '{"items":["ivan@example.com"],"attr":{"quota":"10240"}}'
```

Через веб-панель: **Mail Setup → Mailboxes →** значок карандаша у ящика →
поле `Quota` → **Save**.

> Суммарная квота всех ящиков не может превышать квоту домена.
> Квота домена меняется в **Mail Setup → Domains →** карандаш → `Domain quota`.

### 3.4. Смена пароля ящика

```bash
# Задать новый пароль (оба поля обязательны и должны совпадать)
./tools/mailcow-api.sh POST /api/v1/edit/mailbox \
  '{"items":["ivan@example.com"],"attr":{"password":"НовыйПароль2024!","password2":"НовыйПароль2024!"}}'
```

Пользователь может сменить пароль сам в SOGo: **аватар → Preferences → Password**,
либо на `https://<MAIL_HOSTNAME>/` войдя своим адресом (пользовательский режим).

### 3.5. Отключение ящика

Отключение сохраняет письма, но запрещает вход и приём почты — предпочтительнее
удаления при увольнении сотрудника.

```bash
# Отключить ящик
./tools/mailcow-api.sh POST /api/v1/edit/mailbox \
  '{"items":["ivan@example.com"],"attr":{"active":"0"}}'

# Включить обратно
./tools/mailcow-api.sh POST /api/v1/edit/mailbox \
  '{"items":["ivan@example.com"],"attr":{"active":"1"}}'
```

### 3.6. Удаление ящика

> **ОПАСНАЯ ОПЕРАЦИЯ.** Удаление ящика безвозвратно уничтожает все письма,
> календари и контакты этого пользователя. Восстановление возможно только из
> резервной копии. Перед удалением: сделайте бэкап и убедитесь, что содержимое
> ящика больше не нужно (часто достаточно отключить ящик или превратить его в алиас).

```bash
# 1. Свежая резервная копия
sudo /usr/local/sbin/mailcow-backup

# 2. Удаление (тело запроса — массив адресов)
./tools/mailcow-api.sh POST /api/v1/delete/mailbox '["ivan@example.com"]'
```

### 3.7. Алиасы

Алиас — дополнительный адрес, письма с которого попадают в существующий ящик.
Алиасы не занимают лицензионных мест и не требуют отдельного пароля.

```bash
# Алиас на один ящик
./tools/mailcow-api.sh POST /api/v1/add/alias \
  '{"address":"info@example.com","goto":"ivan@example.com","active":"1"}'

# Алиас-рассылка: копии нескольким получателям (перечисление через запятую)
./tools/mailcow-api.sh POST /api/v1/add/alias \
  '{"address":"all@example.com","goto":"ivan@example.com,anna@example.com","active":"1"}'

# Список всех алиасов
./tools/mailcow-api.sh GET /api/v1/get/alias/all

# Удаление алиаса (по его числовому id из списка выше)
./tools/mailcow-api.sh POST /api/v1/delete/alias '["3"]'
```

В веб-панели: **Mail Setup → Aliases → Add alias**.

### 3.8. Группы рассылки

Для небольшой организации группа рассылки реализуется алиасом с несколькими
получателями (см. выше) — это самый простой и надёжный вариант.

Если нужна рассылка с ограничением «только для сотрудников», в веб-панели у алиаса
доступна опция **Silently discard / Learn as spam** и фильтры. Для полноценных
списков рассылки с архивами и подписками потребуется отдельное ПО (mailman) —
в этот комплект оно не входит.

### 3.9. Полезные запросы к API

```bash
# Все ящики с квотами и занятым местом
./tools/mailcow-api.sh GET /api/v1/get/mailbox/all

# Все домены
./tools/mailcow-api.sh GET /api/v1/get/domain/all

# DKIM-запись домена (нужна для DNS)
./tools/mailcow-api.sh GET /api/v1/get/dkim/example.com

# Журнал доставки (последние записи)
./tools/mailcow-api.sh GET /api/v1/get/logs/postfix/50
```

API-ключ создаётся в веб-панели: **Configuration → Access → API** →
включить `Activate API`, выбрать **read-write**, в поле разрешённых IP указать
`127.0.0.1`. Ключ передаётся в заголовке `X-API-Key` и хранится в `.env`
в переменной `MAILCOW_API_KEY`. Скрипт `tools/mailcow-api.sh` обращается к API
локально (через `--resolve` на `127.0.0.1`), поэтому доступ извне открывать не нужно.

---

## 4. Работа с очередью почты

Очередь Postfix — письма, которые ещё не доставлены. Небольшая очередь нормальна;
постоянно растущая очередь означает проблему.

```bash
cd /opt/mailcow-dockerized

# Просмотр очереди: ID, размер, время, отправитель, получатель, причина задержки
docker compose exec postfix-mailcow postqueue -p

# Краткая сводка: сколько писем в очереди
docker compose exec postfix-mailcow postqueue -p | tail -n 1

# Принудительная попытка доставить всю очередь немедленно
docker compose exec postfix-mailcow postqueue -f

# Подробности по конкретному письму (включая заголовки)
docker compose exec postfix-mailcow postcat -q A1B2C3D4E5
```

Удаление писем из очереди:

```bash
# Удалить одно письмо по его ID
docker compose exec postfix-mailcow postsuper -d A1B2C3D4E5

# Удалить ВСЕ письма из очереди отложенных (deferred)
docker compose exec postfix-mailcow postsuper -d ALL deferred
```

> **ОПАСНАЯ ОПЕРАЦИЯ.** `postsuper -d ALL` безвозвратно удаляет письма —
> отправители не получат ни письма, ни уведомления о его судьбе.
> Сначала изучите очередь через `postqueue -p` и удаляйте адресно.
> Массовое удаление оправдано только при спам-рассылке из взломанного ящика.

### Типичные причины застревания писем

| Признак в `postqueue -p` | Причина | Что делать |
|---|---|---|
| `Connection timed out` для порта 25 | Провайдер VPS блокирует исходящий 25 | Запросить разблокировку в поддержке хостинга |
| `Host or domain name not found` | Проблема разрешения имён | Проверить `unbound-mailcow`: `docker compose logs unbound-mailcow` |
| `blocked using ...dnsbl...` | IP сервера в чёрном списке | Проверить и запросить делистинг, см. `checks/20-check-dns.sh` |
| `550 ... SPF/DKIM/DMARC` | Некорректные DNS-записи домена | Перегенерировать: `./tools/gen-dns-records.sh`, внести у провайдера |
| `Mailbox full` / `quota exceeded` | Ящик получателя переполнен | Для локального ящика — увеличить квоту (раздел 3.3) |
| `Relay access denied` | Ошибка конфигурации/попытка релея | Проверить, что отправитель аутентифицирован |
| Очередь растёт сотнями писем | Вероятно, взломан ящик и идёт спам-рассылка | См. [docs/RUNBOOK.md](RUNBOOK.md): сменить пароль, отключить ящик, очистить очередь |

---

## 5. Журналы и диагностика

### 5.1. Где что искать

| Что | Где |
|---|---|
| Работа скриптов комплекта | `/var/log/mailstack/*.log` |
| Журналы резервного копирования | `/var/log/mailstack/backup-*.log` |
| Логи почтовых сервисов | `docker compose logs <контейнер>` |
| Журнал доставки (удобный поиск) | Веб-панель → **Mail Setup → Logs → Postfix / Dovecot / Rspamd** |
| Системный журнал хоста | `journalctl -xe` |
| Блокировки SSH (fail2ban) | `sudo fail2ban-client status sshd` |
| Блокировки почтовых сервисов | Веб-панель → **Access → Fail2ban** (netfilter) |

### 5.2. Поиск по журналам

```bash
cd /opt/mailcow-dockerized

# Все события по конкретному адресу за последние сутки
docker compose logs --since 24h postfix-mailcow | grep -i "ivan@example.com"

# Проследить судьбу письма по Message-ID
docker compose logs --since 48h postfix-mailcow | grep "20240115120000.ABCDEF@example.com"

# Ошибки Postfix
docker compose logs --tail 500 postfix-mailcow | grep -Ei "error|warning|fatal|reject"

# Неудачные попытки входа (подбор пароля)
docker compose logs --since 6h dovecot-mailcow | grep -i "auth failed"

# Решения антиспама по письмам
docker compose logs --since 2h rspamd-mailcow | grep -Ei "reject|add header|greylist"

# Проблемы с сертификатом
docker compose logs --tail 200 acme-mailcow
```

### 5.3. Полная трассировка доставки письма

Постфикс присваивает письму внутренний ID (`queue ID`). Логика поиска:

```bash
# 1. Найти queue ID по адресу или Message-ID
docker compose logs --since 24h postfix-mailcow | grep "ivan@example.com"
# → строка вида: postfix/smtpd[123]: A1B2C3D4E5: client=...

# 2. Все события этого письма
docker compose logs --since 24h postfix-mailcow | grep "A1B2C3D4E5"
# → в конце будет status=sent (доставлено), status=deferred (отложено)
#   или status=bounced (отказ)
```

---

## 6. Резервное копирование

### 6.1. Что настроено

Скрипт `deploy/50-setup-backup.sh` создал:

| Объект | Назначение |
|---|---|
| `/usr/local/sbin/mailcow-backup` | Скрипт-обёртка над штатным `helper-scripts/backup_and_restore.sh` |
| `mailcow-backup.service` | Одноразовая systemd-служба, запускающая обёртку |
| `mailcow-backup.timer` | Таймер: ежедневно в `BACKUP_SCHEDULE` (по умолчанию `03:30`) |
| `/var/backups/mailcow` | Каталог копий, права `0700` (только root) |

Состав резервной копии:

| Компонент | Содержимое |
|---|---|
| База данных | домены, ящики, алиасы, настройки, данные SOGo |
| Почтовые ящики (`vmail`) | все письма пользователей |
| Redis | ключи DKIM, обученный байесовский фильтр, статистика |
| Конфигурация Rspamd | пользовательские правила, белые и чёрные списки |
| Crypt-ключи | ключи шифрования почтового хранилища |
| `configs-<дата>.tar.gz` | `mailcow.conf` и `data/conf` — отдельный архив, создаётся обёрткой |

Обёртка также:
- отказывается работать, если в каталоге назначения меньше 5 ГБ свободно;
- удаляет копии старше `BACKUP_KEEP_DAYS` дней (по умолчанию 14);
- удаляет свои журналы старше 30 дней;
- пишет журнал в `/var/log/mailstack/backup-<дата>.log`.

> **Важно.** Файл `.env` комплекта **не входит** в бэкап (он лежит в репозитории, а не
> в каталоге mailcow). Храните его копию отдельно и безопасно — в нём пароли и API-ключ.

### 6.2. Ручной запуск и контроль

```bash
# Запустить копирование немедленно
sudo /usr/local/sbin/mailcow-backup

# Статус таймера и время следующего запуска
systemctl status mailcow-backup.timer
systemctl list-timers mailcow-backup.timer

# Результат последнего запуска службы
systemctl status mailcow-backup.service
journalctl -u mailcow-backup.service --since "3 days ago"

# Журнал последнего копирования
sudo tail -n 40 "$(ls -t /var/log/mailstack/backup-*.log | head -1)"
```

### 6.3. Проверка свежести копий

```bash
# Список копий по дате, новейшие сверху
sudo ls -lt /var/backups/mailcow/

# Размер каждой копии
sudo du -sh /var/backups/mailcow/*

# Возраст самой свежей копии в часах
sudo find /var/backups/mailcow -maxdepth 1 -name 'mailcow-*' -printf '%T@ %p\n' \
  | sort -rn | head -1 \
  | awk -v now="$(date +%s)" '{printf "Свежая копия: %s, возраст %.1f ч\n", $2, (now-$1)/3600}'
```

Признаки проблемы: копий нет за последние 48 часов; размер копии резко уменьшился;
в журнале строки со словом `ОШИБКА`.

### 6.4. Отправка копий на внешнее хранилище

> Копии на том же диске, что и данные, не защищают от отказа диска или потери VPS.
> Скрипт `deploy/50-setup-backup.sh` предупреждает об этом. Настройте выгрузку наружу.

**Вариант А: rclone (облачные хранилища S3, Backblaze B2, Яндекс Диск и др.)**

```bash
# 1. Установка
sudo apt-get update && sudo apt-get install -y rclone

# 2. Интерактивная настройка удалённого хранилища (создайте remote с именем «offsite»)
sudo rclone config

# 3. Проверка доступа
sudo rclone lsd offsite:

# 4. Скрипт выгрузки
sudo tee /usr/local/sbin/mailcow-offsite >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SRC=/var/backups/mailcow
DST=offsite:mailcow-backups
LOG=/var/log/mailstack/offsite-$(date '+%Y%m%d-%H%M%S').log
mkdir -p /var/log/mailstack
# --delete-after: удалить в облаке то, что удалено локально (ротация повторяется)
rclone sync "${SRC}" "${DST}" \
  --delete-after \
  --transfers 4 \
  --bwlimit 8M \
  --log-file "${LOG}" --log-level INFO
# Чистим старые журналы выгрузки
find /var/log/mailstack -name 'offsite-*.log' -mtime +30 -delete
EOF
sudo chmod 0700 /usr/local/sbin/mailcow-offsite

# 5. Тестовый прогон
sudo /usr/local/sbin/mailcow-offsite && echo "Выгрузка прошла успешно"
```

**Вариант Б: rsync по SSH на другой сервер**

```bash
# 1. Ключ для автоматической выгрузки (без пароля, только для этой задачи)
sudo ssh-keygen -t ed25519 -f /root/.ssh/offsite_key -N '' -C 'mailcow-offsite'

# 2. Установить публичный ключ на приёмной стороне
sudo ssh-copy-id -i /root/.ssh/offsite_key.pub backup@backup.example.com

# 3. Проверить вход без пароля
sudo ssh -i /root/.ssh/offsite_key backup@backup.example.com 'echo Соединение установлено'

# 4. Скрипт выгрузки
sudo tee /usr/local/sbin/mailcow-offsite >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
SRC=/var/backups/mailcow/
DST=backup@backup.example.com:/srv/backups/mail/
LOG=/var/log/mailstack/offsite-$(date '+%Y%m%d-%H%M%S').log
mkdir -p /var/log/mailstack
# -a сохраняет права, --delete повторяет локальную ротацию на приёмнике
rsync -a --delete --partial \
  --bwlimit=8000 \
  -e "ssh -i /root/.ssh/offsite_key -o StrictHostKeyChecking=yes" \
  "${SRC}" "${DST}" >>"${LOG}" 2>&1
find /var/log/mailstack -name 'offsite-*.log' -mtime +30 -delete
EOF
sudo chmod 0700 /usr/local/sbin/mailcow-offsite
sudo /usr/local/sbin/mailcow-offsite && echo "Выгрузка прошла успешно"
```

**Таймер systemd для выгрузки** (запуск через час после бэкапа, чтобы копия успела создаться):

```bash
sudo tee /etc/systemd/system/mailcow-offsite.service >/dev/null <<'EOF'
[Unit]
Description=Выгрузка резервных копий mailcow на внешнее хранилище
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mailcow-offsite
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=10800
EOF

sudo tee /etc/systemd/system/mailcow-offsite.timer >/dev/null <<'EOF'
[Unit]
Description=Ежедневная выгрузка резервных копий наружу

[Timer]
# На час позже BACKUP_SCHEDULE (по умолчанию 03:30)
OnCalendar=*-*-* 04:30:00
Persistent=true
RandomizedDelaySec=900

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now mailcow-offsite.timer
systemctl list-timers mailcow-offsite.timer
```

> **Предупреждение.** Внешнее хранилище содержит всю переписку организации.
> Доступ к нему должен быть ограничен, а канал — зашифрован (SSH/HTTPS).
> Для облака желательно включить шифрование на стороне клиента
> (в rclone — remote типа `crypt`).

### 6.5. Проверка восстановления

Непроверенная резервная копия не является резервной копией. Проверяйте
восстановление **не реже одного раза в квартал**.

```bash
# Восстановление выполняется интерактивным скриптом:
sudo ./tools/restore.sh
```

Скрипт показывает список доступных копий в `/var/backups/mailcow`, требует явного
подтверждения на каждом шаге и позволяет выбрать восстанавливаемые компоненты.

> **ОПАСНАЯ ОПЕРАЦИЯ.** Восстановление перезаписывает текущие данные. Все письма,
> полученные после создания выбранной копии, будут потеряны. **Никогда не проверяйте
> восстановление на рабочем сервере.** Для проверки поднимите отдельную тестовую VPS,
> установите на неё комплект (`deploy/00-preflight.sh` … `deploy/30-install-mailcow.sh`),
> скопируйте туда архив копии и выполните `tools/restore.sh` там.

Минимальный чеклист успешной проверки: контейнеры поднялись, вход в веб-панель
работает, список ящиков совпадает, в ящике видны старые письма, DKIM-ключ тот же
(`GET /api/v1/get/dkim/<домен>` возвращает прежнее значение).

---

## 7. Обновления

### 7.1. Обновление mailcow

```bash
# Скрипт: проверяет наличие обновлений, показывает список изменений,
# предлагает сделать бэкап, запускает штатный update.sh, проверяет результат
sudo ./tools/update-mailcow.sh
```

Что делает `tools/update-mailcow.sh` по шагам:

1. Показывает текущий коммит и количество отстающих коммитов от `origin`.
2. Предупреждает о простое (обычно 2–10 минут).
3. Предлагает создать резервную копию через `/usr/local/sbin/mailcow-backup`.
4. Запускает `/opt/mailcow-dockerized/update.sh --force`.
5. Ждёт ответа веб-интерфейса и проверяет, что все контейнеры в состоянии `running`.
6. Предлагает удалить неиспользуемые Docker-образы.

При неудаче скрипт выводит команду откота:

```bash
# Откат к версии, которая работала до обновления
cd /opt/mailcow-dockerized && git checkout <прежний_коммит> && docker compose up -d
```

После обновления:

```bash
sudo ./checks/00-full-check.sh
```

Периодичность: раз в месяц, а также немедленно при выходе исправлений безопасности
mailcow. Обновляйтесь только в ветке `master` (`MAILCOW_BRANCH` в `.env`);
`nightly` для рабочего сервера не подходит.

### 7.2. Обновление хостовой ОС

```bash
# Просмотр доступных обновлений
sudo apt-get update && apt-get -s upgrade | grep '^Inst'

# Установка обновлений
sudo apt-get update && sudo apt-get upgrade -y

# Нужна ли перезагрузка (например, после обновления ядра)
[ -f /var/run/reboot-required ] && cat /var/run/reboot-required
```

Порядок обновления с перезагрузкой:

```bash
# 1. Свежая резервная копия
sudo /usr/local/sbin/mailcow-backup

# 2. Обновление пакетов
sudo apt-get update && sudo apt-get upgrade -y

# 3. Корректная остановка почтового стека
cd /opt/mailcow-dockerized && docker compose down

# 4. Перезагрузка
sudo reboot

# 5. После загрузки: контейнеры поднимаются автоматически (restart policy).
#    Если нет — поднять вручную:
cd /opt/mailcow-dockerized && docker compose up -d

# 6. Полная проверка
sudo ./checks/00-full-check.sh
```

### 7.3. Что обновляется автоматически, а что нет

| Компонент | Автообновление | Почему |
|---|---|---|
| Пакеты безопасности Debian | Да, `unattended-upgrades` (`security/50-auto-updates.sh`) | Низкий риск, высокая польза |
| Ядро Linux | Пакет ставится автоматически, но **применяется только после перезагрузки** | Перезагрузку выбирает администратор |
| mailcow (контейнеры) | **Нет** | Обновление меняет схему БД и конфигурацию; требует бэкапа, простоя и контроля результата |
| Docker Engine | Вместе с пакетами ОС | Перезапуск демона кратковременно роняет контейнеры — обновляйте в окно обслуживания |
| Сертификаты Let's Encrypt | Да, `acme-mailcow` | Штатный механизм, вмешательство не нужно |
| Правила Rspamd | Да, при обновлении контейнеров | Обновляются вместе с mailcow |

---

## 8. Сертификаты Let's Encrypt

### 8.1. Как это работает

Контейнер `acme-mailcow` самостоятельно:
- запрашивает сертификат для `MAILCOW_HOSTNAME` и имён из `ADDITIONAL_SAN`;
- проходит проверку HTTP-01 через `nginx-mailcow` на порту 80;
- продлевает сертификат, когда до истечения остаётся менее 30 дней;
- перезагружает Postfix, Dovecot и nginx после обновления сертификата.

Требования: порт 80 открыт извне, DNS-запись A (и AAAA, если `ENABLE_IPV6=yes`)
указывает на этот сервер.

### 8.2. Проверка состояния

```bash
# Срок действия текущего сертификата
echo | openssl s_client -connect localhost:443 -servername mail.example.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

# Сертификат на SMTP-порту (должен быть тем же)
echo | openssl s_client -connect localhost:25 -starttls smtp 2>/dev/null \
  | openssl x509 -noout -dates

# Журнал выпуска и продления
cd /opt/mailcow-dockerized && docker compose logs --tail 100 acme-mailcow

# Файлы сертификата
sudo ls -l /opt/mailcow-dockerized/data/assets/ssl/
```

### 8.3. Диагностика неудачного выпуска

| Сообщение в логах `acme-mailcow` | Причина | Решение |
|---|---|---|
| `Cannot validate ... hostname does not resolve` | A-запись отсутствует или указывает не сюда | Проверить DNS: `./checks/20-check-dns.sh` |
| `Invalid response from http://.../.well-known/...` | Порт 80 закрыт или занят | Проверить firewall (`security/20-firewall.sh`), что порт 80 не слушает другой процесс |
| `too many certificates already issued` | Лимит Let's Encrypt (5 в неделю на домен) | Подождать неделю; не перезапускать acme в цикле |
| `Cannot find a valid ... IPv6` | `ENABLE_IPV6=yes`, но IPv6 не работает | Поставить `ENABLE_IPV6=no` в `.env` и в `mailcow.conf`, пересоздать стек |
| Сертификат `self-signed` после установки | Первый выпуск ещё не завершён | Подождать 5–10 минут, затем `docker compose restart acme-mailcow` |

```bash
# Принудительно повторить попытку выпуска
cd /opt/mailcow-dockerized && docker compose restart acme-mailcow
docker compose logs -f acme-mailcow   # наблюдать за процессом
```

### 8.4. Добавление дополнительных имён (SAN)

Нужно, если пользователи подключаются по именам вроде `imap.example.com`
или `autodiscover.example.com`.

```bash
# 1. Убедитесь, что для новых имён есть A-записи, указывающие на этот сервер.

# 2. Добавьте их в mailcow.conf
sudo nano /opt/mailcow-dockerized/mailcow.conf
# Строка (имена через запятую, без пробелов):
# ADDITIONAL_SAN=autodiscover.example.com,autoconfig.example.com,imap.example.com

# 3. Примените изменения
cd /opt/mailcow-dockerized
sudo docker compose up -d
sudo docker compose restart acme-mailcow

# 4. Проверьте результат (имена должны появиться в SAN)
sudo docker compose logs --tail 50 acme-mailcow
echo | openssl s_client -connect localhost:443 -servername mail.example.com 2>/dev/null \
  | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'
```

---

## 9. Антиспам Rspamd

### 9.1. Доступ к интерфейсу Rspamd

Веб-панель → **Configuration → Rspamd** (или прямо `https://<MAIL_HOSTNAME>/rspamd/`).
Здесь видны: история проверенных писем, сработавшие правила и оценки, состояние
байесовского фильтра, throughput.

### 9.2. Пороги оценок

Rspamd начисляет каждому письму оценку (score). Действия по умолчанию:

| Оценка | Действие | Что видит пользователь |
|---|---|---|
| < 4 | `no action` | Письмо в папке «Входящие» |
| 4 … 6 | `add header` | Письмо помечено как спам, попадает в «Junk» |
| 6 … 12 | `greylist` / `add header` | Отложенная доставка, затем помета |
| > 12 | `reject` | Письмо отклонено, отправитель получает отказ |

Пороги настраиваются в веб-панели: **Configuration → Rspamd → Settings**
(редактор `local.conf`). Пример смягчения порога отклонения:

```
actions {
  reject = 15;
  add_header = 6;
  greylist = 4;
}
```

После сохранения:

```bash
cd /opt/mailcow-dockerized && docker compose restart rspamd-mailcow
```

> Не отключайте `reject` полностью: без него весь спам будет складываться в ящики
> пользователей и расходовать квоту.

### 9.3. Белые и чёрные списки

Через веб-панель (рекомендуется): **Configuration → Rspamd → Whitelist / Blacklist** —
по одному адресу или домену в строке.

Для отдельного ящика: **Mail Setup → Mailboxes →** карандаш у ящика →
вкладка `Spam filter` → `Whitelist` / `Blacklist`. Так пользователь может держать
свой список, не влияя на остальных.

Через API:

```bash
# Разрешить всё с домена (действует на все ящики домена)
./tools/mailcow-api.sh POST /api/v1/add/domain-policy \
  '{"domain":"example.com","object_list":"wl","object_from":"partner.com"}'

# Заблокировать конкретного отправителя
./tools/mailcow-api.sh POST /api/v1/add/domain-policy \
  '{"domain":"example.com","object_list":"bl","object_from":"spam@badsender.net"}'
```

> **Предупреждение.** Белый список отключает проверки для отправителя целиком.
> Адрес отправителя легко подделать, поэтому не вносите в белый список банки,
> платёжные системы и госорганы — именно их адреса чаще всего подделывают.
> Вносите только проверенных контрагентов, и лучше конкретные адреса, а не домены.

### 9.4. Обучение байесовского фильтра

Байес учится на ваших письмах и со временем заметно повышает точность.
Самый простой способ обучения — действия пользователей:

- письмо переложено в папку **Junk** → обучение как спам;
- письмо вынуто из **Junk** в «Входящие» → обучение как не-спам.

Это работает автоматически, пользователям достаточно правильно сортировать почту
(см. [docs/USER.md](USER.md)).

Ручное обучение из командной строки:

```bash
cd /opt/mailcow-dockerized

# Обучить как спам (файл письма в формате .eml)
docker compose exec -T rspamd-mailcow rspamc learn_spam < /tmp/spam.eml

# Обучить как не-спам
docker compose exec -T rspamd-mailcow rspamc learn_ham < /tmp/ham.eml

# Статистика обучения: нужно минимум ~200 писем каждого класса
docker compose exec rspamd-mailcow rspamc stat | grep -i bayes
```

### 9.5. Легитимные письма попадают в спам

Порядок разбора:

```bash
cd /opt/mailcow-dockerized

# 1. Найти письмо и посмотреть, какие правила дали оценку
docker compose logs --since 24h rspamd-mailcow | grep "sender@partner.com"
```

Далее по симптомам:

| Сработавший символ | Смысл | Действие |
|---|---|---|
| `R_SPF_FAIL`, `R_SPF_SOFTFAIL` | У отправителя неверная SPF-запись | Сообщить отправителю; как временная мера — белый список |
| `DKIM_REJECT` | Подпись отправителя не проверяется | Сообщить отправителю |
| `DMARC_POLICY_REJECT` | Политика домена отправителя запрещает такую отправку | Проблема на стороне отправителя |
| `RBL_*`, `DNSBL_*` | IP отправителя в чёрном списке | Отправителю нужно запросить делистинг |
| `BAYES_SPAM` при явно нормальном письме | Байес обучен некорректно | Переложить письма из Junk во «Входящие» (обучение ham), при грубой ошибке — сбросить байес |
| `MISSING_*`, `HTML_*` | Плохо сформированное письмо (часто рассылки) | Обычно достаточно белого списка |

Если байес обучен мусором и портит работу, его можно сбросить (обучение начнётся заново):

```bash
# ОПАСНО: удаляет всю статистику обучения — точность фильтра временно упадёт
cd /opt/mailcow-dockerized
docker compose exec redis-mailcow redis-cli --scan --pattern 'BAYES_*' | \
  xargs -r -n 100 docker compose exec -T redis-mailcow redis-cli DEL
docker compose restart rspamd-mailcow
```

---

## 10. Мониторинг и метрики

### 10.1. Что отслеживать

| Показатель | Норма | Как проверить | Порог тревоги |
|---|---|---|---|
| Свободное место на диске | > 20 % | `df -h /` | < 15 % |
| Свободная память | есть свободная + swap не забит | `free -h` | swap используется постоянно |
| Размер очереди Postfix | 0–20 писем | `postqueue -p \| tail -1` | > 100 писем |
| Возраст резервной копии | < 48 ч | см. раздел 6.3 | > 48 ч |
| Срок сертификата | > 14 дней | см. раздел 8.2 | < 10 дней |
| Все контейнеры `running` | да | `docker compose ps` | любой не `running` |
| IP в DNSBL | отсутствует | `./checks/20-check-dns.sh` | появление в любом списке |
| Неудачные входы | единицы в час | `docker compose logs dovecot-mailcow \| grep "auth failed"` | десятки в минуту |

### 10.2. Регулярная полная проверка

```bash
# Полная проверка: сервисы, DNS, поток почты, безопасность
sudo ./checks/00-full-check.sh

# Автоматический еженедельный запуск с сохранением отчёта
sudo crontab -e
# Добавить строку (понедельник, 07:00):
0 7 * * 1 cd /Users/admin/harness/post-server && ./checks/00-full-check.sh \
  > /var/log/mailstack/weekly-check-$(date +\%Y\%m\%d).log 2>&1
```

Путь к репозиторию в cron укажите фактический — тот, куда вы склонировали комплект
на сервере.

### 10.3. Простой скрипт оповещения

Скрипт проверяет ключевые показатели и отправляет письмо администратору только
при наличии проблем.

```bash
sudo tee /usr/local/sbin/mailcow-alert >/dev/null <<'EOF'
#!/usr/bin/env bash
# Проверка ключевых показателей. Письмо отправляется только при проблемах.
set -uo pipefail

ADMIN="admin@example.com"        # адрес получателя оповещений
MCDIR=/opt/mailcow-dockerized
BKDIR=/var/backups/mailcow
PROBLEMS=""

add() { PROBLEMS+="- $1"$'\n'; }

# 1. Место на диске
USED=$(df --output=pcent / | tail -1 | tr -dc '0-9')
(( USED > 85 )) && add "Диск заполнен на ${USED}%"

# 2. Контейнеры не в состоянии running
cd "${MCDIR}" || exit 1
DOWN=$(docker compose ps --format '{{.Name}} {{.State}}' 2>/dev/null | awk '$2!="running"{print $1}')
[[ -n "${DOWN}" ]] && add "Не работают контейнеры: $(echo ${DOWN} | tr '\n' ' ')"

# 3. Очередь почты
QUEUE=$(docker compose exec -T postfix-mailcow postqueue -p 2>/dev/null | grep -c '^[A-F0-9]' || echo 0)
(( QUEUE > 100 )) && add "В очереди ${QUEUE} писем"

# 4. Свежесть резервной копии (старше 48 часов)
NEWEST=$(find "${BKDIR}" -maxdepth 1 -name 'mailcow-*' -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
if [[ -z "${NEWEST}" ]]; then
  add "Резервных копий не найдено"
else
  AGE_H=$(( ( $(date +%s) - ${NEWEST%.*} ) / 3600 ))
  (( AGE_H > 48 )) && add "Последняя резервная копия создана ${AGE_H} ч назад"
fi

# 5. Срок действия сертификата (менее 10 дней)
END=$(echo | openssl s_client -connect 127.0.0.1:443 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [[ -n "${END}" ]]; then
  DAYS=$(( ( $(date -d "${END}" +%s) - $(date +%s) ) / 86400 ))
  (( DAYS < 10 )) && add "Сертификат истекает через ${DAYS} дн."
fi

# Отправка письма только при наличии проблем
if [[ -n "${PROBLEMS}" ]]; then
  printf 'Проблемы на почтовом сервере %s:\n\n%s\nПроверьте: sudo ./checks/00-full-check.sh\n' \
    "$(hostname -f)" "${PROBLEMS}" \
    | mail -s "[ВНИМАНИЕ] Почтовый сервер $(hostname -f)" "${ADMIN}"
fi
EOF
sudo chmod 0700 /usr/local/sbin/mailcow-alert

# Нужен клиент отправки почты на хосте
sudo apt-get install -y bsd-mailx

# Запуск каждый час
sudo crontab -e
# Добавить: 17 * * * * /usr/local/sbin/mailcow-alert
```

> Оповещения о проблемах почтового сервера, отправляемые через этот же сервер,
> не дойдут, если сервер полностью недоступен. Для критичных систем настройте
> внешний мониторинг доступности (например, проверку портов 25/443 со стороннего
> сервиса) — это дополняет, но не заменяет локальные проверки.

---

## 11. Масштабирование

### 11.1. Добавление ещё одного домена

```bash
# 1. Создать домен в mailcow (квота домена 10 ГБ, до 20 ящиков)
./tools/mailcow-api.sh POST /api/v1/add/domain \
  '{"domain":"newdomain.com","description":"Второй домен","aliases":"100","mailboxes":"20","quota":"10240","defquota":"3072","maxquota":"10240","active":"1"}'

# 2. Сгенерировать DKIM-ключ для нового домена (длина 2048 бит)
./tools/mailcow-api.sh POST /api/v1/add/dkim \
  '{"domains":"newdomain.com","dkim_selector":"dkim","key_size":"2048"}'

# 3. Получить значение DKIM-записи для DNS
./tools/mailcow-api.sh GET /api/v1/get/dkim/newdomain.com
```

Затем внесите у DNS-провайдера нового домена записи:

| Тип | Имя | Значение |
|---|---|---|
| MX | `newdomain.com` | `10 mail.example.com` (имя из `MAIL_HOSTNAME`) |
| TXT | `newdomain.com` | `v=spf1 mx -all` |
| TXT | `dkim._domainkey.newdomain.com` | значение из шага 3 |
| TXT | `_dmarc.newdomain.com` | `v=DMARC1; p=none; rua=mailto:dmarc@example.com` |
| CNAME | `autodiscover.newdomain.com` | `mail.example.com` (необязательно) |

Проверка и создание ящиков:

```bash
# Проверить распространение записей
dig +short MX newdomain.com
dig +short TXT dkim._domainkey.newdomain.com

# Полная проверка DNS (для основного домена из .env)
sudo ./checks/20-check-dns.sh
```

> `tools/add-mailbox.sh` работает только с домном из `MAIL_DOMAIN`.
> Ящики для дополнительного домена создавайте через веб-панель или напрямую API:
> `POST /api/v1/add/mailbox` с полем `"domain":"newdomain.com"`.
>
> Новое имя `mail.newdomain.com` требует добавления в `ADDITIONAL_SAN` (раздел 8.4),
> если пользователи будут подключаться по нему. Использовать один `MAIL_HOSTNAME`
> для всех доменов — проще и надёжнее.

### 11.2. Рост числа ящиков

| Ящиков | Рекомендуемая конфигурация VPS |
|---|---|
| до 20 | 2 vCPU, 6 ГБ RAM, 60 ГБ SSD (базовая) |
| 20–50 | 4 vCPU, 8 ГБ RAM, 150 ГБ SSD |
| 50–150 | 4–6 vCPU, 12–16 ГБ RAM, 300+ ГБ SSD |

Лимит ящиков задан на уровне домена: **Mail Setup → Domains →** карандаш →
`Max. possible mailboxes`. Сначала повышайте лимит домена и квоту домена, затем
создавайте ящики.

Способ снизить нагрузку без роста ресурсов: отключить ClamAV (экономит около 1,5 ГБ RAM).

```bash
# В mailcow.conf: SKIP_CLAMD=y
sudo nano /opt/mailcow-dockerized/mailcow.conf
cd /opt/mailcow-dockerized && sudo docker compose up -d
```

> Отключение антивируса повышает риск доставки вредоносных вложений.
> Делайте это только при реальной нехватке памяти и предупредите пользователей.

### 11.3. Расширение диска

```bash
# 1. Увеличьте диск в панели управления VPS, затем перезагрузите сервер.

# 2. Посмотрите текущее состояние
lsblk
df -h /

# 3. Если используется LVM — расширьте том и файловую систему
sudo lvextend -l +100%FREE /dev/mapper/vg0-root
sudo resize2fs /dev/mapper/vg0-root     # для ext4
# sudo xfs_growfs /                     # для xfs

# 4. Если обычный раздел — расширьте его, затем ФС
sudo growpart /dev/sda 1
sudo resize2fs /dev/sda1

# 5. Проверьте результат
df -h /
```

> **Предупреждение.** Операции с разделами способны уничтожить данные.
> Обязательно сделайте резервную копию (`sudo /usr/local/sbin/mailcow-backup`)
> и снимок (snapshot) диска в панели VPS до начала работ.

Быстрая экономия места без расширения диска:

```bash
# Сколько занимает Docker и что можно освободить
docker system df

# Удалить неиспользуемые образы (безопасно)
docker image prune -f

# Очистка журналов systemd до 500 МБ
sudo journalctl --vacuum-size=500M

# Старые логи комплекта
sudo find /var/log/mailstack -name '*.log' -mtime +30 -delete
```

### 11.4. Увеличение RAM

После увеличения памяти в панели VPS и перезагрузки специальная настройка обычно
не требуется — контейнеры используют доступную память автоматически. Проверить:

```bash
free -h
cd /opt/mailcow-dockerized && docker stats --no-stream
```

---

## 12. Права доступа и секреты

### 12.1. Файлы с секретами

| Файл | Содержимое | Требуемые права | Владелец |
|---|---|---|---|
| `.env` (корень репозитория) | пароль администратора, пароль первого ящика, `MAILCOW_API_KEY` | `600` | `root` |
| `/root/mailstack-credentials.txt` | сгенерированные пароли (создаёт `40-postinstall.sh`) | `600` | `root` |
| `/opt/mailcow-dockerized/mailcow.conf` | пароли БД, Redis, соль | `600` | `root` |
| `/var/backups/mailcow/` | вся почта и база данных | `700` | `root` |
| `/usr/local/sbin/mailcow-backup` | путь и параметры бэкапа | `700` | `root` |
| `/root/.ssh/` | ключи доступа | `700`, файлы `600` | `root` |
| `dns-records-<домен>.txt` | публичные данные (секретов нет) | `644` допустимо | — |

Проверка и исправление прав:

```bash
# Проверить
ls -l .env /root/mailstack-credentials.txt /opt/mailcow-dockerized/mailcow.conf
ls -ld /var/backups/mailcow

# Исправить
sudo chmod 600 .env /root/mailstack-credentials.txt /opt/mailcow-dockerized/mailcow.conf
sudo chmod 700 /var/backups/mailcow /usr/local/sbin/mailcow-backup
sudo chown root:root .env

# Автоматическая проверка прав и настроек безопасности
sudo ./checks/40-check-security.sh
```

### 12.2. Что нельзя коммитить в git

Никогда не добавляйте в репозиторий:

- `.env` — в репозитории должен оставаться только `.env.example` с пустыми значениями;
- `mailcow.conf` и любые файлы из `/opt/mailcow-dockerized/data/`;
- `/root/mailstack-credentials.txt`;
- файлы резервных копий и архивы `configs-*.tar.gz`;
- приватные ключи (`*.key`, `*.pem`, `id_ed25519`, `offsite_key`);
- журналы из `/var/log/mailstack/` (могут содержать адреса и темы писем).

```bash
# Проверить, что .env не отслеживается git
git check-ignore -v .env || echo "ВНИМАНИЕ: .env не в .gitignore!"

# Убедиться, что секреты не попали в индекс
git status --short
```

Если секрет всё же был закоммичен: считайте его скомпрометированным.
Смените пароль администратора, перегенерируйте API-ключ
(**Configuration → Access → API** → удалить и создать заново), смените пароли ящиков.
Удаление из истории git не отменяет утечки.

### 12.3. Ротация секретов

| Секрет | Периодичность | Как сменить |
|---|---|---|
| Пароль администратора mailcow | раз в 6 месяцев и при смене администратора | Веб-панель → **Access → Administrators** → изменить пароль |
| API-ключ | раз в год и при подозрении на утечку | Веб-панель → **Configuration → Access → API** → создать новый, обновить `MAILCOW_API_KEY` в `.env` |
| Пароли ящиков | по политике организации, минимум при увольнении | См. раздел 3.4 |
| SSH-ключи администраторов | при смене состава администраторов | Удалить строку из `~/.ssh/authorized_keys` |

---

## 13. Плановое обслуживание

### Ежедневно (2–3 минуты)

- [ ] Контейнеры работают: `cd /opt/mailcow-dockerized && docker compose ps`
- [ ] Очередь не растёт: `docker compose exec postfix-mailcow postqueue -p | tail -1`
- [ ] Свободно место: `df -h /`
- [ ] Резервная копия за прошлую ночь создана: `sudo ls -lt /var/backups/mailcow | head -3`

### Еженедельно (15 минут)

- [ ] Полная проверка: `sudo ./checks/00-full-check.sh`
- [ ] Ошибки в журналах: `docker compose logs --since 168h postfix-mailcow | grep -Ei "fatal|error" | tail -30`
- [ ] Подозрительная активность входов: `docker compose logs --since 168h dovecot-mailcow | grep -c "auth failed"`
- [ ] Блокировки fail2ban: `sudo fail2ban-client status sshd`
- [ ] IP не в чёрных списках: `sudo ./checks/20-check-dns.sh`
- [ ] Заполнение ящиков: `./tools/mailcow-api.sh GET /api/v1/get/mailbox/all`

### Ежемесячно (1 час)

- [ ] Резервная копия перед обслуживанием: `sudo /usr/local/sbin/mailcow-backup`
- [ ] Обновление mailcow: `sudo ./tools/update-mailcow.sh`
- [ ] Обновление ОС: `sudo apt-get update && sudo apt-get upgrade -y`
- [ ] Проверка необходимости перезагрузки: `[ -f /var/run/reboot-required ] && echo "нужна перезагрузка"`
- [ ] Очистка места: `docker image prune -f && sudo journalctl --vacuum-size=500M`
- [ ] Проверка срока сертификата (раздел 8.2)
- [ ] Ревизия ящиков и алиасов: отключить неиспользуемые
- [ ] Проверка настроек безопасности: `sudo ./checks/40-check-security.sh`

### Ежеквартально (2–3 часа)

- [ ] **Проверка восстановления из резервной копии на тестовом сервере** (раздел 6.5)
- [ ] Проверка работы выгрузки на внешнее хранилище: `sudo /usr/local/sbin/mailcow-offsite`
- [ ] Ревизия администраторов и SSH-ключей (`~/.ssh/authorized_keys`)
- [ ] Смена пароля администратора mailcow (раздел 12.3)
- [ ] Ужесточение политики DMARC: `none` → `quarantine` → `reject`
      (`DMARC_POLICY` в `.env`, затем `./tools/gen-dns-records.sh` и обновление DNS)
- [ ] Проверка доставляемости писем на внешние сервисы (Gmail, Яндекс, Mail.ru):
      `sudo ./checks/30-check-mailflow.sh`
- [ ] Ревизия белых списков Rspamd: удалить устаревшие исключения
- [ ] Проверка актуальности документации: изменились ли адреса, домены, контакты
- [ ] Оценка запаса ресурсов: диск, память, лимит ящиков (раздел 11)

---

## Куда обращаться дальше

| Ситуация | Документ |
|---|---|
| Авария, почта не работает | [docs/RUNBOOK.md](RUNBOOK.md) |
| Вопрос пользователя о настройке клиента | [docs/USER.md](USER.md) |
| Вопрос о настройках защиты | [docs/SECURITY.md](SECURITY.md) |
| Повторное развёртывание с нуля | [PLAN.md](../PLAN.md), [README.md](../README.md) |
| Официальная документация mailcow | https://docs.mailcow.email/ |
| Документация Rspamd | https://rspamd.com/doc/ |
