#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Configuración base
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly SECRETS_ROOT="/opt/aegora/secrets"
readonly RESTORE_ROOT_DEFAULT="/opt/aegora/restore"
readonly LOCK_FILE="/run/lock/aegora-restore.lock"

TENANT="${TENANT:-aegora}"
SNAPSHOT="${SNAPSHOT:-latest}"
RESTORE_ROOT="${RESTORE_ROOT:-$RESTORE_ROOT_DEFAULT}"

MODE="verify"
DATABASE_SELECTION="none"

RESTORE_FILES=false
RESTORE_CONFIG=false
RESTORE_GLOBALS=false
APPLY_PRODUCTION=false
ASSUME_YES=false
KEEP_RESTORE=false

readonly TENANT_CONFIG="${PLATFORM_ROOT}/customers/${TENANT}/tenant.env"
readonly RESTIC_CONFIG="${SECRETS_ROOT}/restic.env"

RESTORE_DIR=""
RUN_DIR=""
RUN_ID=""
SNAPSHOT_ID=""

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

usage() {
  cat <<'EOF'
Uso:

  restore-tenant.sh [opciones]

Por defecto:
  - selecciona el snapshot más reciente del tenant;
  - lo restaura en /opt/aegora/restore;
  - valida hashes y dumps;
  - no modifica producción.

Opciones:

  --tenant ID
      Tenant que se va a restaurar.
      Por defecto: aegora

  --snapshot ID
      Snapshot Restic concreto.
      También admite: latest

  --restore-root RUTA
      Directorio temporal de restauración.
      Por defecto: /opt/aegora/restore

  --verify-only
      Restaura en un directorio aislado y valida hashes y dumps.
      Es el modo predeterminado.

  --test-databases
      Restaura todas las bases en bases temporales de prueba.

  --databases all|directus|n8n|booking|none
      Bases que se restaurarán.
      En producción requiere --apply-production.

  --restore-files
      Restaura datos persistentes de Directus, n8n, Caddy y Booking.

  --restore-config
      Restaura configuración efectiva: compose.yml, .env, Caddyfile y tenant.env.

  --restore-globals
      Aplica globals.sql.
      Es una operación delicada y solo se admite con --apply-production.

  --apply-production
      Permite modificar los servicios y bases de producción.

  --yes
      Omite la confirmación interactiva.
      Solo debe usarse en un procedimiento controlado.

  --keep
      Conserva el directorio temporal después de finalizar.

  --help
      Muestra esta ayuda.

Ejemplos:

  Verificar el último snapshot:

    sudo TENANT=aegora \
      ./scripts/restore/restore-tenant.sh --verify-only

  Probar las tres bases en bases temporales:

    sudo TENANT=aegora \
      ./scripts/restore/restore-tenant.sh --test-databases

  Restaurar únicamente Booking en producción:

    sudo TENANT=aegora \
      ./scripts/restore/restore-tenant.sh \
        --snapshot 9dbb3ff2 \
        --databases booking \
        --apply-production

  Restauración integral:

    sudo TENANT=aegora \
      ./scripts/restore/restore-tenant.sh \
        --snapshot 9dbb3ff2 \
        --databases all \
        --restore-config \
        --restore-files \
        --apply-production
EOF
}

