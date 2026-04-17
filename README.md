<div align="center">

# Universal Backup & Restore

**Один скрипт для бэкапа нескольких проектов на VPS**

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

При первом запуске откроется мастер: язык, Telegram, первый проект, БД, способ отправки.

Скрипт сам создаёт рабочую структуру:

- Для `root`: `/var/lib/universal-backup/`
- Для обычного пользователя: `~/.local/share/universal-backup/`
- Глобальный конфиг: `.../config/backup.cfg`
- Профили проектов: `.../config/projects/*.cfg`
- Локальные архивы: `.../backups/`

Если запуск под `root`, автоматически создаются ссылки:

- `/usr/local/bin/backrest`
- `/usr/local/bin/backup` (обратная совместимость)

---

## Что умеет

| | Поддержка |
|---|---|
| **Проекты** | Несколько независимых профилей, переключение/добавление/удаление из меню |
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
backrest

# Создать бэкап активного проекта (без меню)
backrest backup

# Восстановление
backrest restore

# Создать бэкап конкретного проекта
backrest --project project_id backup

# Использовать другой глобальный конфиг
backrest --config /opt/universal-backup/config/backup.cfg
```

> `backup` тоже работает, но рекомендуем основной алиас `backrest`.

---

## Мультипроектный режим

Управление через меню:

`Настройка конфигурации` → `Настройки проекта`

Доступно:

- Редактирование активного проекта
- Переключение активного проекта
- Добавление нового проекта
- Удаление проекта
- Список всех проектов

Идентификатор активного проекта отображается в главном меню и используется в cron-командах.

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

```text
myproject_2026-04-17_03-00-00.tar.gz
├── backup_meta.json       # метаданные (проект, версия, timestamp)
├── db_dump.dump           # PostgreSQL (.sql для MySQL, .archive для MongoDB)
├── .env                   # переменные окружения
└── project_dir.tar.gz     # архив директории проекта
```

Любой компонент может отсутствовать в зависимости от настроек проекта.

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

## Автоматический бэкап (cron)

Настройка через меню `Настройка расписания` (требует root).

| Вариант | Расписание |
|---|---|
| Ежечасно | `0 * * * *` |
| Ежедневно | Одно или несколько времён UTC |

Скрипт создаёт cron-записи с привязкой к активному проекту:

```text
0 3 * * * /usr/local/bin/backrest --project support backup # universal-backup: support
0 15 * * * /usr/local/bin/backrest --project support backup # universal-backup: support
```

---

## Восстановление

```bash
backrest restore
```

Источники:

- Локальные файлы из директории бэкапов
- S3 (скачивает выбранный архив)

При восстановлении скрипт интерактивно спрашивает что восстанавливать: БД, `.env`, директорию проекта — каждый пункт отдельно, с выбором пути.

---

## Конфигурация

Схема хранения:

- **Глобальный конфиг**: язык, Telegram, автообновление, активный проект
- **Конфиг проекта**: БД, пути проекта, S3/GDrive, retention и т.д.

Права на файлы конфигурации — `600`.

<details>
<summary>Пример глобального конфига (<code>config/backup.cfg</code>)</summary>

```bash
CFG_VERSION=1.0.0
CFG_LANG=ru
CFG_AUTO_UPDATE=true
CFG_ACTIVE_PROJECT=support
PROJECTS_DIR=/var/lib/universal-backup/config/projects

CFG_BOT_TOKEN=123456:ABC...
CFG_CHAT_ID=-100...
CFG_THREAD_ID=''
CFG_TG_PROXY=''
```

</details>

<details>
<summary>Пример профиля проекта (<code>config/projects/support.cfg</code>)</summary>

```bash
CFG_PROJECT_NAME=support
CFG_PROJECT_DIR=/opt/support
CFG_PROJECT_ENV=/opt/support/.env
CFG_BACKUP_DIR=/var/lib/universal-backup/backups
CFG_RETENTION_DAYS=30
CFG_BACKUP_ENV=true
CFG_BACKUP_DIR_ENABLED=true

CFG_DB_TYPE=docker          # none | docker | external
CFG_DB_ENGINE=postgres      # postgres | mysql | mongodb
CFG_DB_CONTAINER=postgres
CFG_DB_USER=postgres
CFG_DB_NAME=support

CFG_UPLOAD_METHOD=s3        # telegram | s3 | google_drive
CFG_S3_ENDPOINT=https://s3.timeweb.cloud
CFG_S3_BUCKET=my-backups
CFG_S3_PREFIX=support/
CFG_S3_RETENTION_DAYS=30
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
