#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Configuración
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly SECRETS_ROOT="/opt/aegora/secrets"
readonly RESTORE_TEST_ROOT="/opt/aegora/restore-test-automatic"
readonly CONTEXT_LIB="${PLATFORM_ROOT}/scripts/backup/tenant-context.sh"

TENANT="${TENANT:-aegora}"
SNAPSHOT="${SNAPSHOT:-latest}"
LOCK_FILE="/run/lock/aegora-restore-test-${TENANT}.lock"

TENANT_ROOT=""
TENANT_CONFIG=""
RESTIC_CONFIG=""
BACKUP_MANIFEST=""
TENANT_POSTGRES_SECRETS=""
CONFIG_LAYOUT=""

POSTGRES_CONTAINER=""
POSTGRES_ADMIN_USER=""
SNAPSHOT_ID=""
RESTORE_DIR=""
RUN_DIR=""
RUN_ID=""

TEST_DATABASES=()

# =============================================================================
# Utilidades
# =============================================================================

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

warn() {
  log "AVISO: $*" >&2
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "Falta el comando requerido: $1"
}

require_file() {
  [[ -f "$1" ]] ||
    fail "Falta el fichero requerido: $1"
}

require_directory() {
  [[ -d "$1" ]] ||
    fail "Falta el directorio requerido: $1"
}

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

container_running() {
  local container="$1"

  [[ "$(
    docker inspect \
      --format='{{.State.Status}}' \
      "$container" 2>/dev/null
  )" == "running" ]]
}

sanitize_identifier() {
  local raw="$1"

  printf '%s' "$raw" |
    tr -c '[:alnum:]_' '_' |
    cut -c1-55
}

database_exists() {
  local database="$1"

  docker exec "$POSTGRES_CONTAINER" \
    psql \
      --username="$POSTGRES_ADMIN_USER" \
      --dbname=postgres \
      --tuples-only \
      --no-align \
      --command="SELECT 1 FROM pg_database WHERE datname = '${database}';" \
    2>/dev/null |
    tr -d '[:space:]'
}

terminate_database_connections() {
  local database="$1"

  docker exec "$POSTGRES_CONTAINER" \
    psql \
      --username="$POSTGRES_ADMIN_USER" \
      --dbname=postgres \
      --set=ON_ERROR_STOP=1 \
      --command="
        SELECT pg_terminate_backend(pid)
        FROM pg_stat_activity
        WHERE datname = '${database}'
          AND pid <> pg_backend_pid();
      " \
    >/dev/null
}

drop_test_database() {
  local database="$1"

  if [[ "$(database_exists "$database")" != "1" ]]; then
    return 0
  fi

  terminate_database_connections "$database"

  docker exec "$POSTGRES_CONTAINER" \
    dropdb \
      --username="$POSTGRES_ADMIN_USER" \
      --if-exists \
      "$database"

  log "Base temporal eliminada: ${database}"
}

cleanup() {
  local exit_code=$?

  trap - EXIT

  for database in "${TEST_DATABASES[@]:-}"; do
    if [[ -n "$database" ]]; then
      drop_test_database "$database" || true
    fi
  done

  if [[ -n "${RESTORE_DIR:-}" && -d "$RESTORE_DIR" ]]; then
    rm -rf "$RESTORE_DIR" || true
    log "Directorio temporal eliminado: ${RESTORE_DIR}"
  fi

  if [[ $exit_code -ne 0 ]]; then
    log "La prueba automática de restauración terminó con errores."
  else
    log "La prueba automática de restauración terminó correctamente."
  fi

  exit "$exit_code"
}

trap cleanup EXIT
trap 'fail "Fallo en la línea ${LINENO}: ${BASH_COMMAND}"' ERR

# =============================================================================
# Prerrequisitos
# =============================================================================

require_command restic
require_command docker
require_command flock
require_command sha256sum
require_command python3
require_command find
require_command sort

require_file "$CONTEXT_LIB"
# shellcheck disable=SC1090
source "$CONTEXT_LIB"

resolve_tenant_context

require_file "$TENANT_CONFIG"
require_file "$RESTIC_CONFIG"

mkdir -p "$(dirname "$LOCK_FILE")"
mkdir -p "$RESTORE_TEST_ROOT"

chmod 700 "$RESTORE_TEST_ROOT"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  fail "Ya hay otra prueba de restauración en ejecución."
fi

# =============================================================================
# Cargar configuración
# =============================================================================

set -a

# shellcheck disable=SC1090
source "$TENANT_CONFIG"

# shellcheck disable=SC1090
source "$RESTIC_CONFIG"

set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${BACKUP_HOST:?Falta BACKUP_HOST}"
: "${BACKUP_TAG_TENANT:?Falta BACKUP_TAG_TENANT}"

: "${RESTIC_REPOSITORY:?Falta RESTIC_REPOSITORY}"
: "${RESTIC_PASSWORD:?Falta RESTIC_PASSWORD}"
: "${AWS_ACCESS_KEY_ID:?Falta AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Falta AWS_SECRET_ACCESS_KEY}"

validate_loaded_tenant_context
log_tenant_context

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-aegora-postgres}"

