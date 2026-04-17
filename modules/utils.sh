#!/usr/bin/env bash
# Общие утилиты

# Цветовые коды
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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

# Меню выбора из списка (нумерованное)
# select_menu "Заголовок" "opt1" "opt2" ...
# Возвращает индекс (1-based) или 0 при выходе
select_menu() {
    local title="$1"; shift
    local options=("$@")
    local n=${#options[@]}
    echo ""
    echo -e "${BOLD}${title}${NC}"
    echo "────────────────────────────────"
    for i in "${!options[@]}"; do
        echo "  $((i+1)). ${options[$i]}"
    done
    echo "  0. ${L[back]}"
    echo "────────────────────────────────"
    while true; do
        read -rp "${L[select_option]}" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice <= n )); then
            echo "$choice"
            return 0
        fi
        log_warn "${L[invalid_input_select]}"
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
