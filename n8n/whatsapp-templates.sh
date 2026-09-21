#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora · plantillas de WhatsApp de un tenant
#
# Crea en el WABA del tenant las plantillas del catálogo de plataforma
# (n8n/whatsapp-templates.json) que todavía no existan, y dice en qué estado
# está cada una.
#
# Dos reglas que no se negocian:
#
#   1. NUNCA edita ni borra una plantilla que ya existe. Editar una aprobada la
#      devuelve a revisión en Meta, así que un script que "sincroniza" puede
#      dejar al tenant sin poder mandar recordatorios durante horas. Si el
#      catálogo y el WABA difieren, se DICE y se decide a mano.
#
#   2. Aprobar tarda. Crear una plantilla no es poder usarla: queda en PENDING
#      y hay que volver a mirar. Por eso este script se ejecuta pronto, aunque
#      lo que las use no esté construido todavía.
#
# Requiere en secrets/whatsapp.env un token con whatsapp_business_management:
# con solo ..._messaging se puede enviar pero no listar ni crear plantillas.
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly CATALOGO="${PLATFORM_ROOT}/n8n/whatsapp-templates.json"
readonly GRAPH="https://graph.facebook.com/v21.0"

TENANT=""
APPLY=false

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  whatsapp-templates.sh --tenant TENANT [--apply]

Sin --apply:  compara el catálogo con el WABA del tenant y enseña el estado.
Con --apply:  crea las que falten. No toca las que ya existen, nunca.

Estados de Meta:
  APPROVED   utilizable
  PENDING    en revisión; suele tardar de minutos a unas horas
  REJECTED   hay que corregirla y volver a enviarla con otro nombre
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant) [[ $# -ge 2 ]] || fail "Falta valor para --tenant."; TENANT="$2"; shift 2 ;;
    --apply)  APPLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Opción desconocida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"
command -v curl >/dev/null 2>&1 || fail "Falta curl."
command -v python3 >/dev/null 2>&1 || fail "Falta python3."
[[ -f "$CATALOGO" ]] || fail "No existe el catálogo: ${CATALOGO}"

SECRETS="${TENANTS_ROOT}/${TENANT}/secrets/whatsapp.env"
if [[ ! -r "$SECRETS" ]]; then
  if [[ $EUID -eq 0 ]]; then
    fail "No existe ${SECRETS}
Este tenant no tiene WhatsApp configurado. Ver n8n/WHATSAPP.md."
  fi
  fail "No se puede leer ${SECRETS}
O no existe, o es cuestión de permisos (los secretos del tenant son de root).
Prueba con sudo."
fi

set -a
# shellcheck disable=SC1090
source "$SECRETS"
set +a

: "${WHATSAPP_TOKEN:?Falta WHATSAPP_TOKEN en whatsapp.env}"
: "${WHATSAPP_WABA_ID:?Falta WHATSAPP_WABA_ID en whatsapp.env}"

# ---------------------------------------------------------------------------
# Qué hay hoy en el WABA. Se pide ANTES de enseñar nada: si el token no tiene
# whatsapp_business_management, Meta responde (#200) y conviene decirlo con esas
# palabras en vez de dejar que el usuario lo descubra en un JSON.
# ---------------------------------------------------------------------------
REMOTO="$(curl -sS --max-time 30 \
  "${GRAPH}/${WHATSAPP_WABA_ID}/message_templates?fields=name,language,status,category&limit=200" \
  -H "Authorization: Bearer ${WHATSAPP_TOKEN}")" ||
  fail "No se pudo consultar Meta."

if printf '%s' "$REMOTO" | grep -q '"error"'; then
  if printf '%s' "$REMOTO" | grep -q '"code":200'; then
    fail "Meta responde 'no tienes permiso' (#200).
Al token le falta whatsapp_business_management: con solo _messaging se puede
enviar pero no listar ni crear plantillas. Ver n8n/WHATSAPP.md."
  fi
  fail "Meta devolvió un error: ${REMOTO}"
fi

INFORME="$(
  AEGORA_REMOTO="$REMOTO" python3 - "$CATALOGO" <<'PY'
import json, os, sys

catalogo = json.load(open(sys.argv[1]))
remoto = json.loads(os.environ["AEGORA_REMOTO"]).get("data", [])
existentes = {(t.get("name"), t.get("language")): t for t in remoto}

faltan, hay = [], []
for p in catalogo["plantillas"]:
    m = p["meta"]
    clave = (m["name"], m["language"])
    if clave in existentes:
        hay.append((m["name"], m["language"], existentes[clave].get("status", "?")))
    else:
        faltan.append(m)

print("###ESTADO")
for nombre, idioma, estado in hay:
    print(f"{nombre}\t{idioma}\t{estado}")
print("###FALTAN")
for m in faltan:
    print(json.dumps(m, ensure_ascii=False))
print("###AJENAS")
nuestras = {(p["meta"]["name"], p["meta"]["language"]) for p in catalogo["plantillas"]}
for t in remoto:
    if (t.get("name"), t.get("language")) not in nuestras:
        print(f"{t.get('name')}\t{t.get('language')}\t{t.get('status','?')}")
PY
)"

