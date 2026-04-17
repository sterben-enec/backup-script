#!/usr/bin/env bash
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

    local env_info
    [[ "$CFG_BACKUP_ENV" == "true" && -n "$CFG_PROJECT_ENV" ]] \
        && env_info="${L[tg_env_yes]}" \
        || env_info="${L[tg_env_no]}"

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
${L[tg_db]} ${db_info}
${L[tg_env]} ${env_info}"

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
