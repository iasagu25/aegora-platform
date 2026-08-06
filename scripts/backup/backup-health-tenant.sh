#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Configuración
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly SECRETS_ROOT="/opt/aegora/secrets"
readonly LOCK_FILE="/run/lock/aegora-backup-health.lock"

TENANT="${TENANT:-aegora}"

# El último snapshot no debe superar esta antigüedad.
MAX_SNAPSHOT_AGE_HOURS="${MAX_SNAPSHOT_AGE_HOURS:-30}"

readonly TENANT_CONFIG="${PLATFORM_ROOT}/customers/${TENANT}/tenant.env"
readonly RESTIC_CONFIG="${SECRETS_ROOT}/restic.env"

ERRORS=()
WARNINGS=()

LATEST_SNAPSHOT_ID=""
LATEST_SNAPSHOT_TIME=""
LATEST_SNAPSHOT_AGE_SECONDS=""

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

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

add_error() {
  ERRORS+=("$1")
}

add_warning() {
  WARNINGS+=("$1")
}

unit_property() {
  local unit="$1"
  local property="$2"

  systemctl show \
    "$unit" \
    --property="$property" \
    --value \
    2>/dev/null || true
}

unit_exists() {
  local unit="$1"

  systemctl cat "$unit" >/dev/null 2>&1
}

check_service_result() {
  local label="$1"
  local unit="$2"
  local required="$3"

  if ! unit_exists "$unit"; then
    if [[ "$required" == "true" ]]; then
      add_error "${label}: unidad no instalada (${unit})"
    else
      add_warning "${label}: unidad no instalada (${unit})"
    fi

    return 0
  fi

  local result
  local active_state
  local invocation_id
  local finished_at

  result="$(unit_property "$unit" Result)"
  active_state="$(unit_property "$unit" ActiveState)"
  invocation_id="$(unit_property "$unit" InvocationID)"
  finished_at="$(unit_property "$unit" ExecMainExitTimestamp)"

  log "${label}:"
  log "  unidad: ${unit}"
  log "  estado: ${active_state:-unknown}"
  log "  resultado: ${result:-unknown}"
  log "  última finalización: ${finished_at:-unknown}"
  log "  invocation ID: ${invocation_id:-unknown}"

  case "$result" in
    success)
      log "  comprobación: OK"
      ;;

    "")
      if [[ "$required" == "true" ]]; then
        add_error "${label}: todavía no existe un resultado de ejecución"
      else
        add_warning "${label}: todavía no existe un resultado de ejecución"
      fi
      ;;

    *)
      add_error "${label}: último resultado '${result}'"
      ;;
  esac
}

cleanup() {
  local exit_code=$?

  trap - EXIT

  if [[ $exit_code -ne 0 ]]; then
    log "La comprobación consolidada terminó con errores."
  fi

  exit "$exit_code"
}

trap cleanup EXIT
trap 'fail "Fallo en la línea ${LINENO}: ${BASH_COMMAND}"' ERR

# =============================================================================
# Prerrequisitos
# =============================================================================

require_command restic
require_command systemctl
require_command python3
require_command flock
require_command date

require_file "$TENANT_CONFIG"
require_file "$RESTIC_CONFIG"

is_positive_integer "$MAX_SNAPSHOT_AGE_HOURS" ||
  fail "MAX_SNAPSHOT_AGE_HOURS debe ser un entero positivo."

mkdir -p "$(dirname "$LOCK_FILE")"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  fail "Ya hay otra comprobación de salud en ejecución."
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

readonly BACKUP_SERVICE="aegora-backup@${TENANT}.service"
readonly PRUNE_SERVICE="aegora-prune@${TENANT}.service"
readonly RESTORE_TEST_SERVICE="aegora-restore-test@${TENANT}.service"

# =============================================================================
# Cabecera
# =============================================================================

log "============================================================"
log "INFORME DE SALUD DE BACKUPS"
log "Tenant: ${TENANT_ID}"
log "Repositorio: ${RESTIC_REPOSITORY}"
log "Host Restic: ${BACKUP_HOST}"
log "Máxima antigüedad permitida: ${MAX_SNAPSHOT_AGE_HOURS} horas"
log "============================================================"

# =============================================================================
# Estado de los servicios
# =============================================================================

check_service_result \
  "Backup diario" \
  "$BACKUP_SERVICE" \
  true

check_service_result \
  "Retención semanal" \
  "$PRUNE_SERVICE" \
  false

check_service_result \
  "Restore test semanal" \
  "$RESTORE_TEST_SERVICE" \
  false

# =============================================================================
# Comprobar último snapshot
# =============================================================================

log "Consultando el último snapshot del tenant."