seccion() { printf '%s\n' "$INFORME" | sed -n "/^###$1\$/,/^###/p" | grep -v '^###' || true; }

ESTADO="$(seccion ESTADO)"
FALTAN="$(seccion FALTAN)"
AJENAS="$(seccion AJENAS)"

N_FALTAN=0
[[ -n "$FALTAN" ]] && N_FALTAN="$(printf '%s\n' "$FALTAN" | grep -c . || true)"

cat <<PLAN

============================================================
AEGORA · PLANTILLAS DE WHATSAPP
============================================================

Tenant:
  ${TENANT}   (WABA ${WHATSAPP_WABA_ID})

Catálogo:
  ${CATALOGO}

Ya están en el WABA:
$( [[ -n "$ESTADO" ]] && printf '%s\n' "$ESTADO" | sed 's/^/  /' || echo "  (ninguna)" )

Faltan por crear:
$( [[ -n "$FALTAN" ]] && printf '%s\n' "$FALTAN" | python3 -c 'import sys,json
for l in sys.stdin:
    l=l.strip()
    if l: print("  " + json.loads(l)["name"])' || echo "  (ninguna)" )

Del tenant, que no son nuestras (no se tocan):
$( [[ -n "$AJENAS" ]] && printf '%s\n' "$AJENAS" | sed 's/^/  /' || echo "  (ninguna)" )

Modo:
  $([[ "$APPLY" == true ]] && printf 'APPLY' || printf 'PLAN')

============================================================

PLAN

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha creado nada. Añade --apply para enviarlas a revisión."
  exit 0
fi

if [[ "$N_FALTAN" -eq 0 ]]; then
  log "No falta ninguna. Nada que hacer."
  exit 0
fi

CREADAS=0
FALLOS=()
while IFS= read -r definicion; do
  [[ -n "$definicion" ]] || continue
  nombre="$(printf '%s' "$definicion" | python3 -c 'import sys,json; print(json.load(sys.stdin)["name"])')"
  log "Creando ${nombre}…"
  respuesta="$(curl -sS --max-time 30 -X POST \
    "${GRAPH}/${WHATSAPP_WABA_ID}/message_templates" \
    -H "Authorization: Bearer ${WHATSAPP_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$definicion")" || respuesta='{"error":{"message":"la llamada falló"}}'

  if printf '%s' "$respuesta" | grep -q '"error"'; then
    FALLOS+=("${nombre}: ${respuesta}")
  else
    CREADAS=$((CREADAS + 1))
    estado="$(printf '%s' "$respuesta" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo '?')"
    log "  creada, estado ${estado}"
  fi
done <<<"$FALTAN"

log "Creadas: ${CREADAS}"
if [[ ${#FALLOS[@]} -gt 0 ]]; then
  log "ERROR: no se pudieron crear:"
  for x in "${FALLOS[@]}"; do log "    ${x}"; done
  fail "Revísalas en el panel de Meta antes de volver a ejecutar."
fi

cat <<FINAL

Creadas, pero todavía NO se pueden usar: quedan en revisión (PENDING). Vuelve a
ejecutar esto sin --apply dentro de un rato para ver si han pasado a APPROVED.

Una rechazada NO se corrige editándola: Meta conserva el nombre con el rechazo.
Se cambia el texto en el catálogo Y el nombre, y se vuelve a enviar.

FINAL
