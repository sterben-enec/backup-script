#!/usr/bin/env bash
# VERSION=1.0.0
#
# Universal Backup & Restore
# Поддерживает: PostgreSQL, MySQL/MariaDB, MongoDB (Docker или external)
# Хранилища: Telegram, S3-compatible, Google Drive
# Лицензия: MIT
#
# Использование:
#   ./backup.sh              — интерактивное меню
#   ./backup.sh backup       — создать бэкап немедленно (для cron)
#   ./backup.sh restore      — восстановление
#   ./backup.sh --config /path/to/config.cfg
#
set -euo pipefail

# ─────────────────────────────────────────────
# Разобрать аргументы (предварительный проход для COMMAND)
# ─────────────────────────────────────────────
_PRECHECK_COMMAND=""
for _arg in "$@"; do
    if [[ "$_arg" == "backup" || "$_arg" == "restore" ]]; then
        _PRECHECK_COMMAND="$_arg"
        break
    fi
done

# Если stdin не является TTY и команда не задана — отказать во избежание
# silent crash от `read` при set -e в неинтерактивной среде (cron, CI)
if [[ -z "$_PRECHECK_COMMAND" ]] && ! [[ -t 0 ]]; then
    echo "[ERROR] Интерактивный режим требует TTY. Для cron используйте: $(basename "$0") backup" >&2
    exit 1
fi
unset _PRECHECK_COMMAND _arg

# ─────────────────────────────────────────────
# Пути
# ─────────────────────────────────────────────
BACKUP_SCRIPT="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$BACKUP_SCRIPT")"
SCRIPT_VERSION="$(grep -m1 '^# VERSION=' "$BACKUP_SCRIPT" | cut -d= -f2)"

# Конфиг по умолчанию — рядом со скриптом
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/backup.cfg}"

# ─────────────────────────────────────────────
# Разобрать аргументы
# ─────────────────────────────────────────────
COMMAND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        backup|restore)
            COMMAND="$1"
            shift
            ;;
        --help|-h)
            cat <<EOF
Universal Backup & Restore v${SCRIPT_VERSION}

Использование:
  $(basename "$0")                         Интерактивное меню
  $(basename "$0") backup                  Создать бэкап (для cron)
  $(basename "$0") restore                 Интерактивное восстановление
  $(basename "$0") --config /path/cfg      Указать конфиг-файл

Переменные окружения:
  CONFIG_FILE    Путь к конфиг-файлу (по умолчанию: рядом со скриптом)
EOF
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# ─────────────────────────────────────────────
# Загрузить модули
# ─────────────────────────────────────────────
_load_modules() {
    local modules=(
        utils
        config
        telegram
        s3
        google_drive
        db
        backup
        restore
        cron
        update
        settings
    )
    for mod in "${modules[@]}"; do
        local mod_file="${SCRIPT_DIR}/modules/${mod}.sh"
        if [[ -f "$mod_file" ]]; then
            # shellcheck source=/dev/null
            source "$mod_file"
        else
            echo "[ERROR] Модуль не найден: $mod_file" >&2
            exit 1
        fi
    done
}

_load_modules

# ─────────────────────────────────────────────
# Загрузить язык (по умолчанию EN до загрузки конфига)
# ─────────────────────────────────────────────
load_language "en"

# ─────────────────────────────────────────────
# Загрузить или создать конфиг
# ─────────────────────────────────────────────
if [[ -f "$CONFIG_FILE" ]]; then
    load_config "$CONFIG_FILE"
    load_language "$CFG_LANG"
else
    # Первый запуск — wizard
    initial_setup "$CONFIG_FILE"
    load_language "$CFG_LANG"
fi

# Создать директорию для бэкапов если не существует
mkdir -p "$CFG_BACKUP_DIR" 2>/dev/null || true

