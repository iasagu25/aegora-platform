#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora - Activate tenant operations
#
# Responsabilidad:
#   - validar backup multi-tenant;
#   - instalar las unidades systemd template actuales;
#   - ejecutar una validación completa:
#       backup -> prune -> restore-test -> health
#   - habilitar timers únicamente si todo lo anterior es correcto.
#
# Notification Center:
#   las unidades ya pasan TENANT=%i a run-and-notify.sh, por lo que no
#   necesita configuración adicional por tenant para las alertas operativas.
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"

TENANT=""
APPLY=false

TENANT_CONFIG=""
TENANT_RESTIC_CONFIG=""

SERVICES=(
  aegora-backup
  aegora-prune
  aegora-restore-test
  aegora-backup-health
)

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Uso:

  activate-tenant-operations.sh \
    --tenant TENANT \
    [--apply]

Sin --apply:
  valida prerrequisitos y muestra el plan.

Con --apply:
  - instala/actualiza las unidades systemd template;
  - ejecuta backup real;
  - ejecuta prune real;
  - ejecuta restore test real;
  - ejecuta backup health;
  - habilita los cuatro timers solo si todo termina correctamente.

Ejemplo:

  sudo /usr/bin/bash \
    /opt/aegora/platform/provisioning/tenant/activate-tenant-operations.sh \
    --tenant demo \
    --apply
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "Falta el comando requerido: $1"
}

require_file() {
  [[ -f "$1" ]] ||
    fail "Falta el fichero requerido: $1"
}

with_tenant_restic() {
  (
    set -a
    # shellcheck disable=SC1090
    source "$TENANT_RESTIC_CONFIG"
    set +a

    "$@"
  )
}

install_unit_templates() {
  local unit

  for unit in "${SERVICES[@]}"; do
    require_file "${PLATFORM_ROOT}/systemd/${unit}@.service"
    require_file "${PLATFORM_ROOT}/systemd/${unit}@.timer"

    install \
      -m 644 \
      "${PLATFORM_ROOT}/systemd/${unit}@.service" \
      "/etc/systemd/system/${unit}@.service"

    install \
      -m 644 \
      "${PLATFORM_ROOT}/systemd/${unit}@.timer" \
      "/etc/systemd/system/${unit}@.timer"
  done

  systemctl daemon-reload
}

run_unit() {
  local unit="$1"

  log "Ejecutando ${unit}@${TENANT}.service"

  systemctl reset-failed \
    "${unit}@${TENANT}.service" \
    >/dev/null 2>&1 || true

  if ! systemctl start "${unit}@${TENANT}.service"; then
    journalctl \
      -u "${unit}@${TENANT}.service" \
      -n 200 \
      --no-pager \
      >&2 || true

    fail "Ha fallado ${unit}@${TENANT}.service"
  fi

  local result
  local status

  result="$(
    systemctl show \
      "${unit}@${TENANT}.service" \
      -p Result \
      --value
  )"

  status="$(
    systemctl show \
      "${unit}@${TENANT}.service" \
      -p ExecMainStatus \
      --value
  )"

  [[ "$result" == "success" && "$status" == "0" ]] ||
    fail \
      "${unit}@${TENANT}.service terminó con Result=${result}, ExecMainStatus=${status}"

  log "${unit}@${TENANT}.service: OK"
}

enable_timers() {
  local timer_args=()
  local unit

  for unit in "${SERVICES[@]}"; do
    timer_args+=("${unit}@${TENANT}.timer")
  done

  systemctl enable --now "${timer_args[@]}"
}

verify_timers() {
  local unit

  for unit in "${SERVICES[@]}"; do
    local timer="${unit}@${TENANT}.timer"

    [[ "$(systemctl is-enabled "$timer")" == "enabled" ]] ||
      fail "Timer no habilitado: ${timer}"

    [[ "$(systemctl is-active "$timer")" == "active" ]] ||
      fail "Timer no activo: ${timer}"

    log "${timer}: enabled + active"
  done
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

    --apply)
      APPLY=true
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

# =============================================================================
# Preflight
# =============================================================================

[[ -n "$TENANT" ]] || fail "Falta --tenant."

[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] ||
  fail "Tenant inválido: ${TENANT}"

[[ "$TENANT" != "aegora" ]] ||
  fail "El tenant legacy 'aegora' ya tiene su operación configurada."

TENANT_CONFIG="${TENANTS_ROOT}/${TENANT}/config/tenant.env"
TENANT_RESTIC_CONFIG="${TENANTS_ROOT}/${TENANT}/secrets/restic.env"

require_command restic
require_command systemctl
require_command install
require_command journalctl

require_file "$TENANT_CONFIG"
require_file "$TENANT_RESTIC_CONFIG"

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${BACKUP_REPOSITORY_CONFIGURED:?Falta BACKUP_REPOSITORY_CONFIGURED}"

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

[[ "$BACKUP_REPOSITORY_CONFIGURED" == "true" ]] ||
  fail "El backup del tenant todavía no está configurado."

log "Verificando acceso al repositorio Restic."

with_tenant_restic restic snapshots >/dev/null

cat <<EOF

============================================================
AEGORA TENANT OPERATIONS
============================================================

Tenant:
  ${TENANT}

Validación previa:
  Restic: OK

Se ejecutará:
  1. aegora-backup@${TENANT}.service
  2. aegora-prune@${TENANT}.service
  3. aegora-restore-test@${TENANT}.service
  4. aegora-backup-health@${TENANT}.service

Después se habilitarán:
  aegora-backup@${TENANT}.timer
  aegora-prune@${TENANT}.timer
  aegora-restore-test@${TENANT}.timer
  aegora-backup-health@${TENANT}.timer

Notification Center:
  heredado de las unidades template mediante TENANT=%i

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha modificado systemd."
  exit 0
fi

[[ $EUID -eq 0 ]] ||
  fail "--apply debe ejecutarse como root."

# =============================================================================
# Instalar templates actuales
# =============================================================================

log "Instalando/actualizando unidades systemd template."

install_unit_templates

# =============================================================================
# Validación end-to-end
# =============================================================================

run_unit aegora-backup
run_unit aegora-prune
run_unit aegora-restore-test
run_unit aegora-backup-health

# =============================================================================
# Activación
# =============================================================================

log "Las cuatro validaciones han sido correctas."
log "Habilitando timers."

enable_timers
verify_timers

cat <<EOF

============================================================
OPERACIÓN DEL TENANT ACTIVADA
============================================================

Tenant:
  ${TENANT}

Backup:
  validado

Prune:
  validado

Restore test:
  validado

Health:
  validado

Timers:
  enabled + active

Notification Center:
  operativo a través de run-and-notify.sh

Estado:
  OPERATIONS READY

============================================================
EOF
