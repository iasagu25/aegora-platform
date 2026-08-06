#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly SECRETS_ROOT="/opt/aegora/secrets"
readonly BACKUP_ROOT="/opt/aegora/backups"
readonly STAGING_ROOT="${BACKUP_ROOT}/staging"
readonly LOCK_FILE="/run/lock/aegora-backup.lock"

TENANT="${TENANT:-aegora}"

readonly TENANT_CONFIG="${PLATFORM_ROOT}/customers/${TENANT}/tenant.env"
readonly RESTIC_CONFIG="${SECRETS_ROOT}/restic.env"
readonly EXCLUDES_FILE="${PLATFORM_ROOT}/scripts/backup/excludes.txt"

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

cleanup() {
  local exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    log "El backup terminó con errores."
  fi

  exit "$exit_code"
}

trap cleanup EXIT
trap 'fail "Fallo en la línea ${LINENO}: ${BASH_COMMAND}"' ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "Falta el comando requerido: $1"
}

require_file() {
  [[ -f "$1" ]] ||
    fail "Falta el fichero requerido: $1"
}

copy_required_file() {
  local source="$1"
  local destination="$2"
  local mode="${3:-600}"

  require_file "$source"

  install \
    --directory \
    --mode=700 \
    "$(dirname "$destination")"

  install \
    --mode="$mode" \
    "$source" \
    "$destination"
}

copy_optional_file() {
  local source="$1"
  local destination="$2"
  local mode="${3:-600}"

  if [[ ! -f "$source" ]]; then
    log "Fichero opcional ausente; se omite: ${source}"
    return 0
  fi

  install \
    --directory \
    --mode=700 \
    "$(dirname "$destination")"

  install \
    --mode="$mode" \
    "$source" \
    "$destination"
}

require_command docker
require_command restic
require_command flock
require_command sha256sum
require_command hostname
require_command python3
require_command find
require_command sort
require_command xargs
require_command install
require_command stat
require_command grep

require_file "$TENANT_CONFIG"
require_file "$RESTIC_CONFIG"
require_file "$EXCLUDES_FILE"

mkdir -p "$(dirname "$LOCK_FILE")"

# Impedir dos backups simultáneos.
exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  fail "Ya hay otro backup en ejecución."
fi

# Cargar configuración del tenant y credenciales Restic/S3.
set -a

# shellcheck disable=SC1090
source "$TENANT_CONFIG"

# shellcheck disable=SC1090
source "$RESTIC_CONFIG"

set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${ENVIRONMENT:?Falta ENVIRONMENT}"
: "${BACKUP_HOST:?Falta BACKUP_HOST}"
: "${BACKUP_TAG_TENANT:?Falta BACKUP_TAG_TENANT}"
: "${BACKUP_TAG_ENVIRONMENT:?Falta BACKUP_TAG_ENVIRONMENT}"

: "${POSTGRES_DIRECTUS_DB:?Falta POSTGRES_DIRECTUS_DB}"
: "${POSTGRES_N8N_DB:?Falta POSTGRES_N8N_DB}"
: "${POSTGRES_BOOKING_DB:?Falta POSTGRES_BOOKING_DB}"

: "${RESTIC_REPOSITORY:?Falta RESTIC_REPOSITORY}"
: "${RESTIC_PASSWORD:?Falta RESTIC_PASSWORD}"
: "${AWS_ACCESS_KEY_ID:?Falta AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Falta AWS_SECRET_ACCESS_KEY}"

readonly RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')"
readonly RUN_DIR="${STAGING_ROOT}/${TENANT_ID}/${RUN_ID}"
readonly POSTGRES_DIR="${RUN_DIR}/postgres"
readonly CONFIG_DIR="${RUN_DIR}/configuration"
readonly MANIFEST_DIR="${RUN_DIR}/manifests"

readonly POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-aegora-postgres}"

DATABASES=(
  "$POSTGRES_DIRECTUS_DB"
  "$POSTGRES_N8N_DB"
  "$POSTGRES_BOOKING_DB"
)