snapshot_data="$(
  restic snapshots \
    --host "$BACKUP_HOST" \
    --tag "$BACKUP_TAG_TENANT" \
    --json |
  python3 -c '
import datetime
import json
import sys

snapshots = json.load(sys.stdin)

if not snapshots:
    raise SystemExit(1)

snapshots.sort(key=lambda item: item["time"])
snapshot = snapshots[-1]

timestamp = snapshot["time"].replace("Z", "+00:00")
snapshot_time = datetime.datetime.fromisoformat(timestamp)
now = datetime.datetime.now(datetime.timezone.utc)

if snapshot_time.tzinfo is None:
    snapshot_time = snapshot_time.replace(tzinfo=datetime.timezone.utc)

age_seconds = int((now - snapshot_time).total_seconds())

snapshot_id = snapshot.get("short_id") or snapshot["id"][:8]

print(snapshot_id)
print(snapshot["time"])
print(age_seconds)
'
)" || add_error "No se pudo obtener el último snapshot del tenant"

if [[ -n "$snapshot_data" ]]; then
  mapfile -t snapshot_fields <<< "$snapshot_data"

  LATEST_SNAPSHOT_ID="${snapshot_fields[0]:-}"
  LATEST_SNAPSHOT_TIME="${snapshot_fields[1]:-}"
  LATEST_SNAPSHOT_AGE_SECONDS="${snapshot_fields[2]:-}"

  if [[
    -z "$LATEST_SNAPSHOT_ID" ||
    -z "$LATEST_SNAPSHOT_TIME" ||
    ! "$LATEST_SNAPSHOT_AGE_SECONDS" =~ ^[0-9]+$
  ]]; then
    add_error "La información del último snapshot no es válida"
  else
    max_age_seconds=$((MAX_SNAPSHOT_AGE_HOURS * 3600))
    age_hours=$((LATEST_SNAPSHOT_AGE_SECONDS / 3600))
    age_minutes=$(((LATEST_SNAPSHOT_AGE_SECONDS % 3600) / 60))

    log "Último snapshot:"
    log "  ID: ${LATEST_SNAPSHOT_ID}"
    log "  fecha: ${LATEST_SNAPSHOT_TIME}"
    log "  antigüedad: ${age_hours} h ${age_minutes} min"

    if (( LATEST_SNAPSHOT_AGE_SECONDS > max_age_seconds )); then
      add_error \
        "El último snapshot tiene ${age_hours} horas; el máximo permitido es ${MAX_SNAPSHOT_AGE_HOURS}"
    else
      log "  comprobación de antigüedad: OK"
    fi
  fi
fi

# =============================================================================
# Comprobar contenido mínimo del último snapshot
# =============================================================================

if [[ -n "$LATEST_SNAPSHOT_ID" ]]; then
  log "Comprobando contenido mínimo del snapshot ${LATEST_SNAPSHOT_ID}."

  snapshot_listing="$(
    restic ls "$LATEST_SNAPSHOT_ID"
  )"

  REQUIRED_PATTERNS=(
    "/postgres/globals.sql"
    "/manifests/SHA256SUMS"
    "/manifests/backup.env"
    "/manifests/backup.manifest.json"
  )

  for pattern in "${REQUIRED_PATTERNS[@]}"; do
    if grep -Fq "$pattern" <<< "$snapshot_listing"; then
      log "  presente: ${pattern}"
    else
      add_error "El snapshot ${LATEST_SNAPSHOT_ID} no contiene ${pattern}"
    fi
  done

  dump_count="$(
    grep -Ec '/postgres/[^/]+\.dump$' <<< "$snapshot_listing" || true
  )"

  if [[ "$dump_count" =~ ^[0-9]+$ ]] && (( dump_count > 0 )); then
    log "  dumps PostgreSQL encontrados: ${dump_count}"
  else
    add_error "El snapshot ${LATEST_SNAPSHOT_ID} no contiene dumps PostgreSQL"
  fi
fi

# =============================================================================
# Resultado consolidado
# =============================================================================

log "============================================================"
log "RESULTADO CONSOLIDADO"
log "============================================================"

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  log "Avisos: ${#WARNINGS[@]}"

  for message in "${WARNINGS[@]}"; do
    warn "$message"
  done
else
  log "Avisos: 0"
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  log "Errores: ${#ERRORS[@]}"

  for message in "${ERRORS[@]}"; do
    log "ERROR: ${message}" >&2
  done

  log "ESTADO FINAL: FAILED"
  exit 1
fi

log "Errores: 0"
log "ESTADO FINAL: HEALTHY"
log "Backup, retención, restore test y snapshot comprobados correctamente."
