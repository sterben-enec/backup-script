#!/usr/bin/env bash
# Создание и восстановление дампов БД (postgres/mysql/mongodb, docker/external)

# ─────────────────────────────────────────────
# Создать дамп БД
# Параметры: output_file
# ─────────────────────────────────────────────
db_dump() {
    local output_file="$1"
    local exit_code=0

    log_step "${L[bk_creating_dump]}"
    log_step "${L[bk_dump_type]} ${CFG_DB_ENGINE}"

    case "$CFG_DB_TYPE" in
        docker)
            log_step "${L[bk_dump_container]} ${CFG_DB_CONTAINER}"
            _db_dump_docker "$output_file"
            exit_code=$?
            ;;
        external)
            _db_dump_external "$output_file"
            exit_code=$?
            ;;
        *)
            log_warn "${L[bk_skip_db]}"
            return 0
            ;;
    esac

    if [[ $exit_code -ne 0 ]]; then
        log_error "${L[bk_dump_err]} ${exit_code}"
        log_warn "${L[bk_check_db]}"
        return 1
    fi

    log_info "${L[bk_dump_ok]}"
    return 0
}

# Дамп из Docker-контейнера
_db_dump_docker() {
    local output_file="$1"
    check_docker || return 1

    case "$CFG_DB_ENGINE" in
        postgres)
            _pg_dump_docker "$output_file"
            ;;
        mysql|mariadb)
            _mysql_dump_docker "$output_file"
            ;;
        mongodb|mongo)
            _mongo_dump_docker "$output_file"
            ;;
        *)
            log_error "Неизвестный тип СУБД: ${CFG_DB_ENGINE}"
            return 1
            ;;
    esac
}

# Дамп внешней БД (без Docker)
_db_dump_external() {
    local output_file="$1"

    case "$CFG_DB_ENGINE" in
        postgres)
            _pg_dump_external "$output_file"
            ;;
        mysql|mariadb)
            _mysql_dump_external "$output_file"
            ;;
        mongodb|mongo)
            _mongo_dump_external "$output_file"
            ;;
        *)
            log_error "Неизвестный тип СУБД: ${CFG_DB_ENGINE}"
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────
# PostgreSQL — Docker
# ─────────────────────────────────────────────
_pg_dump_docker() {
    local output_file="$1"
    local pass_env=""
    [[ -n "$CFG_DB_PASS" ]] && pass_env="-e PGPASSWORD=${CFG_DB_PASS}"

    # shellcheck disable=SC2086
    docker exec $pass_env "$CFG_DB_CONTAINER" \
        pg_dump -U "$CFG_DB_USER" -d "$CFG_DB_NAME" --no-owner --no-acl -Fc \
        > "$output_file"
}

# ─────────────────────────────────────────────
# PostgreSQL — External
# ─────────────────────────────────────────────
_pg_dump_external() {
    local output_file="$1"
    require_cmd pg_dump || _install_pgclient || return 1

    local host="${CFG_DB_HOST:-localhost}"
    local port="${CFG_DB_PORT:-5432}"
    local ssl="${CFG_DB_SSL:-prefer}"

    PGPASSWORD="$CFG_DB_PASS" pg_dump \
        -h "$host" -p "$port" -U "$CFG_DB_USER" -d "$CFG_DB_NAME" \
        --no-owner --no-acl -Fc \
        --sslmode="$ssl" \
        > "$output_file"
}

# Попытка установить pg_dump нужной версии (только Debian/Ubuntu)
_install_pgclient() {
    if [[ $EUID -ne 0 ]]; then
        log_error "pg_dump не найден. Установите postgresql-client-${CFG_DB_PGVER}"
        return 1
    fi
    local ver="${CFG_DB_PGVER:-17}"
    log_step "Установка postgresql-client-${ver}..."
    apt-get install -y "postgresql-client-${ver}" &>/dev/null || return 1
}

# ─────────────────────────────────────────────
# MySQL/MariaDB — Docker
# ─────────────────────────────────────────────
_mysql_dump_docker() {
    local output_file="$1"
    local pass_flag=""
    [[ -n "$CFG_DB_PASS" ]] && pass_flag="-p${CFG_DB_PASS}"

    docker exec "$CFG_DB_CONTAINER" \
        mysqldump -u "$CFG_DB_USER" $pass_flag \
        --single-transaction --routines --triggers \
        "$CFG_DB_NAME" \
        > "$output_file"
}

# ─────────────────────────────────────────────
# MySQL/MariaDB — External
# ─────────────────────────────────────────────
_mysql_dump_external() {
    local output_file="$1"
    require_cmd mysqldump || return 1

    local host="${CFG_DB_HOST:-localhost}"
    local port="${CFG_DB_PORT:-3306}"
    local pass_flag=""
    [[ -n "$CFG_DB_PASS" ]] && pass_flag="-p${CFG_DB_PASS}"

    # shellcheck disable=SC2086
    mysqldump -h "$host" -P "$port" -u "$CFG_DB_USER" $pass_flag \
        --single-transaction --routines --triggers \
        "$CFG_DB_NAME" \
        > "$output_file"
}

# ─────────────────────────────────────────────
# MongoDB — Docker
# ─────────────────────────────────────────────
_mongo_dump_docker() {
    local output_file="$1"
    local tmpdir; tmpdir=$(mktemp -d)

    local auth_args=""
    [[ -n "$CFG_DB_USER" ]] && auth_args="--username ${CFG_DB_USER}"
    [[ -n "$CFG_DB_PASS" ]] && auth_args="${auth_args} --password ${CFG_DB_PASS}"
    [[ -n "$CFG_DB_NAME" ]] && auth_args="${auth_args} --db ${CFG_DB_NAME}"

    # shellcheck disable=SC2086
    docker exec "$CFG_DB_CONTAINER" mongodump $auth_args --archive \
        > "$output_file"
    rm -rf "$tmpdir"
}

