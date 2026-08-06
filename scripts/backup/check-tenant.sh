#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly SECRETS_ROOT="/opt/aegora/secrets"

TENANT="${TENANT:-aegora}"
readonly TENANT_CONFIG="${PLATFORM_ROOT}/customers/${TENANT}/tenant.env"
readonly RESTIC_CONFIG="${SECRETS_ROOT}/restic.env"
readonly LOCK_FILE="/run/lock/aegora-backup-check.lock"

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

[[ -f "$TENANT_CONFIG" ]] || {
  echo "ERROR: falta ${TENANT_CONFIG}" >&2
  exit 1
}

[[ -f "$RESTIC_CONFIG" ]] || {
  echo "ERROR: falta ${RESTIC_CONFIG}" >&2
  exit 1
}

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
  echo "ERROR: ya hay una verificación en ejecución." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
# shellcheck disable=SC1090
source "$RESTIC_CONFIG"
set +a

: "${BACKUP_HOST:?Falta BACKUP_HOST}"
: "${BACKUP_TAG_TENANT:?Falta BACKUP_TAG_TENANT}"

log "Listando snapshots del tenant."

restic snapshots \
  --host "$BACKUP_HOST" \
  --tag "$BACKUP_TAG_TENANT"

log "Comprobando estructura e integridad del repositorio."

restic check \
  --read-data-subset=5%

log "Comprobación finalizada correctamente."