cleanup() {
  local exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    log "La restauración terminó con errores."

    if [[ -n "${RESTORE_DIR:-}" && -d "$RESTORE_DIR" ]]; then
      warn "Se conserva el directorio para diagnóstico: ${RESTORE_DIR}"
    fi

    exit "$exit_code"
  fi

  if [[ "$KEEP_RESTORE" == false &&
        "$MODE" == "verify" &&
        -n "${RESTORE_DIR:-}" &&
        -d "$RESTORE_DIR" ]]; then

    rm -rf "$RESTORE_DIR"
    log "Directorio temporal eliminado."
  elif [[ -n "${RESTORE_DIR:-}" && -d "$RESTORE_DIR" ]]; then
    log "Directorio restaurado conservado en: ${RESTORE_DIR}"
  fi

  exit 0
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

require_directory() {
  [[ -d "$1" ]] ||
    fail "Falta el directorio requerido: $1"
}

sanitize_identifier() {
  printf '%s' "$1" |
    tr -c '[:alnum:]_' '_' |
    cut -c1-50
}

confirm_production_restore() {
  if [[ "$APPLY_PRODUCTION" != true ]]; then
    return 0
  fi

  warn "VAS A MODIFICAR EL ENTORNO DE PRODUCCIÓN."
  warn "Tenant: ${TENANT_ID}"
  warn "Snapshot: ${SNAPSHOT_ID}"
  warn "Bases: ${DATABASE_SELECTION}"
  warn "Datos persistentes: ${RESTORE_FILES}"
  warn "Configuración: ${RESTORE_CONFIG}"
  warn "Objetos globales PostgreSQL: ${RESTORE_GLOBALS}"

  if [[ "$ASSUME_YES" == true ]]; then
    warn "Confirmación interactiva omitida mediante --yes."
    return 0
  fi

  printf '\nEscribe exactamente RESTAURAR-%s para continuar: ' "$TENANT_ID"

  local confirmation
  read -r confirmation

  [[ "$confirmation" == "RESTAURAR-${TENANT_ID}" ]] ||
    fail "Confirmación incorrecta. No se ha modificado producción."
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

stop_container_if_running() {
  local container="$1"

  if ! container_exists "$container"; then
    warn "Contenedor no encontrado; se omite parada: ${container}"
    return 0
  fi

  if container_running "$container"; then
    log "Deteniendo contenedor: ${container}"
    docker stop --time 60 "$container" >/dev/null
  else
    log "Contenedor ya detenido: ${container}"
  fi
}

start_container_if_present() {
  local container="$1"

  if ! container_exists "$container"; then
    warn "Contenedor no encontrado; se omite arranque: ${container}"
    return 0
  fi

  if container_running "$container"; then
    log "Contenedor ya está en ejecución: ${container}"
  else
    log "Arrancando contenedor: ${container}"
    docker start "$container" >/dev/null
  fi
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

create_empty_database() {
  local database="$1"

  if [[ "$(database_exists "$database")" == "1" ]]; then
    terminate_database_connections "$database"

    docker exec "$POSTGRES_CONTAINER" \
      dropdb \
        --username="$POSTGRES_ADMIN_USER" \
        --if-exists \
        "$database"
  fi

  docker exec "$POSTGRES_CONTAINER" \
    createdb \
      --username="$POSTGRES_ADMIN_USER" \
      "$database"
}

restore_database_dump() {
  local source_database="$1"
  local destination_database="$2"
  local dump_file="${RUN_DIR}/postgres/${source_database}.dump"

  require_file "$dump_file"

  log "Creando base vacía: ${destination_database}"
  create_empty_database "$destination_database"

  log "Restaurando '${source_database}' en '${destination_database}'."

  if ! docker exec -i "$POSTGRES_CONTAINER" \
    pg_restore \
      --username="$POSTGRES_ADMIN_USER" \
      --dbname="$destination_database" \
      --no-owner \
      --no-privileges \
      --exit-on-error \
    < "$dump_file"; then

    fail "Falló la restauración de '${source_database}' en '${destination_database}'."
  fi

  log "Base restaurada correctamente: ${destination_database}"
}

count_user_tables() {
  local database="$1"

  docker exec "$POSTGRES_CONTAINER" \
    psql \
      --username="$POSTGRES_ADMIN_USER" \
      --dbname="$database" \
      --tuples-only \
      --no-align \
      --command="
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema');
      " |
    tr -d '[:space:]'
}

restore_directory() {
  local source="$1"
  local destination="$2"

  require_directory "$source"

  log "Restaurando directorio:"
  log "  origen:  ${source}"
  log "  destino: ${destination}"

  mkdir -p "$destination"

  rsync \
    --archive \
    --hard-links \
    --acls \
    --xattrs \
    --delete \
    "${source}/" \
    "${destination}/"
}

restore_config_file() {
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

  log "Configuración restaurada: ${destination}"
}

# =============================================================================
# Argumentos
# =============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      [[ $# -ge 2 ]] || fail "Falta valor para --tenant"
      TENANT="$2"
      shift 2
      ;;

    --snapshot)
      [[ $# -ge 2 ]] || fail "Falta valor para --snapshot"
      SNAPSHOT="$2"
      shift 2
      ;;

    --restore-root)
      [[ $# -ge 2 ]] || fail "Falta valor para --restore-root"
      RESTORE_ROOT="$2"
      shift 2
      ;;

    --verify-only)
      MODE="verify"
      DATABASE_SELECTION="none"
      shift
      ;;

    --test-databases)
      MODE="test-databases"
      DATABASE_SELECTION="all"
      KEEP_RESTORE=true
      shift
      ;;

    --databases)
      [[ $# -ge 2 ]] || fail "Falta valor para --databases"

      case "$2" in
        all|directus|n8n|booking|none)
          DATABASE_SELECTION="$2"
          ;;
        *)
          fail "Valor inválido para --databases: $2"
          ;;
      esac

      shift 2
      ;;

    --restore-files)
      RESTORE_FILES=true
      shift
      ;;

    --restore-config)
      RESTORE_CONFIG=true
      shift
      ;;

    --restore-globals)
      RESTORE_GLOBALS=true
      shift
      ;;

    --apply-production)
      APPLY_PRODUCTION=true
      MODE="production"
      KEEP_RESTORE=true
      shift
      ;;

    --yes)
      ASSUME_YES=true
      shift
      ;;

    --keep)
      KEEP_RESTORE=true
      shift
      ;;

    --help|-h)
      usage
      exit 0
      ;;

    *)
      fail "Opción desconocida: $1"
      ;;
  esac
