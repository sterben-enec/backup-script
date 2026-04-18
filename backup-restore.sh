#!/usr/bin/env bash
# VERSION=1.0.0
#
# Universal Backup & Restore
# Поддерживает: PostgreSQL, MySQL/MariaDB, MongoDB (Docker или external)
# Хранилища: Telegram, S3-compatible, Google Drive
# Лицензия: MIT
#
# Использование:
#   ./backup-restore.sh                    — интерактивное меню
#   ./backup-restore.sh backup             — создать бэкап немедленно (для cron)
#   ./backup-restore.sh restore            — восстановление
#   ./backup-restore.sh --config /path/to/config.cfg
#   ./backup-restore.sh --project PROJECT backup
#
# GitHub: https://github.com/sterben-enec/backup-script
#
set -euo pipefail

# ─────────────────────────────────────────────
# Разобрать аргументы (предварительный проход для COMMAND)
# ─────────────────────────────────────────────
_PRECHECK_COMMAND=""
_PRECHECK_HELP="false"
for _arg in "$@"; do
    if [[ "$_arg" == "backup" || "$_arg" == "restore" ]]; then
        _PRECHECK_COMMAND="$_arg"
        break
    elif [[ "$_arg" == "--help" || "$_arg" == "-h" ]]; then
        _PRECHECK_HELP="true"
    fi
done

# Если stdin не является TTY и команда не задана — отказать во избежание
# silent crash от `read` при set -e в неинтерактивной среде (cron, CI)
if [[ -z "$_PRECHECK_COMMAND" && "$_PRECHECK_HELP" != "true" ]] && ! [[ -t 0 ]]; then
    echo "[ERROR] Интерактивный режим требует TTY. Для cron используйте: $(basename "$0") backup" >&2
    exit 1
fi
unset _PRECHECK_COMMAND _PRECHECK_HELP _arg

# ─────────────────────────────────────────────
# Пути
# ─────────────────────────────────────────────
BACKUP_SCRIPT="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$BACKUP_SCRIPT")"
SCRIPT_VERSION="$(grep -m1 '^# VERSION=' "$BACKUP_SCRIPT" | cut -d= -f2)"
SCRIPT_AUTHOR="${SCRIPT_AUTHOR:-sterben-enec}"

# Рабочие директории по умолчанию (самодостаточный режим)
if [[ $EUID -eq 0 ]]; then
    DEFAULT_BACKREST_HOME="/var/lib/universal-backup"
else
    DEFAULT_BACKREST_HOME="${HOME}/.local/share/universal-backup"
fi
BACKREST_HOME="${BACKREST_HOME:-$DEFAULT_BACKREST_HOME}"
DEFAULT_CONFIG_DIR="${BACKREST_CONFIG_DIR:-${BACKREST_HOME}/config}"
DEFAULT_PROJECTS_DIR="${BACKREST_PROJECTS_DIR:-${DEFAULT_CONFIG_DIR}/projects}"
DEFAULT_BACKUP_DIR="${BACKREST_BACKUP_DIR:-${BACKREST_HOME}/backups}"

# Основной конфиг и директория проектов
CONFIG_FILE="${CONFIG_FILE:-${DEFAULT_CONFIG_DIR}/backup.cfg}"
PROJECTS_DIR="${PROJECTS_DIR:-$DEFAULT_PROJECTS_DIR}"
CLI_PROJECT=""

