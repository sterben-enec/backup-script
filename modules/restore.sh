#!/usr/bin/env bash
# Логика восстановления из бэкапа

# ─────────────────────────────────────────────
# Главная функция восстановления
# ─────────────────────────────────────────────
do_restore() {
    echo ""
    echo -e "${BOLD}${L[rs_title]}${NC}"
    echo "────────────────────────────────"

    # Источник бэкапа
    echo "  1. ${L[rs_source_local]}"
    echo "  2. ${L[rs_source_s3]}"
    echo "  0. ${L[back]}"
    read -rp "${L[select_option]}" source_choice

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
    trap 'cleanup_tmpdir "$tmp_dir"' EXIT INT TERM

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
            echo "  1. ${L[rs_env_dest_original]} (${CFG_PROJECT_ENV})"
            echo "  2. ${L[rs_env_dest_custom]}"
            read -rp "${L[select_option]}" env_choice
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
            echo "  1. ${L[rs_dir_dest_original]} ($(dirname "${CFG_PROJECT_DIR}"))"
            echo "  2. ${L[rs_dir_dest_custom]}"
            read -rp "${L[select_option]}" dir_choice
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