# ─────────────────────────────────────────────
# MongoDB — External
# ─────────────────────────────────────────────
_mongo_dump_external() {
    local output_file="$1"
    require_cmd mongodump || return 1

    local host="${CFG_DB_HOST:-localhost}"
    local port="${CFG_DB_PORT:-27017}"

    local auth_args=""
    [[ -n "$CFG_DB_USER" ]] && auth_args="--username ${CFG_DB_USER}"
    [[ -n "$CFG_DB_PASS" ]] && auth_args="${auth_args} --password ${CFG_DB_PASS}"
    [[ -n "$CFG_DB_NAME" ]] && auth_args="${auth_args} --db ${CFG_DB_NAME}"

    # shellcheck disable=SC2086
    mongodump --host "$host" --port "$port" $auth_args --archive \
        > "$output_file"
}

# ─────────────────────────────────────────────
# Восстановление БД
# ─────────────────────────────────────────────
db_restore() {
    local dump_file="$1"
    local container="${2:-$CFG_DB_CONTAINER}"
    local db_name="${3:-$CFG_DB_NAME}"
    local db_user="${4:-$CFG_DB_USER}"
    local db_pass="${5:-$CFG_DB_PASS}"
    local db_engine="${6:-$CFG_DB_ENGINE}"

    log_step "${L[rs_restoring_db]}"

    case "$db_engine" in
        postgres)
            _pg_restore "$dump_file" "$container" "$db_name" "$db_user" "$db_pass"
            ;;
        mysql|mariadb)
            _mysql_restore "$dump_file" "$container" "$db_name" "$db_user" "$db_pass"
            ;;
        mongodb|mongo)
            _mongo_restore "$dump_file" "$container"
            ;;
        *)
            log_error "Неизвестный тип СУБД для восстановления: ${db_engine}"
            return 1
            ;;
    esac
}

# Дождаться готовности PostgreSQL в контейнере
_wait_pg_ready() {
    local container="$1"
    local user="$2"
    local max_attempts=30
    local attempt=0

    log_step "${L[rs_wait_db]}"
    while (( attempt < max_attempts )); do
        if docker exec "$container" pg_isready -U "$user" &>/dev/null; then
            log_info "${L[rs_db_ready]}"
            return 0
        fi
        sleep 1
        ((attempt++))
    done
    log_error "${L[rs_db_timeout]}"
    return 1
}

_pg_restore() {
    local dump_file="$1" container="$2" db_name="$3" db_user="$4" db_pass="$5"
    _wait_pg_ready "$container" "$db_user" || return 1

    local pass_env=""
    [[ -n "$db_pass" ]] && pass_env="-e PGPASSWORD=${db_pass}"

    # Сначала дропаем и создаём заново
    # shellcheck disable=SC2086
    docker exec $pass_env "$container" \
        psql -U "$db_user" -c "DROP DATABASE IF EXISTS \"${db_name}\";" postgres &>/dev/null || true
    # shellcheck disable=SC2086
    docker exec $pass_env "$container" \
        psql -U "$db_user" -c "CREATE DATABASE \"${db_name}\";" postgres &>/dev/null || true

    # shellcheck disable=SC2086
    docker exec -i $pass_env "$container" \
        pg_restore -U "$db_user" -d "$db_name" --no-owner --no-acl < "$dump_file"
}

_mysql_restore() {
    local dump_file="$1" container="$2" db_name="$3" db_user="$4" db_pass="$5"
    local pass_flag=""
    [[ -n "$db_pass" ]] && pass_flag="-p${db_pass}"

    # shellcheck disable=SC2086
    docker exec -i "$container" \
        mysql -u "$db_user" $pass_flag "$db_name" < "$dump_file"
}

_mongo_restore() {
    local dump_file="$1" container="$2"
    docker exec -i "$container" mongorestore --archive < "$dump_file"
}

# ─────────────────────────────────────────────
# Тест подключения к внешней БД
# ─────────────────────────────────────────────
db_test_connection() {
    if [[ "$CFG_DB_TYPE" != "external" ]]; then
        log_warn "${L[st_db_only_ext]}"
        return 1
    fi

    log_step "${L[st_db_testing]}"
    case "$CFG_DB_ENGINE" in
        postgres)
            PGPASSWORD="$CFG_DB_PASS" pg_isready \
                -h "${CFG_DB_HOST:-localhost}" \
                -p "${CFG_DB_PORT:-5432}" \
                -U "$CFG_DB_USER" &>/dev/null
            ;;
        mysql|mariadb)
            local pass_flag=""
            [[ -n "$CFG_DB_PASS" ]] && pass_flag="-p${CFG_DB_PASS}"
            # shellcheck disable=SC2086
            mysql -h "${CFG_DB_HOST:-localhost}" -P "${CFG_DB_PORT:-3306}" \
                -u "$CFG_DB_USER" $pass_flag -e "SELECT 1;" &>/dev/null
            ;;
        mongodb|mongo)
            mongosh --host "${CFG_DB_HOST:-localhost}" \
                --port "${CFG_DB_PORT:-27017}" \
                --eval "db.runCommand({ping:1})" &>/dev/null
            ;;
        *)
            log_error "Тест не поддерживается для ${CFG_DB_ENGINE}"
            return 1
            ;;
    esac

    if [[ $? -eq 0 ]]; then
        log_info "${L[st_db_test_ok]}"
    else
        log_error "${L[st_db_test_fail]}"
        return 1
    fi
}