# ─────────────────────────────────────────────
# Разобрать аргументы
# ─────────────────────────────────────────────
COMMAND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            [[ $# -lt 2 ]] && { echo "[ERROR] Missing value for --config" >&2; exit 1; }
            CONFIG_FILE="$2"
            shift 2
            ;;
        --project)
            [[ $# -lt 2 ]] && { echo "[ERROR] Missing value for --project" >&2; exit 1; }
            CLI_PROJECT="$2"
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
  $(basename "$0")                                Интерактивное меню
  $(basename "$0") backup                         Создать бэкап (для cron)
  $(basename "$0") restore                        Интерактивное восстановление
  $(basename "$0") --config /path/cfg             Указать конфиг-файл
  $(basename "$0") --project project_id backup    Запуск для конкретного проекта

Переменные окружения:
  CONFIG_FILE            Путь к конфиг-файлу
  BACKREST_HOME          Базовая директория данных скрипта
  BACKREST_CONFIG_DIR    Директория конфигов
  BACKREST_PROJECTS_DIR  Директория профилей проектов
  BACKREST_BACKUP_DIR    Директория локальных бэкапов
EOF
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Если передали --config, но PROJECTS_DIR явно не переопределяли — храним
# профили рядом с выбранным конфигом.
if [[ "${PROJECTS_DIR}" == "${DEFAULT_PROJECTS_DIR}" ]]; then
    PROJECTS_DIR="$(dirname "$CONFIG_FILE")/projects"
fi

###############################################################################
# MODULE: utils
###############################################################################
# Общие утилиты

# Цветовые коды — обнулять при отсутствии TTY (cron, CI), чтобы не было ANSI-мусора в логах
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "${CYAN}[>>]${NC} $*"; }

press_enter() {
    echo ""
    read -rp "${L[press_enter]}" _
}

press_enter_back() {
    echo ""
    read -rp "${L[press_enter_back]}" _
}

confirm() {
    # confirm "Вопрос?" → 0=yes, 1=no
    local msg="${1:-Продолжить?}"
    read -rp "${msg} ${L[yes_no]}" ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

MENU_CHOICE=""

# Универсальный селектор меню: визуальный курсор в списке (↑/↓ + Enter).
# Пример:
# _menu_select "1 2 0" "1" "Enable" "Disable" "Back"
# choice="$MENU_CHOICE"
_menu_select() {
    local options_str="$1"
    local default_choice="${2:-}"
    shift 2

    local -a options labels
    local idx=0 key seq typed=""
    local rendered=0
    MENU_CHOICE=""

    read -r -a options <<< "$options_str"
    labels=("$@")
    (( ${#options[@]} == 0 )) && return 1
    (( ${#labels[@]} != ${#options[@]} )) && return 1

    if [[ -n "$default_choice" ]]; then
        local i
        for i in "${!options[@]}"; do
            if [[ "${options[$i]}" == "$default_choice" ]]; then
                idx="$i"
                break
            fi
        done
    fi

    _menu_select_render() {
        local i marker
        (( rendered )) && printf "\033[%dA" "${#labels[@]}"
        for i in "${!labels[@]}"; do
            if (( i == idx )); then
                marker="${BOLD}${GREEN}>${NC}"
            else
                marker=" "
            fi
            printf "\r\033[2K  %s %s\n" "$marker" "${labels[$i]}"
        done
        rendered=1
    }

    while true; do
        _menu_select_render
        IFS= read -rsn1 key || { echo ""; return 1; }

        if [[ "$key" == $'\e' ]]; then
            seq=""
            while IFS= read -rsn1 -t 0.05 key; do
                seq+="$key"
                [[ "$key" =~ [A-Za-z~] ]] && break
            done
            case "$seq" in
                "[A"|"OA") idx=$(( (idx - 1 + ${#options[@]}) % ${#options[@]} )); typed="" ;;
                "[B"|"OB") idx=$(( (idx + 1) % ${#options[@]} )); typed="" ;;
                *) ;;
            esac
            continue
        fi

        if [[ -z "$key" || "$key" == $'\n' || "$key" == $'\r' ]]; then
            if [[ -n "$typed" ]]; then
                local opt
                for opt in "${options[@]}"; do
                    if [[ "$opt" == "$typed" ]]; then
                        MENU_CHOICE="$typed"
                        return 0
                    fi
                done
                typed=""
                continue
            fi
            MENU_CHOICE="${options[$idx]}"
            return 0
        fi

        if [[ "$key" =~ [0-9] ]]; then
            typed+="$key"
        fi
    done
}

# Форматирование размера файла
format_size() {
    local file="$1"
    if [[ -f "$file" ]]; then
        du -sh "$file" 2>/dev/null | cut -f1
    else
        echo "0"
    fi
}

# Текущая дата/время для имён файлов
timestamp() {
    date +"%Y-%m-%d_%H-%M-%S"
}

# Проверка, что команда доступна
require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Команда '$cmd' не найдена. Установите её и повторите."
        return 1
    fi
}

# Установить права 600 на файл
secure_file() {
    local file="$1"
    if ! chmod 600 "$file" 2>/dev/null; then
        log_warn "${L[chmod_error]} $file. ${L[check_permissions]}"
    fi
}

# Очистить временную директорию
cleanup_tmpdir() {
    local dir="$1"
    [[ -n "$dir" && -d "$dir" ]] && rm -rf "$dir"
}

# Ввод пути с валидацией
input_path() {
    local prompt="$1"
    local allow_empty="${2:-false}"
    local result=""
    while true; do
        read -rp "$prompt" result
        if [[ -z "$result" ]]; then
            if [[ "$allow_empty" == "true" ]]; then
                echo ""
                return 0
            fi
            log_warn "${L[cfg_path_empty]}"
            continue
        fi
        if [[ "$result" != /* ]]; then
            log_warn "${L[cfg_path_abs]}"
            continue
        fi
        echo "$result"
        return 0
    done
}

# Проверка наличия docker
check_docker() {
    if ! command -v docker &>/dev/null; then
        log_error "${L[docker_missing]}"
        if confirm "${L[docker_install_q]}"; then
            install_docker
        else
            log_warn "${L[docker_cancelled]}"
            return 1
        fi
    fi
}

install_docker() {
    if [[ $EUID -ne 0 ]]; then
        log_error "${L[symlink_root]}"
        return 1
    fi
    log_step "${L[docker_installing]}"
    curl -fsSL https://get.docker.com | bash
    if command -v docker &>/dev/null; then
        log_info "${L[docker_installed]}"
    else
        log_error "${L[docker_install_fail]}"
        return 1
    fi
}

# Установка jq
ensure_jq() {
    if command -v jq &>/dev/null; then return 0; fi
    log_step "${L[jq_installing]}"
    if [[ $EUID -ne 0 ]]; then
        log_error "${L[jq_root]}"
        return 1
    fi
    if command -v apt-get &>/dev/null; then
        apt-get install -y jq &>/dev/null && log_info "${L[jq_installed]}" && return 0
    fi
    log_error "${L[jq_no_apt]}"
    return 1
}

# Установка AWS CLI
ensure_awscli() {
    if command -v aws &>/dev/null; then return 0; fi
    log_step "${L[s3_installing_cli]}"
    if [[ $EUID -ne 0 ]]; then
        log_error "${L[s3_cli_root]}"
        return 1
    fi
    if command -v apt-get &>/dev/null; then
        apt-get install -y awscli &>/dev/null
        if command -v aws &>/dev/null; then
            log_info "${L[s3_cli_installed]}"
            return 0
        fi
    fi
    # Fallback: официальный установщик
    log_warn "${L[s3_cli_fallback]}"
    local tmp; tmp=$(mktemp -d)
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$tmp/awscliv2.zip" \
        && unzip -q "$tmp/awscliv2.zip" -d "$tmp" \
        && "$tmp/aws/install" \
        && log_info "${L[s3_cli_installed]}" \
        && cleanup_tmpdir "$tmp" \
        && return 0
    cleanup_tmpdir "$tmp"
    log_error "${L[s3_cli_fail]}"
    return 1
}

# Версия скрипта из заголовка
get_script_version() {
    local script="${BACKUP_SCRIPT:-$0}"
    grep -m1 '^# VERSION=' "$script" 2>/dev/null | cut -d= -f2
}

# Глобальный ассоциативный массив переводов
declare -gA L

###############################################################################
# TRANSLATIONS: English
###############################################################################
_load_lang_en() {

# General
L[select_option]="Select option: "
L[your_choice]="Your choice: "
L[invalid_input]="Invalid input."
L[invalid_input_select]="Invalid input. Please select one of the listed options."
L[press_enter]="Press Enter to continue..."
L[press_enter_back]="Press Enter to return to menu..."
L[press_enter_restart]="Press Enter to restart."
L[back]="Back"
L[back_to_menu]="Back to main menu"
L[exit]="Exit"
L[exit_dots]="Exiting..."
L[input_prompt]="Input: "
L[path_prompt]="Path: "
L[not_set]="Not set"
L[custom_path]="Custom path"
L[select_variant]="Select variant: "
L[saving_config]="Saving configuration to"
L[config_saved]="Configuration saved."
L[chmod_error]="Failed to set permissions (600) for"
L[check_permissions]="Check permissions."
L[yes_no]="(y/n): "

# Symlink
L[symlink_root]="Root permissions required to manage symlink"
L[symlink_skip]="Skipping setup."
L[symlink_ok]="Symlink already configured and points to"
L[symlink_creating]="Creating or updating symlink"
L[symlink_created]="Symlink successfully configured."
L[symlink_fail]="Failed to create symlink"
L[symlink_dir_missing]="Directory not found. Symlink not created."

# Docker
L[docker_missing]="Docker is not installed on this server."
L[docker_install_q]="Would you like to install Docker now?"
L[docker_installing]="Installing Docker..."
L[docker_installed]="Docker successfully installed."
L[docker_install_fail]="Error installing Docker."
L[docker_cancelled]="Operation cancelled."

# jq
L[jq_installing]="Installing jq package..."
L[jq_root]="Root permissions required to install jq. Install manually: sudo apt-get install jq"
L[jq_installed]="jq successfully installed."
L[jq_fail]="Failed to install jq."
L[jq_no_apt]="Package manager apt-get not found. Install jq manually."
L[jq_bad_usage]="Invalid usage. Available commands:"

# AWS CLI
L[s3_installing_cli]="Installing AWS CLI..."
L[s3_cli_root]="Root permissions required to install AWS CLI."
L[s3_cli_fail]="Failed to install AWS CLI."
L[s3_cli_no_pm]="Package manager not found. Install AWS CLI manually."
L[s3_cli_installed]="AWS CLI successfully installed."
L[s3_cli_fallback]="Package awscli unavailable, installing via official AWS installer..."
L[s3_aws_not_found]="AWS CLI not installed. Select S3 in settings for automatic installation."
L[ul_s3_aws_needed]="Failed to install AWS CLI. It is required for S3 support."

# Configuration
L[cfg_loading]="Loading configuration..."
L[cfg_loaded]="Configuration successfully loaded from"
L[cfg_install_fail]="Failed to create installation directory"
L[cfg_backup_fail]="Failed to create backup directory"
L[cfg_move_fail]="Failed to move script to"
L[cfg_new_saved]="New configuration saved to"
L[cfg_tg_not_configured]="Telegram not configured, notifications disabled."
L[cfg_tg_skip_hint]="Leave empty to skip, configure later in settings menu."
L[cfg_tg_skip_warn]="Without Telegram you won't receive backup notifications."
L[cfg_tg_setup]="Telegram notifications setup:"
L[cfg_create_bot]="Create a Telegram bot in @BotFather and get API Token"
L[cfg_enter_token]="Enter API Token: "
L[cfg_chatid_desc]="Enter group Chat ID or your Telegram ID"
L[cfg_chatid_help]="Get ID from @username_to_id_bot"
L[cfg_enter_chatid]="Enter ID: "
L[cfg_thread_info]="Optional: group topic ID (Message Thread ID)"
L[cfg_thread_empty]="Leave empty for main chat"
L[cfg_enter_thread]="Enter Message Thread ID: "

# Project settings
L[cfg_project_name]="Enter project name (used in backup filename): "
L[cfg_project_dir]="Enter path to project directory: "
L[cfg_project_env]="Path to .env file (Enter — skip): "
L[cfg_path_empty]="Path cannot be empty."
L[cfg_path_abs]="Path must be absolute (start with /)."
L[cfg_dir_missing]="Directory does not exist."
L[cfg_continue_path]="Continue with this path?"
L[cfg_custom_set]="Path set:"

# DB
L[cfg_db_skip]="Skip DB setup"
L[cfg_db_setup]="Database connection setup:"
L[cfg_db_container]="Docker container name with DB: "
L[cfg_db_type_prompt]="DB engine (postgres/mysql/mongodb, default postgres): "
L[cfg_enter_db_user]="DB username (default postgres): "
L[cfg_enter_db_name]="Database name (default postgres): "
L[cfg_enter_db_pass]="DB password (Enter — no password): "
L[cfg_db_ext_host]="DB host (for external DB): "
L[cfg_db_ext_port]="DB port (default 5432): "
L[cfg_db_ssl]="SSL mode — prefer/require/disable (default prefer): "
L[cfg_db_pgver]="PostgreSQL client version (13-17, default 17): "

# Google Drive
L[cfg_gd_incomplete]="Incomplete Google Drive data found."
L[cfg_gd_switch_tg]="Upload method will be switched to Telegram."
L[cfg_gd_missing]="Required Google Drive data missing."
L[cfg_gd_enter]="Enter missing Google Drive data:"
L[cfg_gd_no_tokens]="Don't have Client ID and Client Secret tokens?"
L[cfg_gd_guide]="Read the guide:"
L[cfg_enter_gd_id]="Enter Google Client ID: "
L[cfg_enter_gd_secret]="Enter Google Client Secret: "
L[cfg_gd_auth_needed]="Browser authorization required for Refresh Token."
L[cfg_gd_open_url]="Open the link in your browser, authorize and copy the code:"
L[cfg_gd_enter_code]="Enter code from browser: "
L[cfg_gd_getting]="Getting Refresh Token..."
L[cfg_gd_fail]="Failed to get Refresh Token."
L[cfg_gd_incomplete2]="Google Drive setup not complete, switching to Telegram."
L[cfg_gd_folder1]="To specify a Google Drive folder:"
L[cfg_gd_folder2]="1. Open the desired folder in your browser."
L[cfg_gd_folder3]="2. Copy the ID from the URL:"
L[cfg_gd_folder4]="3. ID is the part after /folders/"
L[cfg_gd_folder5]="Leave empty for root folder."
L[cfg_enter_gd_folder]="Enter Google Drive Folder ID (Enter — root): "
L[cfg_s3_incomplete]="Incomplete S3 Storage data found."
L[cfg_s3_switch_tg]="Upload method will be switched to Telegram."

# Telegram API
L[tg_send_err]="Error sending Telegram message. Code:"
L[tg_response]="Telegram response:"
L[tg_curl_err]="CURL error sending document. Code:"
L[tg_check_net]="Check your network connection."
L[tg_api_err]="Telegram API returned an error. Code:"
L[tg_resp_label]="Response:"
L[tg_maybe_big]="File may be too large or BOT_TOKEN/CHAT_ID are incorrect."

# Google Drive API
L[gd_not_set]="Google Drive Client ID, Client Secret or Refresh Token not configured."
L[gd_token_err]="Error getting Google Drive Access Token."
L[gd_upload_err]="Error uploading file to Google Drive."
L[gd_upload_ok]="File successfully uploaded to Google Drive."

# S3
L[s3_upload_err]="Error uploading file to S3."
L[s3_upload_ok]="File successfully uploaded to S3."
L[s3_cleaned]="Deleted old backups from S3: %s"

# Backup
L[bk_starting]="Starting backup process..."
L[bk_project]="Project:"
L[bk_skip_db]="Skipping DB backup."
L[bk_skip_dir]="Skipping project directory backup."
L[bk_creating_dump]="Creating DB dump..."
L[bk_dump_type]="DB engine:"
L[bk_dump_container]="Container:"
L[bk_dump_ok]="DB dump successfully created."
L[bk_dump_err]="Error creating DB dump. Exit code:"
L[bk_check_db]="Check container and DB settings."
L[bk_archiving_dir]="Archiving project directory"
L[bk_archiving_dir_selected]="Archiving selected files/folders from project directory"
L[bk_dir_ok]="Directory successfully archived."
L[bk_dir_err]="Error archiving directory."
L[bk_dir_missing]="Directory not found:"
L[bk_no_data]="No data to backup! Enable at least one source."
L[bk_final_err]="Error creating final archive. Exit code:"
L[bk_final_ok]="Final archive successfully created:"
L[bk_cleaning]="Cleaning intermediate files..."
L[bk_cleaned]="Intermediate files removed."
L[bk_sending]="Sending backup"
L[bk_tg_big]="Backup size (%s) exceeds Telegram limit (50 MB). File not sent."
L[bk_saved_local]="Backup saved locally:"
L[bk_tg_big_notify]="Backup created (%s), but not sent: Telegram 50 MB limit exceeded."
L[bk_tg_ok]="Backup successfully sent to Telegram."
L[bk_tg_err]="Error sending to Telegram."
L[bk_gd_ok]="Backup successfully uploaded to Google Drive."
L[bk_gd_notify_ok]="Success notification sent to Telegram."
L[bk_gd_notify_fail]="Failed to send notification to Telegram."
L[bk_gd_err]="Error sending to Google Drive."
L[bk_gd_err_tg]="Error: failed to send backup to Google Drive."
L[bk_s3_ok]="Backup successfully uploaded to S3."
L[bk_s3_err]="Error uploading to S3."
L[bk_s3_err_tg]="Error uploading backup to S3."
L[bk_s3_notify_ok]="Success notification sent to Telegram."
L[bk_s3_notify_fail]="Failed to send notification to Telegram."
L[bk_s3_impossible]="Backup file not found. Upload to S3 impossible."
L[bk_s3_retention]="Cleaning old S3 backups (older than %s days)..."
L[bk_s3_retention_ok]="S3 cleanup complete."
L[bk_unknown_method]="Unknown upload method:"
L[bk_not_sent]="Backup not sent."
L[bk_file_missing]="Final backup file not found:"
L[bk_impossible]="Sending impossible."
L[bk_gd_impossible]="Backup file not found. Upload to Google Drive impossible."
L[bk_retention]="Applying retention policy (keeping last %s days)..."
L[bk_retention_ok]="Old backups removed."
L[bk_mkdir_err]="Failed to create backup directory"

# Telegram notifications
L[tg_bk_success]="Backup successfully created"
L[tg_bk_gd]="Backup created and uploaded to Google Drive"
L[tg_bk_s3]="Backup uploaded to S3"
L[tg_size]="Size:"
L[tg_date]="Date:"
L[tg_project]="Project:"
L[tg_db]="DB:"
L[tg_db_docker]="Docker"
L[tg_db_ext]="External"
L[tg_db_none]="Not included"
L[tg_env]="Env:"
L[tg_env_yes]="included"
L[tg_env_no]="not included"
L[tg_restore_done]="Restore completed"
L[tg_update_avail]="Script update available"
L[tg_cur_ver]="Current version:"
L[tg_new_ver]="Latest version:"
L[tg_update_menu]="Update via 'Update script' in main menu"
L[tg_auto_updated]="Auto-updated script from"
L[tg_auto_updated_to]="to"
L[tg_auto_update_changelog]="What's new?"

# Restore
L[rs_title]="Restore from backup"
L[rs_source_select]="Select backup source:"
L[rs_source_local]="Local files"
L[rs_source_s3]="Download from S3"
L[rs_place_file]="Place backup file in folder:"
L[rs_no_files]="No backup files found in"
L[rs_select_file]="Select file to restore:"
L[rs_enter_num]="Enter file number (0 — exit): "
L[rs_invalid_num]="Invalid number."
L[rs_unpacking]="Unpacking backup archive..."
L[rs_unpacked]="Archive unpacked."
L[rs_unpack_err]="Error unpacking archive."
L[rs_meta]="Backup metadata — project: "
L[rs_meta_ver]="Script version: "
L[rs_meta_ts]="Timestamp: "
L[rs_meta_unknown]="unknown"
L[rs_no_meta]="No metadata (old format)."
L[rs_cancelled]="Restore cancelled."
L[rs_db_found]="DB dump found in archive."
L[rs_db_q]="Restore DB?"
L[rs_env_found]=".env file found in archive."
L[rs_env_q]="Restore .env?"
L[rs_env_dest]="Where to restore .env?"
L[rs_env_dest_original]="Original path from backup"
L[rs_env_dest_custom]="Custom path"
L[rs_env_enter_path]="Enter path for .env: "
L[rs_env_ok]=".env successfully restored."
L[rs_env_err]="Error restoring .env."
L[rs_dir_found]="Project directory archive found."
L[rs_dir_q]="Restore project directory?"
L[rs_dir_dest]="Where to restore directory?"
L[rs_dir_dest_original]="Original path from backup"
L[rs_dir_dest_custom]="Custom path"
L[rs_dir_enter_path]="Enter path to restore directory: "
L[rs_dir_ok]="Directory successfully restored."
L[rs_dir_err]="Error restoring directory."
L[rs_db_container_prompt]="Enter Docker container name for DB restore: "
L[rs_db_name_prompt]="Enter DB name to restore (default postgres): "
L[rs_db_user_prompt]="Enter DB user (default postgres): "
L[rs_db_pass_prompt]="Enter DB password: "
L[rs_wait_db]="Waiting for DB to be ready..."
L[rs_db_timeout]="DB wait timeout exceeded."
L[rs_db_ready]="DB is ready."
L[rs_restoring_db]="Restoring DB..."
L[rs_db_ok]="DB successfully restored."
L[rs_db_err]="DB restore error."
L[rs_complete]="Restore process complete."
L[rs_s3_listing]="Getting backup list from S3..."
L[rs_s3_no_files]="No backups found in S3."
L[rs_s3_select]="Select backup to download:"
L[rs_s3_stream]="Stream restore from S3:"
L[rs_s3_stream_err]="Error during stream restore from S3."
L[rs_s3_stream_ok]="Backup successfully received from S3."
L[rs_s3_enter_creds]="S3 not configured. Enter connection details:"
L[rs_nothing]="Nothing selected for restore."

# Cron
L[cron_root]="Root permissions required for cron setup."
L[cron_title]="Automatic backup schedule"
L[cron_on]="Automatic backup scheduled at:"
L[cron_utc]="UTC+0."
L[cron_off]="Automatic backup disabled."
L[cron_enable]="Enable / overwrite schedule"
L[cron_disable]="Disable automatic backup"
L[cron_variant]="Select schedule type:"
L[cron_time]="Enter time (e.g.: 02:00 14:00)"
L[cron_hourly]="Hourly"
L[cron_daily]="Daily"
L[cron_enter_utc]="Enter time in UTC+0 (e.g. 03:00):"
L[cron_time_space]="Time separated by spaces: "
L[cron_bad_value]="Invalid time value:"
L[cron_hm_range]="(hours 0-23, minutes 0-59)."
L[cron_bad_fmt]="Invalid time format:"
L[cron_expect_hhmm]="(expected HH:MM)."
L[cron_bad_choice]="Invalid choice."
L[cron_err_input]="Schedule not set due to input errors."
L[cron_setting]="Setting up cron job..."
L[cron_shell]="SHELL=/bin/bash added to crontab."
L[cron_path_add]="PATH added to crontab."
L[cron_path_exists]="PATH already exists in crontab."
L[cron_ok]="Cron job successfully installed."
L[cron_fail]="Failed to install cron job."
L[cron_set]="Schedule set to:"
L[cron_disabling]="Disabling automatic backup..."
L[cron_disabled]="Automatic backup disabled."

# Upload method
L[ul_title]="Backup upload method"
L[ul_current]="Current method:"
L[ul_set_tg]="Telegram"
L[ul_set_gd]="Google Drive"
L[ul_set_s3]="S3 (S3-compatible storage)"
L[ul_tg_set]="Upload method: Telegram."
L[ul_tg_enter]="Enter Telegram credentials:"
L[ul_enter_token]="Enter API Token: "
L[ul_tg_id_help]="Get ID from @userinfobot"
L[ul_enter_tg_id]="Enter Telegram ID: "
L[ul_tg_saved]="Telegram settings saved."
L[ul_gd_set]="Upload method: Google Drive."
L[ul_gd_enter]="Enter Google Drive API credentials."
L[ul_gd_fail]="Failed to get Refresh Token."
L[ul_gd_not_done]="Setup not complete, switching to Telegram."
L[ul_gd_token_ok]="Refresh Token successfully obtained."
L[ul_gd_saved]="Google Drive settings saved."
L[ul_s3_set]="Upload method: S3."
L[ul_s3_enter]="Configure S3 connection."
L[ul_s3_enter_endpoint]="S3 Endpoint URL (e.g. https://s3.amazonaws.com): "
L[ul_s3_enter_region]="Region (Enter — us-east-1): "
L[ul_s3_enter_bucket]="Bucket name: "
L[ul_s3_enter_access]="Access Key: "
L[ul_s3_enter_secret]="Secret Key: "
L[ul_s3_prefix_info1]="Optional: specify a prefix (folder) for backups in the bucket."
L[ul_s3_prefix_info2]="Leave empty to upload to bucket root."
L[ul_s3_enter_prefix]="Prefix (folder): "
L[ul_s3_retain_info]="Backup retention period in S3 (days)."
L[ul_s3_enter_retain]="S3 retention days (Enter — %s days): "
L[ul_s3_fail]="Required fields missing (Bucket, Access Key, Secret Key)."
L[ul_s3_not_done]="S3 setup not complete, switching to Telegram."
L[ul_s3_saved]="S3 settings saved."

# Settings
L[st_title]="Script configuration"
L[st_tg_settings]="Telegram settings"
L[st_gd_settings]="Google Drive settings"
L[st_s3_settings]="S3 settings"
L[st_db_settings]="Database settings"
L[st_project_settings]="Project settings"
L[st_retention_settings]="Backup retention policy"
L[st_lang]="Language"
L[st_auto_update]="Auto-update script"

L[st_tg_title]="Telegram settings"
L[st_tg_token]="API Token:"
L[st_tg_chatid]="Chat ID:"
L[st_tg_thread]="Message Thread ID:"
L[st_tg_proxy]="Proxy:"
L[st_tg_change_token]="Change API Token"
L[st_tg_change_id]="Change Chat ID"
L[st_tg_change_thread]="Change Message Thread ID"
L[st_tg_change_proxy]="Configure proxy"
L[st_tg_enter_token]="Enter new API Token: "
L[st_tg_token_ok]="API Token updated."
L[st_tg_chatid_desc]="Group Chat ID or your Telegram ID"
L[st_tg_enter_id]="Enter new ID: "
L[st_tg_id_ok]="ID updated."
L[st_tg_thread_info]="Group topic ID (Message Thread ID)"
L[st_tg_enter_thread]="Enter Message Thread ID: "
L[st_tg_thread_ok]="Thread ID updated."
L[st_tg_proxy_info]="Proxy for Telegram API requests."
L[st_tg_proxy_examples]="Format: socks5://host:port or http://host:port. Empty — disable."
L[st_tg_enter_proxy]="Proxy (Enter — disable): "
L[st_tg_proxy_ok]="Proxy set."
L[st_tg_proxy_cleared]="Proxy disabled."

L[st_gd_title]="Google Drive settings"
L[st_gd_client_id]="Client ID:"
L[st_gd_secret]="Client Secret:"
L[st_gd_refresh]="Refresh Token:"
L[st_gd_folder]="Folder ID:"
L[st_gd_change_id]="Change Google Client ID"
L[st_gd_change_secret]="Change Google Client Secret"
L[st_gd_change_refresh]="Change Refresh Token"
L[st_gd_change_folder]="Change Folder ID"
L[st_gd_no_tokens]="Don't have Client ID and Client Secret?"
L[st_gd_enter_id]="Enter new Client ID: "
L[st_gd_id_ok]="Client ID updated."
L[st_gd_enter_secret]="Enter new Client Secret: "
L[st_gd_secret_ok]="Client Secret updated."
L[st_gd_auth_needed]="Browser authorization required."
L[st_gd_enter_code]="Enter code from browser: "
L[st_gd_fail]="Failed to get Refresh Token."
L[st_gd_not_done]="Setup not complete."
L[st_gd_token_ok]="Refresh Token updated."
L[st_gd_enter_folder]="Enter new Folder ID (Enter — root): "
L[st_gd_folder_ok]="Folder ID updated."

L[st_s3_title]="S3 settings"
L[st_s3_endpoint]="Endpoint:"
L[st_s3_region]="Region:"
L[st_s3_bucket]="Bucket:"
L[st_s3_access]="Access Key:"
L[st_s3_secret]="Secret Key:"
L[st_s3_prefix]="Prefix:"
L[st_s3_change_endpoint]="Change Endpoint URL"
L[st_s3_change_region]="Change Region"
L[st_s3_change_bucket]="Change Bucket"
L[st_s3_change_access]="Change Access Key"
L[st_s3_change_secret]="Change Secret Key"
L[st_s3_change_prefix]="Change Prefix"
L[st_s3_test]="Test S3 connection"
L[st_s3_enter_endpoint]="Enter new Endpoint URL: "
L[st_s3_enter_region]="Enter new Region (Enter — us-east-1): "
L[st_s3_enter_bucket]="Enter new Bucket: "
L[st_s3_enter_access]="Enter new Access Key: "
L[st_s3_enter_secret]="Enter new Secret Key: "
L[st_s3_enter_prefix]="Enter new Prefix (Enter — root): "
L[st_s3_endpoint_ok]="Endpoint updated."
L[st_s3_region_ok]="Region updated."
L[st_s3_bucket_ok]="Bucket updated."
L[st_s3_access_ok]="Access Key updated."
L[st_s3_secret_ok]="Secret Key updated."
L[st_s3_prefix_ok]="Prefix updated."
L[st_s3_test_missing]="Required S3 fields not filled."
L[st_s3_testing]="Testing S3 connection..."
L[st_s3_test_ok]="S3 connection successful!"
L[st_s3_test_fail]="Failed to connect to S3."

L[st_db_title]="Database settings"
L[st_db_type]="Connection type:"
L[st_db_type_docker]="Docker container"
L[st_db_type_ext]="External DB"
L[st_db_type_none]="Not configured"
L[st_db_engine]="DB engine:"
L[st_db_container]="Container:"
L[st_db_user_label]="User:"
L[st_db_name_label]="Database:"
L[st_db_host_label]="Host:"
L[st_db_port_label]="Port:"
L[st_db_ssl_label]="SSL mode:"
L[st_db_pgver_label]="PG client version:"
L[st_db_change_type]="Change connection type"
L[st_db_change_engine]="Change DB engine"
L[st_db_change_container]="Change container name"
L[st_db_change_user]="Change user"
L[st_db_change_name]="Change database name"
L[st_db_ext_settings]="External DB settings"
L[st_db_test]="Test connection"
L[st_db_disable]="Disable DB backup"
L[st_db_select_type]="Select connection type:"
L[st_db_docker]="Docker container"
L[st_db_external]="External DB"
L[st_db_none]="Don't backup DB"
L[st_db_switched_docker]="Switched to Docker."
L[st_db_switched_ext]="Switched to external DB."
L[st_db_switched_none]="DB backup disabled."
L[st_db_need_ext_params]="Configure external DB parameters."
L[st_db_enter_user]="DB user (Enter — keep %s): "
L[st_db_user_ok]="User updated:"
L[st_db_enter_container]="Container name (Enter — keep %s): "
L[st_db_container_ok]="Container name updated."
L[st_db_enter_name]="DB name (Enter — keep %s): "
L[st_db_name_ok]="DB name updated."
L[st_db_enter_host]="Host (Enter — keep %s): "
L[st_db_enter_port]="Port (Enter — keep %s): "
L[st_db_enter_pass]="Password (Enter — keep current): "
L[st_db_enter_ssl]="SSL mode (Enter — keep %s): "
L[st_db_enter_pgver]="PG client version (Enter — keep %s): "
L[st_db_ext_saved]="External DB settings updated."
L[st_db_testing]="Testing connection..."
L[st_db_test_ok]="Connection successful! DB is available."
L[st_db_test_fail]="Failed to connect to DB."
L[st_db_only_ext]="Test available for external DB only."

L[st_project_title]="Project settings"
L[st_project_name]="Project name:"
L[st_project_dir]="Project directory:"
L[st_project_dir_mode]="Directory backup mode:"
L[st_project_dir_items]="Selected items:"
L[st_project_change_name]="Change project name"
L[st_project_change_dir]="Change project directory"
L[st_project_change_scope]="Choose what to backup from directory"
L[st_project_disable_dir]="Disable directory backup"
L[st_project_enable_dir]="Enable directory backup"
L[st_project_enter_name]="Enter new project name: "
L[st_project_name_ok]="Project name updated."
L[st_project_enter_dir]="Enter new directory path: "
L[st_project_dir_ok]="Directory updated."
L[st_project_dir_disabled]="Directory backup disabled."
L[st_project_dir_enabled]="Directory backup enabled."
L[st_project_scope_saved]="Directory backup scope saved."
L[st_project_scope_full]="Full directory"
L[st_project_scope_selected]="Selected files/folders"
L[st_project_scope_pick]="Pick files/folders"
L[st_project_scope_none]="No items selected"
L[pick_title]="Directory content selection"
L[pick_help]="Arrows: move | Enter: open/confirm | Space: select | Backspace/Left: up | c: confirm"
L[pick_current]="Current:"
L[pick_selected]="Selected:"
L[pick_confirm]="Confirm selected items?"
L[pick_done]="Selection saved."
L[pick_cancel]="Selection cancelled."
L[pick_up]="[..] Up"
L[pick_confirm_item]="[Confirm selection]"

L[st_retention_title]="Backup retention policy"
L[st_retention_local]="Local retention:"
L[st_retention_s3]="S3 retention:"
L[st_retention_days]="days"
L[st_retention_change_local]="Change local retention period"
L[st_retention_change_s3]="Change S3 retention period"
L[st_retention_enter_local]="Local retention days (Enter — %s): "
L[st_retention_enter_s3]="S3 retention days (Enter — %s): "
L[st_retention_local_ok]="Local retention updated:"
L[st_retention_s3_ok]="S3 retention updated:"

L[st_lang_current]="Current language:"
L[st_lang_changed]="Language changed to:"
L[st_auto_update_status]="Current status:"
L[st_auto_update_on]="Enabled"
L[st_auto_update_off]="Disabled"
L[st_auto_update_enable]="Enable auto-update"
L[st_auto_update_disable]="Disable auto-update"
L[st_auto_update_enabled]="Auto-update enabled."
L[st_auto_update_disabled]="Auto-update disabled."

# Update
L[upd_checking]="Checking for updates..."
L[upd_root]="Root permissions required for update."
L[upd_fetching]="Fetching latest version info from GitHub..."
L[upd_fetch_fail]="Failed to fetch version info."
L[upd_parse_fail]="Failed to extract version from remote script."
L[upd_current]="Current version:"
L[upd_available]="Available version:"
L[upd_new_avail]="Update available to version"
L[upd_confirm]="Update now? Enter"
L[upd_cancelled]="Update cancelled."
L[upd_latest]="You have the latest version installed."
L[upd_downloading]="Downloading update..."
L[upd_download_fail]="Failed to download new version."
L[upd_invalid_file]="Downloaded file is empty or not a bash script."
L[upd_rm_old_bak]="Removing old script backups..."
L[upd_creating_bak]="Creating backup of current script..."
L[upd_bak_fail]="Failed to create backup. Update cancelled."
L[upd_move_fail]="Error moving file. Check permissions."
L[upd_restoring_bak]="Restoring from backup..."
L[upd_done]="Script successfully updated to version"
L[upd_restart]="Script will be restarted..."

# Remove
L[rm_warn]="WARNING! The following will be removed:"
L[rm_script]="Script"
L[rm_dir]="Installation directory and all backups"
L[rm_symlink]="Symlink (if exists)"
L[rm_cron]="Cron jobs"
L[rm_confirm]="Are you sure? Enter"
L[rm_cancelled]="Removal cancelled."
L[rm_root]="Root permissions required for full removal."
L[rm_cron_removing]="Removing cron jobs..."
L[rm_cron_removed]="Cron jobs removed."
L[rm_cron_none]="No cron jobs found."
L[rm_symlink_removing]="Removing symlink..."
L[rm_symlink_removed]="Symlink removed."
L[rm_symlink_fail]="Failed to remove symlink."
L[rm_symlink_not_link]="exists but is not a symlink."
L[rm_symlink_none]="Symlink not found."
L[rm_dir_removing]="Removing installation directory..."
L[rm_dir_removed]="(including script, config, backups) removed."
L[rm_dir_fail]="Error removing directory."
L[rm_dir_none]="Installation directory not found."

# Menu
L[menu_title]="UNIVERSAL BACKUP & RESTORE"
L[menu_version]="Version:"
L[menu_update_avail]="update available"
L[menu_project]="Project:"
L[menu_db_docker]="DB: Docker"
L[menu_db_ext]="DB: External"
L[menu_db_none]="DB: not configured"
L[menu_create_backup]="Create backup manually"
L[menu_restore]="Restore from backup"
L[menu_auto_send]="Schedule settings"
L[menu_upload_method]="Upload method"
L[menu_settings]="Configuration"
L[menu_update]="Update script"
L[menu_remove]="Remove script"
L[menu_shortcut]="Quick launch:"
L[menu_author]="Author:"
L[menu_tab_ops]="Operations"
L[menu_tab_config]="Configuration"
L[menu_tab_service]="Service"
L[menu_tabs_label]="Tabs:"
L[menu_tab_current]="Current tab:"
L[menu_tab_prev]="Previous tab"
L[menu_tab_next]="Next tab"
L[menu_tip_tabs]="Tip: use left/right arrow keys to switch tabs"
L[menu_tip_actions]="Choose action:"
L[menu_tip_shortcut]="CLI shortcut:"
L[menu_tab_quick_settings]="Quick settings"
L[menu_tab_projects]="Project settings"
L[menu_tab_db]="Database settings"
L[menu_tab_retention]="Retention policy"
L[menu_tab_language]="Language"
L[menu_tab_auto_update]="Auto-update"
L[menu_tab_check_update]="Check for updates"
L[menu_tab_remove]="Remove script and data"
L[menu_projects_title]="Connected projects:"
L[menu_projects_empty]="No projects found."
L[menu_projects_col_id]="ID"
L[menu_projects_col_name]="Name"
L[menu_projects_col_db]="DB"
L[menu_projects_col_upload]="Upload"
L[menu_projects_col_status]="Status"
L[menu_projects_status_active]="Active"
L[menu_projects_status_ready]="Ready"
L[menu_projects_status_attention]="Needs setup"
L[menu_upload_configured]="Configured upload methods:"
L[menu_actions_for_tab]="Actions for tab:"
}

###############################################################################
# TRANSLATIONS: Russian
###############################################################################
_load_lang_ru() {

# Общие
L[select_option]="Выберите пункт: "
L[your_choice]="Ваш выбор: "
L[invalid_input]="Неверный ввод."
L[invalid_input_select]="Неверный ввод. Пожалуйста, выберите один из предложенных пунктов."
L[press_enter]="Нажмите Enter для продолжения..."
L[press_enter_back]="Нажмите Enter для возврата в меню..."
L[press_enter_restart]="Нажмите Enter для перезапуска."
L[back]="Назад"
L[back_to_menu]="Вернуться в главное меню"
L[exit]="Выход"
L[exit_dots]="Выход..."
L[input_prompt]="Ввод: "
L[path_prompt]="Путь: "
L[not_set]="Не установлен"
L[custom_path]="Указать свой путь"
L[select_variant]="Выберите вариант: "
L[saving_config]="Сохранение конфигурации в"
L[config_saved]="Конфигурация сохранена."
L[chmod_error]="Не удалось установить права доступа (600) для"
L[check_permissions]="Проверьте разрешения."
L[yes_no]="(y/n): "

# Symlink
L[symlink_root]="Для управления символической ссылкой требуются права root"
L[symlink_skip]="Пропускаем настройку."
L[symlink_ok]="Символическая ссылка уже настроена и указывает на"
L[symlink_creating]="Создание или обновление символической ссылки"
L[symlink_created]="Символическая ссылка успешно настроена."
L[symlink_fail]="Не удалось создать символическую ссылку"
L[symlink_dir_missing]="Каталог не найден. Символическая ссылка не создана."

# Docker
L[docker_missing]="Docker не установлен на этом сервере."
L[docker_install_q]="Хотите установить Docker сейчас?"
L[docker_installing]="Установка Docker..."
L[docker_installed]="Docker успешно установлен."
L[docker_install_fail]="Ошибка при установке Docker."
L[docker_cancelled]="Операция отменена."

# jq
L[jq_installing]="Установка пакета jq..."
L[jq_root]="Для установки jq требуются права root. Установите вручную: sudo apt-get install jq"
L[jq_installed]="jq успешно установлен."
L[jq_fail]="Не удалось установить jq."
L[jq_no_apt]="Менеджер пакетов apt-get не найден. Установите jq вручную."
L[jq_bad_usage]="Неверное использование. Доступные команды:"

# AWS CLI
L[s3_installing_cli]="Установка AWS CLI..."
L[s3_cli_root]="Для установки AWS CLI требуются права root."
L[s3_cli_fail]="Не удалось установить AWS CLI."
L[s3_cli_no_pm]="Менеджер пакетов не найден. Установите AWS CLI вручную."
L[s3_cli_installed]="AWS CLI успешно установлен."
L[s3_cli_fallback]="Пакет awscli недоступен, установка через официальный установщик AWS..."
L[s3_aws_not_found]="AWS CLI не установлен. Выберите S3 в настройках для автоматической установки."
L[ul_s3_aws_needed]="Не удалось установить AWS CLI. Он необходим для работы с S3."

# Конфигурация
L[cfg_loading]="Загрузка конфигурации..."
L[cfg_loaded]="Конфигурация успешно загружена из"
L[cfg_install_fail]="Не удалось создать каталог установки"
L[cfg_backup_fail]="Не удалось создать каталог для бэкапов"
L[cfg_move_fail]="Не удалось переместить скрипт в"
L[cfg_new_saved]="Новая конфигурация сохранена в"
L[cfg_tg_not_configured]="Telegram не настроен, уведомления отключены."
L[cfg_tg_skip_hint]="Оставьте пустым чтобы пропустить, настроить можно позже в меню настроек."
L[cfg_tg_skip_warn]="Без Telegram вы не будете получать уведомления о бэкапах."
L[cfg_tg_setup]="Настройка уведомлений Telegram:"
L[cfg_create_bot]="Создайте Telegram бота в @BotFather и получите API Token"
L[cfg_enter_token]="Введите API Token: "
L[cfg_chatid_desc]="Введите Chat ID группы или свой Telegram ID"
L[cfg_chatid_help]="ID можно узнать у бота @username_to_id_bot"
L[cfg_enter_chatid]="Введите ID: "
L[cfg_thread_info]="Опционально: ID топика группы (Message Thread ID)"
L[cfg_thread_empty]="Оставьте пустым для общего чата"
L[cfg_enter_thread]="Введите Message Thread ID: "

# Настройки проекта
L[cfg_project_name]="Введите имя проекта (используется в имени файла бэкапа): "
L[cfg_project_dir]="Введите путь к директории проекта: "
L[cfg_project_env]="Путь к .env файлу (Enter — пропустить): "
L[cfg_path_empty]="Путь не может быть пустым."
L[cfg_path_abs]="Путь должен быть абсолютным (начинаться с /)."
L[cfg_dir_missing]="Директория не существует."
L[cfg_continue_path]="Продолжить с этим путем?"
L[cfg_custom_set]="Установлен путь:"

# БД
L[cfg_db_skip]="Пропустить настройку БД"
L[cfg_db_setup]="Настройка подключения к БД:"
L[cfg_db_container]="Имя Docker-контейнера с БД: "
L[cfg_db_type_prompt]="Тип СУБД (postgres/mysql/mongodb, по умолчанию postgres): "
L[cfg_enter_db_user]="Имя пользователя БД (по умолчанию postgres): "
L[cfg_enter_db_name]="Имя базы данных (по умолчанию postgres): "
L[cfg_enter_db_pass]="Пароль БД (Enter — без пароля): "
L[cfg_db_ext_host]="Хост БД (для внешней БД): "
L[cfg_db_ext_port]="Порт БД (по умолчанию 5432): "
L[cfg_db_ssl]="SSL режим — prefer/require/disable (по умолчанию prefer): "
L[cfg_db_pgver]="Версия PostgreSQL клиента (13-17, по умолчанию 17): "

# Google Drive
L[cfg_gd_incomplete]="Обнаружены неполные данные для Google Drive."
L[cfg_gd_switch_tg]="Способ отправки будет изменён на Telegram."
L[cfg_gd_missing]="Отсутствуют необходимые данные для Google Drive."
L[cfg_gd_enter]="Введите недостающие данные для Google Drive:"
L[cfg_gd_no_tokens]="Если у вас нет Client ID и Client Secret токенов"
L[cfg_gd_guide]="Изучите гайд:"
L[cfg_enter_gd_id]="Введите Google Client ID: "
L[cfg_enter_gd_secret]="Введите Google Client Secret: "
L[cfg_gd_auth_needed]="Для Refresh Token нужна авторизация в браузере."
L[cfg_gd_open_url]="Откройте ссылку в браузере, авторизуйтесь и скопируйте код:"
L[cfg_gd_enter_code]="Введите код из браузера: "
L[cfg_gd_getting]="Получение Refresh Token..."
L[cfg_gd_fail]="Не удалось получить Refresh Token."
L[cfg_gd_incomplete2]="Настройка Google Drive не завершена, переключаемся на Telegram."
L[cfg_gd_folder1]="Чтобы указать папку Google Drive:"
L[cfg_gd_folder2]="1. Откройте нужную папку в браузере."
L[cfg_gd_folder3]="2. Скопируйте ID из ссылки:"
L[cfg_gd_folder4]="3. ID — часть после /folders/"
L[cfg_gd_folder5]="Оставьте пустым для корневой папки."
L[cfg_enter_gd_folder]="Введите Google Drive Folder ID (Enter — корень): "
L[cfg_s3_incomplete]="Обнаружены неполные данные для S3 Storage."
L[cfg_s3_switch_tg]="Способ отправки будет изменён на Telegram."

# Telegram API
L[tg_send_err]="Ошибка отправки сообщения в Telegram. Код:"
L[tg_response]="Ответ от Telegram:"
L[tg_curl_err]="Ошибка CURL при отправке документа. Код:"
L[tg_check_net]="Проверьте сетевое соединение."
L[tg_api_err]="Telegram API вернул ошибку. Код:"
L[tg_resp_label]="Ответ:"
L[tg_maybe_big]="Файл слишком большой или BOT_TOKEN/CHAT_ID неверны."

# Google Drive API
L[gd_not_set]="Google Drive Client ID, Client Secret или Refresh Token не настроены."
L[gd_token_err]="Ошибка получения Google Drive Access Token."
L[gd_upload_err]="Ошибка загрузки файла в Google Drive."
L[gd_upload_ok]="Файл успешно загружен в Google Drive."

# S3
L[s3_upload_err]="Ошибка загрузки файла в S3."
L[s3_upload_ok]="Файл успешно загружен в S3."
L[s3_cleaned]="Удалено старых бэкапов из S3: %s"

# Бэкап
L[bk_starting]="Начинаю создание резервной копии..."
L[bk_project]="Проект:"
L[bk_skip_db]="Пропускаю бэкап БД."
L[bk_skip_dir]="Пропускаю бэкап директории проекта."
L[bk_creating_dump]="Создание дампа БД..."
L[bk_dump_type]="Тип БД:"
L[bk_dump_container]="Контейнер:"
L[bk_dump_ok]="Дамп БД успешно создан."
L[bk_dump_err]="Ошибка при создании дампа БД. Код:"
L[bk_check_db]="Проверьте контейнер и настройки БД."
L[bk_archiving_dir]="Архивирование директории проекта"
L[bk_archiving_dir_selected]="Архивирование выбранных файлов/папок из директории проекта"
L[bk_dir_ok]="Директория успешно заархивирована."
L[bk_dir_err]="Ошибка при архивировании директории."
L[bk_dir_missing]="Директория не найдена:"
L[bk_no_data]="Нет данных для бэкапа! Включите хотя бы один источник."
L[bk_final_err]="Ошибка при создании финального архива. Код:"
L[bk_final_ok]="Финальный архив успешно создан:"
L[bk_cleaning]="Очистка промежуточных файлов..."
L[bk_cleaned]="Промежуточные файлы удалены."
L[bk_sending]="Отправка бэкапа"
L[bk_tg_big]="Размер бэкапа (%s) превышает лимит Telegram (50 МБ). Файл не отправлен."
L[bk_saved_local]="Бэкап сохранен локально:"
L[bk_tg_big_notify]="Бэкап создан (%s), но не отправлен: превышен лимит Telegram (50 МБ)."
L[bk_tg_ok]="Бэкап успешно отправлен в Telegram."
L[bk_tg_err]="Ошибка при отправке в Telegram."
L[bk_gd_ok]="Бэкап успешно загружен в Google Drive."
L[bk_gd_notify_ok]="Уведомление об успехе отправлено в Telegram."
L[bk_gd_notify_fail]="Не удалось отправить уведомление в Telegram."
L[bk_gd_err]="Ошибка при отправке в Google Drive."
L[bk_gd_err_tg]="Ошибка: не удалось отправить бэкап в Google Drive."
L[bk_s3_ok]="Бэкап успешно загружен в S3."
L[bk_s3_err]="Ошибка загрузки в S3."
L[bk_s3_err_tg]="Ошибка загрузки бэкапа в S3."
L[bk_s3_notify_ok]="Уведомление об успехе отправлено в Telegram."
L[bk_s3_notify_fail]="Не удалось отправить уведомление в Telegram."
L[bk_s3_impossible]="Файл бэкапа не найден. Загрузка в S3 невозможна."
L[bk_s3_retention]="Очистка старых бэкапов в S3 (старше %s дней)..."
L[bk_s3_retention_ok]="Очистка S3 завершена."
L[bk_unknown_method]="Неизвестный метод отправки:"
L[bk_not_sent]="Бэкап не отправлен."
L[bk_file_missing]="Финальный файл бэкапа не найден:"
L[bk_impossible]="Отправка невозможна."
L[bk_gd_impossible]="Файл бэкапа не найден. Загрузка в Google Drive невозможна."
L[bk_retention]="Применение политики хранения (оставляем за последние %s дней)..."
L[bk_retention_ok]="Старые бэкапы удалены."
L[bk_mkdir_err]="Не удалось создать каталог бэкапов"

# Telegram уведомления
L[tg_bk_success]="Бэкап успешно создан"
L[tg_bk_gd]="Бэкап успешно создан и отправлен в Google Drive"
L[tg_bk_s3]="Бэкап загружен в S3"
L[tg_size]="Размер:"
L[tg_date]="Дата:"
L[tg_project]="Проект:"
L[tg_db]="БД:"
L[tg_db_docker]="Docker"
L[tg_db_ext]="Внешняя"
L[tg_db_none]="Не включена"
L[tg_env]="Env:"
L[tg_env_yes]="включён"
L[tg_env_no]="не включён"
L[tg_restore_done]="Восстановление завершено"
L[tg_update_avail]="Доступно обновление скрипта"
L[tg_cur_ver]="Текущая версия:"
L[tg_new_ver]="Актуальная версия:"
L[tg_update_menu]="Обновите через пункт «Обновление скрипта» в главном меню"
L[tg_auto_updated]="Автообновление скрипта с"
L[tg_auto_updated_to]="до"
L[tg_auto_update_changelog]="Что нового?"

# Восстановление
L[rs_title]="Восстановление из бэкапа"
L[rs_source_select]="Выберите источник бэкапа:"
L[rs_source_local]="Локальные файлы"
L[rs_source_s3]="Скачать из S3"
L[rs_place_file]="Поместите файл бэкапа в папку:"
L[rs_no_files]="Файлы бэкапов не найдены в"
L[rs_select_file]="Выберите файл для восстановления:"
L[rs_enter_num]="Введите номер файла (0 — выход): "
L[rs_invalid_num]="Неверный номер."
L[rs_unpacking]="Распаковка архива бэкапа..."
L[rs_unpacked]="Архив распакован."
L[rs_unpack_err]="Ошибка распаковки архива."
L[rs_meta]="Метаданные бэкапа — проект: "
L[rs_meta_ver]="Версия скрипта: "
L[rs_meta_ts]="Timestamp: "
L[rs_meta_unknown]="неизвестно"
L[rs_no_meta]="Метаданные отсутствуют (старый формат)."
L[rs_cancelled]="Восстановление отменено."
L[rs_db_found]="Найден дамп БД в архиве."
L[rs_db_q]="Восстановить БД?"
L[rs_env_found]="Найден .env файл в архиве."
L[rs_env_q]="Восстановить .env?"
L[rs_env_dest]="Куда восстановить .env?"
L[rs_env_dest_original]="Оригинальный путь из бэкапа"
L[rs_env_dest_custom]="Указать свой путь"
L[rs_env_enter_path]="Введите путь для .env: "
L[rs_env_ok]=".env успешно восстановлен."
L[rs_env_err]="Ошибка восстановления .env."
L[rs_dir_found]="Найден архив директории проекта."
L[rs_dir_q]="Восстановить директорию проекта?"
L[rs_dir_dest]="Куда восстановить директорию?"
L[rs_dir_dest_original]="Оригинальный путь из бэкапа"
L[rs_dir_dest_custom]="Указать свой путь"
L[rs_dir_enter_path]="Введите путь для восстановления директории: "
L[rs_dir_ok]="Директория успешно восстановлена."
L[rs_dir_err]="Ошибка восстановления директории."
L[rs_db_container_prompt]="Введите имя Docker-контейнера для восстановления БД: "
L[rs_db_name_prompt]="Введите имя БД для восстановления (по умолчанию postgres): "
L[rs_db_user_prompt]="Введите пользователя БД (по умолчанию postgres): "
L[rs_db_pass_prompt]="Введите пароль БД: "
L[rs_wait_db]="Ожидание готовности БД..."
L[rs_db_timeout]="Превышено время ожидания БД."
L[rs_db_ready]="БД готова."
L[rs_restoring_db]="Восстановление БД..."
L[rs_db_ok]="БД успешно восстановлена."
L[rs_db_err]="Ошибка восстановления БД."
L[rs_complete]="Процесс восстановления завершен."
L[rs_s3_listing]="Получение списка бэкапов из S3..."
L[rs_s3_no_files]="В S3 не найдено бэкапов."
L[rs_s3_select]="Выберите бэкап для скачивания:"
L[rs_s3_stream]="Стрим-восстановление из S3:"
L[rs_s3_stream_err]="Ошибка стрим-восстановления из S3."
L[rs_s3_stream_ok]="Бэкап успешно получен из S3."
L[rs_s3_enter_creds]="S3 не настроен. Введите данные для подключения:"
L[rs_nothing]="Ничего не выбрано для восстановления."

# Cron
L[cron_root]="Для настройки cron требуются права root."
L[cron_title]="Настройка автоматического бэкапа"
L[cron_on]="Автоматический бэкап настроен на:"
L[cron_utc]="по UTC+0."
L[cron_off]="Автоматический бэкап выключен."
L[cron_enable]="Включить / перезаписать расписание"
L[cron_disable]="Выключить автоматический бэкап"
L[cron_variant]="Выберите вариант расписания:"
L[cron_time]="Ввести время (например: 02:00 14:00)"
L[cron_hourly]="Ежечасно"
L[cron_daily]="Ежедневно"
L[cron_enter_utc]="Введите время по UTC+0 (например, 03:00):"
L[cron_time_space]="Время через пробел: "
L[cron_bad_value]="Неверное значение времени:"
L[cron_hm_range]="(часы 0-23, минуты 0-59)."
L[cron_bad_fmt]="Неверный формат времени:"
L[cron_expect_hhmm]="(ожидается HH:MM)."
L[cron_bad_choice]="Неверный выбор."
L[cron_err_input]="Расписание не настроено из-за ошибок ввода."
L[cron_setting]="Настройка cron-задачи..."
L[cron_shell]="SHELL=/bin/bash добавлен в crontab."
L[cron_path_add]="PATH добавлен в crontab."
L[cron_path_exists]="PATH уже существует в crontab."
L[cron_ok]="Cron-задача успешно установлена."
L[cron_fail]="Не удалось установить cron-задачу."
L[cron_set]="Расписание установлено на:"
L[cron_disabling]="Отключение автоматического бэкапа..."
L[cron_disabled]="Автоматический бэкап отключен."

# Настройки способа отправки
L[ul_title]="Настройка способа отправки бэкапов"
L[ul_current]="Текущий способ:"
L[ul_set_tg]="Telegram"
L[ul_set_gd]="Google Drive"
L[ul_set_s3]="S3 (S3-совместимое хранилище)"
L[ul_tg_set]="Способ отправки: Telegram."
L[ul_tg_enter]="Введите данные для Telegram:"
L[ul_enter_token]="Введите API Token: "
L[ul_tg_id_help]="ID можно узнать у @userinfobot"
L[ul_enter_tg_id]="Введите Telegram ID: "
L[ul_tg_saved]="Настройки Telegram сохранены."
L[ul_gd_set]="Способ отправки: Google Drive."
L[ul_gd_enter]="Введите данные для Google Drive API."
L[ul_gd_fail]="Не удалось получить Refresh Token."
L[ul_gd_not_done]="Настройка не завершена, переключаемся на Telegram."
L[ul_gd_token_ok]="Refresh Token успешно получен."
L[ul_gd_saved]="Настройки Google Drive сохранены."
L[ul_s3_set]="Способ отправки: S3."
L[ul_s3_enter]="Настройка подключения к S3."
L[ul_s3_enter_endpoint]="S3 Endpoint URL (напр. https://s3.amazonaws.com): "
L[ul_s3_enter_region]="Region (Enter — us-east-1): "
L[ul_s3_enter_bucket]="Bucket name: "
L[ul_s3_enter_access]="Access Key: "
L[ul_s3_enter_secret]="Secret Key: "
L[ul_s3_prefix_info1]="Опционально: укажите префикс (папку) для бэкапов в бакете."
L[ul_s3_prefix_info2]="Оставьте пустым для загрузки в корень бакета."
L[ul_s3_enter_prefix]="Prefix (папка): "
L[ul_s3_retain_info]="Срок хранения бэкапов в S3 (в днях)."
L[ul_s3_enter_retain]="Срок хранения в S3 (Enter — %s дней): "
L[ul_s3_fail]="Не заполнены обязательные поля (Bucket, Access Key, Secret Key)."
L[ul_s3_not_done]="Настройка S3 не завершена, переключаемся на Telegram."
L[ul_s3_saved]="Настройки S3 сохранены."

# Настройки конфигурации
L[st_title]="Настройка конфигурации скрипта"
L[st_tg_settings]="Настройки Telegram"
L[st_gd_settings]="Настройки Google Drive"
L[st_s3_settings]="Настройки S3"
L[st_db_settings]="Настройки БД"
L[st_project_settings]="Настройки проекта"
L[st_retention_settings]="Политика хранения бэкапов"
L[st_lang]="Язык / Language"
L[st_auto_update]="Автообновление скрипта"

L[st_tg_title]="Настройки Telegram"
L[st_tg_token]="API Token:"
L[st_tg_chatid]="ID чата:"
L[st_tg_thread]="Message Thread ID:"
L[st_tg_proxy]="Прокси:"
L[st_tg_change_token]="Изменить API Token"
L[st_tg_change_id]="Изменить Chat ID"
L[st_tg_change_thread]="Изменить Message Thread ID"
L[st_tg_change_proxy]="Настроить прокси"
L[st_tg_enter_token]="Введите новый API Token: "
L[st_tg_token_ok]="API Token обновлен."
L[st_tg_chatid_desc]="Chat ID группы или Telegram ID"
L[st_tg_enter_id]="Введите новый ID: "
L[st_tg_id_ok]="ID обновлен."
L[st_tg_thread_info]="ID топика группы (Message Thread ID)"
L[st_tg_enter_thread]="Введите Message Thread ID: "
L[st_tg_thread_ok]="Thread ID обновлен."
L[st_tg_proxy_info]="Прокси для запросов к Telegram API."
L[st_tg_proxy_examples]="Формат: socks5://host:port или http://host:port. Пустое — отключить."
L[st_tg_enter_proxy]="Прокси (Enter — отключить): "
L[st_tg_proxy_ok]="Прокси установлен."
L[st_tg_proxy_cleared]="Прокси отключен."

L[st_gd_title]="Настройки Google Drive"
L[st_gd_client_id]="Client ID:"
L[st_gd_secret]="Client Secret:"
L[st_gd_refresh]="Refresh Token:"
L[st_gd_folder]="Folder ID:"
L[st_gd_change_id]="Изменить Google Client ID"
L[st_gd_change_secret]="Изменить Google Client Secret"
L[st_gd_change_refresh]="Изменить Refresh Token"
L[st_gd_change_folder]="Изменить Folder ID"
L[st_gd_no_tokens]="Нет Client ID и Client Secret?"
L[st_gd_enter_id]="Введите новый Client ID: "
L[st_gd_id_ok]="Client ID обновлен."
L[st_gd_enter_secret]="Введите новый Client Secret: "
L[st_gd_secret_ok]="Client Secret обновлен."
L[st_gd_auth_needed]="Требуется авторизация в браузере."
L[st_gd_enter_code]="Введите код из браузера: "
L[st_gd_fail]="Не удалось получить Refresh Token."
L[st_gd_not_done]="Настройка не завершена."
L[st_gd_token_ok]="Refresh Token обновлен."
L[st_gd_enter_folder]="Введите новый Folder ID (Enter — корень): "
L[st_gd_folder_ok]="Folder ID обновлен."

L[st_s3_title]="Настройки S3"
L[st_s3_endpoint]="Endpoint:"
L[st_s3_region]="Region:"
L[st_s3_bucket]="Bucket:"
L[st_s3_access]="Access Key:"
L[st_s3_secret]="Secret Key:"
L[st_s3_prefix]="Prefix:"
L[st_s3_change_endpoint]="Изменить Endpoint URL"
L[st_s3_change_region]="Изменить Region"
L[st_s3_change_bucket]="Изменить Bucket"
L[st_s3_change_access]="Изменить Access Key"
L[st_s3_change_secret]="Изменить Secret Key"
L[st_s3_change_prefix]="Изменить Prefix"
L[st_s3_test]="Тест подключения к S3"
L[st_s3_enter_endpoint]="Введите новый Endpoint URL: "
L[st_s3_enter_region]="Введите новый Region (Enter — us-east-1): "
L[st_s3_enter_bucket]="Введите новый Bucket: "
L[st_s3_enter_access]="Введите новый Access Key: "
L[st_s3_enter_secret]="Введите новый Secret Key: "
L[st_s3_enter_prefix]="Введите новый Prefix (Enter — корень): "
L[st_s3_endpoint_ok]="Endpoint обновлен."
L[st_s3_region_ok]="Region обновлен."
L[st_s3_bucket_ok]="Bucket обновлен."
L[st_s3_access_ok]="Access Key обновлен."
L[st_s3_secret_ok]="Secret Key обновлен."
L[st_s3_prefix_ok]="Prefix обновлен."
L[st_s3_test_missing]="Не заполнены обязательные поля S3."
L[st_s3_testing]="Тестирование подключения к S3..."
L[st_s3_test_ok]="Подключение к S3 успешно!"
L[st_s3_test_fail]="Не удалось подключиться к S3."

L[st_db_title]="Настройки БД"
L[st_db_type]="Тип подключения:"
L[st_db_type_docker]="Docker контейнер"
L[st_db_type_ext]="Внешняя БД"
L[st_db_type_none]="Не настроена"
L[st_db_engine]="Тип СУБД:"
L[st_db_container]="Контейнер:"
L[st_db_user_label]="Пользователь:"
L[st_db_name_label]="База данных:"
L[st_db_host_label]="Хост:"
L[st_db_port_label]="Порт:"
L[st_db_ssl_label]="SSL режим:"
L[st_db_pgver_label]="Версия PG клиента:"
L[st_db_change_type]="Изменить тип подключения"
L[st_db_change_engine]="Изменить тип СУБД"
L[st_db_change_container]="Изменить имя контейнера"
L[st_db_change_user]="Изменить пользователя"
L[st_db_change_name]="Изменить имя БД"
L[st_db_ext_settings]="Настройки внешней БД"
L[st_db_test]="Тест подключения"
L[st_db_disable]="Отключить бэкап БД"
L[st_db_select_type]="Выберите тип подключения:"
L[st_db_docker]="Docker контейнер"
L[st_db_external]="Внешняя БД"
L[st_db_none]="Не бэкапить БД"
L[st_db_switched_docker]="Переключено на Docker."
L[st_db_switched_ext]="Переключено на внешнюю БД."
L[st_db_switched_none]="Бэкап БД отключен."
L[st_db_need_ext_params]="Настройте параметры внешней БД."
L[st_db_enter_user]="Пользователь БД (Enter — оставить %s): "
L[st_db_user_ok]="Пользователь обновлен:"
L[st_db_enter_container]="Имя контейнера (Enter — оставить %s): "
L[st_db_container_ok]="Имя контейнера обновлено."
L[st_db_enter_name]="Имя БД (Enter — оставить %s): "
L[st_db_name_ok]="Имя БД обновлено."
L[st_db_enter_host]="Хост (Enter — оставить %s): "
L[st_db_enter_port]="Порт (Enter — оставить %s): "
L[st_db_enter_pass]="Пароль (Enter — оставить текущий): "
L[st_db_enter_ssl]="SSL режим (Enter — оставить %s): "
L[st_db_enter_pgver]="Версия PG клиента (Enter — оставить %s): "
L[st_db_ext_saved]="Настройки внешней БД обновлены."
L[st_db_testing]="Тестирование подключения..."
L[st_db_test_ok]="Подключение успешно! БД доступна."
L[st_db_test_fail]="Не удалось подключиться к БД."
L[st_db_only_ext]="Тест доступен только для внешней БД."

L[st_project_title]="Настройки проекта"
L[st_project_name]="Имя проекта:"
L[st_project_dir]="Директория проекта:"
L[st_project_dir_mode]="Режим бэкапа директории:"
L[st_project_dir_items]="Выбранные элементы:"
L[st_project_change_name]="Изменить имя проекта"
L[st_project_change_dir]="Изменить директорию проекта"
L[st_project_change_scope]="Выбрать что бэкапить из директории"
L[st_project_disable_dir]="Отключить бэкап директории"
L[st_project_enable_dir]="Включить бэкап директории"
L[st_project_enter_name]="Введите новое имя проекта: "
L[st_project_name_ok]="Имя проекта обновлено."
L[st_project_enter_dir]="Введите новый путь к директории: "
L[st_project_dir_ok]="Директория обновлена."
L[st_project_dir_disabled]="Бэкап директории отключен."
L[st_project_dir_enabled]="Бэкап директории включен."
L[st_project_scope_saved]="Область бэкапа директории сохранена."
L[st_project_scope_full]="Вся директория"
L[st_project_scope_selected]="Выбранные файлы/папки"
L[st_project_scope_pick]="Выбрать файлы/папки"
L[st_project_scope_none]="Ничего не выбрано"
L[pick_title]="Выбор содержимого директории"
L[pick_help]="Стрелки: перемещение | Enter: открыть/подтвердить | Пробел: выбрать | Backspace/Влево: вверх | c: подтвердить"
L[pick_current]="Текущая:"
L[pick_selected]="Выбрано:"
L[pick_confirm]="Подтвердить выбранные элементы?"
L[pick_done]="Выбор сохранён."
L[pick_cancel]="Выбор отменён."
L[pick_up]="[..] Вверх"
L[pick_confirm_item]="[Подтвердить выбор]"

L[st_retention_title]="Политика хранения бэкапов"
L[st_retention_local]="Локальное хранение:"
L[st_retention_s3]="Хранение в S3:"
L[st_retention_days]="дней"
L[st_retention_change_local]="Изменить срок локального хранения"
L[st_retention_change_s3]="Изменить срок хранения в S3"
L[st_retention_enter_local]="Срок локального хранения в днях (Enter — %s): "
L[st_retention_enter_s3]="Срок хранения в S3 в днях (Enter — %s): "
L[st_retention_local_ok]="Срок локального хранения обновлён:"
L[st_retention_s3_ok]="Срок хранения в S3 обновлён:"

L[st_lang_current]="Текущий язык:"
L[st_lang_changed]="Язык изменён на:"
L[st_auto_update_status]="Текущий статус:"
L[st_auto_update_on]="Включено"
L[st_auto_update_off]="Выключено"
L[st_auto_update_enable]="Включить автообновление"
L[st_auto_update_disable]="Выключить автообновление"
L[st_auto_update_enabled]="Автообновление включено."
L[st_auto_update_disabled]="Автообновление выключено."

# Обновление скрипта
L[upd_checking]="Проверка обновлений..."
L[upd_root]="Для обновления требуются права root."
L[upd_fetching]="Получение информации о последней версии с GitHub..."
L[upd_fetch_fail]="Не удалось загрузить информацию о новой версии."
L[upd_parse_fail]="Не удалось извлечь версию из удалённого скрипта."
L[upd_current]="Текущая версия:"
L[upd_available]="Доступная версия:"
L[upd_new_avail]="Доступно обновление до версии"
L[upd_confirm]="Хотите обновить? Введите"
L[upd_cancelled]="Обновление отменено."
L[upd_latest]="Установлена актуальная версия скрипта."
L[upd_downloading]="Загрузка обновления..."
L[upd_download_fail]="Не удалось загрузить новую версию."
L[upd_invalid_file]="Загруженный файл пуст или не является bash-скриптом."
L[upd_rm_old_bak]="Удаление старых резервных копий скрипта..."
L[upd_creating_bak]="Создание резервной копии текущего скрипта..."
L[upd_bak_fail]="Не удалось создать резервную копию. Обновление отменено."
L[upd_move_fail]="Ошибка перемещения файла. Проверьте права доступа."
L[upd_restoring_bak]="Восстановление из резервной копии..."
L[upd_done]="Скрипт успешно обновлён до версии"
L[upd_restart]="Скрипт будет перезапущен..."

# Удаление
L[rm_warn]="ВНИМАНИЕ! Будут удалены:"
L[rm_script]="Скрипт"
L[rm_dir]="Каталог установки и все бэкапы"
L[rm_symlink]="Символическая ссылка (если существует)"
L[rm_cron]="Задачи cron"
L[rm_confirm]="Вы уверены? Введите"
L[rm_cancelled]="Удаление отменено."
L[rm_root]="Для полного удаления требуются права root."
L[rm_cron_removing]="Удаление cron-задач..."
L[rm_cron_removed]="Cron-задачи удалены."
L[rm_cron_none]="Cron-задачи не найдены."
L[rm_symlink_removing]="Удаление символической ссылки..."
L[rm_symlink_removed]="Символическая ссылка удалена."
L[rm_symlink_fail]="Не удалось удалить символическую ссылку."
L[rm_symlink_not_link]="существует, но не является символической ссылкой."
L[rm_symlink_none]="Символическая ссылка не найдена."
L[rm_dir_removing]="Удаление каталога установки..."
L[rm_dir_removed]="(включая скрипт, конфигурацию, бэкапы) удален."
L[rm_dir_fail]="Ошибка при удалении каталога."
L[rm_dir_none]="Каталог установки не найден."

# Меню
L[menu_title]="UNIVERSAL BACKUP & RESTORE"
L[menu_version]="Версия:"
L[menu_update_avail]="доступно обновление"
L[menu_project]="Проект:"
L[menu_db_docker]="БД: Docker"
L[menu_db_ext]="БД: Внешняя"
L[menu_db_none]="БД: не настроена"
L[menu_create_backup]="Создание бэкапа вручную"
L[menu_restore]="Восстановление из бэкапа"
L[menu_auto_send]="Настройка расписания"
L[menu_upload_method]="Способ отправки"
L[menu_settings]="Настройка конфигурации"
L[menu_update]="Обновление скрипта"
L[menu_remove]="Удаление скрипта"
L[menu_shortcut]="Быстрый запуск:"
L[menu_author]="Автор:"
L[menu_tab_ops]="Операции"
L[menu_tab_config]="Настройки"
L[menu_tab_service]="Сервис"
L[menu_tabs_label]="Вкладки:"
L[menu_tab_current]="Текущая вкладка:"
L[menu_tab_prev]="Предыдущая вкладка"
L[menu_tab_next]="Следующая вкладка"
L[menu_tip_tabs]="Подсказка: используйте стрелки влево/вправо для переключения вкладок"
L[menu_tip_actions]="Выберите действие:"
L[menu_tip_shortcut]="CLI-команда:"
L[menu_tab_quick_settings]="Быстрые настройки"
L[menu_tab_projects]="Настройки проекта"
L[menu_tab_db]="Настройки базы данных"
L[menu_tab_retention]="Политика хранения"
L[menu_tab_language]="Язык интерфейса"
L[menu_tab_auto_update]="Автообновление"
L[menu_tab_check_update]="Проверить обновления"
L[menu_tab_remove]="Удалить скрипт и данные"
L[menu_projects_title]="Подключённые проекты:"
L[menu_projects_empty]="Проекты не найдены."
L[menu_projects_col_id]="ID"
L[menu_projects_col_name]="Название"
L[menu_projects_col_db]="БД"
L[menu_projects_col_upload]="Отправка"
L[menu_projects_col_status]="Статус"
L[menu_projects_status_active]="Активный"
L[menu_projects_status_ready]="Готов"
L[menu_projects_status_attention]="Требует настройки"
L[menu_upload_configured]="Настроенные способы отправки:"
L[menu_actions_for_tab]="Действия для вкладки:"
}

###############################################################################
# MODULE: config
###############################################################################
# Загрузка, сохранение и начальная настройка конфигурации

# Значения по умолчанию
CFG_VERSION="1.0.0"
CFG_LANG="en"
CFG_AUTO_UPDATE="false"

# Telegram (глобально)
CFG_BOT_TOKEN=""
CFG_CHAT_ID=""
CFG_THREAD_ID=""
CFG_TG_PROXY=""

# Активный профиль проекта
CFG_ACTIVE_PROJECT=""
CFG_PROJECT_ID=""

# Способ отправки: telegram | s3 | google_drive (профиль проекта)
CFG_UPLOAD_METHOD="telegram"

# S3 (профиль проекта)
CFG_S3_ENDPOINT=""
CFG_S3_REGION="us-east-1"
CFG_S3_BUCKET=""
CFG_S3_ACCESS_KEY=""
CFG_S3_SECRET_KEY=""
CFG_S3_PREFIX=""
CFG_S3_RETENTION_DAYS="30"

# Google Drive (профиль проекта)
CFG_GD_CLIENT_ID=""
CFG_GD_CLIENT_SECRET=""
CFG_GD_REFRESH_TOKEN=""
CFG_GD_FOLDER_ID=""

# БД (профиль проекта)
CFG_DB_TYPE="none"          # none | docker | external
CFG_DB_ENGINE="postgres"    # postgres | mysql | mongodb
CFG_DB_CONTAINER=""
CFG_DB_USER="postgres"
CFG_DB_NAME="postgres"
CFG_DB_PASS=""
CFG_DB_HOST=""
CFG_DB_PORT="5432"
CFG_DB_SSL="prefer"
CFG_DB_PGVER="17"

# Проект (профиль проекта)
CFG_PROJECT_NAME=""
CFG_PROJECT_DIR=""
CFG_PROJECT_ENV=""
CFG_BACKUP_DIR="$DEFAULT_BACKUP_DIR"
CFG_RETENTION_DAYS="30"

# Флаги включения источников (профиль проекта)
CFG_BACKUP_ENV="false"
CFG_BACKUP_DIR_ENABLED="true"
CFG_BACKUP_DIR_MODE="full"      # full | selected
CFG_BACKUP_DIR_ITEMS=""         # newline-separated relative paths from CFG_PROJECT_DIR

ensure_runtime_dirs() {
    local cfg_dir
    cfg_dir="$(dirname "$CONFIG_FILE")"
    mkdir -p "$cfg_dir" "$PROJECTS_DIR" "$DEFAULT_BACKUP_DIR" 2>/dev/null || true
    [[ -n "${CFG_BACKUP_DIR:-}" ]] && mkdir -p "$CFG_BACKUP_DIR" 2>/dev/null || true
}

_project_file_path() {
    local project_id="$1"
    echo "${PROJECTS_DIR}/${project_id}.cfg"
}

_project_slug() {
    local raw="$1"
    local slug
    slug="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/_/g; s/_\+/_/g; s/^_//; s/_$//')"
    [[ -z "$slug" ]] && slug="project_$(date +%s)"
    echo "$slug"
}

_project_unique_id() {
    local base="$1"
    local candidate="$base"
    local i=2
    while [[ -f "$(_project_file_path "$candidate")" ]]; do
        candidate="${base}_${i}"
        ((i++))
    done
    echo "$candidate"
}

list_project_ids() {
    [[ -d "$PROJECTS_DIR" ]] || return 0
    find "$PROJECTS_DIR" -maxdepth 1 -type f -name "*.cfg" -print 2>/dev/null \
        | sed 's#.*/##; s/\.cfg$//' \
        | sort
}

project_count() {
    local count=0
    while IFS= read -r _id; do
        [[ -n "$_id" ]] && ((count++))
    done < <(list_project_ids)
    echo "$count"
}

reset_project_profile_defaults() {
    CFG_UPLOAD_METHOD="telegram"

    CFG_S3_ENDPOINT=""
    CFG_S3_REGION="us-east-1"
    CFG_S3_BUCKET=""
    CFG_S3_ACCESS_KEY=""
    CFG_S3_SECRET_KEY=""
    CFG_S3_PREFIX=""
    CFG_S3_RETENTION_DAYS="30"

    CFG_GD_CLIENT_ID=""
    CFG_GD_CLIENT_SECRET=""
    CFG_GD_REFRESH_TOKEN=""
    CFG_GD_FOLDER_ID=""

    CFG_DB_TYPE="none"
    CFG_DB_ENGINE="postgres"
    CFG_DB_CONTAINER=""
    CFG_DB_USER="postgres"
    CFG_DB_NAME="postgres"
    CFG_DB_PASS=""
    CFG_DB_HOST=""
    CFG_DB_PORT="5432"
    CFG_DB_SSL="prefer"
    CFG_DB_PGVER="17"

    CFG_PROJECT_NAME=""
    CFG_PROJECT_DIR=""
    CFG_PROJECT_ENV=""
    CFG_BACKUP_DIR="$DEFAULT_BACKUP_DIR"
    CFG_RETENTION_DAYS="30"
    CFG_BACKUP_ENV="false"
    CFG_BACKUP_DIR_ENABLED="true"
    CFG_BACKUP_DIR_MODE="full"
    CFG_BACKUP_DIR_ITEMS=""
}

project_display_name() {
    local project_id="$1"
    local project_file
    project_file="$(_project_file_path "$project_id")"
    local name=""
    if [[ -f "$project_file" ]]; then
        name="$(
            (
                set +u
                # shellcheck source=/dev/null
                source "$project_file" >/dev/null 2>&1
                printf '%s' "${CFG_PROJECT_NAME:-}"
            ) 2>/dev/null || true
        )"
    fi
    [[ -z "$name" ]] && name="$project_id"
    echo "$name"
}

resolve_project_id() {
    local selector="$1"
    [[ -z "$selector" ]] && return 1
    if [[ -f "$(_project_file_path "$selector")" ]]; then
        echo "$selector"
        return 0
    fi
    local id name
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        name="$(project_display_name "$id")"
        if [[ "$name" == "$selector" ]]; then
            echo "$id"
            return 0
        fi
    done < <(list_project_ids)
    return 1
}

activate_project_by_selector() {
    local selector="$1"
    local persist="${2:-false}"
    local resolved
    resolved="$(resolve_project_id "$selector")" || return 1
    load_project_config "$resolved" || return 1
    CFG_ACTIVE_PROJECT="$resolved"
    CFG_PROJECT_ID="$resolved"
    if [[ "$persist" == "true" ]]; then
        save_global_config "$CONFIG_FILE" || return 1
    fi
    return 0
}

switch_active_project() {
    activate_project_by_selector "$1" true
}

save_global_config() {
    local cfg_file="$1"
    local dir
    dir="$(dirname "$cfg_file")"
    mkdir -p "$dir" "$PROJECTS_DIR" || { log_error "${L[cfg_install_fail]} $dir"; return 1; }

    {
        printf '# Universal Backup — global configuration\n'
        printf '# Created: %s\n\n' "$(date)"
        printf 'CFG_VERSION=%s\n'           "$CFG_VERSION"
        printf 'CFG_LANG=%s\n'              "$CFG_LANG"
        printf 'CFG_AUTO_UPDATE=%s\n'       "$CFG_AUTO_UPDATE"
        printf 'CFG_ACTIVE_PROJECT=%s\n'    "$(printf '%q' "$CFG_ACTIVE_PROJECT")"
        printf 'PROJECTS_DIR=%s\n\n'        "$(printf '%q' "$PROJECTS_DIR")"

        printf '# Telegram\n'
        printf 'CFG_BOT_TOKEN=%s\n'         "$(printf '%q' "$CFG_BOT_TOKEN")"
        printf 'CFG_CHAT_ID=%s\n'           "$(printf '%q' "$CFG_CHAT_ID")"
        printf 'CFG_THREAD_ID=%s\n'         "$(printf '%q' "$CFG_THREAD_ID")"
        printf 'CFG_TG_PROXY=%s\n'          "$(printf '%q' "$CFG_TG_PROXY")"
    } | (umask 077; cat > "${cfg_file}.tmp") && mv "${cfg_file}.tmp" "$cfg_file"
    secure_file "$cfg_file"
}

save_project_config() {
    local project_id="$1"
    local project_file
    project_file="$(_project_file_path "$project_id")"
    mkdir -p "$PROJECTS_DIR" || return 1

    {
        printf '# Universal Backup — project profile\n'
        printf '# Project ID: %s\n' "$project_id"
        printf '# Created: %s\n\n' "$(date)"

        printf 'CFG_UPLOAD_METHOD=%s\n\n' "$CFG_UPLOAD_METHOD"

        printf '# S3\n'
        printf 'CFG_S3_ENDPOINT=%s\n'        "$(printf '%q' "$CFG_S3_ENDPOINT")"
        printf 'CFG_S3_REGION=%s\n'          "$CFG_S3_REGION"
        printf 'CFG_S3_BUCKET=%s\n'          "$(printf '%q' "$CFG_S3_BUCKET")"
        printf 'CFG_S3_ACCESS_KEY=%s\n'      "$(printf '%q' "$CFG_S3_ACCESS_KEY")"
        printf 'CFG_S3_SECRET_KEY=%s\n'      "$(printf '%q' "$CFG_S3_SECRET_KEY")"
        printf 'CFG_S3_PREFIX=%s\n'          "$(printf '%q' "$CFG_S3_PREFIX")"
        printf 'CFG_S3_RETENTION_DAYS=%s\n\n' "$CFG_S3_RETENTION_DAYS"

        printf '# Google Drive\n'
        printf 'CFG_GD_CLIENT_ID=%s\n'       "$(printf '%q' "$CFG_GD_CLIENT_ID")"
        printf 'CFG_GD_CLIENT_SECRET=%s\n'   "$(printf '%q' "$CFG_GD_CLIENT_SECRET")"
        printf 'CFG_GD_REFRESH_TOKEN=%s\n'   "$(printf '%q' "$CFG_GD_REFRESH_TOKEN")"
        printf 'CFG_GD_FOLDER_ID=%s\n\n'     "$(printf '%q' "$CFG_GD_FOLDER_ID")"

        printf '# Database\n'
        printf 'CFG_DB_TYPE=%s\n'            "$CFG_DB_TYPE"
        printf 'CFG_DB_ENGINE=%s\n'          "$CFG_DB_ENGINE"
        printf 'CFG_DB_CONTAINER=%s\n'       "$(printf '%q' "$CFG_DB_CONTAINER")"
        printf 'CFG_DB_USER=%s\n'            "$(printf '%q' "$CFG_DB_USER")"
        printf 'CFG_DB_NAME=%s\n'            "$(printf '%q' "$CFG_DB_NAME")"
        printf 'CFG_DB_PASS=%s\n'            "$(printf '%q' "$CFG_DB_PASS")"
        printf 'CFG_DB_HOST=%s\n'            "$(printf '%q' "$CFG_DB_HOST")"
        printf 'CFG_DB_PORT=%s\n'            "$CFG_DB_PORT"
        printf 'CFG_DB_SSL=%s\n'             "$CFG_DB_SSL"
        printf 'CFG_DB_PGVER=%s\n\n'         "$CFG_DB_PGVER"

        printf '# Project\n'
        printf 'CFG_PROJECT_NAME=%s\n'       "$(printf '%q' "$CFG_PROJECT_NAME")"
        printf 'CFG_PROJECT_DIR=%s\n'        "$(printf '%q' "$CFG_PROJECT_DIR")"
        printf 'CFG_PROJECT_ENV=%s\n'        "$(printf '%q' "$CFG_PROJECT_ENV")"
        printf 'CFG_BACKUP_DIR=%s\n'         "$(printf '%q' "$CFG_BACKUP_DIR")"
        printf 'CFG_RETENTION_DAYS=%s\n'     "$CFG_RETENTION_DAYS"
        printf 'CFG_BACKUP_ENV=%s\n'         "$CFG_BACKUP_ENV"
        printf 'CFG_BACKUP_DIR_ENABLED=%s\n' "$CFG_BACKUP_DIR_ENABLED"
        printf 'CFG_BACKUP_DIR_MODE=%s\n'    "$CFG_BACKUP_DIR_MODE"
        printf 'CFG_BACKUP_DIR_ITEMS=%s\n'   "$(printf '%q' "$CFG_BACKUP_DIR_ITEMS")"
    } | (umask 077; cat > "${project_file}.tmp") && mv "${project_file}.tmp" "$project_file"
    secure_file "$project_file"
}

load_project_config() {
    local project_id="$1"
    [[ "$project_id" == *".."* || "$project_id" == *"/"* ]] && return 1
    local project_file
    project_file="$(_project_file_path "$project_id")"
    [[ -f "$project_file" ]] || return 1
    # shellcheck source=/dev/null
    source "$project_file"
    CFG_BACKUP_DIR_MODE="${CFG_BACKUP_DIR_MODE:-full}"
    CFG_BACKUP_DIR_ITEMS="${CFG_BACKUP_DIR_ITEMS:-}"
    CFG_PROJECT_ID="$project_id"
    CFG_ACTIVE_PROJECT="$project_id"
    return 0
}

_migrate_legacy_single_project() {
    [[ -n "${CFG_ACTIVE_PROJECT:-}" ]] && return 0
    if [[ -n "${CFG_PROJECT_NAME:-}" || -n "${CFG_PROJECT_DIR:-}" || "$CFG_DB_TYPE" != "none" ]]; then
        local base id
        base="$(_project_slug "${CFG_PROJECT_NAME:-backup}")"
        id="$(_project_unique_id "$base")"
        CFG_PROJECT_ID="$id"
        CFG_ACTIVE_PROJECT="$id"
        save_project_config "$id"
        save_global_config "$CONFIG_FILE"
    fi
}

# ─────────────────────────────────────────────
# Загрузить конфиг из файла
# ─────────────────────────────────────────────
load_config() {
    local cfg_file="$1"
    [[ -f "$cfg_file" ]] || return 0

    if [[ "$cfg_file" == *".."* ]]; then
        log_error "Путь к конфигу содержит '..': $cfg_file"
        return 1
    fi

    local real_cfg
    real_cfg=$(realpath "$cfg_file" 2>/dev/null) || {
        log_error "Не удалось канонизировать путь к конфигу: $cfg_file"
        return 1
    }
    if [[ ! -f "$real_cfg" ]]; then
        log_error "Конфиг не является обычным файлом: $real_cfg"
        return 1
    fi

    log_step "${L[cfg_loading]}"
    # shellcheck source=/dev/null
    source "$real_cfg"
    log_info "${L[cfg_loaded]} $real_cfg"

    # Позволяем фиксировать PROJECTS_DIR в конфиге, но если нет — оставляем текущий.
    PROJECTS_DIR="${PROJECTS_DIR:-$(dirname "$CONFIG_FILE")/projects}"
    ensure_runtime_dirs

    _migrate_legacy_single_project

    if [[ -n "${CFG_ACTIVE_PROJECT:-}" ]]; then
        if ! load_project_config "$CFG_ACTIVE_PROJECT"; then
            local fallback
            fallback="$(list_project_ids | head -n1)"
            if [[ -n "$fallback" ]]; then
                load_project_config "$fallback"
            fi
        fi
    else
        local first
        first="$(list_project_ids | head -n1)"
        if [[ -n "$first" ]]; then
            load_project_config "$first"
        fi
    fi
}

# ─────────────────────────────────────────────
# Сохранить конфиг (глобальный + активный проект)
# ─────────────────────────────────────────────
save_config() {
    local cfg_file="$1"
    if [[ -z "${CFG_ACTIVE_PROJECT:-}" ]]; then
        CFG_ACTIVE_PROJECT="$(_project_unique_id "$(_project_slug "${CFG_PROJECT_NAME:-backup}")")"
    fi
    CFG_PROJECT_ID="$CFG_ACTIVE_PROJECT"
    ensure_runtime_dirs

    log_step "${L[saving_config]} $cfg_file"
    save_global_config "$cfg_file" || return 1
    save_project_config "$CFG_ACTIVE_PROJECT" || return 1
    log_info "${L[config_saved]}"
}

_configure_project_wizard() {
    # Имя проекта
    echo ""
    read -rp "${L[cfg_project_name]}" CFG_PROJECT_NAME
    [[ -z "$CFG_PROJECT_NAME" ]] && CFG_PROJECT_NAME="backup"

    # Директория проекта
    while true; do
        CFG_PROJECT_DIR=$(input_path "${L[cfg_project_dir]}" false)
        if [[ -d "$CFG_PROJECT_DIR" ]]; then
            break
        else
            log_warn "${L[cfg_dir_missing]}"
            confirm "${L[cfg_continue_path]}" && break
        fi
    done

    # По умолчанию бэкап директории целиком (без .env как отдельного источника)
    CFG_BACKUP_ENV="false"
    CFG_PROJECT_ENV=""
    CFG_BACKUP_DIR_MODE="full"
    CFG_BACKUP_DIR_ITEMS=""

    CFG_BACKUP_DIR="${DEFAULT_BACKUP_DIR}"

    # БД
    setup_db_wizard

    # Способ отправки
    setup_upload_method_wizard
}

# ─────────────────────────────────────────────
# Первоначальная настройка (wizard)
# ─────────────────────────────────────────────
initial_setup() {
    local cfg_file="$1"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   UNIVERSAL BACKUP — Первый запуск   ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo ""

    # Язык
    echo "Language / Язык:"
    _menu_select "1 2" "1" "English" "Русский"
    lang_choice="$MENU_CHOICE"
    if [[ "$lang_choice" == "2" ]]; then
        CFG_LANG="ru"
        load_language "ru"
    else
        CFG_LANG="en"
        load_language "en"
    fi

    # Telegram
    echo ""
    echo "${L[cfg_tg_setup]}"
    echo "${L[cfg_tg_skip_hint]}"
    echo "${L[cfg_create_bot]}"
    read -rp "${L[cfg_enter_token]}" CFG_BOT_TOKEN
    if [[ -n "$CFG_BOT_TOKEN" ]]; then
        echo "${L[cfg_chatid_help]}"
        read -rp "${L[cfg_enter_chatid]}" CFG_CHAT_ID
        echo "${L[cfg_thread_info]}"
        echo "${L[cfg_thread_empty]}"
        read -rp "${L[cfg_enter_thread]}" CFG_THREAD_ID
    else
        log_warn "${L[cfg_tg_not_configured]}"
    fi

    reset_project_profile_defaults
    _configure_project_wizard

    CFG_ACTIVE_PROJECT="$(_project_unique_id "$(_project_slug "$CFG_PROJECT_NAME")")"
    CFG_PROJECT_ID="$CFG_ACTIVE_PROJECT"

    save_config "$cfg_file"
    echo ""
    log_info "${L[cfg_new_saved]} $cfg_file"
}

# ─────────────────────────────────────────────
# Wizard: настройка БД
# ─────────────────────────────────────────────
setup_db_wizard() {
    echo ""
    echo "${L[cfg_db_setup]}"
    _menu_select "1 2 3" "1" "Docker container" "External DB" "${L[cfg_db_skip]}"
    db_choice="$MENU_CHOICE"

    case "$db_choice" in
        1)
            CFG_DB_TYPE="docker"
            read -rp "${L[cfg_db_container]}" CFG_DB_CONTAINER
            read -rp "${L[cfg_db_type_prompt]}" CFG_DB_ENGINE
            [[ -z "$CFG_DB_ENGINE" ]] && CFG_DB_ENGINE="postgres"
            read -rp "${L[cfg_enter_db_user]}" CFG_DB_USER
            [[ -z "$CFG_DB_USER" ]] && CFG_DB_USER="postgres"
            read -rp "${L[cfg_enter_db_name]}" CFG_DB_NAME
            [[ -z "$CFG_DB_NAME" ]] && CFG_DB_NAME="postgres"
            read -rsp "${L[cfg_enter_db_pass]}" CFG_DB_PASS; echo ""
            if [[ "$CFG_DB_ENGINE" == "postgres" ]]; then
                read -rp "${L[cfg_db_pgver]}" CFG_DB_PGVER
                if [[ -z "$CFG_DB_PGVER" ]]; then
                    CFG_DB_PGVER="17"
                fi
            fi
            ;;
        2)
            CFG_DB_TYPE="external"
            read -rp "${L[cfg_db_type_prompt]}" CFG_DB_ENGINE
            [[ -z "$CFG_DB_ENGINE" ]] && CFG_DB_ENGINE="postgres"
            read -rp "${L[cfg_db_ext_host]}" CFG_DB_HOST
            read -rp "${L[cfg_db_ext_port]}" CFG_DB_PORT
            [[ -z "$CFG_DB_PORT" ]] && CFG_DB_PORT="5432"
            read -rp "${L[cfg_enter_db_user]}" CFG_DB_USER
            [[ -z "$CFG_DB_USER" ]] && CFG_DB_USER="postgres"
            read -rp "${L[cfg_enter_db_name]}" CFG_DB_NAME
            [[ -z "$CFG_DB_NAME" ]] && CFG_DB_NAME="postgres"
            read -rsp "${L[cfg_enter_db_pass]}" CFG_DB_PASS; echo ""
            if [[ "$CFG_DB_ENGINE" == "postgres" ]]; then
                read -rp "${L[cfg_db_ssl]}" CFG_DB_SSL
                [[ -z "$CFG_DB_SSL" ]] && CFG_DB_SSL="prefer"
                read -rp "${L[cfg_db_pgver]}" CFG_DB_PGVER
                if [[ -z "$CFG_DB_PGVER" ]]; then
                    CFG_DB_PGVER="17"
                fi
            fi
            ;;
        *)
            CFG_DB_TYPE="none"
            ;;
    esac
}

# ─────────────────────────────────────────────
# Wizard: способ отправки
# ─────────────────────────────────────────────
setup_upload_method_wizard() {
    echo ""
    echo "${L[ul_title]}"
    _menu_select "1 2 3" "1" "${L[ul_set_tg]}" "${L[ul_set_s3]}" "${L[ul_set_gd]}"
    ul_choice="$MENU_CHOICE"

    case "$ul_choice" in
        2) setup_s3_config ;;
        3) setup_gd_config ;;
        *) CFG_UPLOAD_METHOD="telegram" ;;
    esac
}

# Настройка S3 (используется и из wizard, и из settings)
setup_s3_config() {
    CFG_UPLOAD_METHOD="s3"
    echo ""
    echo "${L[ul_s3_enter]}"
    read -rp "${L[ul_s3_enter_endpoint]}" CFG_S3_ENDPOINT
    read -rp "${L[ul_s3_enter_region]}" CFG_S3_REGION
    [[ -z "$CFG_S3_REGION" ]] && CFG_S3_REGION="us-east-1"
    read -rp "${L[ul_s3_enter_bucket]}" CFG_S3_BUCKET
    read -rp "${L[ul_s3_enter_access]}" CFG_S3_ACCESS_KEY
    read -rsp "${L[ul_s3_enter_secret]}" CFG_S3_SECRET_KEY; echo ""
    echo "${L[ul_s3_prefix_info1]}"
    echo "${L[ul_s3_prefix_info2]}"
    read -rp "${L[ul_s3_enter_prefix]}" CFG_S3_PREFIX
    echo "${L[ul_s3_retain_info]}"
    printf "${L[ul_s3_enter_retain]}" "${CFG_S3_RETENTION_DAYS}"
    read -r s3_ret
    [[ -n "$s3_ret" ]] && CFG_S3_RETENTION_DAYS="$s3_ret"

    if [[ -z "$CFG_S3_BUCKET" || -z "$CFG_S3_ACCESS_KEY" || -z "$CFG_S3_SECRET_KEY" ]]; then
        log_warn "${L[ul_s3_fail]}"
        log_warn "${L[ul_s3_not_done]}"
        CFG_UPLOAD_METHOD="telegram"
        return 1
    fi
    log_info "${L[ul_s3_saved]}"
}

# Настройка Google Drive
setup_gd_config() {
    CFG_UPLOAD_METHOD="google_drive"
    echo ""
    echo "${L[ul_gd_enter]}"
    echo "${L[cfg_gd_no_tokens]}"
    read -rp "${L[cfg_enter_gd_id]}" CFG_GD_CLIENT_ID
    read -rsp "${L[cfg_enter_gd_secret]}" CFG_GD_CLIENT_SECRET; echo ""

    if [[ -z "$CFG_GD_CLIENT_ID" || -z "$CFG_GD_CLIENT_SECRET" ]]; then
        log_warn "${L[cfg_gd_missing]}"
        log_warn "${L[cfg_gd_switch_tg]}"
        CFG_UPLOAD_METHOD="telegram"
        return 1
    fi

    # Получить refresh token
    local auth_url="https://accounts.google.com/o/oauth2/auth?client_id=${CFG_GD_CLIENT_ID}&redirect_uri=urn:ietf:wg:oauth:2.0:oob&response_type=code&scope=https://www.googleapis.com/auth/drive.file"
    echo ""
    echo "${L[cfg_gd_auth_needed]}"
    echo "${L[cfg_gd_open_url]}"
    echo "$auth_url"
    echo ""
    read -rp "${L[cfg_gd_enter_code]}" gd_code

    echo "${L[cfg_gd_getting]}"
    local response
    response=$(curl -s -X POST "https://oauth2.googleapis.com/token" \
        -d "code=${gd_code}&client_id=${CFG_GD_CLIENT_ID}&client_secret=${CFG_GD_CLIENT_SECRET}&redirect_uri=urn:ietf:wg:oauth:2.0:oob&grant_type=authorization_code")
    CFG_GD_REFRESH_TOKEN=$(echo "$response" | grep -o '"refresh_token":"[^"]*"' | cut -d'"' -f4)

    if [[ -z "$CFG_GD_REFRESH_TOKEN" ]]; then
        log_error "${L[cfg_gd_fail]}"
        log_warn "${L[cfg_gd_incomplete2]}"
        CFG_UPLOAD_METHOD="telegram"
        return 1
    fi

    log_info "${L[ul_gd_token_ok]}"
    echo "${L[cfg_gd_folder1]}"
    echo "${L[cfg_gd_folder3]} https://drive.google.com/drive/folders/FOLDER_ID"
    echo "${L[cfg_gd_folder5]}"
    read -rp "${L[cfg_enter_gd_folder]}" CFG_GD_FOLDER_ID
    log_info "${L[ul_gd_saved]}"
}

# ─────────────────────────────────────────────
# Загрузить языковой файл
# ─────────────────────────────────────────────
load_language() {
    local lang="${1:-en}"
    if [[ "$lang" != "en" && "$lang" != "ru" ]]; then
        log_warn "Unknown language '$lang', falling back to 'en'"
        lang="en"
    fi
    case "$lang" in
        ru) _load_lang_ru ;;
        *)  _load_lang_en ;;
    esac
}

###############################################################################
# MODULE: telegram
###############################################################################
# Отправка сообщений и файлов через Telegram Bot API

TG_API_BASE="https://api.telegram.org/bot"

# Отправить текстовое сообщение
tg_send_message() {
    local text="$1"
    [[ -z "$CFG_BOT_TOKEN" || -z "$CFG_CHAT_ID" ]] && return 0

    local curl_args=(-s -X POST "${TG_API_BASE}${CFG_BOT_TOKEN}/sendMessage"
        -d "chat_id=${CFG_CHAT_ID}"
        -d "text=${text}"
        -d "parse_mode=HTML"
    )
    [[ -n "$CFG_THREAD_ID" ]] && curl_args+=(-d "message_thread_id=${CFG_THREAD_ID}")
    [[ -n "$CFG_TG_PROXY" ]] && curl_args+=(--proxy "$CFG_TG_PROXY")

    local response http_code
    response=$(curl "${curl_args[@]}")
    local ok; ok=$(echo "$response" | grep -o '"ok":true')
    if [[ -z "$ok" ]]; then
        log_error "${L[tg_send_err]} $(echo "$response" | grep -o '"error_code":[0-9]*')"
        log_error "${L[tg_response]} $response"
        return 1
    fi
    return 0
}

# Отправить файл в Telegram
tg_send_document() {
    local file="$1"
    local caption="$2"
    [[ -z "$CFG_BOT_TOKEN" || -z "$CFG_CHAT_ID" ]] && return 1
    [[ ! -f "$file" ]] && return 1

    local curl_args=(-s -X POST "${TG_API_BASE}${CFG_BOT_TOKEN}/sendDocument"
        -F "chat_id=${CFG_CHAT_ID}"
        -F "document=@${file}"
    )
    [[ -n "$caption" ]] && curl_args+=(-F "caption=${caption}" -F "parse_mode=HTML")
    [[ -n "$CFG_THREAD_ID" ]] && curl_args+=(-F "message_thread_id=${CFG_THREAD_ID}")
    [[ -n "$CFG_TG_PROXY" ]] && curl_args+=(--proxy "$CFG_TG_PROXY")

    local response
    response=$(curl "${curl_args[@]}")
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_error "${L[tg_curl_err]} $exit_code"
        log_warn "${L[tg_check_net]}"
        return 1
    fi

    local ok; ok=$(echo "$response" | grep -o '"ok":true')
    if [[ -z "$ok" ]]; then
        log_error "${L[tg_api_err]} $(echo "$response" | grep -o '"error_code":[0-9]*')"
        log_error "${L[tg_resp_label]} $response"
        log_warn "${L[tg_maybe_big]}"
        return 1
    fi
    return 0
}

# Уведомление об успешном бэкапе (текст)
tg_notify_backup_success() {
    local file="$1"
    local method="${2:-telegram}"

    local size; size=$(format_size "$file")
    local date_str; date_str=$(date "+%Y-%m-%d %H:%M:%S")

    local db_info
    case "$CFG_DB_TYPE" in
        docker)   db_info="${L[tg_db_docker]} (${CFG_DB_ENGINE}: ${CFG_DB_NAME})" ;;
        external) db_info="${L[tg_db_ext]} (${CFG_DB_ENGINE}@${CFG_DB_HOST})" ;;
        *)        db_info="${L[tg_db_none]}" ;;
    esac

    local title
    case "$method" in
        s3)           title="${L[tg_bk_s3]}" ;;
        google_drive) title="${L[tg_bk_gd]}" ;;
        *)            title="${L[tg_bk_success]}" ;;
    esac

    local msg
    msg="✅ <b>${title}</b>

