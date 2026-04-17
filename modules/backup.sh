#!/usr/bin/env bash
# Логика создания резервной копии

# ─────────────────────────────────────────────
# Основная функция создания бэкапа
# ─────────────────────────────────────────────
do_backup() {
    local ts; ts=$(timestamp)
    local archive_name="${CFG_PROJECT_NAME}_${ts}.tar.gz"
    local backup_dir="$CFG_BACKUP_DIR"
    local tmp_dir; tmp_dir=$(mktemp -d)
    # Гарантировать очистку временной директории при выходе или сигналах
    trap 'cleanup_tmpdir "$tmp_dir"' EXIT INT TERM
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

    # ── 2. .env файл ────────────────────────────
    if [[ "$CFG_BACKUP_ENV" == "true" && -n "$CFG_PROJECT_ENV" ]]; then
        if [[ -f "$CFG_PROJECT_ENV" ]]; then
            log_step "${L[bk_archiving_env]}"
            if cp "$CFG_PROJECT_ENV" "${tmp_dir}/.env"; then
                log_info "${L[bk_env_ok]}"
                has_data=true
            else
                log_error "${L[bk_env_err]}"
            fi
        else
            log_warn "${L[bk_env_missing]} $CFG_PROJECT_ENV"
        fi
    else
        log_warn "${L[bk_skip_env]}"
    fi

    # ── 3. Директория проекта ───────────────────
    if [[ "$CFG_BACKUP_DIR_ENABLED" == "true" && -n "$CFG_PROJECT_DIR" ]]; then
        if [[ -d "$CFG_PROJECT_DIR" ]]; then
            log_step "${L[bk_archiving_dir]} ${CFG_PROJECT_DIR}"
            if tar -czf "${tmp_dir}/project_dir.tar.gz" \
                    --exclude="${CFG_PROJECT_DIR}/.git" \
                    -C "$(dirname "$CFG_PROJECT_DIR")" \
                    "$(basename "$CFG_PROJECT_DIR")" 2>/dev/null; then
                log_info "${L[bk_dir_ok]}"
                has_data=true
            else
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

    # ── 4. Записать метаданные ───────────────────
    cat > "${tmp_dir}/backup_meta.json" <<EOF
{
  "project": "${CFG_PROJECT_NAME}",
  "version": "${SCRIPT_VERSION}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "db_type": "${CFG_DB_TYPE}",
  "db_engine": "${CFG_DB_ENGINE}",
  "env_included": ${CFG_BACKUP_ENV:-false},
  "dir_included": ${CFG_BACKUP_DIR_ENABLED:-false}
}
EOF

    # ── 5. Финальный архив ───────────────────────
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

    # ── 6. Отправить/загрузить ───────────────────
    _send_backup "$final_archive"
    local send_status=$?

    # ── 7. Локальная ротация ─────────────────────
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
