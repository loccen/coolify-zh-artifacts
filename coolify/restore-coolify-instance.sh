#!/bin/bash

set -Eeuo pipefail

COOLIFY_ROOT="/data/coolify"
COOLIFY_ENV_FILE="$COOLIFY_ROOT/source/.env"
RESTORE_TMP_ROOT="/tmp"

PACKAGE_PATH=""
S3_ENV_FILE=""
S3_OBJECT_KEY=""
HELPER_IMAGE=""
S3_HELPER_CONTAINER=""
DOWNLOADED_PACKAGE=""
EXTRACT_DIR=""
CURRENT_ENV_BACKUP=""
CURRENT_DB_BACKUP=""
CURRENT_SSH_BACKUP=""
ROLLBACK_READY=0
RESTORE_SUCCESS=0

usage() {
    cat <<'USAGE'
用法:
  restore-coolify-instance.sh --package /path/to/backup.tar.gz
  restore-coolify-instance.sh --s3-env-file /tmp/coolify-s3.env --s3-object-key data/coolify/backups/.../backup.tar.gz --helper-image ghcr.io/loccen/coolify-helper:1.0.14
USAGE
}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    log "错误: $*"
    exit 1
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "缺少命令: $1"
    fi
}

source_env_file() {
    if [ ! -f "$1" ]; then
        fail "环境文件不存在: $1"
    fi

    set -a
    # shellcheck disable=SC1090
    source "$1"
    set +a
}

ensure_container_exists() {
    local container="$1"

    if ! docker ps -a --format '{{.Names}}' | grep -Fx "$container" >/dev/null 2>&1; then
        fail "容器不存在: $container"
    fi
}

merge_previous_keys() {
    local current_app_key="$1"
    local current_previous_keys="$2"
    local backup_app_key="$3"
    local merged="$current_previous_keys"

    if [ -n "$current_app_key" ] && [ "$current_app_key" != "$backup_app_key" ]; then
        case ",$merged," in
            *,"$current_app_key",*)
                ;;
            *)
                merged="${merged:+$merged,}$current_app_key"
                ;;
        esac
    fi

    printf '%s' "$merged"
}

rewrite_env_keys() {
    local new_app_key="$1"
    local new_previous_keys="$2"
    local temp_env

    temp_env="$(mktemp "$RESTORE_TMP_ROOT/coolify-env-write.XXXXXX")"
    grep -vE '^APP_KEY=|^APP_PREVIOUS_KEYS=' "$COOLIFY_ENV_FILE" > "$temp_env"
    printf 'APP_KEY=%s\n' "$new_app_key" >> "$temp_env"

    if [ -n "$new_previous_keys" ]; then
        printf 'APP_PREVIOUS_KEYS=%s\n' "$new_previous_keys" >> "$temp_env"
    fi

    mv "$temp_env" "$COOLIFY_ENV_FILE"
}

cleanup_temp_files() {
    if [ -n "$S3_HELPER_CONTAINER" ]; then
        docker rm -f "$S3_HELPER_CONTAINER" >/dev/null 2>&1 || true
    fi

    if [ -n "$DOWNLOADED_PACKAGE" ] && [ -f "$DOWNLOADED_PACKAGE" ]; then
        rm -f "$DOWNLOADED_PACKAGE" >/dev/null 2>&1 || true
    fi

    if [ -n "$S3_ENV_FILE" ] && [ -f "$S3_ENV_FILE" ]; then
        rm -f "$S3_ENV_FILE" >/dev/null 2>&1 || true
    fi

    if [ -n "$EXTRACT_DIR" ] && [ -d "$EXTRACT_DIR" ]; then
        rm -rf "$EXTRACT_DIR" >/dev/null 2>&1 || true
    fi
}

restart_coolify_services() {
    local container

    for container in coolify coolify-realtime; do
        if docker ps -a --format '{{.Names}}' | grep -Fx "$container" >/dev/null 2>&1; then
            docker start "$container" >/dev/null 2>&1 || docker restart "$container" >/dev/null 2>&1 || true
        fi
    done
}