done

readonly TENANT_CONFIG="${PLATFORM_ROOT}/customers/${TENANT}/tenant.env"

# =============================================================================
# Prerrequisitos
# =============================================================================

require_command restic
require_command docker
require_command flock
require_command sha256sum
require_command find
require_command sort
require_command grep
require_command rsync
require_command install
require_command python3

require_file "$TENANT_CONFIG"
require_file "$RESTIC_CONFIG"

mkdir -p "$(dirname "$LOCK_FILE")"
mkdir -p "$RESTORE_ROOT"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  fail "Ya hay otra restauración en ejecución."
fi

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

: "${POSTGRES_DIRECTUS_DB:?Falta POSTGRES_DIRECTUS_DB}"
: "${POSTGRES_N8N_DB:?Falta POSTGRES_N8N_DB}"
: "${POSTGRES_BOOKING_DB:?Falta POSTGRES_BOOKING_DB}"

: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"
: "${N8N_CONTAINER:?Falta N8N_CONTAINER}"
: "${BOOKING_CONTAINER:?Falta BOOKING_CONTAINER}"

: "${DIRECTUS_DATA_DIR:?Falta DIRECTUS_DATA_DIR}"
: "${N8N_DATA_DIR:?Falta N8N_DATA_DIR}"
: "${BOOKING_DATA_DIR:?Falta BOOKING_DATA_DIR}"

: "${RESTIC_REPOSITORY:?Falta RESTIC_REPOSITORY}"
: "${RESTIC_PASSWORD:?Falta RESTIC_PASSWORD}"
: "${AWS_ACCESS_KEY_ID:?Falta AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Falta AWS_SECRET_ACCESS_KEY}"

readonly POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-aegora-postgres}"

container_exists "$POSTGRES_CONTAINER" ||
  fail "No existe el contenedor PostgreSQL: ${POSTGRES_CONTAINER}"

POSTGRES_ADMIN_USER="$(
  docker exec "$POSTGRES_CONTAINER" \
    printenv POSTGRES_USER 2>/dev/null |
    tr -d '\r\n'
)"

[[ -n "$POSTGRES_ADMIN_USER" ]] ||
  fail "No se pudo obtener POSTGRES_USER."

readonly POSTGRES_ADMIN_USER

# =============================================================================
# Seleccionar snapshot
# =============================================================================

log "Buscando snapshot para el tenant '${TENANT_ID}'."

