#!/usr/bin/env bash

set -Eeuo pipefail

# Espera única a los contenedores (ver el fichero): nunca sleep ni un healthy exigido sin esperar.
# shellcheck source=/dev/null
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../scripts/lib/esperar-contenedor.sh"
IFS=$'\n\t'

# =============================================================================
# Configuración base
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly SECRETS_ROOT="/opt/aegora/secrets"
readonly RESTORE_ROOT_DEFAULT="/opt/aegora/restore"
readonly LOCK_FILE="/run/lock/aegora-restore.lock"

# Resolución de rutas del tenant, compartida con backup-tenant.sh y
# restore-test-tenant.sh. Este script estaba escrito SOLO para el layout antiguo
# (`customers/<tenant>/tenant.env` + `compose/<servicio>/`), que ya no existe:
# no podía restaurar ningún tenant gestionado, que son todos.
readonly CONTEXT_LIB="${PLATFORM_ROOT}/scripts/backup/tenant-context.sh"

# Sin valor por defecto: este script para servicios y sobrescribe bases de
# producción. Que asumiera un tenant si te olvidabas de --tenant era regalarle
# una bala al día peor del año.
TENANT="${TENANT:-}"
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

TENANT_CONFIG=""
RESTIC_CONFIG=""
CONFIG_LAYOUT=""
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

Comportamiento predeterminado:

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
      Directorio de restauración.
      Por defecto: /opt/aegora/restore

  --verify-only
      Restaura en un directorio aislado y valida hashes y dumps.
      Es el modo predeterminado.

  --test-databases
      Restaura las bases en bases temporales de prueba.

  --databases all|directus|n8n|booking|none
      Bases que se restaurarán.
      En producción requiere --apply-production.

  --restore-files
      Restaura los datos persistentes de Directus, n8n, Caddy y Booking.

  --restore-config
      Restaura tenant.env, restic.env y el compose del tenant.
      En un tenant gestionado NO toca la configuración de Postgres ni de
      Caddy: son de plataforma y no están en el backup de ningún tenant.

  --restore-globals
      Aplica globals.sql.
      Solo se admite con --apply-production.

  --apply-production
      Permite modificar servicios y bases de producción.

  --yes
      Omite la confirmación interactiva.

  --keep
      Conserva el directorio restaurado después de finalizar.

  --help
      Muestra esta ayuda.

Ejemplos:

  Verificar el último snapshot:

    sudo ./scripts/restore/restore-tenant.sh --tenant demo \
      --verify-only

  Verificar un snapshot concreto:

    sudo ./scripts/restore/restore-tenant.sh --tenant demo \
      --snapshot 9dbb3ff2 \
      --verify-only \
      --keep

  Probar las tres bases en bases temporales:

    sudo ./scripts/restore/restore-tenant.sh --tenant demo \
      --snapshot 9dbb3ff2 \
      --test-databases

  Restaurar únicamente Booking en producción:

    sudo ./scripts/restore/restore-tenant.sh --tenant demo \
      --snapshot 9dbb3ff2 \
      --databases booking \
      --apply-production

  Restauración integral:

    sudo ./scripts/restore/restore-tenant.sh --tenant demo \
      --snapshot 9dbb3ff2 \
      --databases all \
      --restore-config \
      --restore-files \
      --apply-production
EOF
}

