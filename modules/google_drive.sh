#!/usr/bin/env bash
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
