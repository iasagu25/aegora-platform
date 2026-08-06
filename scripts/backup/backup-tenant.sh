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
  [[ -f "$1" ]] || fail "Falta el fichero requerido: $1"
}

require_directory() {
  [[ -d "$1" ]] || fail "Falta el directorio requerido: $1"
}

require_command docker
require_command restic
require_command flock
require_command sha256sum
require_command hostname

require_file "$TENANT_CONFIG"
require_file "$RESTIC_CONFIG"
require_file "$EXCLUDES_FILE"

# Evita dos backups simultáneos.
exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  fail "Ya hay otro backup en ejecución."
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
: "${BACKUP_TAG_ENVIRONMENT:?Falta BACKUP_TAG_ENVIRONMENT}"
: "${POSTGRES_DIRECTUS_DB:?Falta POSTGRES_DIRECTUS_DB}"
: "${POSTGRES_N8N_DB:?Falta POSTGRES_N8N_DB}"
: "${POSTGRES_BOOKING_DB:?Falta POSTGRES_BOOKING_DB}"
: "${RESTIC_REPOSITORY:?Falta RESTIC_REPOSITORY}"
: "${RESTIC_PASSWORD:?Falta RESTIC_PASSWORD}"

readonly RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')"
readonly RUN_DIR="${STAGING_ROOT}/${TENANT_ID}/${RUN_ID}"
readonly POSTGRES_DIR="${RUN_DIR}/postgres"
readonly MANIFEST_DIR="${RUN_DIR}/manifests"

readonly POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-aegora-postgres}"

POSTGRES_ADMIN_USER="$(
  docker exec "$POSTGRES_CONTAINER" printenv POSTGRES_USER
)"

[[ -n "$POSTGRES_ADMIN_USER" ]] ||
  fail "No se pudo obtener POSTGRES_USER del contenedor."

DATABASES=(
  "$POSTGRES_DIRECTUS_DB"
  "$POSTGRES_N8N_DB"
  "$POSTGRES_BOOKING_DB"
)

log "Iniciando backup del tenant '${TENANT_ID}'."
log "Repositorio: ${RESTIC_REPOSITORY}"
log "Ejecución: ${RUN_ID}"

docker inspect "$POSTGRES_CONTAINER" >/dev/null 2>&1 ||
  fail "No existe el contenedor ${POSTGRES_CONTAINER}"

postgres_health="$(
  docker inspect \
    --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    "$POSTGRES_CONTAINER"
)"

[[ "$postgres_health" == "healthy" || "$postgres_health" == "running" ]] ||
  fail "PostgreSQL no está disponible: ${postgres_health}"

rm -rf "${STAGING_ROOT:?}/${TENANT_ID:?}"
mkdir -p "$POSTGRES_DIR" "$MANIFEST_DIR"
chmod 700 "$RUN_DIR" "$POSTGRES_DIR" "$MANIFEST_DIR"

log "Exportando roles y objetos globales de PostgreSQL."

if ! docker exec "$POSTGRES_CONTAINER" \
  pg_dumpall \
    --username="$POSTGRES_ADMIN_USER" \
    --globals-only \
  > "${POSTGRES_DIR}/globals.sql" \
  2> "${POSTGRES_DIR}/globals.stderr"; then

  cat "${POSTGRES_DIR}/globals.stderr" >&2
  fail "No se pudieron exportar los objetos globales."
fi

rm -f "${POSTGRES_DIR}/globals.stderr"

if ! docker exec "$POSTGRES_CONTAINER" \
  pg_dump \
	    --username="$POSTGRES_ADMIN_USER" \
	    --dbname="$database" \
	    --format=custom \
	    --compress=6 \
	    --no-owner \
	    --file=- \
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

  docker exec -i "$POSTGRES_CONTAINER" \
    pg_restore \
      --list \
    < "$destination" \
    > /dev/null
done

log "Creando manifiesto."

cat > "${MANIFEST_DIR}/backup.env" <<EOF
BACKUP_RUN_ID=${RUN_ID}
BACKUP_CREATED_AT=$(date -u --iso-8601=seconds)
TENANT_ID=${TENANT_ID}
ENVIRONMENT=${ENVIRONMENT}
BACKUP_HOST=${BACKUP_HOST}
SOURCE_HOSTNAME=$(hostname --fqdn 2>/dev/null || hostname)
POSTGRES_CONTAINER=${POSTGRES_CONTAINER}
POSTGRES_VERSION=$(docker exec "$POSTGRES_CONTAINER" postgres --version)
RESTIC_VERSION=$(restic version | head -n 1)
EOF

(
  cd "$RUN_DIR"
  find . -type f -print0 |
    sort -z |
    xargs -0 sha256sum
) > "${MANIFEST_DIR}/SHA256SUMS"

BACKUP_PATHS=(
  "$RUN_DIR"
  "$PLATFORM_ROOT"
  "$SECRETS_ROOT"
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
  else
    log "Ruta opcional ausente, se omite: ${path}"
  fi
done

log "Verificando acceso al repositorio Restic."

restic snapshots \
  --host "$BACKUP_HOST" \
  --tag "$BACKUP_TAG_TENANT" \
  >/dev/null

log "Enviando backup cifrado a Object Storage."

restic backup \
  "${BACKUP_PATHS[@]}" \
  --host "$BACKUP_HOST" \
  --tag "$BACKUP_TAG_TENANT" \
  --tag "$BACKUP_TAG_ENVIRONMENT" \
  --tag "type=full" \
  --tag "run=${RUN_ID}" \
  --exclude-file="$EXCLUDES_FILE" \
  --one-file-system=false \
  --verbose

log "Comprobando que el snapshot se ha creado."

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

print(snapshots[-1]["short_id"])
'
)"

[[ -n "$snapshot_id" ]] ||
  fail "No se pudo localizar el snapshot recién creado."

log "Snapshot creado correctamente: ${snapshot_id}"

# Solo se elimina el staging si Restic ha terminado bien.
rm -rf "${STAGING_ROOT:?}/${TENANT_ID:?}"

log "Backup finalizado correctamente."
