#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Configuración base
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly SECRETS_ROOT="/opt/aegora/secrets"
readonly BACKUP_ROOT="/opt/aegora/backups"
readonly STAGING_ROOT="${BACKUP_ROOT}/staging"
readonly LOCK_FILE="/run/lock/aegora-backup.lock"

TENANT="${TENANT:-aegora}"

readonly TENANT_CONFIG="${PLATFORM_ROOT}/customers/${TENANT}/tenant.env"
readonly BACKUP_MANIFEST="${PLATFORM_ROOT}/customers/${TENANT}/backup.manifest.json"
readonly RESTIC_CONFIG="${SECRETS_ROOT}/restic.env"
readonly EXCLUDES_FILE="${PLATFORM_ROOT}/scripts/backup/excludes.txt"

RUN_ID=""
RUN_DIR=""
POSTGRES_DIR=""
CONFIG_DIR=""
MANIFEST_DIR=""

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

cleanup() {
  local exit_code=$?

  trap - EXIT

  if [[ $exit_code -ne 0 ]]; then
    log "El backup terminó con errores."

    if [[ -n "${RUN_DIR:-}" && -d "$RUN_DIR" ]]; then
      warn "El staging se conserva para diagnóstico: ${RUN_DIR}"
    fi
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

require_directory() {
  [[ -d "$1" ]] ||
    fail "Falta el directorio requerido: $1"
}

copy_configuration_file() {
  local source="$1"
  local destination="$2"
  local required="$3"
  local mode="$4"

  if [[ ! -f "$source" ]]; then
    if [[ "$required" == "true" ]]; then
      fail "Falta el fichero requerido por el manifiesto: ${source}"
    fi

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

  log "Configuración incluida: ${source}"
}

validate_manifest() {
  python3 - "$BACKUP_MANIFEST" <<'PY'
import json
import os
import re
import sys

manifest_path = sys.argv[1]

with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

if manifest.get("version") != 1:
    raise SystemExit("ERROR: versión de manifiesto no soportada")

databases = manifest.get("databases")
persistent_paths = manifest.get("persistent_paths")
configuration_files = manifest.get("configuration_files")

if not isinstance(databases, list) or not databases:
    raise SystemExit("ERROR: databases debe ser una lista no vacía")

if not isinstance(persistent_paths, list):
    raise SystemExit("ERROR: persistent_paths debe ser una lista")

if not isinstance(configuration_files, list):
    raise SystemExit("ERROR: configuration_files debe ser una lista")

unresolved_pattern = re.compile(r"\$\{[^}]+\}")

def expand(value: str) -> str:
    expanded = os.path.expandvars(value)

    if unresolved_pattern.search(expanded):
        raise SystemExit(
            f"ERROR: variable sin resolver en el manifiesto: {value}"
        )

    return expanded

expanded_databases = []

for database in databases:
    if not isinstance(database, str) or not database.strip():
        raise SystemExit("ERROR: database inválida")

    expanded_database = expand(database.strip())

    if not re.fullmatch(r"[A-Za-z0-9_]+", expanded_database):
        raise SystemExit(
            f"ERROR: nombre de base no permitido: {expanded_database}"
        )

    expanded_databases.append(expanded_database)

if len(expanded_databases) != len(set(expanded_databases)):
    raise SystemExit("ERROR: hay bases de datos duplicadas")

for entry in persistent_paths:
    if not isinstance(entry, dict):
        raise SystemExit("ERROR: entrada inválida en persistent_paths")

    path = entry.get("path")
    required = entry.get("required")

    if not isinstance(path, str) or not path:
        raise SystemExit("ERROR: persistent path sin path")

    if not isinstance(required, bool):
        raise SystemExit(
            "ERROR: required debe ser booleano en persistent_paths"
        )

    expanded_path = expand(path)

    if not expanded_path.startswith("/"):
        raise SystemExit(
            f"ERROR: persistent path debe ser absoluto: {expanded_path}"
        )

destinations = set()

for entry in configuration_files:
    if not isinstance(entry, dict):
        raise SystemExit("ERROR: entrada inválida en configuration_files")

    source = entry.get("source")
    destination = entry.get("destination")
    required = entry.get("required")
    mode = entry.get("mode")

    if not isinstance(source, str) or not source:
        raise SystemExit("ERROR: configuration file sin source")

    if not isinstance(destination, str) or not destination:
        raise SystemExit("ERROR: configuration file sin destination")

    if not isinstance(required, bool):
        raise SystemExit(
            "ERROR: required debe ser booleano en configuration_files"
        )

    if not isinstance(mode, str) or not re.fullmatch(r"[0-7]{3,4}", mode):
        raise SystemExit(
            f"ERROR: modo inválido para {destination}: {mode}"
        )

    expanded_source = expand(source)
    expanded_destination = expand(destination)

    if not expanded_source.startswith("/"):
        raise SystemExit(
            f"ERROR: source debe ser absoluto: {expanded_source}"
        )

    if expanded_destination.startswith("/"):
        raise SystemExit(
            "ERROR: destination debe ser relativa al staging"
        )

    normalized_destination = os.path.normpath(expanded_destination)

    if normalized_destination.startswith("../") or normalized_destination == "..":
        raise SystemExit(
            f"ERROR: destination sale del staging: {expanded_destination}"
        )

    if normalized_destination in destinations:
        raise SystemExit(
            f"ERROR: destination duplicado: {normalized_destination}"
        )

    destinations.add(normalized_destination)

print("Manifiesto válido")
PY
}

read_databases() {
  python3 - "$BACKUP_MANIFEST" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

for database in manifest["databases"]:
    expanded = os.path.expandvars(database)
    sys.stdout.write(expanded)
    sys.stdout.write("\0")
PY
}

read_persistent_paths() {
  python3 - "$BACKUP_MANIFEST" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

for entry in manifest["persistent_paths"]:
    path = os.path.expandvars(entry["path"])
    required = "true" if entry["required"] else "false"

    sys.stdout.write(path)
    sys.stdout.write("\0")
    sys.stdout.write(required)
    sys.stdout.write("\0")
PY
}

read_configuration_files() {
  python3 - "$BACKUP_MANIFEST" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

for entry in manifest["configuration_files"]:
    source = os.path.expandvars(entry["source"])
    destination = os.path.expandvars(entry["destination"])
    required = "true" if entry["required"] else "false"
    mode = entry["mode"]

    for value in (source, destination, required, mode):
        sys.stdout.write(value)
        sys.stdout.write("\0")
PY
}

# =============================================================================
# Prerrequisitos
# =============================================================================

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
require_file "$BACKUP_MANIFEST"
require_file "$RESTIC_CONFIG"
require_file "$EXCLUDES_FILE"

mkdir -p "$(dirname "$LOCK_FILE")"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  fail "Ya hay otro backup en ejecución."
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
: "${ENVIRONMENT:?Falta ENVIRONMENT}"
: "${BACKUP_HOST:?Falta BACKUP_HOST}"
: "${BACKUP_TAG_TENANT:?Falta BACKUP_TAG_TENANT}"
: "${BACKUP_TAG_ENVIRONMENT:?Falta BACKUP_TAG_ENVIRONMENT}"

: "${RESTIC_REPOSITORY:?Falta RESTIC_REPOSITORY}"
: "${RESTIC_PASSWORD:?Falta RESTIC_PASSWORD}"
: "${AWS_ACCESS_KEY_ID:?Falta AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Falta AWS_SECRET_ACCESS_KEY}"

# Estas rutas se exportan para que os.path.expandvars pueda resolverlas.
export PLATFORM_ROOT
export SECRETS_ROOT
export TENANT_CONFIG
export BACKUP_MANIFEST
export RESTIC_CONFIG

validate_manifest

DATABASES=()

while IFS= read -r -d '' database; do
  DATABASES+=("$database")
done < <(read_databases)

[[ ${#DATABASES[@]} -gt 0 ]] ||
  fail "El manifiesto no contiene bases de datos."

# =============================================================================
# Preparar ejecución
# =============================================================================

readonly POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-aegora-postgres}"

RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')"
RUN_DIR="${STAGING_ROOT}/${TENANT_ID}/${RUN_ID}"
POSTGRES_DIR="${RUN_DIR}/postgres"
CONFIG_DIR="${RUN_DIR}/configuration"
MANIFEST_DIR="${RUN_DIR}/manifests"

readonly RUN_ID
readonly RUN_DIR
readonly POSTGRES_DIR
readonly CONFIG_DIR
readonly MANIFEST_DIR

log "Iniciando backup del tenant '${TENANT_ID}'."
log "Repositorio: ${RESTIC_REPOSITORY}"
log "Manifiesto: ${BACKUP_MANIFEST}"
log "Ejecución: ${RUN_ID}"

# =============================================================================
# Validar PostgreSQL
# =============================================================================

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

if [[
  "$postgres_health" != "not-configured" &&
  "$postgres_health" != "healthy"
 ]]; then
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

# =============================================================================
# Preparar staging
# =============================================================================

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

# Guardar el manifiesto exacto utilizado en el snapshot.
install \
  --mode=644 \
  "$BACKUP_MANIFEST" \
  "${MANIFEST_DIR}/backup.manifest.json"

# =============================================================================
# PostgreSQL: objetos globales
# =============================================================================

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

# =============================================================================
# PostgreSQL: bases declaradas en el manifiesto
# =============================================================================

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

# =============================================================================
# Configuración declarada en el manifiesto
# =============================================================================

log "Copiando configuración declarada en el manifiesto."

while true; do
  IFS= read -r -d '' source || break
  IFS= read -r -d '' relative_destination ||
    fail "Registro incompleto en configuration_files"
  IFS= read -r -d '' required ||
    fail "Registro incompleto en configuration_files"
  IFS= read -r -d '' mode ||
    fail "Registro incompleto en configuration_files"

  copy_configuration_file \
    "$source" \
    "${CONFIG_DIR}/${relative_destination}" \
    "$required" \
    "$mode"
done < <(read_configuration_files)

# =============================================================================
# Manifiesto técnico y hashes
# =============================================================================

log "Creando manifiesto técnico del backup."

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

database_list="$(
  IFS=,
  printf '%s' "${DATABASES[*]}"
)"

cat > "${MANIFEST_DIR}/backup.env" <<EOF
BACKUP_RUN_ID=${RUN_ID}
BACKUP_CREATED_AT=$(date -u --iso-8601=seconds)
BACKUP_MANIFEST_VERSION=1
TENANT_ID=${TENANT_ID}
ENVIRONMENT=${ENVIRONMENT}
BACKUP_HOST=${BACKUP_HOST}
SOURCE_HOSTNAME=${source_hostname}
POSTGRES_CONTAINER=${POSTGRES_CONTAINER}
POSTGRES_ADMIN_USER=${POSTGRES_ADMIN_USER}
POSTGRES_VERSION=${postgres_version}
RESTIC_VERSION=${restic_version}
DATABASES=${database_list}
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

# =============================================================================
# Rutas persistentes declaradas
# =============================================================================

BACKUP_PATHS=(
  "$RUN_DIR"
)

log "Procesando rutas persistentes declaradas en el manifiesto."

while true; do
  IFS= read -r -d '' persistent_path || break
  IFS= read -r -d '' required ||
    fail "Registro incompleto en persistent_paths"

  if [[ -d "$persistent_path" ]]; then
    BACKUP_PATHS+=("$persistent_path")
    log "Incluyendo ruta persistente: ${persistent_path}"
    continue
  fi

  if [[ "$required" == "true" ]]; then
    fail "Falta la ruta persistente requerida: ${persistent_path}"
  fi

  log "Ruta persistente opcional ausente; se omite: ${persistent_path}"
done < <(read_persistent_paths)

# =============================================================================
# Restic
# =============================================================================

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
  --tag "manifest=v1" \
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

# =============================================================================
# Verificación remota
# =============================================================================

log "Verificando contenido obligatorio en el snapshot remoto."

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
expected_manifest="/opt/aegora/backups/staging/${TENANT_ID}/${RUN_ID}/manifests/backup.manifest.json"
expected_hashes="/opt/aegora/backups/staging/${TENANT_ID}/${RUN_ID}/manifests/SHA256SUMS"

for expected_path in \
  "$expected_globals" \
  "$expected_manifest" \
  "$expected_hashes"; do

  if ! grep -Fq "$expected_path" <<< "$snapshot_listing"; then
    fail "El snapshot no contiene el fichero esperado: ${expected_path}"
  fi
done

log "Todos los dumps y manifiestos están presentes en el snapshot."

rm -rf "${STAGING_ROOT:?}/${TENANT_ID:?}"

log "Staging local eliminado."
log "Backup finalizado correctamente."