log "Iniciando backup del tenant '${TENANT_ID}'."
log "Repositorio: ${RESTIC_REPOSITORY}"
log "Ejecución: ${RUN_ID}"

# ---------------------------------------------------------------------------
# Validar PostgreSQL
# ---------------------------------------------------------------------------

docker inspect "$POSTGRES_CONTAINER" >/dev/null 2>&1 ||
  fail "No existe el contenedor '${POSTGRES_CONTAINER}'."

postgres_status="$(
  docker inspect \
    --format='{{.State.Status}}' \
    "$POSTGRES_CONTAINER"
)"

postgres_health="$(
  docker inspect \
    --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}' \
    "$POSTGRES_CONTAINER"
)"

[[ "$postgres_status" == "running" ]] ||
  fail "PostgreSQL no está en ejecución. Estado: ${postgres_status}"

if [[ "$postgres_health" != "not-configured" &&
      "$postgres_health" != "healthy" ]]; then
  fail "PostgreSQL no está healthy. Estado: ${postgres_health}"
fi

POSTGRES_ADMIN_USER="$(
  docker exec "$POSTGRES_CONTAINER" \
    printenv POSTGRES_USER 2>/dev/null |
    tr -d '\r\n'
)"

[[ -n "$POSTGRES_ADMIN_USER" ]] ||
  fail "No se pudo obtener POSTGRES_USER del contenedor."

readonly POSTGRES_ADMIN_USER

log "Usuario administrativo PostgreSQL detectado: ${POSTGRES_ADMIN_USER}"

# ---------------------------------------------------------------------------
# Preparar staging
# ---------------------------------------------------------------------------

rm -rf "${STAGING_ROOT:?}/${TENANT_ID:?}"

mkdir -p \
  "$POSTGRES_DIR" \
  "$CONFIG_DIR" \
  "$MANIFEST_DIR"

chmod 700 \
  "$RUN_DIR" \
  "$POSTGRES_DIR" \
  "$CONFIG_DIR" \
  "$MANIFEST_DIR"

# ---------------------------------------------------------------------------
# PostgreSQL: roles y objetos globales
# ---------------------------------------------------------------------------

log "Exportando roles y objetos globales de PostgreSQL."

globals_file="${POSTGRES_DIR}/globals.sql"
globals_error="${POSTGRES_DIR}/globals.stderr"

if ! docker exec "$POSTGRES_CONTAINER" \
  pg_dumpall \
    --username="$POSTGRES_ADMIN_USER" \
    --globals-only \
  > "$globals_file" \
  2> "$globals_error"; then

  log "pg_dumpall falló:"
  cat "$globals_error" >&2

  fail "No se pudieron exportar los objetos globales de PostgreSQL."
fi

rm -f "$globals_error"

[[ -s "$globals_file" ]] ||
  fail "El dump de objetos globales está vacío."

# ---------------------------------------------------------------------------
# PostgreSQL: bases del tenant
# ---------------------------------------------------------------------------

for database in "${DATABASES[@]}"; do
  destination="${POSTGRES_DIR}/${database}.dump"
  dump_error="${POSTGRES_DIR}/${database}.stderr"

  log "Comprobando existencia de la base '${database}'."

  database_exists="$(
    docker exec "$POSTGRES_CONTAINER" \
      psql \
        --username="$POSTGRES_ADMIN_USER" \
        --dbname=postgres \
        --tuples-only \
        --no-align \
        --command="SELECT 1 FROM pg_database WHERE datname = '${database}';" \
      2>/dev/null |
      tr -d '[:space:]'
  )"

  [[ "$database_exists" == "1" ]] ||
    fail "La base declarada '${database}' no existe."

  log "Exportando base '${database}'."

  if ! docker exec "$POSTGRES_CONTAINER" \
    pg_dump \
      --username="$POSTGRES_ADMIN_USER" \
      --dbname="$database" \
      --format=custom \
      --compress=6 \
      --no-owner \
    > "$destination" \
    2> "$dump_error"; then

    log "pg_dump falló para '${database}':"
    cat "$dump_error" >&2

    fail "No se pudo exportar la base '${database}'."
  fi

  rm -f "$dump_error"

  [[ -s "$destination" ]] ||
    fail "El dump de '${database}' está vacío."

  log "Validando estructura del dump '${database}'."

  if ! docker exec -i "$POSTGRES_CONTAINER" \
    pg_restore --list \
    < "$destination" \
    > /dev/null; then

    fail "El dump de '${database}' no supera pg_restore --list."
  fi

  dump_size="$(stat --format='%s' "$destination")"

  log "Dump '${database}' válido: ${dump_size} bytes."