if [[ "$SNAPSHOT" == "latest" ]]; then
  SNAPSHOT_ID="$(
    restic snapshots \
      --host "$BACKUP_HOST" \
      --tag "$BACKUP_TAG_TENANT" \
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
  fail "No se pudo seleccionar ningún snapshot."

log "Snapshot seleccionado: ${SNAPSHOT_ID}"

RESTORE_DIR="${RESTORE_ROOT}/${TENANT_ID}/${SNAPSHOT_ID}"

if [[ -e "$RESTORE_DIR" ]]; then
  fail "El directorio de restauración ya existe: ${RESTORE_DIR}"
fi

mkdir -p "$RESTORE_DIR"
chmod 700 "$RESTORE_DIR"

# =============================================================================
# Restaurar snapshot a zona aislada
# =============================================================================

log "Restaurando snapshot en zona aislada."

restic restore "$SNAPSHOT_ID" \
  --target "$RESTORE_DIR"

RUN_DIR="$(
  find \
    "${RESTORE_DIR}/opt/aegora/backups/staging/${TENANT_ID}" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -printf '%f\n' |
    sort |
    tail -n 1
)"

[[ -n "$RUN_DIR" ]] ||
  fail "No se encontró ninguna ejecución dentro del snapshot."

RUN_ID="$RUN_DIR"
RUN_DIR="${RESTORE_DIR}/opt/aegora/backups/staging/${TENANT_ID}/${RUN_ID}"

require_directory "$RUN_DIR"
require_directory "${RUN_DIR}/postgres"
require_directory "${RUN_DIR}/configuration"
require_directory "${RUN_DIR}/manifests"

log "Ejecución restaurada: ${RUN_ID}"
log "Ruta de ejecución: ${RUN_DIR}"

# =============================================================================
# Validaciones obligatorias
# =============================================================================

log "Validando hashes SHA-256."

(
  cd "$RUN_DIR"
  sha256sum --check manifests/SHA256SUMS
)

log "Validando dumps PostgreSQL."

DATABASES=(
  "$POSTGRES_DIRECTUS_DB"
  "$POSTGRES_N8N_DB"
  "$POSTGRES_BOOKING_DB"
)

for database in "${DATABASES[@]}"; do
  dump_file="${RUN_DIR}/postgres/${database}.dump"

  require_file "$dump_file"

  if ! docker exec -i "$POSTGRES_CONTAINER" \
    pg_restore --list \
    < "$dump_file" \
    > /dev/null; then

    fail "Dump no válido: ${dump_file}"
  fi

  log "Dump válido: ${database}.dump"
done

require_file "${RUN_DIR}/postgres/globals.sql"
require_file "${RUN_DIR}/manifests/backup.env"

log "Snapshot restaurado y validado correctamente."

# =============================================================================
# Prueba de restauración en bases temporales
# =============================================================================

if [[ "$MODE" == "test-databases" ]]; then
  log "Iniciando restauración de prueba de las bases."

  safe_run_id="$(sanitize_identifier "$RUN_ID")"

  for database in "${DATABASES[@]}"; do
    test_database="$(
      sanitize_identifier "${database}_restore_test_${safe_run_id}"
    )"

    restore_database_dump "$database" "$test_database"

    table_count="$(count_user_tables "$test_database")"

    log "Base de prueba '${test_database}': ${table_count} tablas de usuario."
  done

  log "Las bases de prueba se conservan para revisión."
  log "Elimínalas después con dropdb cuando termines."

  exit 0
fi

# =============================================================================
# Protección de producción
# =============================================================================

if [[ "$APPLY_PRODUCTION" != true ]]; then
  log "Modo verificación completado."
  log "No se ha modificado ningún servicio de producción."
  exit 0
fi

if [[ "$DATABASE_SELECTION" == "none" &&
      "$RESTORE_FILES" == false &&
      "$RESTORE_CONFIG" == false &&
      "$RESTORE_GLOBALS" == false ]]; then

  fail "No se ha seleccionado ningún componente para restaurar."
fi

confirm_production_restore

# =============================================================================
# Determinar servicios afectados
# =============================================================================

RESTORE_DIRECTUS=false
RESTORE_N8N=false
RESTORE_BOOKING=false