restore_database_from_dump() {
    local dump_path="$1"

    source_env_file "$COOLIFY_ENV_FILE"
    ensure_container_exists "coolify-db"
    docker start coolify-db >/dev/null 2>&1 || true

    log "导入 coolify 数据库..."
    docker exec coolify-db rm -f /tmp/coolify-instance-restore.dmp >/dev/null 2>&1 || true
    docker exec -i coolify-db sh -lc 'cat > /tmp/coolify-instance-restore.dmp' < "$dump_path"
    docker exec -e PGPASSWORD="$DB_PASSWORD" coolify-db dropdb -U "$DB_USERNAME" --if-exists "${DB_DATABASE:-coolify}"
    docker exec -e PGPASSWORD="$DB_PASSWORD" coolify-db createdb -U "$DB_USERNAME" "${DB_DATABASE:-coolify}"
    docker exec -e PGPASSWORD="$DB_PASSWORD" coolify-db pg_restore -U "$DB_USERNAME" -d "${DB_DATABASE:-coolify}" /tmp/coolify-instance-restore.dmp
    docker exec coolify-db rm -f /tmp/coolify-instance-restore.dmp >/dev/null 2>&1 || true
}

rollback_restore() {
    log "恢复失败，开始回滚当前实例..."

    if [ -n "$CURRENT_ENV_BACKUP" ] && [ -f "$CURRENT_ENV_BACKUP" ]; then
        cp "$CURRENT_ENV_BACKUP" "$COOLIFY_ENV_FILE"
    fi

    if [ -n "$CURRENT_DB_BACKUP" ] && [ -f "$CURRENT_DB_BACKUP" ]; then
        restore_database_from_dump "$CURRENT_DB_BACKUP" || true
    fi

    if [ -n "$CURRENT_SSH_BACKUP" ] && [ -f "$CURRENT_SSH_BACKUP" ]; then
        rm -rf "$COOLIFY_ROOT/ssh"
        mkdir -p "$COOLIFY_ROOT/ssh"
        tar -xzf "$CURRENT_SSH_BACKUP" -C /
    fi

    restart_coolify_services
    log "回滚流程结束。"
}

handle_exit() {
    local exit_code=$?

    if [ "$exit_code" -ne 0 ] && [ "$ROLLBACK_READY" -eq 1 ] && [ "$RESTORE_SUCCESS" -eq 0 ]; then
        rollback_restore || true
    fi

    cleanup_temp_files
}

download_package_from_s3() {
    [ -n "$S3_ENV_FILE" ] || fail "缺少 --s3-env-file"
    [ -n "$S3_OBJECT_KEY" ] || fail "缺少 --s3-object-key"
    [ -n "$HELPER_IMAGE" ] || fail "缺少 --helper-image"

    source_env_file "$S3_ENV_FILE"

    [ -n "${S3_ENDPOINT:-}" ] || fail "S3_ENDPOINT 为空"
    [ -n "${S3_ACCESS_KEY:-}" ] || fail "S3_ACCESS_KEY 为空"
    [ -n "${S3_SECRET_KEY:-}" ] || fail "S3_SECRET_KEY 为空"
    [ -n "${S3_BUCKET:-}" ] || fail "S3_BUCKET 为空"

    S3_HELPER_CONTAINER="coolify-instance-restore-$RANDOM$RANDOM"
    DOWNLOADED_PACKAGE="$(mktemp "$RESTORE_TMP_ROOT/coolify-instance-package.XXXXXX.tar.gz")"

    log "从 S3 下载实例备份包..."
    docker run -d --name "$S3_HELPER_CONTAINER" "$HELPER_IMAGE" sleep 3600 >/dev/null
    docker exec "$S3_HELPER_CONTAINER" mc alias set restore "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null
    docker exec "$S3_HELPER_CONTAINER" mc stat "restore/$S3_BUCKET/$S3_OBJECT_KEY" >/dev/null
    docker exec "$S3_HELPER_CONTAINER" mc cp "restore/$S3_BUCKET/$S3_OBJECT_KEY" /tmp/restore-package.tar.gz >/dev/null
    docker cp "$S3_HELPER_CONTAINER:/tmp/restore-package.tar.gz" "$DOWNLOADED_PACKAGE"
    PACKAGE_PATH="$DOWNLOADED_PACKAGE"
}

prepare_current_state_backup() {
    local ssh_source="$COOLIFY_ROOT/ssh"

    CURRENT_ENV_BACKUP="$(mktemp "$RESTORE_TMP_ROOT/coolify-env-backup.XXXXXX")"
    cp "$COOLIFY_ENV_FILE" "$CURRENT_ENV_BACKUP"

    CURRENT_DB_BACKUP="$(mktemp "$RESTORE_TMP_ROOT/coolify-db-backup.XXXXXX.dmp")"
    source_env_file "$COOLIFY_ENV_FILE"
    ensure_container_exists "coolify-db"
    docker start coolify-db >/dev/null 2>&1 || true
    docker exec -e PGPASSWORD="$DB_PASSWORD" coolify-db pg_dump --format=custom --no-acl --no-owner --username "$DB_USERNAME" "${DB_DATABASE:-coolify}" > "$CURRENT_DB_BACKUP"

    if [ -d "$ssh_source" ]; then
        CURRENT_SSH_BACKUP="$(mktemp "$RESTORE_TMP_ROOT/coolify-ssh-backup.XXXXXX.tar.gz")"
        tar -czf "$CURRENT_SSH_BACKUP" -C / data/coolify/ssh
    fi

    ROLLBACK_READY=1
}