cleanup() {
  local exit_code=$?

  trap - EXIT

  if [[ $exit_code -ne 0 ]]; then
    log "La restauración terminó con errores."

    if [[ -n "${RESTORE_DIR:-}" && -d "$RESTORE_DIR" ]]; then
      warn "Se conserva el directorio para diagnóstico: ${RESTORE_DIR}"
    fi

    exit "$exit_code"
  fi

  if [[
    "$KEEP_RESTORE" == false &&
    "$MODE" == "verify" &&
    -n "${RESTORE_DIR:-}" &&
    -d "$RESTORE_DIR"
  ]]; then
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

# -----------------------------------------------------------------------------
# Devolver la propiedad de una base restaurada a su rol de aplicación.
#
# `createdb` la crea a nombre del administrador y `pg_restore --no-owner
# --no-privileges` quita propiedad y permisos de todo lo que hay dentro. El
# resultado es una base perfectamente restaurada a la que su propia aplicación
# no puede entrar: Directus y n8n arrancan y mueren con "permission denied for
# schema public". Pasó en el primer ensayo real sobre `dev`.
#
# Se conservan esos flags a propósito: hacen que la restauración no dependa de
# que los roles del dump existan, que es lo que uno quiere con el sistema caído.
# El precio es que hay que reponer la propiedad aquí, a mano y explícitamente.
# Se pierden GRANTs a terceros roles, que en esta plataforma no existen: cada
# base tiene exactamente una aplicación.
# -----------------------------------------------------------------------------
apply_database_owner() {
  local database="$1"
  local role="$2"

  [[ -n "$role" ]] || return 0

  log "Devolviendo la propiedad de '${database}' a '${role}'."

  docker exec "$POSTGRES_CONTAINER" \
    psql \
      --username="$POSTGRES_ADMIN_USER" \
      --dbname=postgres \
      --set=ON_ERROR_STOP=1 \
      --quiet \
      --command="ALTER DATABASE \"${database}\" OWNER TO \"${role}\"" \
    >/dev/null

  docker exec -i "$POSTGRES_CONTAINER" \
    psql \
      --username="$POSTGRES_ADMIN_USER" \
      --dbname="$database" \
      --set=ON_ERROR_STOP=1 \
      --quiet \
    >/dev/null <<SQL
DO \$aegora_owner\$
DECLARE
  r record;
BEGIN
  EXECUTE format('ALTER SCHEMA public OWNER TO %I', '${role}');

  -- Las secuencias LIGADAS a una columna (identity/serial) no admiten cambio de
  -- dueño por su cuenta: PostgreSQL responde "cannot change owner of sequence
  -- ... is linked to table ...". Siguen a su tabla, así que se excluyen y se
  -- arreglan solas al cambiar el dueño de esta. Las secuencias sueltas sí van.
  --
  -- Las tablas primero y las secuencias sueltas al final: el ORDER BY pone
  -- false (todo lo que no es secuencia) antes que true.
  FOR r IN
    SELECT c.relname, c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'S', 'v', 'm', 'p')
      AND NOT (
        c.relkind = 'S'
        AND EXISTS (
          SELECT 1
          FROM pg_depend d
          WHERE d.classid = 'pg_class'::regclass
            AND d.objid = c.oid
            AND d.deptype = 'a'
        )
      )
    ORDER BY (c.relkind = 'S'), c.relname
  LOOP
    EXECUTE format(
      'ALTER %s public.%I OWNER TO %I',
      CASE r.relkind
        WHEN 'S' THEN 'SEQUENCE'
        WHEN 'v' THEN 'VIEW'
        WHEN 'm' THEN 'MATERIALIZED VIEW'
        ELSE 'TABLE'
      END,
      r.relname,
      '${role}'
    );
  END LOOP;
END
\$aegora_owner\$;
SQL

  log "Propiedad de '${database}' devuelta a '${role}'."
}