case "$DATABASE_SELECTION" in
  all)
    RESTORE_DIRECTUS=true
    RESTORE_N8N=true
    RESTORE_BOOKING=true
    ;;

  directus)
    RESTORE_DIRECTUS=true
    ;;

  n8n)
    RESTORE_N8N=true
    ;;

  booking)
    RESTORE_BOOKING=true
    ;;

  none)
    ;;
esac

if [[ "$RESTORE_FILES" == true ]]; then
  RESTORE_DIRECTUS=true
  RESTORE_N8N=true

  if [[ -d "${RESTORE_DIR}${BOOKING_DATA_DIR}" ]]; then
    RESTORE_BOOKING=true
  fi
fi

# =============================================================================
# Detener servicios afectados
# =============================================================================

if [[ "$RESTORE_BOOKING" == true ]]; then
  stop_container_if_running "$BOOKING_CONTAINER"
fi

if [[ "$RESTORE_N8N" == true ]]; then
  stop_container_if_running "$N8N_CONTAINER"
fi

if [[ "$RESTORE_DIRECTUS" == true ]]; then
  stop_container_if_running "$DIRECTUS_CONTAINER"
fi

# =============================================================================
# Restaurar configuración efectiva
# =============================================================================

if [[ "$RESTORE_CONFIG" == true ]]; then
  log "Restaurando configuración efectiva."

  restore_config_file \
    "${RUN_DIR}/configuration/tenant/tenant.env" \
    "${PLATFORM_ROOT}/customers/${TENANT}/tenant.env" \
    600

  restore_config_file \
    "${RUN_DIR}/configuration/secrets/restic.env" \
    "${SECRETS_ROOT}/restic.env" \
    600

  restore_config_file \
    "${RUN_DIR}/configuration/compose/postgres/compose.yml" \
    "${PLATFORM_ROOT}/compose/postgres/compose.yml" \
    600

  restore_config_file \
    "${RUN_DIR}/configuration/compose/postgres/.env" \
    "${PLATFORM_ROOT}/compose/postgres/.env" \
    600

  restore_config_file \
    "${RUN_DIR}/configuration/compose/directus/compose.yml" \
    "${PLATFORM_ROOT}/compose/directus/compose.yml" \
    600

  restore_config_file \
    "${RUN_DIR}/configuration/compose/directus/.env" \
    "${PLATFORM_ROOT}/compose/directus/.env" \
    600

  restore_config_file \
    "${RUN_DIR}/configuration/compose/n8n/compose.yml" \
    "${PLATFORM_ROOT}/compose/n8n/compose.yml" \
    600

  restore_config_file \
    "${RUN_DIR}/configuration/compose/n8n/.env" \
    "${PLATFORM_ROOT}/compose/n8n/.env" \
    600

  restore_config_file \
    "${RUN_DIR}/configuration/compose/caddy/compose.yml" \
    "${PLATFORM_ROOT}/compose/caddy/compose.yml" \
    600

  restore_config_file \
    "${RUN_DIR}/configuration/compose/caddy/.env" \
    "${PLATFORM_ROOT}/compose/caddy/.env" \
    600

  restore_config_file \
    "${RUN_DIR}/configuration/compose/caddy/Caddyfile" \
    "${PLATFORM_ROOT}/compose/caddy/Caddyfile" \
    600

  if [[ -f "${RUN_DIR}/configuration/compose/booking/compose.yml" ]]; then
    restore_config_file \
      "${RUN_DIR}/configuration/compose/booking/compose.yml" \
      "${PLATFORM_ROOT}/compose/booking/compose.yml" \
      600
  fi

  if [[ -f "${RUN_DIR}/configuration/compose/booking/.env" ]]; then
    restore_config_file \
      "${RUN_DIR}/configuration/compose/booking/.env" \
      "${PLATFORM_ROOT}/compose/booking/.env" \
      600
  fi
fi

# =============================================================================
# Restaurar objetos globales PostgreSQL
# =============================================================================