${L[tg_project]} <code>${CFG_PROJECT_NAME}</code>
${L[tg_size]} <code>${size}</code>
${L[tg_date]} <code>${date_str}</code>
${L[tg_db]} ${db_info}"

    tg_send_message "$msg"
}

# Уведомление об ошибке
tg_notify_error() {
    local msg="$1"
    [[ -z "$CFG_BOT_TOKEN" || -z "$CFG_CHAT_ID" ]] && return 0
    tg_send_message "❌ <b>${CFG_PROJECT_NAME}</b>: ${msg}"
}

# Уведомление о доступном обновлении
tg_notify_update() {
    local current="$1"
    local latest="$2"
    local changelog="$3"
    local msg
    msg="🔔 <b>${L[tg_update_avail]}</b>
${L[tg_cur_ver]} <code>${current}</code>
${L[tg_new_ver]} <code>${latest}</code>
${L[tg_update_menu]}"
    [[ -n "$changelog" ]] && msg+="

${L[tg_auto_update_changelog]}
${changelog}"
    tg_send_message "$msg"
}

###############################################################################
# MODULE: s3
###############################################################################
# Работа с S3-совместимым хранилищем через AWS CLI

# Настроить окружение AWS CLI из текущего конфига
_s3_env() {
    export AWS_ACCESS_KEY_ID="$CFG_S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$CFG_S3_SECRET_KEY"
    export AWS_DEFAULT_REGION="${CFG_S3_REGION:-us-east-1}"
}

