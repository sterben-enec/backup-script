#!/usr/bin/env bash
# Управление cron-расписанием автоматического бэкапа

# Вычисляется лениво, после загрузки конфига
_cron_marker() { echo "# universal-backup: ${CFG_PROJECT_NAME:-backup}"; }

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
        echo ""
        echo -e "${BOLD}${L[cron_title]}${NC}"
        echo "────────────────────────────────"
        _cron_status_line
        echo ""
        echo "  1. ${L[cron_enable]}"
        echo "  2. ${L[cron_disable]}"
        echo "  0. ${L[back_to_menu]}"
        echo "────────────────────────────────"
        read -rp "${L[select_option]}" choice
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
    local current; current=$(crontab -l 2>/dev/null | grep -F "$(_cron_marker)")
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
    echo "  1. ${L[cron_hourly]}"
    echo "  2. ${L[cron_daily]}"
    echo "  0. ${L[back]}"
    read -rp "${L[select_option]}" variant

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
    # cron_expr может содержать несколько строк (по одной на каждое время)
    local cron_lines=""
    while IFS= read -r expr_line; do
        [[ -z "$expr_line" ]] && continue
        cron_lines+="${expr_line} ${script_path} backup ${marker}"$'\n'
    done <<< "$cron_expr"

    log_step "${L[cron_setting]}"

    # Удалить старые записи этого проекта
    local current_cron
    current_cron=$(crontab -l 2>/dev/null | grep -vF "$marker")

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
    current_cron=$(crontab -l 2>/dev/null | grep -vF "$(_cron_marker)")
    echo "$current_cron" | crontab -
    log_info "${L[cron_disabled]}"
}