restore_database_dump() {
  local source_database="$1"
  local destination_database="$2"
  # Vacío en las bases de prueba: son temporales, las lee el administrador y
  # nadie más se conecta a ellas.
  local role="${3:-}"
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

  apply_database_owner "$destination_database" "$role"

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

# Para lo que puede faltar sin que sea un error: el compose de booking no está
# en el manifiesto de un tenant moderno, y no por ello la restauración falla.
restore_config_file_optional() {
  if [[ ! -f "$1" ]]; then
    log "No está en el snapshot; se omite: $(basename "$(dirname "$1")")/$(basename "$1")"
    return 0
  fi
  restore_config_file "$@"
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

[[ -n "$TENANT" ]] ||
  fail "Falta --tenant. No hay valor por defecto: esto para servicios y
sobrescribe bases de producción, y el tenant se dice a propósito."

# Resuelve TENANT_CONFIG, RESTIC_CONFIG y CONFIG_LAYOUT según dónde viva de
# verdad la configuración del tenant. El contexto expone además TENANT_ROOT,
# pero NO se fija aquí: tenant.env define su propio TENANT_ROOT y hacerlo
# readonly antes de leerlo rompería el `source`.
require_file "$CONTEXT_LIB"
# shellcheck disable=SC1090
source "$CONTEXT_LIB"
resolve_tenant_context
CTX_TENANT_ROOT="$TENANT_ROOT"

readonly TENANT
readonly SNAPSHOT
readonly RESTORE_ROOT
readonly TENANT_CONFIG
readonly RESTIC_CONFIG
readonly CONFIG_LAYOUT
readonly CTX_TENANT_ROOT

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

# Comprobación de identidad ANTES de tocar nada. La librería verifica que el
# TENANT_ID del fichero coincide con el pedido y que el repositorio Restic
# apunta al bucket de ESE tenant -- que es lo que impide restaurar el backup de
# un cliente encima de otro.
validate_loaded_tenant_context

# Los roles de aplicación viven en secrets/postgres.env, no en tenant.env. Este
# script no lo leía, y sin ellos no hay forma de devolver la propiedad de las
# bases restauradas a quien las usa (ver apply_database_owner).
if [[ "$CONFIG_LAYOUT" == "managed" && -n "${TENANT_POSTGRES_SECRETS:-}" &&
      -f "$TENANT_POSTGRES_SECRETS" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$TENANT_POSTGRES_SECRETS"
  set +a
fi

# Por convención de la plataforma el rol se llama igual que su base; si el
# fichero de secretos no estuviera, se cae a esa convención en vez de fallar.
POSTGRES_DIRECTUS_USER="${POSTGRES_DIRECTUS_USER:-$POSTGRES_DIRECTUS_DB}"
POSTGRES_N8N_USER="${POSTGRES_N8N_USER:-$POSTGRES_N8N_DB}"

# Y que el tenant.env cargado describa al tenant que el contexto localizó: si
# no coinciden, la configuración se ha movido y nada de lo que sigue es fiable.
if [[ -n "${TENANT_ROOT:-}" && "$TENANT_ROOT" != "$CTX_TENANT_ROOT" ]]; then
  fail "Incoherencia: tenant.env dice TENANT_ROOT='${TENANT_ROOT}' pero la
configuración se encontró en '${CTX_TENANT_ROOT}'."
fi

: "${ENVIRONMENT:?Falta ENVIRONMENT}"
: "${BACKUP_HOST:?Falta BACKUP_HOST}"
: "${BACKUP_TAG_TENANT:?Falta BACKUP_TAG_TENANT}"

: "${POSTGRES_DIRECTUS_DB:?Falta POSTGRES_DIRECTUS_DB}"
: "${POSTGRES_N8N_DB:?Falta POSTGRES_N8N_DB}"

: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"
: "${N8N_CONTAINER:?Falta N8N_CONTAINER}"
: "${BOOKING_CONTAINER:?Falta BOOKING_CONTAINER}"

: "${DIRECTUS_DATA_DIR:?Falta DIRECTUS_DATA_DIR}"
: "${N8N_DATA_DIR:?Falta N8N_DATA_DIR}"

# Booking V1 usa la base `directus_<tenant>`: create-tenant.sh dejó de crear
# `booking_<tenant>` y su directorio de datos. Los tenants anteriores al cambio
# los conservan. Exigirlos aquí hacía imposible restaurar un tenant moderno --
# el mismo fallo que tenía backup-tenant.sh.
POSTGRES_BOOKING_DB="${POSTGRES_BOOKING_DB:-}"
BOOKING_DATA_DIR="${BOOKING_DATA_DIR:-}"
TIENE_BOOKING_DB=false
if [[ -n "$POSTGRES_BOOKING_DB" ]]; then TIENE_BOOKING_DB=true; fi

: "${RESTIC_REPOSITORY:?Falta RESTIC_REPOSITORY}"
: "${RESTIC_PASSWORD:?Falta RESTIC_PASSWORD}"
: "${AWS_ACCESS_KEY_ID:?Falta AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Falta AWS_SECRET_ACCESS_KEY}"

readonly POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-aegora-postgres}"

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
# Restaurar snapshot en zona aislada
# =============================================================================

log "Restaurando snapshot en zona aislada."

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
  fail "No se encontró ninguna ejecución dentro del snapshot."

RUN_DIR="${staging_parent}/${RUN_ID}"

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
)

if [[ "$TIENE_BOOKING_DB" == true ]]; then
  DATABASES+=("$POSTGRES_BOOKING_DB")
fi

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
# Prueba en bases temporales
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
# Salida segura en modo verificación
# =============================================================================

if [[ "$APPLY_PRODUCTION" != true ]]; then
  log "Modo verificación completado."
  log "No se ha modificado ningún servicio de producción."
  exit 0
fi

if [[
  "$DATABASE_SELECTION" == "none" &&
  "$RESTORE_FILES" == false &&
  "$RESTORE_CONFIG" == false &&
  "$RESTORE_GLOBALS" == false
 ]]; then
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
    RESTORE_BOOKING="$TIENE_BOOKING_DB"
    ;;

  directus)
    RESTORE_DIRECTUS=true
    ;;

  n8n)
    RESTORE_N8N=true
    ;;

  booking)
    [[ "$TIENE_BOOKING_DB" == true ]] ||
      fail "Este tenant no tiene base de booking (Booking V1 usa la de Directus)."
    RESTORE_BOOKING=true
    ;;

  none)
    ;;