# ─────────────────────────────────────────────
# Настроить symlink /usr/local/bin/backup
# ─────────────────────────────────────────────
_setup_symlink() {
    local symlink="/usr/local/bin/backup"
    [[ $EUID -ne 0 ]] && return
    if [[ ! -L "$symlink" ]] || [[ "$(readlink "$symlink")" != "$BACKUP_SCRIPT" ]]; then
        if ln -sf "$BACKUP_SCRIPT" "$symlink" 2>/dev/null; then
            log_info "${L[symlink_created]} ($symlink → $BACKUP_SCRIPT)"
        fi
    fi
}
_setup_symlink

# Фоновая проверка обновлений
check_update_bg &

# ─────────────────────────────────────────────
# Не-интерактивные команды (для cron и CI)
# ─────────────────────────────────────────────
if [[ -n "$COMMAND" ]]; then
    case "$COMMAND" in
        backup)
            do_backup
            exit $?
            ;;
        restore)
            do_restore
            exit $?
            ;;
    esac
fi

# ─────────────────────────────────────────────
# Интерактивное главное меню
# ─────────────────────────────────────────────
_main_menu() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
        printf  "${BOLD}║   %-40s║${NC}\n" "${L[menu_title]}"
        printf  "${BOLD}║   %-40s║${NC}\n" "${L[menu_version]} ${SCRIPT_VERSION}"
        echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
        echo ""

        # Статус
        echo -e "  ${L[menu_project]} ${CYAN}${CFG_PROJECT_NAME:-${L[not_set]}}${NC}"
        case "$CFG_DB_TYPE" in
            docker)   echo -e "  ${L[menu_db_docker]} (${CFG_DB_ENGINE})" ;;
            external) echo -e "  ${L[menu_db_ext]} (${CFG_DB_ENGINE}@${CFG_DB_HOST})" ;;
            *)        echo -e "  ${L[menu_db_none]}" ;;
        esac
        echo ""
        echo -e "  ${L[ul_title]}: ${YELLOW}${CFG_UPLOAD_METHOD}${NC}"
        echo ""

        echo "────────────────────────────────────────────"
        echo "  1. ${L[menu_create_backup]}"
        echo "  2. ${L[menu_restore]}"
        echo "  3. ${L[menu_auto_send]}"
        echo "  4. ${L[menu_upload_method]}"
        echo "  5. ${L[menu_settings]}"
        echo "  6. ${L[menu_update]}"
        echo "  7. ${L[menu_remove]}"
        echo "  0. ${L[exit]}"
        echo "────────────────────────────────────────────"
        [[ -n "$BACKUP_SCRIPT" ]] && echo -e "  ${L[menu_shortcut]} ${CYAN}backup${NC}"
        echo ""
        read -rp "${L[select_option]}" choice

        case "$choice" in
            1)
                do_backup
                press_enter_back
                ;;
            2)
                do_restore
                press_enter_back
                ;;
            3)
                cron_menu
                ;;
            4)
                echo ""
                echo "${L[ul_title]}"
                echo "  ${L[ul_current]} ${CFG_UPLOAD_METHOD}"
                echo ""
                echo "  1. ${L[ul_set_tg]}"
                echo "  2. ${L[ul_set_s3]}"
                echo "  3. ${L[ul_set_gd]}"
                echo "  0. ${L[back]}"
                read -rp "${L[select_option]}" ul_choice
                case "$ul_choice" in
                    1) CFG_UPLOAD_METHOD="telegram"; log_info "${L[ul_tg_set]}" ;;
                    2) setup_s3_config ;;
                    3) setup_gd_config ;;
                esac
                save_config "$CONFIG_FILE"
                press_enter
                ;;
            5)
                settings_menu
                ;;
            6)
                do_update
                ;;
            7)
                do_remove
                ;;
            0)
                echo "${L[exit_dots]}"
                exit 0
                ;;
            *)
                log_warn "${L[invalid_input_select]}"
                sleep 1
                ;;
        esac
    done
}

_main_menu
