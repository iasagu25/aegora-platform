#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Configuración
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly SECRETS_ROOT="/opt/aegora/secrets"
readonly CONTEXT_LIB="${PLATFORM_ROOT}/scripts/backup/tenant-context.sh"

TENANT="${TENANT:-aegora}"
DRY_RUN="${DRY_RUN:-false}"
LOCK_FILE="/run/lock/aegora-backup-prune-${TENANT}.lock"

TENANT_ROOT=""
TENANT_CONFIG=""
RESTIC_CONFIG=""
BACKUP_MANIFEST=""
TENANT_POSTGRES_SECRETS=""
CONFIG_LAYOUT=""

# Política de retención.
KEEP_DAILY="${KEEP_DAILY:-14}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"
KEEP_YEARLY="${KEEP_YEARLY:-3}"

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
    log "La operación de retención terminó con errores."
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

is_non_negative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# =============================================================================
# Prerrequisitos
# =============================================================================

require_command restic
require_command flock

require_file "$CONTEXT_LIB"
# shellcheck disable=SC1090
source "$CONTEXT_LIB"

resolve_tenant_context

require_file "$TENANT_CONFIG"
require_file "$RESTIC_CONFIG"

for value in \
  "$KEEP_DAILY" \
  "$KEEP_WEEKLY" \
  "$KEEP_MONTHLY" \
  "$KEEP_YEARLY"; do

  is_non_negative_integer "$value" ||
    fail "Los valores de retención deben ser enteros no negativos."
done

case "$DRY_RUN" in
  true|false)
    ;;
  *)
    fail "DRY_RUN debe ser true o false."
    ;;
esac

mkdir -p "$(dirname "$LOCK_FILE")"

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  fail "Ya hay otra operación de retención para '${TENANT}' en ejecución."
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

# =============================================================================
# Estado previo
# =============================================================================

log "Aplicando política de retención del tenant '${TENANT_ID}'."
log "Repositorio: ${RESTIC_REPOSITORY}"
log "Host Restic: ${BACKUP_HOST}"
log "Etiqueta: ${BACKUP_TAG_TENANT}"
log "Retención: ${KEEP_DAILY} diarios, ${KEEP_WEEKLY} semanales, ${KEEP_MONTHLY} mensuales y ${KEEP_YEARLY} anuales."

log "Snapshots actuales del tenant:"

restic snapshots \
  --host "$BACKUP_HOST" \
  --tag "$BACKUP_TAG_TENANT"

# =============================================================================
# Retención
# =============================================================================

FORGET_ARGS=(
  forget
  --host "$BACKUP_HOST"
  --tag "$BACKUP_TAG_TENANT"
  --group-by host,tags
  --keep-daily "$KEEP_DAILY"
  --keep-weekly "$KEEP_WEEKLY"
  --keep-monthly "$KEEP_MONTHLY"
  --keep-yearly "$KEEP_YEARLY"
  --prune
  --verbose
)

if [[ "$DRY_RUN" == "true" ]]; then
  warn "Modo simulación: no se eliminará ningún snapshot ni bloque."
  FORGET_ARGS+=(--dry-run)
fi

restic "${FORGET_ARGS[@]}"

# =============================================================================
# Verificación posterior
# =============================================================================

if [[ "$DRY_RUN" == "false" ]]; then
  log "Comprobando la estructura del repositorio tras la poda."

  restic check

  log "Retención y poda completadas correctamente."
else
  log "Simulación de retención completada correctamente."
fi