# Получить S3-путь к файлу (с префиксом)
_s3_key() {
    local filename="$1"
    if [[ -n "$CFG_S3_PREFIX" ]]; then
        echo "${CFG_S3_PREFIX%/}/${filename}"
    else
        echo "$filename"
    fi
}

# Заполнить глобальный массив S3_EXTRA_ARGS аргументами для aws s3
# Использование: _s3_args; затем "${S3_EXTRA_ARGS[@]}" в вызовах aws
_s3_args() {
    S3_EXTRA_ARGS=()
    [[ -n "$CFG_S3_ENDPOINT" ]] && S3_EXTRA_ARGS+=(--endpoint-url "$CFG_S3_ENDPOINT")
}

# ─────────────────────────────────────────────
# Загрузить файл в S3
# ─────────────────────────────────────────────
s3_upload() {
    local file="$1"
    [[ ! -f "$file" ]] && { log_error "${L[bk_s3_impossible]}"; return 1; }

    ensure_awscli || { log_error "${L[ul_s3_aws_needed]}"; return 1; }
    _s3_env

    local filename; filename=$(basename "$file")
    local key; key=$(_s3_key "$filename")
    _s3_args

    log_step "${L[bk_sending]} → s3://${CFG_S3_BUCKET}/${key}"
    if aws s3 cp "$file" "s3://${CFG_S3_BUCKET}/${key}" "${S3_EXTRA_ARGS[@]}"; then
        log_info "${L[s3_upload_ok]}"
        return 0
    else
        log_error "${L[s3_upload_err]}"
        return 1
    fi
}