esac

if [[ "$RESTORE_FILES" == true ]]; then
  RESTORE_DIRECTUS=true
  RESTORE_N8N=true

  # Sin el chequeo de vacío, "${RESTORE_DIR}${BOOKING_DATA_DIR}" se queda en
  # "${RESTORE_DIR}" -- un directorio que existe -- y activaría booking en un
  # tenant que no lo tiene.
  if [[ -n "$BOOKING_DATA_DIR" && -d "${RESTORE_DIR}${BOOKING_DATA_DIR}" ]]; then
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
# Restaurar configuración
# =============================================================================

if [[ "$RESTORE_CONFIG" == true ]]; then
  log "Restaurando configuración efectiva (layout: ${CONFIG_LAYOUT})."

  # Estos dos son iguales en los dos layouts: el contexto ya resolvió dónde van.
  restore_config_file \
    "${RUN_DIR}/configuration/tenant/tenant.env" \
    "$TENANT_CONFIG" \
    600

  if [[ "$CONFIG_LAYOUT" == "legacy" ]]; then
    warn "Layout legacy: ${RESTIC_CONFIG} es el fichero de credenciales S3
COMPARTIDO del que dependen los tenants gestionados. Se va a sobrescribir."
  fi

  # Opcional a propósito, no por descuido: si no está en el snapshot NO se
  # aborta la restauración. Quien está restaurando ya tiene la contraseña del
  # repositorio -- la ha necesitado para leer este snapshot -- así que perder
  # este fichero es una molestia, no un motivo para dejar el tenant a medias en
  # el peor día del año. Pero se avisa, porque sin él sus backups no corren.
  if [[ -f "${RUN_DIR}/configuration/secrets/restic.env" ]]; then
    restore_config_file \
      "${RUN_DIR}/configuration/secrets/restic.env" \
      "$RESTIC_CONFIG" \
      600
  else
    warn "El snapshot no trae secrets/restic.env. El tenant quedará restaurado
