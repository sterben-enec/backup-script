#!/usr/bin/env bash
# Проверка обновлений и самообновление скрипта

GITHUB_RAW_URL="https://raw.githubusercontent.com/YOUR_USERNAME/universal-backup/main/backup.sh"
GITHUB_API_URL="https://api.github.com/repos/YOUR_USERNAME/universal-backup/releases/latest"

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
    latest_info=$(curl -sf "$GITHUB_API_URL" 2>/dev/null)
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
    sleep 1
    exec "$script_path"
}

# ─────────────────────────────────────────────
# Фоновая проверка (вызывается при старте)
# ─────────────────────────────────────────────
check_update_bg() {
    [[ "$CFG_AUTO_UPDATE" != "true" ]] && return

    local latest_info
    latest_info=$(curl -sf --max-time 5 "$GITHUB_API_URL" 2>/dev/null) || return

    local latest_version
    latest_version=$(echo "$latest_info" | grep '"tag_name"' | head -1 | cut -d'"' -f4 | tr -d 'v')
    [[ -z "$latest_version" || "$latest_version" == "$SCRIPT_VERSION" ]] && return

    local changelog
    changelog=$(echo "$latest_info" | grep '"body"' | head -1 | cut -d'"' -f4 | head -c 500)

    if [[ "$CFG_AUTO_UPDATE" == "true" ]]; then
        tg_notify_update "$SCRIPT_VERSION" "$latest_version" "$changelog"
    fi
}