# ─────────────────────────────────────────────
# Удалить старые бэкапы из S3 (по retention)
# ─────────────────────────────────────────────
s3_cleanup() {
    local retention="${CFG_S3_RETENTION_DAYS:-30}"
    ensure_awscli || return 1
    _s3_env

    local prefix="${CFG_S3_PREFIX:+${CFG_S3_PREFIX%/}/}"
    _s3_args
    local cutoff; cutoff=$(date -d "-${retention} days" +%s 2>/dev/null || date -v-"${retention}"d +%s)

    printf "${L[bk_s3_retention]}\n" "$retention"

    local deleted=0
    while IFS= read -r line; do
        local file_date file_key
        file_date=$(echo "$line" | awk '{print $1, $2}')
        file_key=$(echo "$line" | awk '{print $4}')
        [[ -z "$file_key" ]] && continue

        local file_ts
        file_ts=$(date -d "$file_date" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$file_date" +%s 2>/dev/null)
        if [[ -n "$file_ts" && "$file_ts" -lt "$cutoff" ]]; then
            aws s3 rm "s3://${CFG_S3_BUCKET}/${file_key}" "${S3_EXTRA_ARGS[@]}" &>/dev/null && ((deleted++)) || true
        fi
    done < <(aws s3 ls "s3://${CFG_S3_BUCKET}/${prefix}" "${S3_EXTRA_ARGS[@]}" 2>/dev/null)

    printf "${L[s3_cleaned]}\n" "$deleted"
    log_info "${L[bk_s3_retention_ok]}"
}

# ─────────────────────────────────────────────
# Получить список бэкапов из S3
# ─────────────────────────────────────────────
s3_list_backups() {
    ensure_awscli || return 1
    _s3_env

    local prefix="${CFG_S3_PREFIX:+${CFG_S3_PREFIX%/}/}"
    _s3_args

    log_step "${L[rs_s3_listing]}"
    aws s3 ls "s3://${CFG_S3_BUCKET}/${prefix}" "${S3_EXTRA_ARGS[@]}" 2>/dev/null \
        | grep '\.tar\.gz$' \
        | sort -k1,2 -r
}

# ─────────────────────────────────────────────
# Скачать файл из S3
# ─────────────────────────────────────────────
s3_download() {
    local s3_key="$1"
    local dest="$2"
    ensure_awscli || return 1
    _s3_env

    _s3_args
    aws s3 cp "s3://${CFG_S3_BUCKET}/${s3_key}" "$dest" "${S3_EXTRA_ARGS[@]}"
}

# ─────────────────────────────────────────────
# Тест подключения к S3
# ─────────────────────────────────────────────
s3_test_connection() {
    if [[ -z "$CFG_S3_BUCKET" || -z "$CFG_S3_ACCESS_KEY" || -z "$CFG_S3_SECRET_KEY" ]]; then
        log_error "${L[st_s3_test_missing]}"
        return 1
    fi
    ensure_awscli || return 1
    _s3_env

    _s3_args
    log_step "${L[st_s3_testing]}"
    if aws s3 ls "s3://${CFG_S3_BUCKET}" "${S3_EXTRA_ARGS[@]}" &>/dev/null; then
        log_info "${L[st_s3_test_ok]}"
        return 0
    else
        log_error "${L[st_s3_test_fail]}"
        return 1
    fi
}

###############################################################################
# MODULE: google_drive
###############################################################################
# Загрузка файлов в Google Drive через API

GD_API_UPLOAD="https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart"
GD_API_TOKEN="https://oauth2.googleapis.com/token"

# Получить access token через refresh token
_gd_access_token() {
    if [[ -z "$CFG_GD_CLIENT_ID" || -z "$CFG_GD_CLIENT_SECRET" || -z "$CFG_GD_REFRESH_TOKEN" ]]; then
        log_error "${L[gd_not_set]}"
        return 1
    fi

    local response
    response=$(curl -s -X POST "$GD_API_TOKEN" \
        -d "client_id=${CFG_GD_CLIENT_ID}" \
        -d "client_secret=${CFG_GD_CLIENT_SECRET}" \
        -d "refresh_token=${CFG_GD_REFRESH_TOKEN}" \
        -d "grant_type=refresh_token")

    local token
    token=$(echo "$response" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
    if [[ -z "$token" ]]; then
        log_error "${L[gd_token_err]}"
        return 1
    fi
    echo "$token"
}

# ─────────────────────────────────────────────
# Загрузить файл в Google Drive
# ─────────────────────────────────────────────
gd_upload() {
    local file="$1"
    [[ ! -f "$file" ]] && { log_error "${L[bk_gd_impossible]}"; return 1; }

    local access_token
    access_token=$(_gd_access_token) || return 1

    local filename; filename=$(basename "$file")

    # Метаданные файла
    local metadata="{\"name\":\"${filename}\""
    [[ -n "$CFG_GD_FOLDER_ID" ]] && metadata+=",\"parents\":[\"${CFG_GD_FOLDER_ID}\"]"
    metadata+="}"

    log_step "${L[bk_sending]} → Google Drive"

    # Формируем multipart/related тело вручную
    local boundary="boundary_$(date +%s)_$$"
    local body_file; body_file=$(mktemp)

    printf -- "--%s\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n%s\r\n--%s\r\nContent-Type: application/gzip\r\n\r\n" \
        "$boundary" "$metadata" "$boundary" > "$body_file"
    cat "$file" >> "$body_file"
    printf -- "\r\n--%s--\r\n" "$boundary" >> "$body_file"

    local response
    response=$(curl -s -X POST "$GD_API_UPLOAD" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Content-Type: multipart/related; boundary=${boundary}" \
        --data-binary "@${body_file}")

    rm -f "$body_file"

    local file_id
    file_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [[ -z "$file_id" ]]; then
        log_error "${L[gd_upload_err]}"
        return 1
    fi
    log_info "${L[gd_upload_ok]} (id: ${file_id})"
    return 0
}

###############################################################################
# MODULE: db
###############################################################################
# Создание и восстановление дампов БД (postgres/mysql/mongodb, docker/external)

# ─────────────────────────────────────────────
# Создать дамп БД
# Параметры: output_file
# ─────────────────────────────────────────────
db_dump() {
    local output_file="$1"
    local exit_code=0

    log_step "${L[bk_creating_dump]}"
    log_step "${L[bk_dump_type]} ${CFG_DB_ENGINE}"

    case "$CFG_DB_TYPE" in
        docker)
            log_step "${L[bk_dump_container]} ${CFG_DB_CONTAINER}"
            _db_dump_docker "$output_file"
            exit_code=$?
            ;;
        external)
            _db_dump_external "$output_file"
            exit_code=$?
            ;;
        *)
            log_warn "${L[bk_skip_db]}"
            return 0
            ;;
    esac

    if [[ $exit_code -ne 0 ]]; then
        log_error "${L[bk_dump_err]} ${exit_code}"
        log_warn "${L[bk_check_db]}"
        return 1
    fi

    log_info "${L[bk_dump_ok]}"
    return 0
}

# Дамп из Docker-контейнера
_db_dump_docker() {
    local output_file="$1"
    check_docker || return 1
    if [[ -z "${CFG_DB_CONTAINER:-}" ]]; then
        log_error "Не задано имя Docker-контейнера с БД."
        return 1
    fi
    if ! docker container inspect "$CFG_DB_CONTAINER" &>/dev/null; then
        log_error "Docker-контейнер не найден: ${CFG_DB_CONTAINER}"
        return 1
    fi

    case "$CFG_DB_ENGINE" in
        postgres)
            _pg_dump_docker "$output_file"
            ;;
        mysql|mariadb)
            _mysql_dump_docker "$output_file"
            ;;
        mongodb|mongo)
            _mongo_dump_docker "$output_file"
            ;;
        *)
            log_error "Неизвестный тип СУБД: ${CFG_DB_ENGINE}"
            return 1
            ;;
    esac
}

# Дамп внешней БД (без Docker)
_db_dump_external() {
    local output_file="$1"

    case "$CFG_DB_ENGINE" in
        postgres)
            _pg_dump_external "$output_file"
            ;;
        mysql|mariadb)
            _mysql_dump_external "$output_file"
            ;;
        mongodb|mongo)
            _mongo_dump_external "$output_file"
            ;;
        *)
            log_error "Неизвестный тип СУБД: ${CFG_DB_ENGINE}"
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────
# PostgreSQL — Docker
# ─────────────────────────────────────────────
_pg_dump_docker() {
    local output_file="$1"
    local pass_env=()
    [[ -n "$CFG_DB_PASS" ]] && pass_env=(-e "PGPASSWORD=${CFG_DB_PASS}")

    docker exec "${pass_env[@]}" "$CFG_DB_CONTAINER" \
        pg_dump -U "$CFG_DB_USER" -d "$CFG_DB_NAME" --no-owner --no-acl -Fc \
        > "$output_file"
}

# ─────────────────────────────────────────────
# PostgreSQL — External
# ─────────────────────────────────────────────
_pg_dump_external() {
    local output_file="$1"
    require_cmd pg_dump || _install_pgclient || return 1

    local host="${CFG_DB_HOST:-localhost}"
    local port="${CFG_DB_PORT:-5432}"
    local ssl="${CFG_DB_SSL:-prefer}"

    PGPASSWORD="$CFG_DB_PASS" pg_dump \
        -h "$host" -p "$port" -U "$CFG_DB_USER" -d "$CFG_DB_NAME" \
        --no-owner --no-acl -Fc \
        --sslmode="$ssl" \
        > "$output_file"
}

# Попытка установить pg_dump нужной версии (только Debian/Ubuntu)
_install_pgclient() {
    if [[ $EUID -ne 0 ]]; then
        log_error "pg_dump не найден. Установите postgresql-client-${CFG_DB_PGVER}"
        return 1
    fi
    local ver="${CFG_DB_PGVER:-17}"
    log_step "Установка postgresql-client-${ver}..."
    apt-get install -y "postgresql-client-${ver}" &>/dev/null || return 1
}

# ─────────────────────────────────────────────
# MySQL/MariaDB — Docker
# ─────────────────────────────────────────────
_mysql_dump_docker() {
    local output_file="$1"
    local pass_env=()
    [[ -n "$CFG_DB_PASS" ]] && pass_env=(-e "MYSQL_PWD=${CFG_DB_PASS}")

    docker exec "${pass_env[@]}" "$CFG_DB_CONTAINER" \
        mysqldump -u "$CFG_DB_USER" \
        --single-transaction --routines --triggers \
        "$CFG_DB_NAME" \
        > "$output_file"
}

# ─────────────────────────────────────────────
# MySQL/MariaDB — External
# ─────────────────────────────────────────────
_mysql_dump_external() {
    local output_file="$1"
    require_cmd mysqldump || return 1

    local host="${CFG_DB_HOST:-localhost}"
    local port="${CFG_DB_PORT:-3306}"

    MYSQL_PWD="$CFG_DB_PASS" mysqldump -h "$host" -P "$port" -u "$CFG_DB_USER" \
        --single-transaction --routines --triggers \
        "$CFG_DB_NAME" \
        > "$output_file"
}

# ─────────────────────────────────────────────
# MongoDB — Docker
# ─────────────────────────────────────────────
_mongo_dump_docker() {
    local output_file="$1"
    local auth_args=()
    [[ -n "$CFG_DB_USER" ]] && auth_args+=(--username "$CFG_DB_USER")
    [[ -n "$CFG_DB_PASS" ]] && auth_args+=(--password "$CFG_DB_PASS")
    [[ -n "$CFG_DB_NAME" ]] && auth_args+=(--db "$CFG_DB_NAME")

    docker exec "$CFG_DB_CONTAINER" mongodump "${auth_args[@]}" --archive \
        > "$output_file"
}

# ─────────────────────────────────────────────
# MongoDB — External
# ─────────────────────────────────────────────
_mongo_dump_external() {
    local output_file="$1"
    require_cmd mongodump || return 1

    local host="${CFG_DB_HOST:-localhost}"
    local port="${CFG_DB_PORT:-27017}"

    local auth_args=()
    [[ -n "$CFG_DB_USER" ]] && auth_args+=(--username "$CFG_DB_USER")
    [[ -n "$CFG_DB_PASS" ]] && auth_args+=(--password "$CFG_DB_PASS")
    [[ -n "$CFG_DB_NAME" ]] && auth_args+=(--db "$CFG_DB_NAME")

    mongodump --host "$host" --port "$port" "${auth_args[@]}" --archive \
        > "$output_file"
}

# ─────────────────────────────────────────────
# Восстановление БД
# ─────────────────────────────────────────────
db_restore() {
    local dump_file="$1"
    local container="${2:-$CFG_DB_CONTAINER}"
    local db_name="${3:-$CFG_DB_NAME}"
    local db_user="${4:-$CFG_DB_USER}"
    local db_pass="${5:-$CFG_DB_PASS}"
    local db_engine="${6:-$CFG_DB_ENGINE}"

    log_step "${L[rs_restoring_db]}"

    case "$db_engine" in
        postgres)
            _pg_restore "$dump_file" "$container" "$db_name" "$db_user" "$db_pass"
            ;;
        mysql|mariadb)
            _mysql_restore "$dump_file" "$container" "$db_name" "$db_user" "$db_pass"
            ;;
        mongodb|mongo)
            _mongo_restore "$dump_file" "$container"
            ;;
        *)
            log_error "Неизвестный тип СУБД для восстановления: ${db_engine}"
            return 1
            ;;
    esac
}

# Дождаться готовности PostgreSQL в контейнере
_wait_pg_ready() {
    local container="$1"
    local user="$2"
    local max_attempts=30
    local attempt=0

    log_step "${L[rs_wait_db]}"
    while (( attempt < max_attempts )); do
        if docker exec "$container" pg_isready -U "$user" &>/dev/null; then
            log_info "${L[rs_db_ready]}"
            return 0
        fi
        sleep 1
        ((attempt++))
    done
    log_error "${L[rs_db_timeout]}"
    return 1
}

_pg_restore() {
    local dump_file="$1" container="$2" db_name="$3" db_user="$4" db_pass="$5"
    _wait_pg_ready "$container" "$db_user" || return 1

    local pass_env=()
    [[ -n "$db_pass" ]] && pass_env=(-e "PGPASSWORD=${db_pass}")

    # Сначала дропаем и создаём заново
    docker exec "${pass_env[@]}" "$container" \
        psql -U "$db_user" -c "DROP DATABASE IF EXISTS \"${db_name}\";" postgres &>/dev/null || true
    docker exec "${pass_env[@]}" "$container" \
        psql -U "$db_user" -c "CREATE DATABASE \"${db_name}\";" postgres &>/dev/null || true

    docker exec -i "${pass_env[@]}" "$container" \
        pg_restore -U "$db_user" -d "$db_name" --no-owner --no-acl < "$dump_file"
}

