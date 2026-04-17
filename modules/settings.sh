#!/usr/bin/env bash
# Интерактивные настройки через меню

settings_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}${L[st_title]}${NC}"
        echo "────────────────────────────────"
        echo "  1. ${L[st_tg_settings]}"
        echo "  2. ${L[st_s3_settings]}"
        echo "  3. ${L[st_gd_settings]}"
        echo "  4. ${L[st_db_settings]}"
        echo "  5. ${L[st_project_settings]}"
        echo "  6. ${L[st_retention_settings]}"
        echo "  7. ${L[st_lang]}"
        echo "  8. ${L[st_auto_update]}"
        echo "  0. ${L[back_to_menu]}"
        echo "────────────────────────────────"
        read -rp "${L[select_option]}" choice
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
        echo ""
        echo -e "${BOLD}${L[st_tg_title]}${NC}"
        echo "────────────────────────────────"
        echo "  ${L[st_tg_token]} ${CFG_BOT_TOKEN:+***}"
        echo "  ${L[st_tg_chatid]} ${CFG_CHAT_ID:-${L[not_set]}}"
        echo "  ${L[st_tg_thread]} ${CFG_THREAD_ID:-${L[not_set]}}"
        echo "  ${L[st_tg_proxy]} ${CFG_TG_PROXY:-${L[not_set]}}"
        echo ""
        echo "  1. ${L[st_tg_change_token]}"
        echo "  2. ${L[st_tg_change_id]}"
        echo "  3. ${L[st_tg_change_thread]}"
        echo "  4. ${L[st_tg_change_proxy]}"
        echo "  0. ${L[back]}"
        echo "────────────────────────────────"
        read -rp "${L[select_option]}" choice
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
        echo "  1. ${L[st_s3_change_endpoint]}"
        echo "  2. ${L[st_s3_change_region]}"
        echo "  3. ${L[st_s3_change_bucket]}"
        echo "  4. ${L[st_s3_change_access]}"
        echo "  5. ${L[st_s3_change_secret]}"
        echo "  6. ${L[st_s3_change_prefix]}"
        echo "  7. ${L[st_s3_test]}"
        echo "  0. ${L[back]}"
        echo "────────────────────────────────"
        read -rp "${L[select_option]}" choice
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
        echo ""
        echo -e "${BOLD}${L[st_gd_title]}${NC}"
        echo "────────────────────────────────"
        echo "  ${L[st_gd_client_id]} ${CFG_GD_CLIENT_ID:0:10}..."
        echo "  ${L[st_gd_secret]}    ***"
        echo "  ${L[st_gd_refresh]}   ${CFG_GD_REFRESH_TOKEN:+set}"
        echo "  ${L[st_gd_folder]}    ${CFG_GD_FOLDER_ID:-${L[not_set]}}"
        echo ""
        echo "  1. ${L[st_gd_change_id]}"
        echo "  2. ${L[st_gd_change_secret]}"
        echo "  3. ${L[st_gd_change_refresh]}"
        echo "  4. ${L[st_gd_change_folder]}"
        echo "  0. ${L[back]}"
        echo "────────────────────────────────"
        read -rp "${L[select_option]}" choice
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
        echo "  1. ${L[st_db_change_type]}"
        echo "  2. ${L[st_db_change_engine]}"
        echo "  3. ${L[st_db_change_container]}"
        echo "  4. ${L[st_db_change_user]}"
        echo "  5. ${L[st_db_change_name]}"
        echo "  6. ${L[st_db_ext_settings]}"
        echo "  7. ${L[st_db_test]}"
        echo "  8. ${L[st_db_disable]}"
        echo "  0. ${L[back]}"
        echo "────────────────────────────────"
        read -rp "${L[select_option]}" choice
        case "$choice" in
            1)
                echo "  1. ${L[st_db_docker]}"
                echo "  2. ${L[st_db_external]}"
                echo "  3. ${L[st_db_none]}"
                read -rp "${L[select_option]}" t
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
_settings_project() {
    while true; do
        echo ""
        echo -e "${BOLD}${L[st_project_title]}${NC}"
        echo "────────────────────────────────"
        echo "  ${L[st_project_name]} ${CFG_PROJECT_NAME:-${L[not_set]}}"
        echo "  ${L[st_project_dir]}  ${CFG_PROJECT_DIR:-${L[not_set]}}"
        echo "  ${L[st_project_env]}  ${CFG_PROJECT_ENV:-${L[not_set]}}"
        echo ""
        echo "  1. ${L[st_project_change_name]}"
        echo "  2. ${L[st_project_change_dir]}"
        echo "  3. ${L[st_project_change_env]}"
        if [[ "$CFG_BACKUP_DIR_ENABLED" == "true" ]]; then
            echo "  4. ${L[st_project_disable_dir]}"
        else
            echo "  4. ${L[st_project_enable_dir]}"
        fi
        if [[ "$CFG_BACKUP_ENV" == "true" ]]; then
            echo "  5. ${L[st_project_disable_env]}"
        else
            echo "  5. ${L[st_project_enable_env]}"
        fi
        echo "  0. ${L[back]}"
        echo "────────────────────────────────"
        read -rp "${L[select_option]}" choice
        case "$choice" in
            1) read -rp "${L[st_project_enter_name]}" CFG_PROJECT_NAME; log_info "${L[st_project_name_ok]}" ;;
            2)
                local val; val=$(input_path "${L[st_project_enter_dir]}" true)
                [[ -n "$val" ]] && CFG_PROJECT_DIR="$val" && log_info "${L[st_project_dir_ok]}"
                ;;
            3)
                local val; val=$(input_path "${L[st_project_enter_env]}" true)
                [[ -n "$val" ]] && CFG_PROJECT_ENV="$val" && CFG_BACKUP_ENV="true" && log_info "${L[st_project_env_ok]}"
                ;;
            4)
                if [[ "$CFG_BACKUP_DIR_ENABLED" == "true" ]]; then
                    CFG_BACKUP_DIR_ENABLED="false"; log_info "${L[st_project_dir_disabled]}"
                else
                    CFG_BACKUP_DIR_ENABLED="true"; log_info "${L[st_project_dir_enabled]}"
                fi
                ;;
            5)
                if [[ "$CFG_BACKUP_ENV" == "true" ]]; then
                    CFG_BACKUP_ENV="false"; log_info "${L[st_project_env_disabled]}"
                else
                    CFG_BACKUP_ENV="true"; log_info "${L[st_project_env_enabled]}"
                fi
                ;;
            0) return ;;
            *) log_warn "${L[invalid_input_select]}" ;;
        esac
    done
}