container_exists "$POSTGRES_CONTAINER" ||
  fail "No existe el contenedor PostgreSQL: ${POSTGRES_CONTAINER}"

container_running "$POSTGRES_CONTAINER" ||
  fail "El contenedor PostgreSQL no está en ejecución."

POSTGRES_ADMIN_USER="$(
  docker exec "$POSTGRES_CONTAINER" \
    printenv POSTGRES_USER 2>/dev/null |
    tr -d '\r\n'
)"

[[ -n "$POSTGRES_ADMIN_USER" ]] ||
  fail "No se pudo obtener POSTGRES_USER del contenedor PostgreSQL."

# =============================================================================
# Seleccionar snapshot
# =============================================================================

log "Seleccionando snapshot del tenant '${TENANT_ID}'."

if [[ "$SNAPSHOT" == "latest" ]]; then
  SNAPSHOT_ID="$(
    restic snapshots \
      --host "$BACKUP_HOST" \
      --tag "$BACKUP_TAG_TENANT" \
      --tag "manifest=v1" \
      --json |
      python3 -c '
import json
import sys

snapshots = json.load(sys.stdin)

if not snapshots:
    raise SystemExit(1)

snapshots.sort(key=lambda item: item["time"])
snapshot = snapshots[-1]

print(snapshot.get("short_id") or snapshot["id"][:8])
'
  )"
else
  SNAPSHOT_ID="$SNAPSHOT"
fi

[[ -n "$SNAPSHOT_ID" ]] ||
  fail "No se encontró ningún snapshot manifest=v1 para el tenant."

log "Snapshot seleccionado: ${SNAPSHOT_ID}"

RESTORE_DIR="${RESTORE_TEST_ROOT}/${TENANT_ID}-${SNAPSHOT_ID}-$$"

[[ ! -e "$RESTORE_DIR" ]] ||
  fail "El directorio temporal ya existe: ${RESTORE_DIR}"

mkdir -p "$RESTORE_DIR"
chmod 700 "$RESTORE_DIR"

# =============================================================================
# Restaurar snapshot
# =============================================================================

log "Restaurando snapshot en: ${RESTORE_DIR}"

restic restore "$SNAPSHOT_ID" \
  --target "$RESTORE_DIR"

staging_parent="${RESTORE_DIR}/opt/aegora/backups/staging/${TENANT_ID}"

require_directory "$staging_parent"

RUN_ID="$(
  find "$staging_parent" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -printf '%f\n' |
    sort |
    tail -n 1
)"

[[ -n "$RUN_ID" ]] ||
  fail "No se encontró ninguna ejecución restaurada."

RUN_DIR="${staging_parent}/${RUN_ID}"

require_directory "$RUN_DIR"
require_directory "${RUN_DIR}/postgres"
require_directory "${RUN_DIR}/manifests"