_mysql_restore() {
    local dump_file="$1" container="$2" db_name="$3" db_user="$4" db_pass="$5"
    local pass_env=()
    [[ -n "$db_pass" ]] && pass_env=(-e "MYSQL_PWD=${db_pass}")

    docker exec -i "${pass_env[@]}" "$container" \
        mysql -u "$db_user" "$db_name" < "$dump_file"
}

_mongo_restore() {
    local dump_file="$1" container="$2"
    docker exec -i "$container" mongorestore --drop --archive < "$dump_file"
}

# ─────────────────────────────────────────────
# Тест подключения к внешней БД
# ─────────────────────────────────────────────
db_test_connection() {
    if [[ "$CFG_DB_TYPE" != "external" ]]; then
        log_warn "${L[st_db_only_ext]}"
        return 1
    fi

    log_step "${L[st_db_testing]}"
    case "$CFG_DB_ENGINE" in
        postgres)
            PGPASSWORD="$CFG_DB_PASS" pg_isready \
                -h "${CFG_DB_HOST:-localhost}" \
                -p "${CFG_DB_PORT:-5432}" \
                -U "$CFG_DB_USER" &>/dev/null
            ;;
        mysql|mariadb)
            MYSQL_PWD="$CFG_DB_PASS" mysql -h "${CFG_DB_HOST:-localhost}" -P "${CFG_DB_PORT:-3306}" \
                -u "$CFG_DB_USER" -e "SELECT 1;" &>/dev/null
            ;;
        mongodb|mongo)
            mongosh --host "${CFG_DB_HOST:-localhost}" \
                --port "${CFG_DB_PORT:-27017}" \
                --eval "db.runCommand({ping:1})" &>/dev/null
            ;;
        *)
            log_error "Тест не поддерживается для ${CFG_DB_ENGINE}"
            return 1
            ;;
    esac

    if [[ $? -eq 0 ]]; then
        log_info "${L[st_db_test_ok]}"
    else
        log_error "${L[st_db_test_fail]}"
        return 1
    fi
}

###############################################################################
# MODULE: backup_logic
###############################################################################
# Логика создания резервной копии