done

# ---------------------------------------------------------------------------
# Copiar solamente configuración efectiva
# ---------------------------------------------------------------------------

log "Copiando configuración efectiva."

copy_required_file \
  "$TENANT_CONFIG" \
  "${CONFIG_DIR}/tenant/tenant.env" \
  600

copy_required_file \
  "$RESTIC_CONFIG" \
  "${CONFIG_DIR}/secrets/restic.env" \
  600

copy_required_file \
  "${PLATFORM_ROOT}/compose/postgres/compose.yml" \
  "${CONFIG_DIR}/compose/postgres/compose.yml" \
  600

copy_required_file \
  "${PLATFORM_ROOT}/compose/postgres/.env" \
  "${CONFIG_DIR}/compose/postgres/.env" \
  600

copy_required_file \
  "${PLATFORM_ROOT}/compose/directus/compose.yml" \
  "${CONFIG_DIR}/compose/directus/compose.yml" \
  600

copy_required_file \
  "${PLATFORM_ROOT}/compose/directus/.env" \
  "${CONFIG_DIR}/compose/directus/.env" \
  600

copy_required_file \
  "${PLATFORM_ROOT}/compose/n8n/compose.yml" \
  "${CONFIG_DIR}/compose/n8n/compose.yml" \
  600

copy_required_file \
  "${PLATFORM_ROOT}/compose/n8n/.env" \
  "${CONFIG_DIR}/compose/n8n/.env" \
  600

copy_required_file \
  "${PLATFORM_ROOT}/compose/caddy/compose.yml" \
  "${CONFIG_DIR}/compose/caddy/compose.yml" \
  600

copy_required_file \
  "${PLATFORM_ROOT}/compose/caddy/.env" \
  "${CONFIG_DIR}/compose/caddy/.env" \
  600

copy_required_file \
  "${PLATFORM_ROOT}/compose/caddy/Caddyfile" \
  "${CONFIG_DIR}/compose/caddy/Caddyfile" \
  600

copy_optional_file \
  "${PLATFORM_ROOT}/compose/booking/compose.yml" \
  "${CONFIG_DIR}/compose/booking/compose.yml" \
  600

copy_optional_file \
  "${PLATFORM_ROOT}/compose/booking/.env" \
  "${CONFIG_DIR}/compose/booking/.env" \
  600

# ---------------------------------------------------------------------------
# Manifiesto
# ---------------------------------------------------------------------------

log "Creando manifiesto del backup."

postgres_version="$(
  docker exec "$POSTGRES_CONTAINER" postgres --version
)"

restic_version="$(
  restic version |
    head -n 1
)"

source_hostname="$(
  hostname --fqdn 2>/dev/null ||
    hostname
)"

cat > "${MANIFEST_DIR}/backup.env" <<EOF
BACKUP_RUN_ID=${RUN_ID}
BACKUP_CREATED_AT=$(date -u --iso-8601=seconds)
TENANT_ID=${TENANT_ID}
ENVIRONMENT=${ENVIRONMENT}
BACKUP_HOST=${BACKUP_HOST}
SOURCE_HOSTNAME=${source_hostname}
POSTGRES_CONTAINER=${POSTGRES_CONTAINER}
POSTGRES_ADMIN_USER=${POSTGRES_ADMIN_USER}
POSTGRES_VERSION=${postgres_version}
RESTIC_VERSION=${restic_version}
DATABASES=${DATABASES[*]}
EOF

