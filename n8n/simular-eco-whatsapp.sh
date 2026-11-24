#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora · simula un eco de WhatsApp (coexistencia) contra el webhook de un tenant
#
# Con coexistencia, lo que alguien del negocio escribe desde la app de WhatsApp
# Business del móvil le llega a la API como un eco (`smb_message_echoes`), y
# `WHATSAPP · Eco del móvil` calla a Lucía en ese hilo unos minutos.
#
# Para qué existe: el número de pruebas de Meta que usa `dev` no tiene app en
# ningún móvil, así que en `dev` nunca llegará un eco de verdad. Este script
# construye uno con la forma documentada por Meta, lo FIRMA con el App Secret del
# tenant (como hace Meta) y lo manda al webhook público. Así se prueba el camino
# entero -- firma, clasificación, silencio, bandeja y memoria -- sin móvil.
#
# Sin --apply solo enseña lo que mandaría (sin secretos).
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"

TENANT=""
TELEFONO=""
TEXTO=""
APPLY=false

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  simular-eco-whatsapp.sh --tenant TENANT --telefono 346XXXXXXXX --texto "..." [--apply]

  --telefono   El CLIENTE, en E.164 sin '+' (como lo manda Meta en `to`).
  --texto      Lo que "escribió" el negocio desde el móvil.

Sin --apply:  enseña URL y cuerpo, no envía nada.
Con --apply:  lo firma con WHATSAPP_APP_SECRET y lo manda al webhook del tenant.

Después, en el n8n del tenant: una ejecución de `WHATSAPP · Eco del móvil` con
`silencio_hasta`, y en Directus el mensaje en la bandeja de ese hilo. Si el
cliente escribe antes de esa hora, Lucía no contesta.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)   [[ $# -ge 2 ]] || fail "Falta valor para --tenant.";   TENANT="$2";   shift 2 ;;
    --telefono) [[ $# -ge 2 ]] || fail "Falta valor para --telefono."; TELEFONO="$2"; shift 2 ;;
    --texto)    [[ $# -ge 2 ]] || fail "Falta valor para --texto.";    TEXTO="$2";    shift 2 ;;
    --apply)    APPLY=true; shift ;;
    --help|-h)  usage; exit 0 ;;
    *) fail "Opción desconocida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"
TELEFONO="${TELEFONO#+}"
[[ "$TELEFONO" =~ ^[0-9]{8,15}$ ]] || fail "--telefono tiene que ser E.164 sin '+', p.ej. 34611222333."
[[ -n "$TEXTO" ]] || fail "Falta --texto."
command -v curl >/dev/null 2>&1 || fail "Falta curl."
command -v openssl >/dev/null 2>&1 || fail "Falta openssl."
command -v python3 >/dev/null 2>&1 || fail "Falta python3."

TENANT_ENV="${TENANTS_ROOT}/${TENANT}/config/tenant.env"
SECRETS="${TENANTS_ROOT}/${TENANT}/secrets/whatsapp.env"
[[ -r "$TENANT_ENV" ]] || fail "No se puede leer ${TENANT_ENV} (¿sudo?)."
[[ -r "$SECRETS" ]] || fail "No se puede leer ${SECRETS}: o no existe o falta sudo."

WEBHOOK_HOST="$(grep -E '^WEBHOOK_HOST=' "$TENANT_ENV" | tail -1 | cut -d= -f2- | tr -d '"'"'")"
[[ -n "$WEBHOOK_HOST" ]] || fail "Falta WEBHOOK_HOST en ${TENANT_ENV}."

set -a
# shellcheck disable=SC1090
source "$SECRETS"
set +a
: "${WHATSAPP_PHONE_NUMBER_ID:?Falta WHATSAPP_PHONE_NUMBER_ID en whatsapp.env}"
: "${WHATSAPP_APP_SECRET:?Falta WHATSAPP_APP_SECRET en whatsapp.env}"

URL="https://${WEBHOOK_HOST}/webhook/whatsapp"

# El cuerpo, con la forma de la referencia de Meta para `smb_message_echoes`. El
# `from` es el número del negocio; aquí no importa (el adapter no lo mira) y se
# deja un marcador. Se firma ESTE texto exacto: re-serializarlo rompería la firma.
CUERPO="$(TELEFONO="$TELEFONO" TEXTO="$TEXTO" PNID="$WHATSAPP_PHONE_NUMBER_ID" python3 -c '
import json, os, time, uuid
print(json.dumps({
  "object": "whatsapp_business_account",
  "entry": [{"id": "simulado", "changes": [{"field": "smb_message_echoes", "value": {
    "messaging_product": "whatsapp",
    "metadata": {"display_phone_number": "simulado", "phone_number_id": os.environ["PNID"]},
    "message_echoes": [{
      "from": "simulado", "to": os.environ["TELEFONO"],
      "id": "wamid.SIMULADO." + uuid.uuid4().hex,
      "timestamp": str(int(time.time())), "type": "text",
      "text": {"body": os.environ["TEXTO"]}}]}}]}]}, ensure_ascii=False, separators=(",", ":")))
')"

log "Destino: ${URL}"
log "Cuerpo:  ${CUERPO//${WHATSAPP_PHONE_NUMBER_ID}/<phone_number_id del tenant>}"

if [[ "$APPLY" != true ]]; then
  log "PLAN: no se ha enviado nada. Repite con --apply."
  exit 0
fi

FIRMA="$(printf '%s' "$CUERPO" | openssl dgst -sha256 -hmac "$WHATSAPP_APP_SECRET" -hex | sed 's/^.*= //')"
CODIGO="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X POST "$URL" \
  -H 'Content-Type: application/json' \
  -H "X-Hub-Signature-256: sha256=${FIRMA}" \
  --data-binary "$CUERPO")" || fail "No se pudo llegar a ${URL}."

log "Respuesta del webhook: HTTP ${CODIGO}"
[[ "$CODIGO" == "200" ]] || fail "El webhook no contestó 200."
log "Mira en n8n la ejecución de 'WHATSAPP · Eco del móvil' (su salida dice silencio_hasta)."