require_file "${RUN_DIR}/manifests/SHA256SUMS"
require_file "${RUN_DIR}/manifests/backup.manifest.json"
require_file "${RUN_DIR}/postgres/globals.sql"

log "Ejecución restaurada: ${RUN_ID}"

# =============================================================================
# Validar hashes
# =============================================================================

log "Validando hashes SHA-256."

(
  cd "$RUN_DIR"
  sha256sum --check manifests/SHA256SUMS
)

# =============================================================================
# Leer las bases del manifiesto incluido en el snapshot
# =============================================================================

DATABASES=()

while IFS= read -r -d '' database; do
  DATABASES+=("$database")
done < <(
  python3 - "${RUN_DIR}/manifests/backup.manifest.json" <<'PY'
import json
import os
import re
import sys

manifest_path = sys.argv[1]

with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

databases = manifest.get("databases")

if not isinstance(databases, list) or not databases:
    raise SystemExit("El manifiesto no contiene bases de datos")

for database in databases:
    expanded = os.path.expandvars(database)

    if not re.fullmatch(r"[A-Za-z0-9_]+", expanded):
        raise SystemExit(f"Nombre de base inválido: {expanded}")

    sys.stdout.write(expanded)
    sys.stdout.write("\0")
PY
)

[[ ${#DATABASES[@]} -gt 0 ]] ||
  fail "No se pudieron leer bases desde el manifiesto restaurado."

# =============================================================================
# Validar y restaurar cada dump
# =============================================================================

safe_run_id="$(sanitize_identifier "$RUN_ID")"

for source_database in "${DATABASES[@]}"; do
  dump_file="${RUN_DIR}/postgres/${source_database}.dump"

  require_file "$dump_file"

  log "Validando dump: ${source_database}.dump"

  docker exec -i "$POSTGRES_CONTAINER" \
    pg_restore --list \
    < "$dump_file" \
    > /dev/null

  test_database="$(
    sanitize_identifier \
      "rt_${TENANT_ID}_${source_database}_${safe_run_id}"
  )"

  TEST_DATABASES+=("$test_database")

  drop_test_database "$test_database"

  log "Creando base temporal: ${test_database}"

  docker exec "$POSTGRES_CONTAINER" \
    createdb \
      --username="$POSTGRES_ADMIN_USER" \
      "$test_database"

  log "Restaurando '${source_database}' en '${test_database}'."

  docker exec -i "$POSTGRES_CONTAINER" \
    pg_restore \
      --username="$POSTGRES_ADMIN_USER" \
      --dbname="$test_database" \
      --no-owner \
      --no-privileges \
      --exit-on-error \
    < "$dump_file"

  schema_count="$(
    docker exec "$POSTGRES_CONTAINER" \
      psql \
        --username="$POSTGRES_ADMIN_USER" \
        --dbname="$test_database" \
        --tuples-only \
        --no-align \
        --command="
          SELECT COUNT(*)
          FROM information_schema.schemata
          WHERE schema_name NOT IN (
            'pg_catalog',
            'information_schema',
            'pg_toast'
          );
        " |
      tr -d '[:space:]'
  )"

  table_count="$(
    docker exec "$POSTGRES_CONTAINER" \
      psql \
        --username="$POSTGRES_ADMIN_USER" \
        --dbname="$test_database" \
        --tuples-only \
        --no-align \
        --command="
          SELECT COUNT(*)
          FROM information_schema.tables
          WHERE table_schema NOT IN (
            'pg_catalog',
            'information_schema'
          );
        " |
      tr -d '[:space:]'
  )"

  [[ "$schema_count" =~ ^[0-9]+$ ]] ||
    fail "No se pudo consultar la base temporal '${test_database}'."

  [[ "$table_count" =~ ^[0-9]+$ ]] ||
    fail "No se pudo contar tablas en '${test_database}'."

  log "Restauración válida: ${source_database}"
  log "  base temporal: ${test_database}"
  log "  esquemas de usuario: ${schema_count}"
  log "  tablas de usuario: ${table_count}"
done

log "Todos los dumps se han restaurado y consultado correctamente."