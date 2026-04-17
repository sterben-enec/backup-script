#!/usr/bin/env bash
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

# Базовые аргументы aws s3 с endpoint
_s3_args() {
    local args=()
    [[ -n "$CFG_S3_ENDPOINT" ]] && args+=(--endpoint-url "$CFG_S3_ENDPOINT")
    echo "${args[@]}"
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
    local s3_args; s3_args=$(_s3_args)

    log_step "${L[bk_sending]} → s3://${CFG_S3_BUCKET}/${key}"
    # shellcheck disable=SC2086
    if aws s3 cp "$file" "s3://${CFG_S3_BUCKET}/${key}" $s3_args; then
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
    local s3_args; s3_args=$(_s3_args)
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
            # shellcheck disable=SC2086
            aws s3 rm "s3://${CFG_S3_BUCKET}/${file_key}" $s3_args &>/dev/null && ((deleted++)) || true
        fi
    # shellcheck disable=SC2086
    done < <(aws s3 ls "s3://${CFG_S3_BUCKET}/${prefix}" $s3_args 2>/dev/null)

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
    local s3_args; s3_args=$(_s3_args)

    log_step "${L[rs_s3_listing]}"
    # shellcheck disable=SC2086
    aws s3 ls "s3://${CFG_S3_BUCKET}/${prefix}" $s3_args 2>/dev/null \
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

    local s3_args; s3_args=$(_s3_args)
    # shellcheck disable=SC2086
    aws s3 cp "s3://${CFG_S3_BUCKET}/${s3_key}" "$dest" $s3_args
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

    local s3_args; s3_args=$(_s3_args)
    log_step "${L[st_s3_testing]}"
    # shellcheck disable=SC2086
    if aws s3 ls "s3://${CFG_S3_BUCKET}" $s3_args &>/dev/null; then
        log_info "${L[st_s3_test_ok]}"
        return 0
    else
        log_error "${L[st_s3_test_fail]}"
        return 1
    fi
}
