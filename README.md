# Universal Backup & Restore

Универсальный bash-скрипт для резервного копирования проектов на VPS.

Поддерживает любые БД в Docker или внешние, любое S3-совместимое хранилище, Google Drive и Telegram. Каждый источник и каждый способ отправки можно включить или отключить независимо.

## Возможности

- **БД:** PostgreSQL, MySQL / MariaDB, MongoDB
- **Тип подключения:** Docker-контейнер или внешняя БД
- **Что бэкапится:** дамп БД + `.env` файл + директория проекта (каждый пункт опционален)
- **Хранилища:** Telegram, S3-совместимые (AWS, Yandex, Timeweb, MinIO и др.), Google Drive
- **Уведомления:** Telegram — статус после каждого бэкапа и восстановления
- **Автоматизация:** встроенное управление cron-расписанием
- **Ротация:** удаление старых бэкапов локально и в S3
- **Восстановление:** интерактивный выбор из локальных файлов или S3
- **Языки:** русский и английский

## Требования

| Инструмент | Обязателен | Назначение |
|---|---|---|
| `bash` ≥ 4 | да | выполнение скрипта |
| `tar`, `gzip` | да | архивирование |
| `curl` | да | Telegram API, Google Drive API |
| `docker` | при использовании Docker-БД | дамп/восстановление из контейнера |
| `aws` (AWS CLI) | при использовании S3 | загрузка в S3 |
| `pg_dump` / `mysqldump` / `mongodump` | при использовании внешней БД | дамп без Docker |

AWS CLI устанавливается автоматически при первом выборе S3 (если есть root).

## Установка

```bash
git clone https://github.com/YOUR_USERNAME/universal-backup.git
cd universal-backup
chmod +x backup.sh
./backup.sh
```

При первом запуске откроется wizard — он запросит имя проекта, путь к директории, данные БД, способ отправки и Telegram (опционально). Конфиг сохраняется в `backup.cfg` рядом со скриптом.

При наличии прав root создаётся симлинк `/usr/local/bin/backup` для быстрого запуска из любого места.

## Использование

```bash
# Интерактивное меню
./backup.sh

# Создать бэкап немедленно (для cron, без меню)
./backup.sh backup

# Восстановление
./backup.sh restore

# Указать другой конфиг-файл
./backup.sh --config /opt/myproject/backup.cfg
```

## Структура бэкапа

Каждый бэкап — это единый `.tar.gz` архив с именем вида:

```
myproject_2026-04-17_03-00-00.tar.gz
```

Внутри архива:

```
backup_meta.json      — метаданные (проект, версия, timestamp, что включено)
db_dump.dump          — дамп PostgreSQL (или .sql для MySQL, .archive для MongoDB)
.env                  — файл переменных окружения
project_dir.tar.gz    — архив директории проекта
```

Любой из компонентов может отсутствовать — в зависимости от настроек.

## Настройка S3

Работает с любым S3-совместимым хранилищем. При настройке потребуется:

| Параметр | Пример |
|---|---|
| Endpoint URL | `https://s3.timeweb.cloud` |
| Region | `ru-1` |
| Bucket | `my-backups` |
| Access Key | `...` |
| Secret Key | `...` |
| Prefix (опционально) | `myproject/` |

Для AWS S3 endpoint можно оставить пустым.

## Настройка Google Drive

1. Создать проект в [Google Cloud Console](https://console.cloud.google.com/)
2. Включить Google Drive API
3. Создать OAuth 2.0 credentials (тип: Desktop app)
4. Скопировать Client ID и Client Secret
5. Вставить в wizard или меню настроек — скрипт откроет ссылку для авторизации и сохранит Refresh Token

## Автоматический бэкап (cron)

Настройка через меню `Настройка расписания`. Требует root.

Доступные варианты:
- **Ежечасно** — каждый час в 00 минут
- **Ежедневно** — одно или несколько конкретных времён (UTC)

Пример crontab-записи для бэкапа в 03:00 UTC:

```
0 3 * * * /opt/universal-backup/backup.sh backup
```

## Восстановление

```bash
./backup.sh restore
```

Или через меню → `Восстановление из бэкапа`.

Источники:
- **Локальные файлы** — из директории `CFG_BACKUP_DIR`
- **S3** — скачивает выбранный архив и разворачивает

При восстановлении скрипт интерактивно спрашивает:
- Восстанавливать ли БД, и в какой контейнер / на какой хост
- Восстанавливать ли `.env`, и по какому пути
- Восстанавливать ли директорию проекта

## Конфиг-файл

Файл `backup.cfg` хранит все настройки в формате bash-переменных. Создаётся wizard'ом, редактируется через меню или вручную.

Права на файл автоматически выставляются `600`.

Основные переменные:

```bash
CFG_PROJECT_NAME="myproject"
CFG_PROJECT_DIR="/opt/myproject"
CFG_PROJECT_ENV="/opt/myproject/.env"
CFG_BACKUP_DIR="/var/backups/universal-backup"
CFG_RETENTION_DAYS="30"

CFG_DB_TYPE="docker"          # none | docker | external
CFG_DB_ENGINE="postgres"      # postgres | mysql | mongodb
CFG_DB_CONTAINER="myproject_db"
CFG_DB_USER="postgres"
CFG_DB_NAME="myproject"

CFG_UPLOAD_METHOD="s3"        # telegram | s3 | google_drive

CFG_S3_ENDPOINT="https://s3.timeweb.cloud"
CFG_S3_BUCKET="my-backups"
CFG_S3_PREFIX="myproject/"
CFG_S3_RETENTION_DAYS="30"

CFG_BOT_TOKEN="..."
CFG_CHAT_ID="..."
```

## Структура файлов

```
backup.sh               — точка входа
backup.cfg              — конфиг (создаётся при первом запуске)
modules/
  utils.sh              — логирование, цвета, helpers
  config.sh             — загрузка/сохранение конфига, wizard
  telegram.sh           — Telegram Bot API
  s3.sh                 — AWS CLI: upload, download, cleanup
  google_drive.sh       — Google Drive OAuth2 + upload
  db.sh                 — дамп/восстановление БД
  backup.sh             — логика создания архива
  restore.sh            — интерактивное восстановление
  cron.sh               — управление расписанием
  update.sh             — самообновление скрипта
  settings.sh           — меню настроек
translations/
  en.sh
  ru.sh
```

## Обновление

Через меню → `Обновление скрипта`. Требует root.

Скрипт сравнивает версии, предлагает обновиться, создаёт резервную копию текущего скрипта и заменяет его. При ошибке автоматически восстанавливает предыдущую версию.

Для подключения автообновления к своему репозиторию замените в `modules/update.sh`:

```bash
GITHUB_RAW_URL="https://raw.githubusercontent.com/YOUR_USERNAME/universal-backup/main/backup.sh"
GITHUB_API_URL="https://api.github.com/repos/YOUR_USERNAME/universal-backup/releases/latest"
```

## Лицензия

MIT
