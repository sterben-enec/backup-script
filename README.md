<div align="center">

# Universal Backup & Restore

**Один скрипт для бэкапа любого проекта на VPS**

PostgreSQL / MySQL / MongoDB | Docker / External DB | S3 / Telegram / Google Drive

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash%204%2B-green.svg)](#требования)

</div>

---

## Установка

```bash
curl -o ~/backup-restore.sh https://raw.githubusercontent.com/sterben-enec/backup-script/main/backup-restore.sh \
  && chmod +x ~/backup-restore.sh \
  && ~/backup-restore.sh
```

При первом запуске откроется мастер настройки — язык, Telegram, проект, БД, способ отправки. Конфиг сохраняется в `backup.cfg` рядом со скриптом.

---

## Что умеет

| | Поддержка |
|---|---|
| **Базы данных** | PostgreSQL, MySQL / MariaDB, MongoDB |
| **Подключение к БД** | Docker-контейнер или внешний хост |
| **Что бэкапится** | Дамп БД + `.env` + директория проекта (каждый пункт опционален) |
| **Хранилища** | S3-совместимые (AWS, Yandex, Timeweb, MinIO и др.), Telegram, Google Drive |
| **Уведомления** | Telegram — статус каждого бэкапа / восстановления |
| **Автоматизация** | Встроенное управление cron (ежечасно / ежедневно / произвольное время) |
| **Ротация** | Автоудаление старых бэкапов локально и в S3 |
| **Восстановление** | Интерактивный выбор из локальных файлов или S3 |
| **Языки** | Русский, English |
| **Обновление** | Самообновление из GitHub через меню |

---

## Использование

```bash
# Интерактивное меню
~/backup-restore.sh

# Создать бэкап (для cron, без меню)
~/backup-restore.sh backup

# Восстановление
~/backup-restore.sh restore

# Указать другой конфиг
~/backup-restore.sh --config /opt/myproject/backup.cfg
```

> При наличии прав root создаётся симлинк `/usr/local/bin/backup` — запуск из любого места командой `backup`.

---

## Требования

| Инструмент | Нужен | Для чего |
|---|:---:|---|
| `bash` >= 4 | **да** | Выполнение скрипта |
| `tar`, `gzip`, `curl` | **да** | Архивирование, API-запросы |
| `docker` | при Docker-БД | Дамп / восстановление из контейнера |
| `aws` CLI | при S3 | Устанавливается автоматически |
| `pg_dump` / `mysqldump` / `mongodump` | при внешней БД | Дамп без Docker |

---

## Структура бэкапа

Каждый бэкап — `.tar.gz` архив:

```
myproject_2026-04-17_03-00-00.tar.gz
├── backup_meta.json       # метаданные (проект, версия, timestamp)
├── db_dump.dump           # PostgreSQL (.sql для MySQL, .archive для MongoDB)
├── .env                   # переменные окружения
└── project_dir.tar.gz     # архив директории проекта
```

Любой компонент может отсутствовать в зависимости от настроек.

---

## Настройка S3

Работает с любым S3-совместимым хранилищем:

| Параметр | Пример |
|---|---|
| Endpoint URL | `https://s3.timeweb.cloud` |
| Region | `ru-1` |
| Bucket | `my-backups` |
| Access Key | `AKID...` |
| Secret Key | `...` |
| Prefix | `myproject/` (опционально) |

Для AWS S3 endpoint можно оставить пустым.

---

## Настройка Google Drive

1. Создать проект в [Google Cloud Console](https://console.cloud.google.com/)
2. Включить **Google Drive API**
3. Создать **OAuth 2.0 credentials** (тип: Desktop app)
4. Вставить Client ID и Client Secret в мастер настройки
5. Перейти по ссылке в браузере, авторизоваться, вставить код — Refresh Token сохранится автоматически

---

## Автоматический бэкап

Настройка через меню `Настройка расписания` (требует root).

| Вариант | Расписание |
|---|---|
| Ежечасно | `0 * * * *` |
| Ежедневно | Одно или несколько времён UTC |

Пример для бэкапа в 03:00 и 15:00 UTC:

```
0 3 * * * /root/backup-restore.sh backup
0 15 * * * /root/backup-restore.sh backup
```

---

## Восстановление

```bash
~/backup-restore.sh restore
```

Источники:
- **Локальные файлы** — из директории бэкапов
- **S3** — скачивает выбранный архив

При восстановлении скрипт интерактивно спрашивает что восстанавливать: БД, `.env`, директорию проекта — каждый пункт отдельно, с выбором пути.

---

## Конфигурация

Файл `backup.cfg` создаётся мастером, редактируется через меню или вручную. Права `600`.

<details>
<summary>Пример конфигурации</summary>

```bash
CFG_PROJECT_NAME=myproject
CFG_PROJECT_DIR=/opt/myproject
CFG_PROJECT_ENV=/opt/myproject/.env
CFG_BACKUP_DIR=/var/backups/universal-backup
CFG_RETENTION_DAYS=30

CFG_DB_TYPE=docker          # none | docker | external
CFG_DB_ENGINE=postgres      # postgres | mysql | mongodb
CFG_DB_CONTAINER=myproject_db
CFG_DB_USER=postgres
CFG_DB_NAME=myproject

CFG_UPLOAD_METHOD=s3        # telegram | s3 | google_drive

CFG_S3_ENDPOINT=https://s3.timeweb.cloud
CFG_S3_BUCKET=my-backups
CFG_S3_PREFIX=myproject/
CFG_S3_RETENTION_DAYS=30

CFG_BOT_TOKEN=123456:ABC...
CFG_CHAT_ID=-100...
```

</details>

---

## Обновление

Через меню → **Обновление скрипта** (требует root).

Скрипт проверяет версию на GitHub, предлагает обновиться, создаёт резервную копию текущего файла и заменяет его. При ошибке автоматически откатывается.

---

## Вдохновлено

[distillium/remnawave-backup-restore](https://github.com/distillium/remnawave-backup-restore) — отличный скрипт для Remnawave. Universal Backup — это его идея, расширенная до универсального инструмента для любого проекта.

---

## Лицензия

[MIT](LICENSE)
