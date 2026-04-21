<h1 align="center">BACKREST - BACKUP & RESTORE</h1>

<p align="center">
  Один скрипт для бэкапа нескольких проектов на Linux-сервере
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License"></a>
  <img src="https://img.shields.io/badge/Shell-Bash%204%2B-4EAA25?logo=gnubash&logoColor=white" alt="Shell">
  <img src="https://img.shields.io/badge/Version-1.0.0-orange" alt="Version">
  <img src="https://img.shields.io/badge/Platform-Linux-FCC624?logo=linux&logoColor=black" alt="Platform">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/PostgreSQL-supported-4169E1?logo=postgresql&logoColor=white" alt="PostgreSQL">
  <img src="https://img.shields.io/badge/MySQL-supported-4479A1?logo=mysql&logoColor=white" alt="MySQL">
  <img src="https://img.shields.io/badge/MongoDB-supported-47A248?logo=mongodb&logoColor=white" alt="MongoDB">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/S3-compatible-FF9900?logo=amazons3&logoColor=white" alt="S3">
  <img src="https://img.shields.io/badge/Telegram-notifications-26A5E4?logo=telegram&logoColor=white" alt="Telegram">
  <img src="https://img.shields.io/badge/Google%20Drive-supported-4285F4?logo=googledrive&logoColor=white" alt="Google Drive">
</p>

---

## Быстрый старт

```bash
curl -o ~/backrest https://raw.githubusercontent.com/sterben-enec/backrest/main/backup-restore.sh \
  && chmod +x ~/backrest \
  && ~/backrest
```

При первом запуске откроется мастер настройки: язык, Telegram, первый проект, БД, способ отправки.

После установки (под `root`) доступны команды:

```bash
backrest          # интерактивное меню
backrest backup   # создать бэкап без меню
backrest restore  # восстановление
```

---

## Возможности

| Категория | Что поддерживается |
|---|---|
| **Базы данных** | PostgreSQL, MySQL / MariaDB, MongoDB |
| **Подключение к БД** | Docker-контейнер, внешний хост |
| **Хранилища** | S3-совместимые (AWS, Yandex, Timeweb, MinIO...), Google Drive |
| **Бэкап файлов** | Директория проекта целиком или выборочно (папки / файлы) |
| **Уведомления** | Telegram — статус каждого бэкапа и восстановления |
| **Расписание** | Встроенное управление cron (можно включить одновременно `ежечасно` и `ежедневно`, час 1-24) |
| **Ротация** | Единая политика хранения для локальных файлов, S3 и Google Drive (`weekly/monthly` или срок в днях) |
| **Проекты** | Несколько независимых профилей, переключение из меню |
| **Языки** | Русский, English |
| **Обновление** | Самообновление из GitHub через меню |

---

## Использование

```bash
# Интерактивное меню
backrest

# Создать бэкап активного проекта
backrest backup

# Восстановление
backrest restore

# Бэкап конкретного проекта
backrest --project project_id backup

# Другой конфиг
backrest --config /opt/universal-backup/config/backup.cfg
```

> Алиас `backup` тоже работает, но рекомендуется `backrest`.

---

## Структура рабочей директории

```
/var/lib/universal-backup/          # root
~/.local/share/universal-backup/    # обычный пользователь
├── config/
│   ├── backup.cfg                  # глобальный конфиг
│   └── projects/
│       ├── support.cfg             # профиль проекта
│       └── store.cfg
└── backups/
    └── support_2026-04-17_03-00-00.tar.gz
```

Ссылки `/usr/local/bin/backrest` и `/usr/local/bin/backup` создаются автоматически при запуске под `root`.

---

## Структура архива

Каждый бэкап — один `.tar.gz` файл:

```
myproject_2026-04-17_03-00-00.tar.gz
├── backup_meta.json       # метаданные (проект, версия, timestamp)
├── db_dump.dump           # дамп БД (.sql для MySQL, .archive для MongoDB)
└── project_dir.tar.gz     # архив директории проекта
```

Любой компонент может отсутствовать в зависимости от настроек.

---

## Конфигурация

### Глобальный конфиг (`config/backup.cfg`)

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

### Профиль проекта (`config/projects/support.cfg`)