pero SIN configuración de backup: hay que reponer ${RESTIC_CONFIG} a mano
(o volver a ejecutar configure-tenant-backup.sh) o dejará de respaldarse."
  fi

  if [[ "$CONFIG_LAYOUT" == "managed" ]]; then
    # El manifiesto de un tenant gestionado solo lleva SU compose. Postgres y
    # Caddy son de plataforma y no salen en el backup de ningún tenant: si se
    # restauraran desde aquí, un tenant pisaría la configuración de todos.
    : "${TENANT_COMPOSE_ROOT:?Falta TENANT_COMPOSE_ROOT}"

    for servicio in directus n8n; do
      restore_config_file \
        "${RUN_DIR}/configuration/compose/${servicio}/compose.yml" \
        "${TENANT_COMPOSE_ROOT}/${servicio}/compose.yml" \
        644

      restore_config_file \
        "${RUN_DIR}/configuration/compose/${servicio}/.env" \
        "${TENANT_COMPOSE_ROOT}/${servicio}/.env" \
        600
    done

    restore_config_file_optional \
      "${RUN_DIR}/configuration/compose/booking/compose.yml" \
      "${TENANT_COMPOSE_ROOT}/booking/compose.yml" \
      644

    restore_config_file_optional \
      "${RUN_DIR}/configuration/compose/booking/.env" \
      "${TENANT_COMPOSE_ROOT}/booking/.env" \
      600
  else
    # Layout antiguo: el backup incluía toda la plataforma, así que se restaura
    # tal cual se hacía. No queda ningún tenant así, pero un snapshot viejo sí
    # se puede querer recuperar algún día.
    for pieza in \
      "compose/postgres/compose.yml:644" \
      "compose/postgres/.env:600" \
      "compose/directus/compose.yml:644" \
      "compose/directus/.env:600" \
      "compose/n8n/compose.yml:644" \
      "compose/n8n/.env:600" \
      "compose/caddy/compose.yml:644" \
      "compose/caddy/.env:600" \
      "compose/caddy/Caddyfile:644" \
      "compose/booking/compose.yml:644" \
      "compose/booking/.env:600"; do
      ruta="${pieza%:*}"
      modo="${pieza##*:}"
      restore_config_file_optional \
        "${RUN_DIR}/configuration/${ruta}" \
        "${PLATFORM_ROOT}/${ruta}" \
        "$modo"
    done
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
    restore_database_dump "$POSTGRES_DIRECTUS_DB" "$POSTGRES_DIRECTUS_DB" "$POSTGRES_DIRECTUS_USER"
    restore_database_dump "$POSTGRES_N8N_DB" "$POSTGRES_N8N_DB" "$POSTGRES_N8N_USER"
    if [[ "$TIENE_BOOKING_DB" == true ]]; then
      restore_database_dump "$POSTGRES_BOOKING_DB" "$POSTGRES_BOOKING_DB" "${POSTGRES_BOOKING_USER:-$POSTGRES_BOOKING_DB}"
    fi
    ;;

  directus)
    restore_database_dump "$POSTGRES_DIRECTUS_DB" "$POSTGRES_DIRECTUS_DB" "$POSTGRES_DIRECTUS_USER"
    ;;

  n8n)
    restore_database_dump "$POSTGRES_N8N_DB" "$POSTGRES_N8N_DB" "$POSTGRES_N8N_USER"
    ;;

  booking)
    restore_database_dump "$POSTGRES_BOOKING_DB" "$POSTGRES_BOOKING_DB" "${POSTGRES_BOOKING_USER:-$POSTGRES_BOOKING_DB}"
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

  if [[ -n "$BOOKING_DATA_DIR" && -d "${RESTORE_DIR}${BOOKING_DATA_DIR}" ]]; then
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

# Un ensayo de recuperación termina cuando el servicio ATIENDE, no cuando el script
# acaba: aquí se espera a `healthy` de verdad. Antes era un sleep 20 y valía con
# "starting", o sea que un tenant que nunca llegaba a arrancar se daba por restaurado.

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

  esperar_healthy "$container"
done

log "Restauración de producción finalizada correctamente."
log "Directorio de trabajo conservado en: ${RESTORE_DIR}"
