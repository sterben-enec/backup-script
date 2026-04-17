#!/usr/bin/env bash
# Загрузка, сохранение и начальная настройка конфигурации

# Значения по умолчанию
CFG_VERSION="1.0.0"
CFG_LANG="en"
CFG_AUTO_UPDATE="false"

# Telegram
CFG_BOT_TOKEN=""
CFG_CHAT_ID=""
CFG_THREAD_ID=""
CFG_TG_PROXY=""

# Способ отправки: telegram | s3 | google_drive
CFG_UPLOAD_METHOD="telegram"

# S3
CFG_S3_ENDPOINT=""
CFG_S3_REGION="us-east-1"
CFG_S3_BUCKET=""
CFG_S3_ACCESS_KEY=""
CFG_S3_SECRET_KEY=""
CFG_S3_PREFIX=""
CFG_S3_RETENTION_DAYS="30"

# Google Drive
CFG_GD_CLIENT_ID=""
CFG_GD_CLIENT_SECRET=""
CFG_GD_REFRESH_TOKEN=""
CFG_GD_FOLDER_ID=""

# БД
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

# Проект
CFG_PROJECT_NAME=""
CFG_PROJECT_DIR=""
CFG_PROJECT_ENV=""
CFG_BACKUP_DIR="/var/backups/universal-backup"
CFG_RETENTION_DAYS="30"

# Флаги включения источников
CFG_BACKUP_ENV="true"
CFG_BACKUP_DIR_ENABLED="true"

# ─────────────────────────────────────────────
# Загрузить конфиг из файла
# ─────────────────────────────────────────────
load_config() {
    local cfg_file="$1"
    if [[ -f "$cfg_file" ]]; then
        log_step "${L[cfg_loading]}"
        # shellcheck source=/dev/null
        source "$cfg_file"
        log_info "${L[cfg_loaded]} $cfg_file"
    fi
}

# ─────────────────────────────────────────────
# Сохранить конфиг в файл
# ─────────────────────────────────────────────
save_config() {
    local cfg_file="$1"
    local dir; dir=$(dirname "$cfg_file")
    mkdir -p "$dir" || { log_error "${L[cfg_install_fail]} $dir"; return 1; }

    log_step "${L[saving_config]} $cfg_file"
    cat > "$cfg_file" <<EOF
# Universal Backup — конфигурация
# Создан: $(date)

CFG_VERSION="${CFG_VERSION}"
CFG_LANG="${CFG_LANG}"
CFG_AUTO_UPDATE="${CFG_AUTO_UPDATE}"

# Telegram
CFG_BOT_TOKEN="${CFG_BOT_TOKEN}"
CFG_CHAT_ID="${CFG_CHAT_ID}"
CFG_THREAD_ID="${CFG_THREAD_ID}"
CFG_TG_PROXY="${CFG_TG_PROXY}"

# Способ отправки
CFG_UPLOAD_METHOD="${CFG_UPLOAD_METHOD}"

# S3
CFG_S3_ENDPOINT="${CFG_S3_ENDPOINT}"
CFG_S3_REGION="${CFG_S3_REGION}"
CFG_S3_BUCKET="${CFG_S3_BUCKET}"
CFG_S3_ACCESS_KEY="${CFG_S3_ACCESS_KEY}"
CFG_S3_SECRET_KEY="${CFG_S3_SECRET_KEY}"
CFG_S3_PREFIX="${CFG_S3_PREFIX}"
CFG_S3_RETENTION_DAYS="${CFG_S3_RETENTION_DAYS}"

# Google Drive
CFG_GD_CLIENT_ID="${CFG_GD_CLIENT_ID}"
CFG_GD_CLIENT_SECRET="${CFG_GD_CLIENT_SECRET}"
CFG_GD_REFRESH_TOKEN="${CFG_GD_REFRESH_TOKEN}"
CFG_GD_FOLDER_ID="${CFG_GD_FOLDER_ID}"

# База данных
CFG_DB_TYPE="${CFG_DB_TYPE}"
CFG_DB_ENGINE="${CFG_DB_ENGINE}"
CFG_DB_CONTAINER="${CFG_DB_CONTAINER}"
CFG_DB_USER="${CFG_DB_USER}"
CFG_DB_NAME="${CFG_DB_NAME}"
CFG_DB_PASS="${CFG_DB_PASS}"
CFG_DB_HOST="${CFG_DB_HOST}"
CFG_DB_PORT="${CFG_DB_PORT}"
CFG_DB_SSL="${CFG_DB_SSL}"
CFG_DB_PGVER="${CFG_DB_PGVER}"

# Проект
CFG_PROJECT_NAME="${CFG_PROJECT_NAME}"
CFG_PROJECT_DIR="${CFG_PROJECT_DIR}"
CFG_PROJECT_ENV="${CFG_PROJECT_ENV}"
CFG_BACKUP_DIR="${CFG_BACKUP_DIR}"
CFG_RETENTION_DAYS="${CFG_RETENTION_DAYS}"
CFG_BACKUP_ENV="${CFG_BACKUP_ENV}"
CFG_BACKUP_DIR_ENABLED="${CFG_BACKUP_DIR_ENABLED}"
EOF
    secure_file "$cfg_file"
    log_info "${L[config_saved]}"
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
    echo "  1. English"
    echo "  2. Русский"
    read -rp "${L[select_option]}" lang_choice
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

    # .env файл
    echo ""
    CFG_PROJECT_ENV=$(input_path "${L[cfg_project_env]}" true)
    if [[ -z "$CFG_PROJECT_ENV" ]]; then
        CFG_BACKUP_ENV="false"
    fi

    # БД
    setup_db_wizard

    # Способ отправки
    setup_upload_method_wizard

    # Сохранить
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
    echo "  1. Docker container"
    echo "  2. External DB"
    echo "  3. ${L[cfg_db_skip]}"
    read -rp "${L[select_option]}" db_choice

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
                [[ -z "$CFG_DB_PGVER" ]] && CFG_DB_PGVER="17"
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
                [[ -z "$CFG_DB_PGVER" ]] && CFG_DB_PGVER="17"
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
    echo "  1. ${L[ul_set_tg]}"
    echo "  2. ${L[ul_set_s3]}"
    echo "  3. ${L[ul_set_gd]}"
    read -rp "${L[select_option]}" ul_choice

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
    local lang_file="${SCRIPT_DIR}/translations/${lang}.sh"
    if [[ -f "$lang_file" ]]; then
        # shellcheck source=/dev/null
        source "$lang_file"
    else
        # Fallback на английский
        source "${SCRIPT_DIR}/translations/en.sh"
    fi
}
