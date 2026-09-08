#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora · Booking API — credencial técnica por tenant
#
# Responsabilidad:
#   - garantizar un BOOKING_API_TOKEN estable por tenant en
#     <tenant>/secrets/booking.env  (root, mode 600).
#
# Es un secreto compartido que el contenedor del Booking API valida en la
# cabecera Authorization. No se registra en ningún servicio externo, así que
# aquí no hay llamada a API: solo generación y persistencia idempotentes.
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"

TENANT=""
APPLY=false
ROTATE=false

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  provision-booking-access.sh --tenant TENANT [--apply] [--rotate]

Sin --apply:
  muestra el estado (existe / falta) sin escribir nada.

Con --apply:
  crea <tenant>/secrets/booking.env con un BOOKING_API_TOKEN nuevo si no
  existe. Con --rotate además reemplaza el token existente.
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Falta el comando requerido: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      [[ $# -ge 2 ]] || fail "Falta valor para --tenant."
      TENANT="$2"
      shift 2
      ;;
    --apply)
      APPLY=true
      shift
      ;;
    --rotate)
      ROTATE=true
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

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"
[[ "$TENANT" != "aegora" ]] || fail "El tenant heredado 'aegora' está protegido."

require_command openssl

readonly TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
readonly SECRETS_DIR="${TENANT_ROOT}/secrets"
readonly BOOKING_SECRET="${SECRETS_DIR}/booking.env"

[[ -d "$TENANT_ROOT" ]] || fail "No existe el tenant: ${TENANT_ROOT}"

EXISTS=false
if [[ -f "$BOOKING_SECRET" ]] &&
   grep -qE '^BOOKING_API_TOKEN=..' "$BOOKING_SECRET"; then
  EXISTS=true
fi

cat <<EOF

============================================================
AEGORA · BOOKING API TOKEN
============================================================

Tenant:
  ${TENANT}

Secret:
  ${BOOKING_SECRET}

Estado:
  $([[ "$EXISTS" == true ]] && printf 'presente' || printf 'ausente')

Modo:
  $([[ "$APPLY" == true ]] && printf 'APPLY' || printf 'PLAN')$([[ "$ROTATE" == true ]] && printf ' (rotate)')

============================================================

EOF

if [[ "$EXISTS" == true && "$ROTATE" != true ]]; then
  log "El token ya existe. Nada que hacer (usa --rotate para reemplazarlo)."
  exit 0
fi

if [[ "$APPLY" != true ]]; then
  log "PLAN: en APPLY se $([[ "$EXISTS" == true ]] && echo 'rotará' || echo 'creará') el token."
  exit 0
fi

[[ $EUID -eq 0 ]] || fail "--apply debe ejecutarse como root."

install -d -m 700 -o root -g root "$SECRETS_DIR"

TOKEN="$(openssl rand -hex 32)"

umask 077
cat > "$BOOKING_SECRET" <<EOF
BOOKING_API_TOKEN='${TOKEN}'
EOF
chmod 600 "$BOOKING_SECRET"
chown root:root "$BOOKING_SECRET"

# No se imprime el token.
bash -n "$BOOKING_SECRET"

log "BOOKING_API_TOKEN $([[ "$EXISTS" == true ]] && echo rotado || echo creado) en ${BOOKING_SECRET}."