# ─────────────────────────────────────────────
# Политика хранения
# ─────────────────────────────────────────────
_settings_retention() {
    while true; do
        echo ""
        echo -e "${BOLD}${L[st_retention_title]}${NC}"
        echo "────────────────────────────────"
        echo "  ${L[st_retention_local]} ${CFG_RETENTION_DAYS} ${L[st_retention_days]}"
        echo "  ${L[st_retention_s3]}    ${CFG_S3_RETENTION_DAYS} ${L[st_retention_days]}"
        echo ""
        echo "  1. ${L[st_retention_change_local]}"
        echo "  2. ${L[st_retention_change_s3]}"
        echo "  0. ${L[back]}"
        echo "────────────────────────────────"
        read -rp "${L[select_option]}" choice
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
    echo ""
    echo "${L[st_lang_current]} $CFG_LANG"
    echo ""
    echo "  1. English"
    echo "  2. Русский"
    echo "  0. ${L[back]}"
    read -rp "${L[select_option]}" choice
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
    echo ""
    echo "${L[st_auto_update_status]} $( [[ "$CFG_AUTO_UPDATE" == "true" ]] && echo "${L[st_auto_update_on]}" || echo "${L[st_auto_update_off]}" )"
    echo ""
    if [[ "$CFG_AUTO_UPDATE" == "true" ]]; then
        echo "  1. ${L[st_auto_update_disable]}"
    else
        echo "  1. ${L[st_auto_update_enable]}"
    fi
    echo "  0. ${L[back]}"
    read -rp "${L[select_option]}" choice
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
    echo "  - ${L[rm_dir]}: $(dirname "$BACKUP_SCRIPT")"
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
    local symlink="/usr/local/bin/backup"
    if [[ -L "$symlink" ]]; then
        log_step "${L[rm_symlink_removing]}"
        rm -f "$symlink" && log_info "${L[rm_symlink_removed]}" || log_warn "${L[rm_symlink_fail]}"
    fi

    # Директория установки
    local install_dir; install_dir=$(dirname "$BACKUP_SCRIPT")
    if [[ -d "$install_dir" ]]; then
        log_step "${L[rm_dir_removing]}"
        rm -rf "$install_dir" && log_info "${install_dir} ${L[rm_dir_removed]}" || log_error "${L[rm_dir_fail]}"
    fi

    echo ""
    log_info "Uninstalled."
    exit 0
}