```bash
CFG_PROJECT_NAME=support
CFG_PROJECT_DIR=/opt/support
CFG_BACKUP_DIR=/var/lib/universal-backup/backups
CFG_SCHEDULE_HOURLY_ENABLED=true
CFG_SCHEDULE_DAILY_ENABLED=false
CFG_RETENTION_DAILY_HOUR=3        # 1-24
CFG_TELEGRAM_SEND_MODE=weekly     # hourly | weekly
CFG_BACKUP_DIR_ENABLED=true
CFG_BACKUP_DIR_MODE=full       # full | selected
CFG_BACKUP_DIR_ITEMS=''        # список путей при selected

CFG_DB_TYPE=docker             # none | docker | external
CFG_DB_ENGINE=postgres         # postgres | mysql | mongodb
CFG_DB_CONTAINER=postgres
CFG_DB_USER=postgres
CFG_DB_NAME=support

CFG_UPLOAD_METHOD=google_drive            # один или несколько: s3,google_drive
CFG_S3_ENDPOINT=https://s3.timeweb.cloud
CFG_S3_BUCKET=my-backups
CFG_S3_PREFIX=support/
CFG_STORAGE_KEEP_WEEKLY=true
CFG_STORAGE_KEEP_MONTHLY=true
CFG_RETENTION_DAYS=30              # когда weekly/monthly выключены
```

Права на файлы конфигурации — `600`.

---

## Политика хранения

Единая политика применяется к:
- локальным архивам;
- S3;
- Google Drive.

Telegram не участвует в очистке: используется только для уведомлений.

### Что настраивается

| Блок | Параметр | Варианты |
|---|---|---|
| Расписание | Ежечасные бэкапы | `on/off` |
| Расписание | Ежедневные бэкапы | `on/off` |
| Расписание | Час ежедневного бэкапа | `1-24` (где `24` = `00:00`) |
| Telegram | Режим отправки | `hourly` / `weekly` |
| Retention | Хранить недельные | `true` / `false` |
| Retention | Хранить месячные | `true` / `false` |
| Retention | Дней хранения | число (`1+`) |

### Как это работает простыми словами

1. Очистка по политике запускается только для автоматических (cron) бэкапов.
2. Если включены `weekly/monthly`, остаются последние бэкапы за неделю и/или месяц, остальное удаляется.
3. Если `weekly=false` и `monthly=false`, работает хранение по дням: всё старше `CFG_RETENTION_DAYS` удаляется.
4. Ручные бэкапы в политику не включаются: они сохраняются с маркером `*_manual_*` и не удаляются retention.
5. Telegram не чистится: он используется только для уведомлений.

### Параметры конфига

```bash
# Расписание
CFG_SCHEDULE_HOURLY_ENABLED=true   # true | false
CFG_SCHEDULE_DAILY_ENABLED=false   # true | false
CFG_RETENTION_DAILY_HOUR=3         # 1-24

# Telegram
CFG_TELEGRAM_SEND_MODE=weekly      # hourly | weekly

# Единая политика хранения
CFG_STORAGE_KEEP_WEEKLY=true       # true | false
CFG_STORAGE_KEEP_MONTHLY=true      # true | false
CFG_RETENTION_DAYS=30              # число дней, когда weekly/monthly выключены
```

---

## Настройка хранилищ

<details>
<summary><b>S3-совместимое хранилище</b></summary>

Работает с любым S3-совместимым провайдером: AWS, Yandex Cloud, Timeweb, MinIO и др.

| Параметр | Пример |
|---|---|
| Endpoint URL | `https://s3.timeweb.cloud` |
| Region | `ru-1` |
| Bucket | `my-backups` |
| Access Key | `AKID...` |
| Secret Key | `...` |
| Prefix | `myproject/` (опционально) |

Для AWS S3 endpoint можно оставить пустым.

</details>

<details>
<summary><b>Google Drive</b></summary>

1. Создать проект в [Google Cloud Console](https://console.cloud.google.com/)
2. Включить **Google Drive API**
3. Создать **OAuth 2.0 credentials** (тип: Desktop app)
4. Вставить Client ID и Client Secret в мастер настройки
5. Перейти по ссылке в браузере, авторизоваться, вставить код — Refresh Token сохранится автоматически

</details>

---

## Автоматический бэкап (cron)

Настраивается через меню `Настройка расписания` (требует root):  
- можно отдельно включать `Ежечасно` и `Ежедневно`;
- для ежедневного задаётся час `1-24` (по UTC+0);
- Telegram работает по этому же стандартному расписанию:
  - `hourly` — отправка при каждом запуске;
  - `weekly` — отправка в недельный слот (воскресенье, час `CFG_RETENTION_DAILY_HOUR`, UTC).
- именно cron-запуск применяет политику хранения (ретеншн).

```
0 * * * *  /usr/local/bin/backrest --project support backup  # universal-backup: support (ежечасно)
0 3 * * *  /usr/local/bin/backrest --project support backup  # universal-backup: support (ежедневно, 03:00 UTC)
```

---

## Требования

| Инструмент | Когда нужен |
|---|---|
| `bash >= 4` | обязательно |
| `tar`, `gzip`, `curl` | обязательно |
| `docker` | при Docker-БД |
| `aws` CLI | при S3 (устанавливается автоматически) |
| `pg_dump` / `mysqldump` / `mongodump` | при внешней БД |

---

## Лицензия

[MIT](LICENSE)