extract_and_validate_package() {
    [ -f "$PACKAGE_PATH" ] || fail "备份包不存在: $PACKAGE_PATH"

    EXTRACT_DIR="$(mktemp -d "$RESTORE_TMP_ROOT/coolify-instance-restore.XXXXXX")"
    tar -xzf "$PACKAGE_PATH" -C "$EXTRACT_DIR"

    [ -f "$EXTRACT_DIR/manifest.json" ] || fail "备份包缺少 manifest.json"
    [ -f "$EXTRACT_DIR/database/coolify.dmp" ] || fail "备份包缺少 database/coolify.dmp"

    if ! grep -q '"type"[[:space:]]*:[[:space:]]*"coolify-instance-backup"' "$EXTRACT_DIR/manifest.json"; then
        fail "备份包类型不正确"
    fi
}

apply_package_app_key_if_present() {
    local app_key_file="$EXTRACT_DIR/secrets/app_key.txt"
    local current_app_key=""
    local current_previous_keys=""
    local backup_app_key=""
    local merged_previous_keys=""

    if [ ! -f "$app_key_file" ]; then
        log "备份包未携带 APP_KEY，保留当前实例 APP_KEY。"

        return
    fi

    backup_app_key="$(tr -d '\n' < "$app_key_file")"
    current_app_key="$(grep '^APP_KEY=' "$COOLIFY_ENV_FILE" | head -n1 | cut -d= -f2- || true)"
    current_previous_keys="$(grep '^APP_PREVIOUS_KEYS=' "$COOLIFY_ENV_FILE" | head -n1 | cut -d= -f2- || true)"

    merged_previous_keys="$(merge_previous_keys "$current_app_key" "$current_previous_keys" "$backup_app_key")"
    rewrite_env_keys "$backup_app_key" "$merged_previous_keys"
    log "已更新 APP_KEY，并保留必要的 APP_PREVIOUS_KEYS。"
}

wait_for_coolify_health() {
    local attempts=90

    log "等待 Coolify 健康检查通过..."
    while [ "$attempts" -gt 0 ]; do
        if docker exec coolify curl --fail --silent http://127.0.0.1:8080/api/health >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
        attempts=$((attempts - 1))
    done

    return 1
}

verify_encrypted_settings() {
    log "校验加密字段是否可读取..."
    docker exec coolify sh -lc 'cd /var/www/html && php artisan tinker --execute '\''try { optional(App\\Models\\InstanceSettings::query()->first())->smtp_host; optional(App\\Models\\PrivateKey::query()->first())->private_key; optional(App\\Models\\S3Storage::query()->first())->key; echo "RECOVERY_DECRYPT_OK"; } catch (Throwable $e) { fwrite(STDERR, $e->getMessage()); exit(1); }'\'''
}

while [ $# -gt 0 ]; do
    case "$1" in
        --package)
            PACKAGE_PATH="${2:-}"
            shift 2
            ;;
        --s3-env-file)
            S3_ENV_FILE="${2:-}"
            shift 2
            ;;
        --s3-object-key)
            S3_OBJECT_KEY="${2:-}"
            shift 2
            ;;
        --helper-image)
            HELPER_IMAGE="${2:-}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage
            fail "未知参数: $1"
            ;;
    esac
done

trap handle_exit EXIT

require_command docker
require_command tar
require_command grep
require_command awk
require_command curl
ensure_container_exists "coolify"
ensure_container_exists "coolify-db"

if [ -z "$PACKAGE_PATH" ] && [ -z "$S3_OBJECT_KEY" ]; then
    usage
    fail "必须提供本地备份包或 S3 备份对象路径"
fi

if [ -z "$PACKAGE_PATH" ]; then
    download_package_from_s3
fi

extract_and_validate_package
prepare_current_state_backup

log "停止 Coolify 控制面容器..."
docker stop coolify >/dev/null 2>&1 || true
docker stop coolify-realtime >/dev/null 2>&1 || true

apply_package_app_key_if_present
restore_database_from_dump "$EXTRACT_DIR/database/coolify.dmp"
restart_coolify_services

wait_for_coolify_health || fail "Coolify 健康检查未通过"
verify_encrypted_settings >/dev/null

RESTORE_SUCCESS=1
log "Coolify 实例恢复完成。"