# ─────────────────────────────────────────────
# Основная функция создания бэкапа
# ─────────────────────────────────────────────
do_backup() {
    if [[ -z "${CFG_PROJECT_NAME:-}" ]]; then
        log_error "Активный проект не выбран. Откройте настройки проекта и выберите профиль."
        return 1
    fi
    local ts; ts=$(timestamp)
    local archive_name="${CFG_PROJECT_NAME}_${ts}.tar.gz"
    local backup_dir="$CFG_BACKUP_DIR"
    local tmp_dir; tmp_dir=$(mktemp -d)
    # Гарантировать очистку временной директории при выходе или сигналах
    trap 'cleanup_tmpdir "${tmp_dir:-}"' EXIT INT TERM
    local final_archive="${backup_dir}/${archive_name}"
    local has_data=false

    # Создать директорию для бэкапов
    if ! mkdir -p "$backup_dir"; then
        log_error "${L[bk_mkdir_err]} $backup_dir"
        cleanup_tmpdir "$tmp_dir"
        return 1
    fi

    echo ""
    echo -e "${BOLD}${L[bk_starting]}${NC}"
    log_step "${L[bk_project]} ${CFG_PROJECT_NAME}"

    # ── 1. Дамп БД ──────────────────────────────
    if [[ "$CFG_DB_TYPE" != "none" && -n "$CFG_DB_TYPE" ]]; then
        local db_ext
        case "$CFG_DB_ENGINE" in
            mysql|mariadb) db_ext="sql" ;;
            mongodb|mongo) db_ext="archive" ;;
            *)             db_ext="dump" ;;
        esac
        local dump_file="${tmp_dir}/db_dump.${db_ext}"

        if db_dump "$dump_file"; then
            has_data=true
        else
            cleanup_tmpdir "$tmp_dir"
            tg_notify_error "${L[bk_dump_err]}"
            return 1
        fi
    else
        log_warn "${L[bk_skip_db]}"
    fi

    # ── 2. Директория проекта ───────────────────
    if [[ "$CFG_BACKUP_DIR_ENABLED" == "true" && -n "$CFG_PROJECT_DIR" ]]; then
        if [[ -d "$CFG_PROJECT_DIR" ]]; then
            local project_parent project_base archive_ok=false archive_attempted=false
            project_parent="$(dirname "$CFG_PROJECT_DIR")"
            project_base="$(basename "$CFG_PROJECT_DIR")"

            if [[ "${CFG_BACKUP_DIR_MODE:-full}" == "selected" ]]; then
                log_step "${L[bk_archiving_dir_selected]} ${CFG_PROJECT_DIR}"
                local rel abs_path
                local -a tar_items=()
                while IFS= read -r rel; do
                    [[ -z "$rel" ]] && continue
                    [[ "$rel" == /* || "$rel" == *".."* ]] && continue
                    abs_path="${CFG_PROJECT_DIR}/${rel}"
                    if [[ -e "$abs_path" ]]; then
                        tar_items+=("${project_base}/${rel}")
                    fi
                done <<< "${CFG_BACKUP_DIR_ITEMS:-}"

                if (( ${#tar_items[@]} > 0 )); then
                    archive_attempted=true
                    if tar -czf "${tmp_dir}/project_dir.tar.gz" -C "$project_parent" "${tar_items[@]}" 2>/dev/null; then
                        archive_ok=true
                    fi
                else
                    log_warn "${L[st_project_scope_none]}"
                fi
            else
                log_step "${L[bk_archiving_dir]} ${CFG_PROJECT_DIR}"
                archive_attempted=true
                if tar -czf "${tmp_dir}/project_dir.tar.gz" \
                        --exclude="${CFG_PROJECT_DIR}/.git" \
                        -C "$project_parent" \
                        "$project_base" 2>/dev/null; then
                    archive_ok=true
                fi
            fi

            if [[ "$archive_ok" == "true" ]]; then
                log_info "${L[bk_dir_ok]}"
                has_data=true
            elif [[ "$archive_attempted" == "true" ]]; then
                log_error "${L[bk_dir_err]}"
            fi
        else
            log_warn "${L[bk_dir_missing]} $CFG_PROJECT_DIR"
        fi
    else
        log_warn "${L[bk_skip_dir]}"
    fi

    # ── Проверить, есть ли что архивировать ─────
    if [[ "$has_data" != "true" ]]; then
        log_error "${L[bk_no_data]}"
        cleanup_tmpdir "$tmp_dir"
        return 1
    fi

    # ── 3. Записать метаданные ───────────────────
    cat > "${tmp_dir}/backup_meta.json" <<EOF
{
  "project": "${CFG_PROJECT_NAME}",
  "version": "${SCRIPT_VERSION}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "db_type": "${CFG_DB_TYPE}",
  "db_engine": "${CFG_DB_ENGINE}",
  "dir_included": ${CFG_BACKUP_DIR_ENABLED:-false},
  "dir_mode": "${CFG_BACKUP_DIR_MODE:-full}"
}
EOF

    # ── 4. Финальный архив ───────────────────────
    log_step "${L[bk_cleaning]}"
    if ! tar -czf "$final_archive" -C "$tmp_dir" . 2>/dev/null; then
        local exit_code=$?
        log_error "${L[bk_final_err]} $exit_code"
        cleanup_tmpdir "$tmp_dir"
        return 1
    fi

    cleanup_tmpdir "$tmp_dir"
    # Сбросить trap после явной очистки
    trap - EXIT INT TERM
    log_info "${L[bk_final_ok]} $final_archive"

    # ── 5. Отправить/загрузить ───────────────────
    _send_backup "$final_archive"
    local send_status=$?

    # ── 6. Локальная ротация ─────────────────────
    _apply_local_retention

    return $send_status
}

# ─────────────────────────────────────────────
# Отправить бэкап выбранным методом
# ─────────────────────────────────────────────
_send_backup() {
    local file="$1"
    local size; size=$(format_size "$file")
    log_step "${L[bk_sending]} ($size)"

    case "$CFG_UPLOAD_METHOD" in
        telegram)
            _send_via_telegram "$file" "$size"
            ;;
        s3)
            _send_via_s3 "$file"
            ;;
        google_drive)
            _send_via_gd "$file"
            ;;
        *)
            log_error "${L[bk_unknown_method]} ${CFG_UPLOAD_METHOD}"
            log_warn "${L[bk_not_sent]}"
            log_info "${L[bk_saved_local]} $file"
            return 1
            ;;
    esac
}

_send_via_telegram() {
    local file="$1"
    local size="$2"

    # Проверить лимит Telegram (50 MB)
    local size_bytes; size_bytes=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
    local limit=$((50 * 1024 * 1024))

    if (( size_bytes > limit )); then
        printf "${L[bk_tg_big]}\n" "$size"
        log_info "${L[bk_saved_local]} $file"
        tg_notify_backup_success "$file" "telegram"
        printf "${L[bk_tg_big_notify]}\n" "$size"
        return 0
    fi

    if tg_send_document "$file" "💾 Backup: ${CFG_PROJECT_NAME} | ${size}"; then
        log_info "${L[bk_tg_ok]}"
    else
        log_error "${L[bk_tg_err]}"
        log_info "${L[bk_saved_local]} $file"
        return 1
    fi
}

_send_via_s3() {
    local file="$1"
    if s3_upload "$file"; then
        log_info "${L[bk_s3_ok]}"
        if tg_notify_backup_success "$file" "s3"; then
            log_info "${L[bk_s3_notify_ok]}"
        else
            log_warn "${L[bk_s3_notify_fail]}"
        fi
        s3_cleanup
    else
        log_error "${L[bk_s3_err]}"
        tg_notify_error "${L[bk_s3_err_tg]}"
        return 1
    fi
}

_send_via_gd() {
    local file="$1"
    if gd_upload "$file"; then
        log_info "${L[bk_gd_ok]}"
        if tg_notify_backup_success "$file" "google_drive"; then
            log_info "${L[bk_gd_notify_ok]}"
        else
            log_warn "${L[bk_gd_notify_fail]}"
        fi
    else
        log_error "${L[bk_gd_err]}"
        tg_notify_error "${L[bk_gd_err_tg]}"
        return 1
    fi
}

# ─────────────────────────────────────────────
# Локальная ротация (удалить старые бэкапы)
# ─────────────────────────────────────────────
_apply_local_retention() {
    local retention="${CFG_RETENTION_DAYS:-30}"
    # Проверить, что значение является положительным целым числом
    if ! [[ "$retention" =~ ^[1-9][0-9]*$ ]]; then
        log_warn "CFG_RETENTION_DAYS='$retention' не является положительным целым числом — локальная ротация пропущена"
        return 0
    fi
    printf "${L[bk_retention]}\n" "$retention"
    find "$CFG_BACKUP_DIR" -maxdepth 1 -name "*.tar.gz" \
        -mtime "+${retention}" -delete 2>/dev/null || true
    log_info "${L[bk_retention_ok]}"
}

###############################################################################
# MODULE: restore
###############################################################################
# Логика восстановления из бэкапа

# ─────────────────────────────────────────────
# Главная функция восстановления
# ─────────────────────────────────────────────
do_restore() {
    echo ""
    echo -e "${BOLD}${L[rs_title]}${NC}"
    echo "────────────────────────────────"

    # Источник бэкапа
    _menu_select "1 2 0" "1" "${L[rs_source_local]}" "${L[rs_source_s3]}" "${L[back]}"
    source_choice="$MENU_CHOICE"

    local archive_file=""
    case "$source_choice" in
        1) archive_file=$(_pick_local_backup) ;;
        2) archive_file=$(_pick_s3_backup) ;;
        0) return 0 ;;
        *) log_warn "${L[invalid_input_select]}"; return 1 ;;
    esac

    [[ -z "$archive_file" || ! -f "$archive_file" ]] && {
        log_warn "${L[rs_cancelled]}"
        return 0
    }

    _restore_from_archive "$archive_file"
}

# Выбрать локальный файл бэкапа
_pick_local_backup() {
    local dir="$CFG_BACKUP_DIR"
    echo "${L[rs_place_file]} $dir" >&2

    local files=()
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$dir" -maxdepth 1 -name "*.tar.gz" -printf "%T@ %p\n" 2>/dev/null \
        | sort -rn | awk '{print $2}')

    if [[ ${#files[@]} -eq 0 ]]; then
        log_warn "${L[rs_no_files]} $dir" >&2
        return 0
    fi

    echo "" >&2
    echo "${L[rs_select_file]}" >&2
    for i in "${!files[@]}"; do
        echo "  $((i+1)). $(basename "${files[$i]}")" >&2
    done

    while true; do
        read -rp "${L[rs_enter_num]}" num
        if [[ "$num" == "0" ]]; then
            return 0
        fi
        if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#files[@]} )); then
            echo "${files[$((num-1))]}"
            return 0
        fi
        log_warn "${L[rs_invalid_num]}" >&2
    done
}

# Выбрать бэкап из S3 и скачать его
_pick_s3_backup() {
    local lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done < <(s3_list_backups)

    if [[ ${#lines[@]} -eq 0 ]]; then
        log_warn "${L[rs_s3_no_files]}" >&2
        return 0
    fi

    echo "" >&2
    echo "${L[rs_s3_select]}" >&2
    for i in "${!lines[@]}"; do
        echo "  $((i+1)). ${lines[$i]}" >&2
    done

    while true; do
        read -rp "${L[rs_enter_num]}" num
        [[ "$num" == "0" ]] && return 0
        if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#lines[@]} )); then
            local selected="${lines[$((num-1))]}"
            local s3_key; s3_key=$(echo "$selected" | awk '{print $4}')
            local filename; filename=$(basename "$s3_key")
            local dest="${CFG_BACKUP_DIR}/${filename}"
            mkdir -p "$CFG_BACKUP_DIR"
            log_step "${L[rs_s3_stream]} $s3_key" >&2
            if s3_download "$s3_key" "$dest"; then
                log_info "${L[rs_s3_stream_ok]}" >&2
                echo "$dest"
            else
                log_error "${L[rs_s3_stream_err]}" >&2
            fi
            return 0
        fi
        log_warn "${L[rs_invalid_num]}" >&2
    done
}

# ─────────────────────────────────────────────
# Восстановление из конкретного архива
# ─────────────────────────────────────────────
_restore_from_archive() {
    local archive="$1"
    local tmp_dir; tmp_dir=$(mktemp -d)
    # Гарантировать очистку временной директории при выходе или сигналах
    trap 'cleanup_tmpdir "${tmp_dir:-}"' EXIT INT TERM

    # Распаковать
    log_step "${L[rs_unpacking]}"
    if ! tar -xzf "$archive" -C "$tmp_dir" 2>/dev/null; then
        log_error "${L[rs_unpack_err]}"
        cleanup_tmpdir "$tmp_dir"
        return 1
    fi
    log_info "${L[rs_unpacked]}"

    # Прочитать метаданные
    local meta_file="${tmp_dir}/backup_meta.json"
    if [[ -f "$meta_file" ]]; then
        local project version ts
        project=$(grep -o '"project":"[^"]*"' "$meta_file" | cut -d'"' -f4)
        version=$(grep -o '"version":"[^"]*"' "$meta_file" | cut -d'"' -f4)
        ts=$(grep -o '"timestamp":"[^"]*"' "$meta_file" | cut -d'"' -f4)
        echo "${L[rs_meta]} ${project:-${L[rs_meta_unknown]}}"
        echo "${L[rs_meta_ver]} ${version:-${L[rs_meta_unknown]}}"
        echo "${L[rs_meta_ts]} ${ts:-${L[rs_meta_unknown]}}"
    else
        log_warn "${L[rs_no_meta]}"
    fi

    local restored_anything=false

    # ── БД ──────────────────────────────────────
    local dump_file
    dump_file=$(find "$tmp_dir" -maxdepth 1 -name "db_dump.*" | head -1)
    if [[ -f "$dump_file" ]]; then
        echo ""
        log_info "${L[rs_db_found]}"
        if confirm "${L[rs_db_q]}"; then
            read -rp "${L[rs_db_container_prompt]}" rs_container
            [[ -z "$rs_container" ]] && rs_container="$CFG_DB_CONTAINER"
            read -rp "${L[rs_db_name_prompt]}" rs_db_name
            [[ -z "$rs_db_name" ]] && rs_db_name="${CFG_DB_NAME:-postgres}"
            read -rp "${L[rs_db_user_prompt]}" rs_db_user
            [[ -z "$rs_db_user" ]] && rs_db_user="${CFG_DB_USER:-postgres}"
            read -rsp "${L[rs_db_pass_prompt]}" rs_db_pass; echo ""

            if db_restore "$dump_file" "$rs_container" "$rs_db_name" "$rs_db_user" "$rs_db_pass" "$CFG_DB_ENGINE"; then
                log_info "${L[rs_db_ok]}"
                restored_anything=true
            else
                log_error "${L[rs_db_err]}"
            fi
        fi
    fi

    # ── .env ────────────────────────────────────
    if [[ -f "${tmp_dir}/.env" ]]; then
        echo ""
        log_info "${L[rs_env_found]}"
        if confirm "${L[rs_env_q]}"; then
            local env_dest
            _menu_select "1 2" "1" "${L[rs_env_dest_original]} (${CFG_PROJECT_ENV})" "${L[rs_env_dest_custom]}"
            env_choice="$MENU_CHOICE"
            if [[ "$env_choice" == "2" ]]; then
                env_dest=$(input_path "${L[rs_env_enter_path]}" false)
            else
                env_dest="$CFG_PROJECT_ENV"
            fi

            if [[ -n "$env_dest" ]]; then
                mkdir -p "$(dirname "$env_dest")"
                if cp "${tmp_dir}/.env" "$env_dest"; then
                    secure_file "$env_dest"
                    log_info "${L[rs_env_ok]}"
                    restored_anything=true
                else
                    log_error "${L[rs_env_err]}"
                fi
            fi
        fi
    fi

    # ── Директория проекта ───────────────────────
    if [[ -f "${tmp_dir}/project_dir.tar.gz" ]]; then
        echo ""
        log_info "${L[rs_dir_found]}"
        if confirm "${L[rs_dir_q]}"; then
            local dir_dest
            _menu_select "1 2" "1" "${L[rs_dir_dest_original]} ($(dirname "${CFG_PROJECT_DIR}"))" "${L[rs_dir_dest_custom]}"
            dir_choice="$MENU_CHOICE"
            if [[ "$dir_choice" == "2" ]]; then
                dir_dest=$(input_path "${L[rs_dir_enter_path]}" false)
            else
                dir_dest="$(dirname "${CFG_PROJECT_DIR}")"
            fi

            if [[ -n "$dir_dest" ]]; then
                mkdir -p "$dir_dest"
                if tar -xzf "${tmp_dir}/project_dir.tar.gz" -C "$dir_dest" 2>/dev/null; then
                    log_info "${L[rs_dir_ok]}"
                    restored_anything=true
                else
                    log_error "${L[rs_dir_err]}"
                fi
            fi
        fi
    fi

    cleanup_tmpdir "$tmp_dir"
    # Сбросить trap после явной очистки
    trap - EXIT INT TERM

    if [[ "$restored_anything" == "false" ]]; then
        log_warn "${L[rs_nothing]}"
    else
        echo ""
        log_info "${L[rs_complete]}"
        tg_send_message "✅ <b>${L[tg_restore_done]}</b>
${L[tg_project]} <code>${CFG_PROJECT_NAME}</code>
${L[tg_date]} <code>$(date '+%Y-%m-%d %H:%M:%S')</code>"
    fi
}

###############################################################################
# MODULE: cron
###############################################################################
# Управление cron-расписанием автоматического бэкапа

# Вычисляется лениво, после загрузки конфига
_cron_marker() { echo "# universal-backup: ${CFG_ACTIVE_PROJECT:-default}"; }

# ─────────────────────────────────────────────
# Меню настройки cron
# ─────────────────────────────────────────────
cron_menu() {
    if [[ $EUID -ne 0 ]]; then
        log_warn "${L[cron_root]}"
        press_enter_back
        return
    fi

    while true; do
        clear
        echo ""
        echo -e "${BOLD}${L[cron_title]}${NC}"
        echo "────────────────────────────────"
        _cron_status_line
        echo ""
        _menu_select "1 2 0" "1" "${L[cron_enable]}" "${L[cron_disable]}" "${L[back_to_menu]}"
        choice="$MENU_CHOICE"
        case "$choice" in
            1) _cron_enable ;;
            2) _cron_disable ;;
            0) return ;;
            *) log_warn "${L[invalid_input_select]}" ;;
        esac
    done
}

# Показать текущий статус cron
_cron_status_line() {
    local current
    current=$({ crontab -l 2>/dev/null || true; } | grep -F "$(_cron_marker)" || true)
    if [[ -n "$current" ]]; then
        local schedule; schedule=$(echo "$current" | awk '{print $1,$2,$3,$4,$5}')
        echo "${L[cron_on]} ${schedule} ${L[cron_utc]}"
    else
        echo "${L[cron_off]}"
    fi
}

# Включить / перезаписать расписание
_cron_enable() {
    echo ""
    echo "${L[cron_variant]}"
    _menu_select "1 2 0" "1" "${L[cron_hourly]}" "${L[cron_daily]}" "${L[back]}"
    variant="$MENU_CHOICE"

    local cron_expr=""
    case "$variant" in
        1)
            cron_expr="0 * * * *"
            ;;
        2)
            echo "${L[cron_enter_utc]}"
            read -rp "${L[cron_time_space]}" time_input
            cron_expr=$(_parse_daily_times $time_input)
            [[ -z "$cron_expr" ]] && { log_warn "${L[cron_err_input]}"; return; }
            ;;
        0) return ;;
        *) log_warn "${L[cron_bad_choice]}"; return ;;
    esac

    _install_cron "$cron_expr"
}

# Разобрать одно или несколько времён "HH:MM ..." в cron-выражение
_parse_daily_times() {
    local times=("$@")
    local minutes_list=()
    local hours_list=()

    for t in "${times[@]}"; do
        if ! [[ "$t" =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
            log_warn "${L[cron_bad_fmt]} $t ${L[cron_expect_hhmm]}"
            return 1
        fi
        local h="${BASH_REMATCH[1]}"
        local m="${BASH_REMATCH[2]}"
        if (( h > 23 || m > 59 )); then
            log_warn "${L[cron_bad_value]} $t ${L[cron_hm_range]}"
            return 1
        fi
        hours_list+=("$h")
        minutes_list+=("$m")
    done

    local i
    for (( i = 0; i < ${#times[@]}; i++ )); do
        echo "${minutes_list[$i]} ${hours_list[$i]} * * *"
    done
}

# Установить cron-задачу
_install_cron() {
    local cron_expr="$1"
    local script_path; script_path=$(realpath "$BACKUP_SCRIPT" 2>/dev/null || echo "$BACKUP_SCRIPT")
    local marker; marker=$(_cron_marker)
    local project_arg="${CFG_ACTIVE_PROJECT:-default}"
    # cron_expr может содержать несколько строк (по одной на каждое время)
    local cron_lines=""
    while IFS= read -r expr_line; do
        [[ -z "$expr_line" ]] && continue
        cron_lines+="${expr_line} ${script_path} --project ${project_arg} backup ${marker}"$'\n'
    done <<< "$cron_expr"

    log_step "${L[cron_setting]}"

    # Удалить старые записи этого проекта
    local current_cron
    current_cron=$({ crontab -l 2>/dev/null || true; } | grep -vF "$marker" || true)

    # Добавить SHELL и PATH если нет
    local new_cron=""
    if ! printf '%s\n' "$current_cron" | grep -q "^SHELL="; then
        new_cron+=$'SHELL=/bin/bash\n'
        log_info "${L[cron_shell]}"
    fi
    if ! printf '%s\n' "$current_cron" | grep -q "^PATH="; then
        new_cron+=$'PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n'
        log_info "${L[cron_path_add]}"
    else
        log_info "${L[cron_path_exists]}"
    fi

    new_cron+="${current_cron}"$'\n'"${cron_lines}"

    if printf '%s\n' "$new_cron" | crontab -; then
        log_info "${L[cron_ok]}"
        echo "${L[cron_set]} ${cron_expr}"
    else
        log_error "${L[cron_fail]}"
    fi
}

# Выключить автоматический бэкап
_cron_disable() {
    log_step "${L[cron_disabling]}"
    local current_cron
    current_cron=$({ crontab -l 2>/dev/null || true; } | grep -vF "$(_cron_marker)" || true)
    echo "$current_cron" | crontab -
    log_info "${L[cron_disabled]}"
}

###############################################################################
# MODULE: update
###############################################################################
# Проверка обновлений и самообновление скрипта

GITHUB_RAW_URL="https://raw.githubusercontent.com/sterben-enec/backup-script/main/backup-restore.sh"
GITHUB_API_URL="https://api.github.com/repos/sterben-enec/backup-script/releases/latest"

# ─────────────────────────────────────────────
# Проверить и применить обновление
# ─────────────────────────────────────────────
do_update() {
    if [[ $EUID -ne 0 ]]; then
        log_warn "${L[upd_root]}"
        press_enter_back
        return
    fi

    log_step "${L[upd_checking]}"
    log_step "${L[upd_fetching]}"

    local latest_info
    latest_info=$(curl -sf "$GITHUB_API_URL" 2>/dev/null || true)
    if [[ -z "$latest_info" ]]; then
        log_error "${L[upd_fetch_fail]}"
        press_enter_back
        return
    fi

    local latest_version
    latest_version=$(echo "$latest_info" | grep '"tag_name"' | head -1 | cut -d'"' -f4 | tr -d 'v')
    if [[ -z "$latest_version" ]]; then
        log_error "${L[upd_parse_fail]}"
        press_enter_back
        return
    fi

    local current_version="$SCRIPT_VERSION"
    echo "${L[upd_current]} $current_version"
    echo "${L[upd_available]} $latest_version"

    if [[ "$latest_version" == "$current_version" ]]; then
        log_info "${L[upd_latest]}"
        press_enter_back
        return
    fi

    echo ""
    log_info "${L[upd_new_avail]} $latest_version"
    if ! confirm "${L[upd_confirm]}"; then
        log_warn "${L[upd_cancelled]}"
        press_enter_back
        return
    fi

    _perform_update "$latest_version"
}

_perform_update() {
    local new_version="$1"
    local script_path; script_path=$(realpath "$BACKUP_SCRIPT")
    local tmp_file; tmp_file=$(mktemp)

    log_step "${L[upd_downloading]}"
    if ! curl -sf "$GITHUB_RAW_URL" -o "$tmp_file"; then
        log_error "${L[upd_download_fail]}"
        rm -f "$tmp_file"
        press_enter_back
        return
    fi

    # Проверить, что скачали bash-скрипт
    if [[ ! -s "$tmp_file" ]] || ! head -1 "$tmp_file" | grep -q "bash"; then
        log_error "${L[upd_invalid_file]}"
        rm -f "$tmp_file"
        press_enter_back
        return
    fi

    # Удалить старые бэкапы скрипта (оставить последний)
    log_step "${L[upd_rm_old_bak]}"
    find "$(dirname "$script_path")" -maxdepth 1 -name "backup.sh.bak.*" | sort | head -n -1 | xargs rm -f 2>/dev/null || true

    # Создать бэкап текущего
    log_step "${L[upd_creating_bak]}"
    local bak_file="${script_path}.bak.$(date +%Y%m%d_%H%M%S)"
    if ! cp "$script_path" "$bak_file"; then
        log_error "${L[upd_bak_fail]}"
        rm -f "$tmp_file"
        press_enter_back
        return
    fi

    # Заменить скрипт
    if ! mv "$tmp_file" "$script_path"; then
        log_error "${L[upd_move_fail]}"
        log_step "${L[upd_restoring_bak]}"
        cp "$bak_file" "$script_path"
        press_enter_back
        return
    fi

    chmod +x "$script_path"
    log_info "${L[upd_done]} $new_version"
    echo "${L[upd_restart]}"
    press_enter_back
}

check_update() {
    log_step "${L[upd_checking]}"
    log_step "${L[upd_fetching]}"

    local latest_info
    latest_info=$(curl -sf "$GITHUB_API_URL" 2>/dev/null || true)
    if [[ -z "$latest_info" ]]; then
        log_error "${L[upd_fetch_fail]}"
        return 1
    fi

    local latest_version current_version
    latest_version=$(echo "$latest_info" | grep '"tag_name"' | head -1 | cut -d'"' -f4 | tr -d 'v')
    current_version="$SCRIPT_VERSION"

    if [[ -z "$latest_version" ]]; then
        log_error "${L[upd_parse_fail]}"
        return 1
    fi

    echo "${L[upd_current]} $current_version"
    echo "${L[upd_available]} $latest_version"
    if [[ "$latest_version" == "$current_version" ]]; then
        log_info "${L[upd_latest]}"
    else
        log_info "${L[upd_new_avail]} $latest_version"
    fi
}

# ─────────────────────────────────────────────
# Фоновая проверка (вызывается при старте)
# ─────────────────────────────────────────────
check_update_bg() {
    [[ "$CFG_AUTO_UPDATE" != "true" ]] && return

    local latest_info
    latest_info=$(curl -sf --max-time 5 "$GITHUB_API_URL" 2>/dev/null || true)
    [[ -z "$latest_info" ]] && return

    local latest_version
    latest_version=$(echo "$latest_info" | grep '"tag_name"' | head -1 | cut -d'"' -f4 | tr -d 'v')
    [[ -z "$latest_version" || "$latest_version" == "$SCRIPT_VERSION" ]] && return

    local changelog
    changelog=$(echo "$latest_info" | grep '"body"' | head -1 | cut -d'"' -f4 | head -c 500)

    if [[ "$CFG_AUTO_UPDATE" == "true" ]]; then
        tg_notify_update "$SCRIPT_VERSION" "$latest_version" "$changelog"
    fi
}

_project_selected_items_count() {
    local count=0 line
    while IFS= read -r line; do
        [[ -n "$line" ]] && ((count++))
    done <<< "${CFG_BACKUP_DIR_ITEMS:-}"
    echo "$count"
}

_project_selected_items_preview() {
    local preview="" line count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ((count++))
        if (( count <= 3 )); then
            if [[ -z "$preview" ]]; then
                preview="$line"
            else
                preview+=", $line"
            fi
        fi
    done <<< "${CFG_BACKUP_DIR_ITEMS:-}"

    if (( count == 0 )); then
        echo "${L[st_project_scope_none]}"
    elif (( count > 3 )); then
        echo "${preview}, +$((count - 3))"
    else
        echo "$preview"
    fi
}

_project_dir_picker() {
    local root="$1"
    local current_rel="" current_abs="$root"
    local key seq cursor=0 i
    local -A selected=()
    local -a dirs files entries labels keys

    [[ -d "$root" ]] || return 1

    # preload current selection
    while IFS= read -r i; do
        [[ -n "$i" ]] && selected["$i"]=1
    done <<< "${CFG_BACKUP_DIR_ITEMS:-}"

    while true; do
        dirs=()
        files=()
        entries=()
        labels=()
        keys=()

        local p name
        shopt -s nullglob dotglob
        for p in "$current_abs"/*; do
            name="${p##*/}"
            [[ "$name" == "." || "$name" == ".." ]] && continue
            if [[ -d "$p" ]]; then
                dirs+=("$name/")
            else
                files+=("$name")
            fi
        done
        shopt -u nullglob dotglob

        if (( ${#dirs[@]} > 0 )); then
            mapfile -t dirs < <(printf '%s\n' "${dirs[@]}" | LC_ALL=C sort)
        fi
        if (( ${#files[@]} > 0 )); then
            mapfile -t files < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort)
        fi

        keys+=("__confirm")
        labels+=("${L[pick_confirm_item]}")

        if [[ -n "$current_rel" ]]; then
            keys+=("__up")
            labels+=("${L[pick_up]}")
        fi

        for name in "${dirs[@]}" "${files[@]}"; do
            local rel
            if [[ -n "$current_rel" ]]; then
                rel="${current_rel}/${name%/}"
            else
                rel="${name%/}"
            fi
            keys+=("item:${name}")
            if [[ -n "${selected[$rel]+x}" ]]; then
                labels+=("[x] ${name}")
            else
                labels+=("[ ] ${name}")
            fi
        done

        (( cursor >= ${#labels[@]} )) && cursor=$(( ${#labels[@]} - 1 ))
        (( cursor < 0 )) && cursor=0

        clear
        echo ""
        echo -e "${BOLD}${L[pick_title]}${NC}"
        echo "────────────────────────────────────────────────────────────────"
        echo "${L[pick_current]} ${current_rel:-/}"
        echo "${L[pick_selected]} ${#selected[@]}"
        echo "${L[pick_help]}"
        echo ""

        for i in "${!labels[@]}"; do
            if (( i == cursor )); then
                echo -e "  ${BOLD}${GREEN}>${NC} ${labels[$i]}"
            else
                echo "    ${labels[$i]}"
            fi
        done

        IFS= read -rsn1 key || return 1

        if [[ "$key" == $'\e' ]]; then
            seq=""
            while IFS= read -rsn1 -t 0.05 key; do
                seq+="$key"
                [[ "$key" =~ [A-Za-z~] ]] && break
            done
            case "$seq" in
                "[A"|"OA") cursor=$(( (cursor - 1 + ${#labels[@]}) % ${#labels[@]} )) ;;
                "[B"|"OB") cursor=$(( (cursor + 1) % ${#labels[@]} )) ;;
                "[D"|"OD")
                    if [[ -n "$current_rel" ]]; then
                        if [[ "$current_rel" == */* ]]; then
                            current_rel="${current_rel%/*}"
                        else
                            current_rel=""
                        fi
                        current_abs="$root${current_rel:+/$current_rel}"
                        cursor=0
                    fi
                    ;;
            esac
            continue
        fi

        if [[ "$key" == " " ]]; then
            local selected_key="${keys[$cursor]}"
            if [[ "$selected_key" == item:* ]]; then
                name="${selected_key#item:}"
                local rel
                if [[ -n "$current_rel" ]]; then
                    rel="${current_rel}/${name%/}"
                else
                    rel="${name%/}"
                fi
                if [[ -n "${selected[$rel]+x}" ]]; then
                    unset 'selected[$rel]'
                else
                    selected["$rel"]=1
                fi
            fi
            continue
        fi

        if [[ "$key" == $'\177' ]]; then
            if [[ -n "$current_rel" ]]; then
                if [[ "$current_rel" == */* ]]; then
                    current_rel="${current_rel%/*}"
                else
                    current_rel=""
                fi
                current_abs="$root${current_rel:+/$current_rel}"
                cursor=0
            fi
            continue
        fi

        if [[ "$key" == "c" || "$key" == "C" || -z "$key" || "$key" == $'\n' || "$key" == $'\r' ]]; then
            local selected_key="${keys[$cursor]}"
            case "$selected_key" in
                __confirm)
                    echo ""
                    echo "${L[pick_selected]}"
                    if (( ${#selected[@]} == 0 )); then
                        echo "  - ${L[st_project_scope_none]}"
                    else
                        local line
                        while IFS= read -r line; do
                            [[ -n "$line" ]] && echo "  - $line"
                        done < <(printf '%s\n' "${!selected[@]}" | LC_ALL=C sort)
                    fi
                    confirm "${L[pick_confirm]}" || { log_warn "${L[pick_cancel]}"; press_enter; continue; }

                    CFG_BACKUP_DIR_ITEMS="$(printf '%s\n' "${!selected[@]}" | LC_ALL=C sort)"
                    log_info "${L[pick_done]}"
                    press_enter
                    return 0
                    ;;
                __up)
                    if [[ "$current_rel" == */* ]]; then
                        current_rel="${current_rel%/*}"
                    else
                        current_rel=""
                    fi
                    current_abs="$root${current_rel:+/$current_rel}"
                    cursor=0
                    ;;
                item:*)
                    name="${selected_key#item:}"
                    if [[ -d "${current_abs}/${name%/}" ]]; then
                        if [[ -n "$current_rel" ]]; then
                            current_rel="${current_rel}/${name%/}"
                        else
                            current_rel="${name%/}"
                        fi
                        current_abs="$root/${current_rel}"
                        cursor=0
                    fi
                    ;;
            esac
        fi
    done
}

_settings_project_scope() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${L[st_project_change_scope]}${NC}"
        echo "────────────────────────────────"
        _menu_select "1 2 3 0" "1" \
            "${L[st_project_scope_full]}" \
            "${L[st_project_scope_selected]}" \
            "${L[st_project_scope_pick]}" \
            "${L[back]}"
        local choice="$MENU_CHOICE"
        case "$choice" in
            1)
                CFG_BACKUP_DIR_MODE="full"
                CFG_BACKUP_DIR_ITEMS=""
                log_info "${L[st_project_scope_saved]}"
                return
                ;;
            2)
                CFG_BACKUP_DIR_MODE="selected"
                log_info "${L[st_project_scope_saved]}"
                return
                ;;
            3)
                if [[ -z "$CFG_PROJECT_DIR" || ! -d "$CFG_PROJECT_DIR" ]]; then
                    log_warn "${L[bk_dir_missing]} ${CFG_PROJECT_DIR:-${L[not_set]}}"
                    press_enter
                    continue
                fi
                _project_dir_picker "$CFG_PROJECT_DIR" || true
                CFG_BACKUP_DIR_MODE="selected"
                return
                ;;
            0) return ;;
        esac
    done
}

###############################################################################
# MODULE: settings
###############################################################################
# Интерактивные настройки через меню

settings_menu() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${L[st_title]}${NC}"
        echo "────────────────────────────────"
        _menu_select "1 2 3 4 5 6 7 8 0" "1" \
            "${L[st_tg_settings]}" "${L[st_s3_settings]}" "${L[st_gd_settings]}" "${L[st_db_settings]}" \
            "${L[st_project_settings]}" "${L[st_retention_settings]}" "${L[st_lang]}" "${L[st_auto_update]}" "${L[back_to_menu]}"
        choice="$MENU_CHOICE"
        case "$choice" in
            1) _settings_telegram ;;
            2) _settings_s3 ;;
            3) _settings_gd ;;
            4) _settings_db ;;
            5) _settings_project ;;
            6) _settings_retention ;;
            7) _settings_lang ;;
            8) _settings_autoupdate ;;
            0) return ;;
            *) log_warn "${L[invalid_input_select]}" ;;
        esac
        save_config "$CONFIG_FILE"
    done
}

# ─────────────────────────────────────────────
# Настройки Telegram
# ─────────────────────────────────────────────
_settings_telegram() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${L[st_tg_title]}${NC}"
        echo "────────────────────────────────"
        echo "  ${L[st_tg_token]} ${CFG_BOT_TOKEN:+***}"
        echo "  ${L[st_tg_chatid]} ${CFG_CHAT_ID:-${L[not_set]}}"
        echo "  ${L[st_tg_thread]} ${CFG_THREAD_ID:-${L[not_set]}}"
        echo "  ${L[st_tg_proxy]} ${CFG_TG_PROXY:-${L[not_set]}}"
        echo ""
        _menu_select "1 2 3 4 0" "1" \
            "${L[st_tg_change_token]}" "${L[st_tg_change_id]}" "${L[st_tg_change_thread]}" "${L[st_tg_change_proxy]}" "${L[back]}"
        choice="$MENU_CHOICE"
        case "$choice" in
            1)
                read -rp "${L[st_tg_enter_token]}" CFG_BOT_TOKEN
                log_info "${L[st_tg_token_ok]}"
                ;;
            2)
                echo "${L[st_tg_chatid_desc]}"
                read -rp "${L[st_tg_enter_id]}" CFG_CHAT_ID
                log_info "${L[st_tg_id_ok]}"
                ;;
            3)
                echo "${L[st_tg_thread_info]}"
                read -rp "${L[st_tg_enter_thread]}" CFG_THREAD_ID
                log_info "${L[st_tg_thread_ok]}"
                ;;
            4)
                echo "${L[st_tg_proxy_info]}"
                echo "${L[st_tg_proxy_examples]}"
                read -rp "${L[st_tg_enter_proxy]}" CFG_TG_PROXY
                [[ -n "$CFG_TG_PROXY" ]] && log_info "${L[st_tg_proxy_ok]}" \
                                         || log_info "${L[st_tg_proxy_cleared]}"
                ;;
            0) return ;;
            *) log_warn "${L[invalid_input_select]}" ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Настройки S3
# ─────────────────────────────────────────────
_settings_s3() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${L[st_s3_title]}${NC}"
        echo "────────────────────────────────"
        echo "  ${L[st_s3_endpoint]} ${CFG_S3_ENDPOINT:-${L[not_set]}}"
        echo "  ${L[st_s3_region]}   ${CFG_S3_REGION:-${L[not_set]}}"
        echo "  ${L[st_s3_bucket]}   ${CFG_S3_BUCKET:-${L[not_set]}}"
        echo "  ${L[st_s3_access]}   ${CFG_S3_ACCESS_KEY:0:8}..."
        echo "  ${L[st_s3_secret]}   ***"
        echo "  ${L[st_s3_prefix]}   ${CFG_S3_PREFIX:-${L[not_set]}}"
        echo ""
        _menu_select "1 2 3 4 5 6 7 0" "1" \
            "${L[st_s3_change_endpoint]}" "${L[st_s3_change_region]}" "${L[st_s3_change_bucket]}" "${L[st_s3_change_access]}" \
            "${L[st_s3_change_secret]}" "${L[st_s3_change_prefix]}" "${L[st_s3_test]}" "${L[back]}"
        choice="$MENU_CHOICE"
        case "$choice" in
            1) read -rp "${L[st_s3_enter_endpoint]}" CFG_S3_ENDPOINT; log_info "${L[st_s3_endpoint_ok]}" ;;
            2) read -rp "${L[st_s3_enter_region]}" CFG_S3_REGION
               [[ -z "$CFG_S3_REGION" ]] && CFG_S3_REGION="us-east-1"
               log_info "${L[st_s3_region_ok]}" ;;
            3) read -rp "${L[st_s3_enter_bucket]}" CFG_S3_BUCKET; log_info "${L[st_s3_bucket_ok]}" ;;
            4) read -rp "${L[st_s3_enter_access]}" CFG_S3_ACCESS_KEY; log_info "${L[st_s3_access_ok]}" ;;
            5) read -rsp "${L[st_s3_enter_secret]}" CFG_S3_SECRET_KEY; echo ""; log_info "${L[st_s3_secret_ok]}" ;;
            6) read -rp "${L[st_s3_enter_prefix]}" CFG_S3_PREFIX; log_info "${L[st_s3_prefix_ok]}" ;;
            7) s3_test_connection ;;
            0) return ;;
            *) log_warn "${L[invalid_input_select]}" ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Настройки Google Drive
# ─────────────────────────────────────────────
_settings_gd() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${L[st_gd_title]}${NC}"
        echo "────────────────────────────────"
        echo "  ${L[st_gd_client_id]} ${CFG_GD_CLIENT_ID:0:10}..."
        echo "  ${L[st_gd_secret]}    ***"
        echo "  ${L[st_gd_refresh]}   ${CFG_GD_REFRESH_TOKEN:+set}"
        echo "  ${L[st_gd_folder]}    ${CFG_GD_FOLDER_ID:-${L[not_set]}}"
        echo ""
        _menu_select "1 2 3 4 0" "1" \
            "${L[st_gd_change_id]}" "${L[st_gd_change_secret]}" "${L[st_gd_change_refresh]}" "${L[st_gd_change_folder]}" "${L[back]}"
        choice="$MENU_CHOICE"
        case "$choice" in
            1) read -rp "${L[st_gd_enter_id]}" CFG_GD_CLIENT_ID; log_info "${L[st_gd_id_ok]}" ;;
            2) read -rsp "${L[st_gd_enter_secret]}" CFG_GD_CLIENT_SECRET; echo ""; log_info "${L[st_gd_secret_ok]}" ;;
            3)
                setup_gd_config
                ;;
            4) read -rp "${L[st_gd_enter_folder]}" CFG_GD_FOLDER_ID; log_info "${L[st_gd_folder_ok]}" ;;
            0) return ;;
            *) log_warn "${L[invalid_input_select]}" ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Настройки БД
# ─────────────────────────────────────────────
_settings_db() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${L[st_db_title]}${NC}"
        echo "────────────────────────────────"
        local type_label
        case "$CFG_DB_TYPE" in
            docker)   type_label="${L[st_db_type_docker]}" ;;
            external) type_label="${L[st_db_type_ext]}" ;;
            *)        type_label="${L[st_db_type_none]}" ;;
        esac
        echo "  ${L[st_db_type]}    $type_label"
        echo "  ${L[st_db_engine]}  ${CFG_DB_ENGINE:-${L[not_set]}}"
        if [[ "$CFG_DB_TYPE" == "docker" ]]; then
            echo "  ${L[st_db_container]} ${CFG_DB_CONTAINER:-${L[not_set]}}"
        elif [[ "$CFG_DB_TYPE" == "external" ]]; then
            echo "  ${L[st_db_host_label]} ${CFG_DB_HOST:-${L[not_set]}}:${CFG_DB_PORT}"
        fi
        echo "  ${L[st_db_user_label]}  ${CFG_DB_USER:-${L[not_set]}}"
        echo "  ${L[st_db_name_label]}  ${CFG_DB_NAME:-${L[not_set]}}"
        echo ""
        _menu_select "1 2 3 4 5 6 7 8 0" "1" \
            "${L[st_db_change_type]}" "${L[st_db_change_engine]}" "${L[st_db_change_container]}" "${L[st_db_change_user]}" \
            "${L[st_db_change_name]}" "${L[st_db_ext_settings]}" "${L[st_db_test]}" "${L[st_db_disable]}" "${L[back]}"
        choice="$MENU_CHOICE"
        case "$choice" in
            1)
                _menu_select "1 2 3" "1" "${L[st_db_docker]}" "${L[st_db_external]}" "${L[st_db_none]}"
                t="$MENU_CHOICE"
                case "$t" in
                    1) CFG_DB_TYPE="docker"; log_info "${L[st_db_switched_docker]}" ;;
                    2) CFG_DB_TYPE="external"; log_info "${L[st_db_switched_ext]}" ;;
                    3) CFG_DB_TYPE="none"; log_info "${L[st_db_switched_none]}" ;;
                esac
                ;;
            2) read -rp "${L[st_db_change_engine]} (postgres/mysql/mongodb): " CFG_DB_ENGINE ;;
            3)
                printf "${L[st_db_enter_container]}" "${CFG_DB_CONTAINER}"
                read -r val; [[ -n "$val" ]] && CFG_DB_CONTAINER="$val"
                log_info "${L[st_db_container_ok]}"
                ;;
            4)
                printf "${L[st_db_enter_user]}" "${CFG_DB_USER}"
                read -r val; [[ -n "$val" ]] && CFG_DB_USER="$val"
                log_info "${L[st_db_user_ok]} $CFG_DB_USER"
                ;;
            5)
                printf "${L[st_db_enter_name]}" "${CFG_DB_NAME}"
                read -r val; [[ -n "$val" ]] && CFG_DB_NAME="$val"
                log_info "${L[st_db_name_ok]}"
                ;;
            6)
                printf "${L[st_db_enter_host]}" "${CFG_DB_HOST}"; read -r val; [[ -n "$val" ]] && CFG_DB_HOST="$val"
                printf "${L[st_db_enter_port]}" "${CFG_DB_PORT}"; read -r val; [[ -n "$val" ]] && CFG_DB_PORT="$val"
                printf "${L[st_db_enter_ssl]}" "${CFG_DB_SSL}"; read -r val; [[ -n "$val" ]] && CFG_DB_SSL="$val"
                read -rsp "${L[st_db_enter_pass]}" val; echo ""; [[ -n "$val" ]] && CFG_DB_PASS="$val"
                log_info "${L[st_db_ext_saved]}"
                ;;
            7) db_test_connection; press_enter ;;
            8) CFG_DB_TYPE="none"; log_info "${L[st_db_switched_none]}" ;;
            0) return ;;
            *) log_warn "${L[invalid_input_select]}" ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Настройки проекта
# ─────────────────────────────────────────────
_settings_projects_list() {
    local active="${CFG_ACTIVE_PROJECT:-$CFG_PROJECT_ID}"
    local id name marker
    local has_any=false

    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        has_any=true
        name="$(project_display_name "$id")"
        marker=" "
        [[ "$id" == "$active" ]] && marker="*"
        echo "  [$marker] ${name} (${id})"
    done < <(list_project_ids)

    if [[ "$has_any" != "true" ]]; then
        if [[ "$CFG_LANG" == "ru" ]]; then
            log_warn "Проекты не найдены."
        else
            log_warn "No projects found."
        fi
    fi
}

_settings_projects_switch() {
    local ids=()
    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] && ids+=("$id")
    done < <(list_project_ids)

    if [[ ${#ids[@]} -eq 0 ]]; then
        if [[ "$CFG_LANG" == "ru" ]]; then
            log_warn "Проекты не найдены."
        else
            log_warn "No projects found."
        fi
        return
    fi

    echo ""
    if [[ "$CFG_LANG" == "ru" ]]; then
        echo "Список проектов:"
    else
        echo "Project list:"
    fi
    local i=1
    local -a labels=()
    for id in "${ids[@]}"; do
        local name
        name="$(project_display_name "$id")"
        labels+=("${name} (${id})")
        ((i++))
    done

    local choice options_str=""
    local n
    for ((n=1; n<=${#ids[@]}; n++)); do
        options_str="${options_str:+$options_str }$n"
    done
    options_str="${options_str:+$options_str }0"
    labels+=("${L[back]}")
    _menu_select "$options_str" "1" "${labels[@]}"
    choice="$MENU_CHOICE"
    [[ "$choice" == "0" ]] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ids[@]} )); then
        log_warn "${L[invalid_input_select]}"
        return
    fi

    local target="${ids[$((choice - 1))]}"
    if switch_active_project "$target"; then
        if [[ "$CFG_LANG" == "ru" ]]; then
            log_info "Активный проект: $(project_display_name "$target") (${target})"
        else
            log_info "Active project: $(project_display_name "$target") (${target})"
        fi
    else
        if [[ "$CFG_LANG" == "ru" ]]; then
            log_error "Не удалось переключить проект."
        else
            log_error "Failed to switch project."
        fi
    fi
}

_settings_projects_add() {
    reset_project_profile_defaults
    _configure_project_wizard

    local new_id
    new_id="$(_project_unique_id "$(_project_slug "${CFG_PROJECT_NAME:-backup}")")"
    CFG_ACTIVE_PROJECT="$new_id"
    CFG_PROJECT_ID="$new_id"

    if save_config "$CONFIG_FILE"; then
        if [[ "$CFG_LANG" == "ru" ]]; then
            log_info "Проект добавлен: ${CFG_PROJECT_NAME} (${new_id})"
        else
            log_info "Project added: ${CFG_PROJECT_NAME} (${new_id})"
        fi
    fi
}

_settings_projects_delete() {
    local ids=()
    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] && ids+=("$id")
    done < <(list_project_ids)

    if (( ${#ids[@]} <= 1 )); then
        if [[ "$CFG_LANG" == "ru" ]]; then
            log_warn "Нельзя удалить единственный проект."
        else
            log_warn "Cannot remove the only project."
        fi
        return
    fi

    echo ""
    if [[ "$CFG_LANG" == "ru" ]]; then
        echo "Выберите проект для удаления:"
    else
        echo "Select project to delete:"
    fi
    local i=1
    local -a labels=()
    for id in "${ids[@]}"; do
        local name
        name="$(project_display_name "$id")"
        labels+=("${name} (${id})")
        ((i++))
    done

    local choice options_str=""
    local n
    for ((n=1; n<=${#ids[@]}; n++)); do
        options_str="${options_str:+$options_str }$n"
    done
    options_str="${options_str:+$options_str }0"
    labels+=("${L[back]}")
    _menu_select "$options_str" "1" "${labels[@]}"
    choice="$MENU_CHOICE"
    [[ "$choice" == "0" ]] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ids[@]} )); then
        log_warn "${L[invalid_input_select]}"
        return
    fi

    local target="${ids[$((choice - 1))]}"
    local target_name
    target_name="$(project_display_name "$target")"

    if [[ "$CFG_LANG" == "ru" ]]; then
        confirm "Удалить проект '${target_name}' (${target})?" || return
    else
        confirm "Delete project '${target_name}' (${target})?" || return
    fi

    rm -f "$(_project_file_path "$target")"

    if [[ "$CFG_ACTIVE_PROJECT" == "$target" ]]; then
        local next
        next="$(list_project_ids | head -n1)"
        if [[ -n "$next" ]]; then
            load_project_config "$next" || true
            CFG_ACTIVE_PROJECT="$next"
            CFG_PROJECT_ID="$next"
        fi
    fi

    save_global_config "$CONFIG_FILE"
    if [[ "$CFG_LANG" == "ru" ]]; then
        log_info "Проект удалён."
    else
        log_info "Project removed."
    fi
}

_settings_project() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${L[st_project_title]}${NC}"
        echo "────────────────────────────────"
        echo "  ID: ${CFG_ACTIVE_PROJECT:-${L[not_set]}}"
        echo "  ${L[st_project_name]} ${CFG_PROJECT_NAME:-${L[not_set]}}"
        echo "  ${L[st_project_dir]}  ${CFG_PROJECT_DIR:-${L[not_set]}}"
        if [[ "${CFG_BACKUP_DIR_MODE:-full}" == "selected" ]]; then
            echo "  ${L[st_project_dir_mode]} ${L[st_project_scope_selected]}"
            echo "  ${L[st_project_dir_items]} $(_project_selected_items_preview)"
        else
            echo "  ${L[st_project_dir_mode]} ${L[st_project_scope_full]}"
        fi
        echo ""
        local project_toggle_dir_label
        if [[ "$CFG_BACKUP_DIR_ENABLED" == "true" ]]; then
            project_toggle_dir_label="${L[st_project_disable_dir]}"
        else
            project_toggle_dir_label="${L[st_project_enable_dir]}"
        fi
        local project_switch_label project_add_label project_remove_label project_list_label
        if [[ "$CFG_LANG" == "ru" ]]; then
            project_switch_label="Переключить активный проект"
            project_add_label="Добавить новый проект"
            project_remove_label="Удалить проект"
            project_list_label="Список проектов"
        else
            project_switch_label="Switch active project"
            project_add_label="Add new project"
            project_remove_label="Remove project"
            project_list_label="List projects"
        fi
        _menu_select "1 2 3 4 5 6 7 8 0" "1" \
            "${L[st_project_change_name]}" "${L[st_project_change_dir]}" "${L[st_project_change_scope]}" \
            "$project_toggle_dir_label" \
            "$project_switch_label" "$project_add_label" "$project_remove_label" "$project_list_label" "${L[back]}"
        choice="$MENU_CHOICE"
        case "$choice" in
            1) read -rp "${L[st_project_enter_name]}" CFG_PROJECT_NAME; log_info "${L[st_project_name_ok]}" ;;
            2)
                local val; val=$(input_path "${L[st_project_enter_dir]}" true)
                [[ -n "$val" ]] && CFG_PROJECT_DIR="$val" && log_info "${L[st_project_dir_ok]}"
                ;;
            3) _settings_project_scope ;;
            4)
                if [[ "$CFG_BACKUP_DIR_ENABLED" == "true" ]]; then
                    CFG_BACKUP_DIR_ENABLED="false"; log_info "${L[st_project_dir_disabled]}"
                else
                    CFG_BACKUP_DIR_ENABLED="true"; log_info "${L[st_project_dir_enabled]}"
                fi
                ;;
            5) _settings_projects_switch ;;
            6) _settings_projects_add ;;
            7) _settings_projects_delete ;;
            8) _settings_projects_list; press_enter ;;
            0) return ;;
            *) log_warn "${L[invalid_input_select]}" ;;
        esac
        save_config "$CONFIG_FILE"
    done
}

# ─────────────────────────────────────────────
# Политика хранения
# ─────────────────────────────────────────────
_settings_retention() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${L[st_retention_title]}${NC}"
        echo "────────────────────────────────"
        echo "  ${L[st_retention_local]} ${CFG_RETENTION_DAYS} ${L[st_retention_days]}"
        echo "  ${L[st_retention_s3]}    ${CFG_S3_RETENTION_DAYS} ${L[st_retention_days]}"
        echo ""
        _menu_select "1 2 0" "1" "${L[st_retention_change_local]}" "${L[st_retention_change_s3]}" "${L[back]}"
        choice="$MENU_CHOICE"
        case "$choice" in
            1)
                printf "${L[st_retention_enter_local]}" "${CFG_RETENTION_DAYS}"
                read -r val; [[ -n "$val" ]] && CFG_RETENTION_DAYS="$val"
                log_info "${L[st_retention_local_ok]} $CFG_RETENTION_DAYS"
                ;;
            2)
                printf "${L[st_retention_enter_s3]}" "${CFG_S3_RETENTION_DAYS}"
                read -r val; [[ -n "$val" ]] && CFG_S3_RETENTION_DAYS="$val"
                log_info "${L[st_retention_s3_ok]} $CFG_S3_RETENTION_DAYS"
                ;;
            0) return ;;
            *) log_warn "${L[invalid_input_select]}" ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Язык
# ─────────────────────────────────────────────
_settings_lang() {
    clear
    echo ""
    echo "${L[st_lang_current]} $CFG_LANG"
    echo ""
    _menu_select "1 2 0" "1" "English" "Русский" "${L[back]}"
    choice="$MENU_CHOICE"
    case "$choice" in
        1) CFG_LANG="en"; load_language "en"; log_info "${L[st_lang_changed]} English" ;;
        2) CFG_LANG="ru"; load_language "ru"; log_info "${L[st_lang_changed]} Русский" ;;
        0) return ;;
        *) log_warn "${L[invalid_input_select]}" ;;
    esac
}

# ─────────────────────────────────────────────
# Автообновление
# ─────────────────────────────────────────────
_settings_autoupdate() {
    clear
    echo ""
    echo "${L[st_auto_update_status]} $( [[ "$CFG_AUTO_UPDATE" == "true" ]] && echo "${L[st_auto_update_on]}" || echo "${L[st_auto_update_off]}" )"
    echo ""
    local toggle_label
    if [[ "$CFG_AUTO_UPDATE" == "true" ]]; then
        toggle_label="${L[st_auto_update_disable]}"
    else
        toggle_label="${L[st_auto_update_enable]}"
    fi
    _menu_select "1 0" "1" "$toggle_label" "${L[back]}"
    choice="$MENU_CHOICE"
    case "$choice" in
        1)
            if [[ "$CFG_AUTO_UPDATE" == "true" ]]; then
                CFG_AUTO_UPDATE="false"
                log_info "${L[st_auto_update_disabled]}"
            else
                CFG_AUTO_UPDATE="true"
                log_info "${L[st_auto_update_enabled]}"
            fi
            ;;
        0) return ;;
    esac
}

# ─────────────────────────────────────────────
# Удаление скрипта
# ─────────────────────────────────────────────
do_remove() {
    echo ""
    echo -e "${RED}${BOLD}${L[rm_warn]}${NC}"
    echo "  - ${L[rm_script]}: $BACKUP_SCRIPT"
    echo "  - ${L[rm_dir]}: ${BACKREST_HOME}"
    echo "  - ${L[rm_symlink]}"
    echo "  - ${L[rm_cron]}"
    echo ""
    if ! confirm "${L[rm_confirm]}"; then
        log_warn "${L[rm_cancelled]}"
        press_enter_back
        return
    fi

    if [[ $EUID -ne 0 ]]; then
        log_warn "${L[rm_root]}"
    fi

    # Cron
    log_step "${L[rm_cron_removing]}"
    if crontab -l 2>/dev/null | grep -q "universal-backup"; then
        crontab -l 2>/dev/null | grep -v "universal-backup" | crontab -
        log_info "${L[rm_cron_removed]}"
    else
        log_info "${L[rm_cron_none]}"
    fi

    # Symlink
    local symlink
    for symlink in /usr/local/bin/backup /usr/local/bin/backrest; do
        if [[ -L "$symlink" ]]; then
            log_step "${L[rm_symlink_removing]} $symlink"
            rm -f "$symlink" && log_info "${L[rm_symlink_removed]}" || log_warn "${L[rm_symlink_fail]}"
        fi
    done

    # Файл скрипта
    if [[ -f "$BACKUP_SCRIPT" ]]; then
        rm -f "$BACKUP_SCRIPT" 2>/dev/null || true
    fi

    # Рабочая директория скрипта
    if [[ -n "${BACKREST_HOME:-}" && "$BACKREST_HOME" != "/" && -d "$BACKREST_HOME" ]]; then
        log_step "${L[rm_dir_removing]}"
        rm -rf "$BACKREST_HOME" && log_info "${BACKREST_HOME} ${L[rm_dir_removed]}" || log_error "${L[rm_dir_fail]}"
    fi

    echo ""
    log_info "Uninstalled."
    exit 0
}

###############################################################################
# MAIN
###############################################################################
# ─────────────────────────────────────────────
# Загрузить язык (по умолчанию EN до загрузки конфига)
# ─────────────────────────────────────────────
load_language "en"

# ─────────────────────────────────────────────
# Загрузить или создать конфиг
# ─────────────────────────────────────────────
ensure_runtime_dirs
if [[ -f "$CONFIG_FILE" ]]; then
    load_config "$CONFIG_FILE"
    load_language "$CFG_LANG"
else
    if [[ -n "$COMMAND" ]]; then
        log_error "Конфигурация не найдена: $CONFIG_FILE. Сначала выполните интерактивную настройку."
        exit 1
    fi
    # Первый запуск — wizard
    initial_setup "$CONFIG_FILE"
    load_language "$CFG_LANG"
fi

# Явный выбор проекта через CLI (без изменения сохраненного активного профиля)
if [[ -n "$CLI_PROJECT" ]]; then
    if ! activate_project_by_selector "$CLI_PROJECT" false; then
        log_error "Проект '$CLI_PROJECT' не найден."
        exit 1
    fi
fi

# Создать директорию для бэкапов если не существует
mkdir -p "$CFG_BACKUP_DIR" 2>/dev/null || true

# ─────────────────────────────────────────────
# Настроить symlink /usr/local/bin/{backup,backrest}
# ─────────────────────────────────────────────
_setup_symlinks() {
    local target="$BACKUP_SCRIPT"
    local symlink
    [[ $EUID -ne 0 ]] && return
    for symlink in /usr/local/bin/backup /usr/local/bin/backrest; do
        if [[ ! -L "$symlink" ]] || [[ "$(readlink "$symlink")" != "$target" ]]; then
            if ln -sf "$target" "$symlink" 2>/dev/null; then
                log_info "${L[symlink_created]} ($symlink → $target)"
            fi
        fi
    done
}
_setup_symlinks

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
_next_main_tab() {
    case "$1" in
        ops) echo "config" ;;
        config) echo "service" ;;
        *) echo "ops" ;;
    esac
}

_prev_main_tab() {
    case "$1" in
        ops) echo "service" ;;
        config) echo "ops" ;;
        *) echo "config" ;;
    esac
}

_tab_title() {
    case "$1" in
        ops) echo "${L[menu_tab_ops]}" ;;
        config) echo "${L[menu_tab_config]}" ;;
        *) echo "${L[menu_tab_service]}" ;;
    esac
}

_project_cfg_value() {
    local project_id="$1"
    local key="$2"
    local default_value="${3:-}"
    local file value
    file="$(_project_file_path "$project_id")"
    [[ -f "$file" ]] || { echo "$default_value"; return; }

    value=$(grep -E "^${key}=" "$file" | tail -1 | cut -d'=' -f2- | tr -d '"')
    [[ -n "$value" ]] && echo "$value" || echo "$default_value"
}

_trim_cell() {
    local value="$1"
    local width="$2"
    value="$(_sanitize_text "$value")"
    if (( ${#value} > width )); then
        echo "${value:0:$((width-3))}..."
    else
        echo "$value"
    fi
}

_sanitize_text() {
    local value="$1"
    # Удаляем управляющие символы и (по возможности) битые UTF-8 байты.
    if command -v iconv >/dev/null 2>&1; then
        value=$(printf '%s' "$value" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || printf '%s' "$value")
    fi
    printf '%s' "$value" | tr -d '\000-\010\013-\037\177'
}

_render_projects_overview() {
    local ids=()
    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] && ids+=("$id")
    done < <(list_project_ids)

    echo -e "  ${L[menu_projects_title]}"
    if (( ${#ids[@]} == 0 )); then
        echo "  ${L[menu_projects_empty]}"
        echo ""
        return
    fi

    local table_line="+--------------+----------------------+----------+-------------+----------------+"
    echo "  ${table_line}"
    printf "  | %-12s | %-20s | %-8s | %-11s | %-14s |\n" \
        "${L[menu_projects_col_id]}" \
        "${L[menu_projects_col_name]}" \
        "${L[menu_projects_col_db]}" \
        "${L[menu_projects_col_upload]}" \
        "${L[menu_projects_col_status]}"
    echo "  ${table_line}"

    for id in "${ids[@]}"; do
        local name db_type upload_method status_label
        name="$(project_display_name "$id")"
        db_type="$(_project_cfg_value "$id" "CFG_DB_TYPE" "none")"
        upload_method="$(_project_cfg_value "$id" "CFG_UPLOAD_METHOD" "telegram")"

        if [[ "$id" == "${CFG_ACTIVE_PROJECT:-}" ]]; then
            status_label="${L[menu_projects_status_active]}"
        elif [[ "$db_type" == "none" ]]; then
            status_label="${L[menu_projects_status_attention]}"
        else
            status_label="${L[menu_projects_status_ready]}"
        fi

        printf "  | %-12s | %-20s | %-8s | %-11s | %-14s |\n" \
            "$(_trim_cell "$id" 12)" \
            "$(_trim_cell "$name" 20)" \
            "$(_trim_cell "$db_type" 8)" \
            "$(_trim_cell "$upload_method" 11)" \
            "$(_trim_cell "$status_label" 14)"
    done
    echo "  ${table_line}"
    echo ""
}

_render_upload_methods_overview() {
    local ids=()
    local id method methods_text
    local -a methods=()
    local -A seen=()

    while IFS= read -r id; do
        [[ -n "$id" ]] && ids+=("$id")
    done < <(list_project_ids)

    for id in "${ids[@]}"; do
        method="$(_project_cfg_value "$id" "CFG_UPLOAD_METHOD" "")"
        [[ -z "$method" ]] && continue
        if [[ -z "${seen[$method]+x}" ]]; then
            seen["$method"]=1
            methods+=("$method")
        fi
    done

    if (( ${#methods[@]} == 0 )); then
        methods_text="${L[not_set]}"
    else
        local IFS=", "
        methods_text="${methods[*]}"
    fi

    echo -e "  ${L[menu_upload_configured]} ${YELLOW}${methods_text}${NC}"
    echo ""
}

_render_main_header() {
    local _current_tab="$1"
    local clean_author
    clean_author="$(_sanitize_text "$SCRIPT_AUTHOR")"

    echo ""
    echo -e "  ${BOLD}${CYAN}${L[menu_title]}${NC}"
    echo -e "  ${L[menu_version]} ${SCRIPT_VERSION}  |  ${L[menu_author]} ${clean_author}"
    echo "  ──────────────────────────────────────────────────────────────"
    echo ""
}

_render_tabs_panel() {
    local current_tab="$1"
    local tab_ops tab_cfg tab_srv
    tab_ops="${L[menu_tab_ops]}"
    tab_cfg="${L[menu_tab_config]}"
    tab_srv="${L[menu_tab_service]}"

    case "$current_tab" in
        ops) tab_ops="${BOLD}${GREEN}[${L[menu_tab_ops]}]${NC}" ;;
        config) tab_cfg="${BOLD}${GREEN}[${L[menu_tab_config]}]${NC}" ;;
        service) tab_srv="${BOLD}${GREEN}[${L[menu_tab_service]}]${NC}" ;;
    esac

    echo -e "  ${L[menu_tabs_label]} ${tab_ops}  ${tab_cfg}  ${tab_srv}"
    echo -e "  ${L[menu_tip_tabs]}"
    echo "  ──────────────────────────────────────────────────────────────"
    echo ""
}

_render_main_status() {
    _render_projects_overview
    _render_upload_methods_overview
}

_menu_choose_upload_method() {
    local ul_choice
    clear
    echo ""
    echo "${L[ul_title]}"
    echo "  ${L[ul_current]} ${CFG_UPLOAD_METHOD}"
    echo ""
    _menu_select "1 2 3 0" "1" "${L[ul_set_tg]}" "${L[ul_set_s3]}" "${L[ul_set_gd]}" "${L[back]}"
    ul_choice="$MENU_CHOICE"
    case "$ul_choice" in
        1) CFG_UPLOAD_METHOD="telegram"; log_info "${L[ul_tg_set]}" ;;
        2) setup_s3_config ;;
        3) setup_gd_config ;;
        0) return ;;
        *) log_warn "${L[invalid_input_select]}" ;;
    esac
    save_config "$CONFIG_FILE"
    press_enter
}

_render_tab_menu() {
    local current_tab="$1"
    echo -e "  ${L[menu_actions_for_tab]} ${BOLD}$(_tab_title "$current_tab")${NC}"
    echo "  ${L[menu_tip_actions]}"
    echo ""
}

_read_main_menu_choice() {
    local options_str="$1"
    local default_choice="${2:-1}"
    shift 2
    local -a options
    local -a labels
    local idx=0 key seq typed=""
    MAIN_MENU_CHOICE=""
    MAIN_MENU_CURSOR="$default_choice"

    read -r -a options <<< "$options_str"
    labels=("$@")
    (( ${#options[@]} == 0 )) && return 1
    (( ${#labels[@]} != ${#options[@]} )) && return 1

    local i
    for i in "${!options[@]}"; do
        if [[ "${options[$i]}" == "$default_choice" ]]; then
            idx="$i"
            break
        fi
    done

    local rendered=0
    _render_main_choice_list() {
        local j marker
        (( rendered )) && printf "\033[%dA" "${#labels[@]}"
        for j in "${!labels[@]}"; do
            if (( j == idx )); then
                marker="${BOLD}${GREEN}>${NC}"
            else
                marker=" "
            fi
            printf "\r\033[2K  %s %s\n" "$marker" "${labels[$j]}"
        done
        rendered=1
    }

    while true; do
        _render_main_choice_list
        IFS= read -rsn1 key || { echo ""; return 1; }

        if [[ "$key" == $'\e' ]]; then
            seq=""
            while IFS= read -rsn1 -t 0.05 key; do
                seq+="$key"
                [[ "$key" =~ [A-Za-z~] ]] && break
            done
            case "$seq" in
                "[A"|"OA") idx=$(( (idx - 1 + ${#options[@]}) % ${#options[@]} )); typed="" ;;
                "[B"|"OB") idx=$(( (idx + 1) % ${#options[@]} )); typed="" ;;
                "[D"|"OD") MAIN_MENU_CHOICE="__TAB_PREV"; MAIN_MENU_CURSOR="${options[$idx]}"; return 0 ;;
                "[C"|"OC") MAIN_MENU_CHOICE="__TAB_NEXT"; MAIN_MENU_CURSOR="${options[$idx]}"; return 0 ;;
                *) ;;
            esac
            continue
        fi

        if [[ -z "$key" || "$key" == $'\n' || "$key" == $'\r' ]]; then
            if [[ -n "$typed" ]]; then
                local opt
                for opt in "${options[@]}"; do
                    if [[ "$opt" == "$typed" ]]; then
                        MAIN_MENU_CHOICE="$typed"
                        MAIN_MENU_CURSOR="$typed"
                        return 0
                    fi
                done
                typed=""
                continue
            fi
            MAIN_MENU_CHOICE="${options[$idx]}"
            MAIN_MENU_CURSOR="${options[$idx]}"
            return 0
        fi

        if [[ "$key" =~ [0-9] ]]; then
            typed+="$key"
        fi
    done
}

_main_menu() {
    local current_tab="ops"
    local choice
    local choice_ops="1" choice_config="1" choice_service="1"
    local current_choice options_for_tab

    while true; do
        clear
        _render_main_header "$current_tab"
        _render_main_status
        _render_tabs_panel "$current_tab"
        _render_tab_menu "$current_tab"

        local -a main_labels=()
        case "$current_tab" in
            ops)
                options_for_tab="1 2 3 4 0"
                current_choice="$choice_ops"
                main_labels=("${L[menu_create_backup]}" "${L[menu_restore]}" "${L[menu_auto_send]}" "${L[menu_upload_method]}" "${L[exit]}")
                ;;
            config)
                options_for_tab="1 2 3 4 5 6 0"
                current_choice="$choice_config"
                main_labels=("${L[menu_tab_quick_settings]}" "${L[menu_tab_projects]}" "${L[menu_tab_db]}" "${L[menu_tab_retention]}" "${L[menu_tab_language]}" "${L[menu_tab_auto_update]}" "${L[exit]}")
                ;;
            service)
                options_for_tab="1 2 3 0"
                current_choice="$choice_service"
                main_labels=("${L[menu_update]}" "${L[menu_tab_check_update]}" "${L[menu_tab_remove]}" "${L[exit]}")
                ;;
        esac

        _read_main_menu_choice "$options_for_tab" "$current_choice" "${main_labels[@]}"
        choice="$MAIN_MENU_CHOICE"
        case "$current_tab" in
            ops) choice_ops="$MAIN_MENU_CURSOR" ;;
            config) choice_config="$MAIN_MENU_CURSOR" ;;
            service) choice_service="$MAIN_MENU_CURSOR" ;;
        esac

        case "$choice" in
            "") continue ;;
            __TAB_PREV) current_tab="$(_prev_main_tab "$current_tab")"; continue ;;
            __TAB_NEXT) current_tab="$(_next_main_tab "$current_tab")"; continue ;;
            0) echo "${L[exit_dots]}"; exit 0 ;;
        esac

        case "$current_tab" in
            ops)
                case "$choice" in
                    1) do_backup; press_enter_back ;;
                    2) do_restore; press_enter_back ;;
                    3) cron_menu ;;
                    4) _menu_choose_upload_method ;;
                    *) log_warn "${L[invalid_input_select]}"; sleep 1 ;;
                esac
                ;;
            config)
                case "$choice" in
                    1) settings_menu ;;
                    2) _settings_project ;;
                    3) _settings_db ;;
                    4) _settings_retention ;;
                    5) _settings_lang; save_config "$CONFIG_FILE"; press_enter ;;
                    6) _settings_autoupdate; save_config "$CONFIG_FILE"; press_enter ;;
                    *) log_warn "${L[invalid_input_select]}"; sleep 1 ;;
                esac
                ;;
            service)
                case "$choice" in
                    1) do_update ;;
                    2) check_update; press_enter_back ;;
                    3) do_remove ;;
                    *) log_warn "${L[invalid_input_select]}"; sleep 1 ;;
                esac
                ;;
        esac
    done
}

_main_menu