if [[ "$RESTORE_GLOBALS" == true ]]; then
  warn "Aplicando roles y objetos globales de PostgreSQL."

  docker exec -i "$POSTGRES_CONTAINER" \
    psql \
      --username="$POSTGRES_ADMIN_USER" \
      --dbname=postgres \
      --set=ON_ERROR_STOP=1 \
    < "${RUN_DIR}/postgres/globals.sql"
fi

# =============================================================================
# Restaurar bases de producción
# =============================================================================

case "$DATABASE_SELECTION" in
  all)
    restore_database_dump "$POSTGRES_DIRECTUS_DB" "$POSTGRES_DIRECTUS_DB"
    restore_database_dump "$POSTGRES_N8N_DB" "$POSTGRES_N8N_DB"
    restore_database_dump "$POSTGRES_BOOKING_DB" "$POSTGRES_BOOKING_DB"
    ;;

  directus)
    restore_database_dump "$POSTGRES_DIRECTUS_DB" "$POSTGRES_DIRECTUS_DB"
    ;;

  n8n)
    restore_database_dump "$POSTGRES_N8N_DB" "$POSTGRES_N8N_DB"
    ;;

  booking)
    restore_database_dump "$POSTGRES_BOOKING_DB" "$POSTGRES_BOOKING_DB"
    ;;

  none)
    ;;
esac

# =============================================================================
# Restaurar datos persistentes
# =============================================================================

if [[ "$RESTORE_FILES" == true ]]; then
  log "Restaurando datos persistentes."

  if [[ -d "${RESTORE_DIR}${DIRECTUS_DATA_DIR}" ]]; then
    restore_directory \
      "${RESTORE_DIR}${DIRECTUS_DATA_DIR}" \
      "$DIRECTUS_DATA_DIR"
  else
    warn "No hay datos persistentes de Directus en el snapshot."
  fi

  if [[ -d "${RESTORE_DIR}${N8N_DATA_DIR}" ]]; then
    restore_directory \
      "${RESTORE_DIR}${N8N_DATA_DIR}" \
      "$N8N_DATA_DIR"
  else
    warn "No hay datos persistentes de n8n en el snapshot."
  fi

  if [[ -d "${RESTORE_DIR}/opt/aegora/data/caddy" ]]; then
    restore_directory \
      "${RESTORE_DIR}/opt/aegora/data/caddy" \
      "/opt/aegora/data/caddy"
  else
    warn "No hay datos persistentes de Caddy en el snapshot."
  fi

  if [[ -d "${RESTORE_DIR}${BOOKING_DATA_DIR}" ]]; then
    restore_directory \
      "${RESTORE_DIR}${BOOKING_DATA_DIR}" \
      "$BOOKING_DATA_DIR"
  else
    warn "No hay datos persistentes de Booking en el snapshot."
  fi
fi

# =============================================================================
# Arrancar servicios y comprobar estado
# =============================================================================

if [[ "$RESTORE_DIRECTUS" == true ]]; then
  start_container_if_present "$DIRECTUS_CONTAINER"
fi

if [[ "$RESTORE_N8N" == true ]]; then
  start_container_if_present "$N8N_CONTAINER"
fi

if [[ "$RESTORE_BOOKING" == true ]]; then
  start_container_if_present "$BOOKING_CONTAINER"
fi

log "Esperando 20 segundos para estabilización."
sleep 20

for container in \
  "$DIRECTUS_CONTAINER" \
  "$N8N_CONTAINER" \
  "$BOOKING_CONTAINER"; do

  if ! container_exists "$container"; then
    continue
  fi

  status="$(
    docker inspect \
      --format='{{.State.Status}}' \
      "$container"
  )"

  health="$(
    docker inspect \
      --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}' \
      "$container"
  )"

  log "Contenedor ${container}: status=${status}, health=${health}"

  [[ "$status" == "running" ]] ||
    fail "El contenedor '${container}' no está en ejecución."

  if [[ "$health" != "not-configured" &&
        "$health" != "healthy" &&
        "$health" != "starting" ]]; then

    fail "El contenedor '${container}' no está healthy."
  fi
done

log "Restauración de producción finalizada correctamente."
log "Directorio de trabajo conservado en: ${RESTORE_DIR}"
