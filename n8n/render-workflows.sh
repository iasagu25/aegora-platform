#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora · lleva los workflows de Git a un tenant
#
# En Git los workflows llevan tokens (__DIRECTUS_BASE_URL__, __TENANT_ID__…).
# Aquí se resuelven contra `tenant.env` y se importan. El porqué de los tokens
# en vez de un nodo `Config` por workflow está en workflow-tokens.py.
#
# De paso sustituye la importación a mano de 41 JSON por la UI de n8n.
#
# Lo que NO hace, y hay que seguir haciendo una vez por tenant:
#   - Crear las credenciales (nunca están en Git): `Directus`, `Booking API`,
#     `WhatsApp`, `OpenAi account`, `Postgres account`. Los nombres ya no llevan
#     el tenant: cada tenant tiene su propia instancia de n8n. n8n las re-mapea
#     por nombre al importar, así que tienen que llamarse exactamente así.
#   - Activar los workflows que lleven webhook.
#
# La dirección inversa (del tenant a Git) es export-workflows.sh.
#
# Idempotente: importar por segunda vez actualiza por `id`, no duplica.
# Sin --apply solo enseña el plan.
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly PLATFORM_ROOT="/opt/aegora/platform"

TENANT=""
APPLY=false
OUT=""

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Uso:
  render-workflows.sh --tenant TENANT [--out DIR] [--apply]

Sin --apply:  renderiza, enseña el plan y deja los ficheros para inspección.
Con --apply:  además los importa en el n8n del tenant.

Por defecto renderiza en /tmp/aegora-workflows-<tenant>.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant) [[ $# -ge 2 ]] || fail "Falta valor para --tenant."; TENANT="$2"; shift 2 ;;
    --out)    [[ $# -ge 2 ]] || fail "Falta valor para --out.";    OUT="$2";    shift 2 ;;
    --apply)  APPLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Opción desconocida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"
command -v docker >/dev/null 2>&1 || fail "Falta docker."
command -v python3 >/dev/null 2>&1 || fail "Falta python3."

OUT="${OUT:-/tmp/aegora-workflows-${TENANT}}"

TENANT_CONFIG="${TENANTS_ROOT}/${TENANT}/config/tenant.env"
SRC="${PLATFORM_ROOT}/n8n/workflows"
TOKENS="${PLATFORM_ROOT}/n8n/workflow-tokens.py"

[[ -f "$TENANT_CONFIG" ]] || fail "No existe ${TENANT_CONFIG}"
[[ -d "$SRC" ]] || fail "No existe ${SRC}"
[[ -f "$TOKENS" ]] || fail "No existe ${TOKENS}"

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"
: "${BOOKING_CONTAINER:?Falta BOOKING_CONTAINER}"
: "${N8N_CONTAINER:?Falta N8N_CONTAINER}"

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

# Los hosts salen del nombre del contenedor, no de una convención repetida aquí:
# si un tenant tiene un contenedor con otro nombre, esto lo sigue.
export DIRECTUS_BASE_URL="http://${DIRECTUS_CONTAINER}:8055"
export BOOKING_BASE_URL="http://${BOOKING_CONTAINER}:3000"
# Editable en tenant.env cuando cada negocio tenga la suya de verdad; hoy el
# enlace es ficticio (ver CLAUDE.md, apartado de verificación de Google).
export PRIVACY_POLICY_URL="${PRIVACY_POLICY_URL:-https://aegora.es/legal/${TENANT_ID}-privacidad}"

TOTAL="$(find "$SRC" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"

cat <<PLAN

============================================================
AEGORA · WORKFLOWS DE n8n -> TENANT
============================================================

Tenant:
  ${TENANT_ID}   (${N8N_CONTAINER})

Workflows:
  ${TOTAL} desde ${SRC}

Tokens que se resuelven:
  __TENANT_ID__           ${TENANT_ID}
  __DIRECTUS_BASE_URL__   ${DIRECTUS_BASE_URL}
  __BOOKING_BASE_URL__    ${BOOKING_BASE_URL}
  __PRIVACY_POLICY_URL__  ${PRIVACY_POLICY_URL}

Salida:
  ${OUT}

Modo:
  $([[ "$APPLY" == true ]] && echo apply || echo plan)

============================================================

PLAN

rm -rf "$OUT"
python3 "$TOKENS" render "$SRC" "$OUT"

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. Los ficheros renderizados están en ${OUT}; no se ha importado nada."
  log "Revisa uno antes de aplicar, p.ej.: grep -n 'http://' ${OUT}/06-CONTACT-Get.json"
  exit 0
fi

[[ "$(docker inspect --format '{{.State.Status}}' "$N8N_CONTAINER" 2>/dev/null)" == "running" ]] ||
  fail "n8n no está running: ${N8N_CONTAINER}"

# Los flags del CLI de n8n cambian entre versiones y la doc heredada ya nos ha
# mentido otras veces: se comprueban contra el binario real antes de usarlos.
log "Comprobando los flags de 'n8n import:workflow' en ${N8N_CONTAINER}…"
IMPORT_HELP="$(docker exec "$N8N_CONTAINER" n8n import:workflow --help 2>&1 || true)"
for flag in --separate --input; do
  grep -q -- "$flag" <<<"$IMPORT_HELP" ||
    fail "'n8n import:workflow' no reconoce ${flag} en esta versión. Salida de --help:
${IMPORT_HELP}"
done

log "Copiando ${TOTAL} workflows a ${N8N_CONTAINER}…"
docker exec "$N8N_CONTAINER" sh -c 'rm -rf /tmp/aegora-import && mkdir -p /tmp/aegora-import'
docker cp "${OUT}/." "${N8N_CONTAINER}:/tmp/aegora-import/"

log "Importando…"
docker exec "$N8N_CONTAINER" n8n import:workflow --separate --input=/tmp/aegora-import
docker exec "$N8N_CONTAINER" rm -rf /tmp/aegora-import

cat <<DONE

============================================================
IMPORTADO
============================================================

Queda por hacer a mano en la UI de ${N8N_CONTAINER}:

  1. Credenciales, si es un tenant nuevo. Con estos nombres exactos:
     Directus · Booking API · WhatsApp · OpenAi account · Postgres account
     (importar NO las crea; n8n las re-mapea por nombre)

  2. Activar los workflows con webhook:
     WEBCHAT · Adapter · WHATSAPP · Adapter

  3. WHATSAPP · Adapter -> nodo Config: los valores de secrets/whatsapp.env
     (siguen sin automatizar).

============================================================

DONE