(
  cd "$RUN_DIR"

  find . \
    -type f \
    ! -path './manifests/SHA256SUMS' \
    -print0 |
    sort -z |
    xargs -0 sha256sum
) > "${MANIFEST_DIR}/SHA256SUMS"

[[ -s "${MANIFEST_DIR}/SHA256SUMS" ]] ||
  fail "No se pudo generar el manifiesto SHA256."

# ---------------------------------------------------------------------------
# Rutas persistentes
# ---------------------------------------------------------------------------

BACKUP_PATHS=(
  "$RUN_DIR"
)

OPTIONAL_PATHS=(
  "/opt/aegora/data/directus"
  "/opt/aegora/data/n8n"
  "/opt/aegora/data/caddy"
  "/opt/aegora/data/booking"
)

for path in "${OPTIONAL_PATHS[@]}"; do
  if [[ -d "$path" ]]; then
    BACKUP_PATHS+=("$path")
    log "Incluyendo ruta persistente: ${path}"
  else
    log "Ruta opcional ausente; se omite: ${path}"
  fi
done

# Ya no incluimos:
#
# /opt/aegora/platform
# /opt/aegora/secrets
#
# La configuración efectiva necesaria está copiada selectivamente dentro
# de RUN_DIR/configuration.

# ---------------------------------------------------------------------------
# Restic
# ---------------------------------------------------------------------------

log "Verificando acceso al repositorio Restic."

if ! restic snapshots \
  --host "$BACKUP_HOST" \
  --tag "$BACKUP_TAG_TENANT" \
  >/dev/null; then

  fail "No se pudo acceder al repositorio Restic."
fi

log "Enviando backup cifrado a Object Storage."

if ! restic backup \
  "${BACKUP_PATHS[@]}" \
  --host "$BACKUP_HOST" \
  --tag "$BACKUP_TAG_TENANT" \
  --tag "$BACKUP_TAG_ENVIRONMENT" \
  --tag "type=full" \
  --tag "run=${RUN_ID}" \
  --exclude-file="$EXCLUDES_FILE" \
  --verbose; then

  fail "Restic no pudo completar el backup."
fi

log "Localizando el snapshot recién creado."

snapshot_id="$(
  restic snapshots \
    --host "$BACKUP_HOST" \
    --tag "run=${RUN_ID}" \
    --json |
    python3 -c '
import json
import sys

snapshots = json.load(sys.stdin)

if not snapshots:
    raise SystemExit(1)

snapshot = snapshots[-1]
print(snapshot.get("short_id") or snapshot["id"][:8])
'
)"

[[ -n "$snapshot_id" ]] ||
  fail "No se pudo localizar el snapshot recién creado."

log "Snapshot creado: ${snapshot_id}"

# ---------------------------------------------------------------------------
# Verificar que los dumps están realmente dentro del snapshot
# ---------------------------------------------------------------------------

log "Verificando presencia de dumps en el snapshot remoto."

snapshot_listing="$(
  restic ls "$snapshot_id"
)"

for database in "${DATABASES[@]}"; do
  expected_path="/opt/aegora/backups/staging/${TENANT_ID}/${RUN_ID}/postgres/${database}.dump"

  if ! grep -Fq "$expected_path" <<< "$snapshot_listing"; then
    fail "El snapshot no contiene el dump esperado: ${expected_path}"
  fi

  log "Dump confirmado en snapshot: ${database}.dump"
done

expected_globals="/opt/aegora/backups/staging/${TENANT_ID}/${RUN_ID}/postgres/globals.sql"

if ! grep -Fq "$expected_globals" <<< "$snapshot_listing"; then
  fail "El snapshot no contiene globals.sql."
fi

log "Todos los dumps están presentes en el snapshot."

# El staging solo se elimina después de verificar el contenido remoto.
rm -rf "${STAGING_ROOT:?}/${TENANT_ID:?}"

log "Staging local eliminado."
log "Backup finalizado correctamente."
