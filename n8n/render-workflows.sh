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
#   - Crear las credenciales (nunca están en Git). Este script las busca por
#     nombre en el n8n del tenant y mete su `id` en los workflows; si falta
#     alguna, se para y te dice cuáles con su nombre y su tipo. Los nombres ya
#     no llevan el tenant: cada uno tiene su propia instancia de n8n.
#     (la publicación sí la hace este script: importar no publica, y en n8n 2.x
#     un sub-workflow sin publicar no se puede llamar).
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
ORDER="${PLATFORM_ROOT}/n8n/workflow-order.py"

# Sin permiso para atravesar el directorio, "no existe" y "no puedo leerlo" son
# indistinguibles desde aquí -- y los secretos del tenant son de root. Así que se
# dicen las dos posibilidades en vez de mandar a buscar un fichero que sí está.
if [[ ! -r "$TENANT_CONFIG" ]]; then
  if [[ $EUID -eq 0 ]]; then
    fail "No existe ${TENANT_CONFIG}"
  fi
  fail "No se puede leer ${TENANT_CONFIG}
O no existe, o es cuestión de permisos (los secretos del tenant son de root).
Prueba con sudo."
fi
[[ -d "$SRC" ]] || fail "No existe ${SRC}"
[[ -f "$TOKENS" ]] || fail "No existe ${TOKENS}"
[[ -f "$ORDER" ]] || fail "No existe ${ORDER}"

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
# La política de Aegora, que hoy vale para todos los tenants. Sigue siendo un
# token y no un literal porque es plausible que un negocio acabe teniendo la
# suya: entonces basta con poner PRIVACY_POLICY_URL en su tenant.env.
export PRIVACY_POLICY_URL="${PRIVACY_POLICY_URL:-https://aegora.es/politica-privacidad}"

# Los secretos de WhatsApp. En Git el adapter lleva REPLACE_*, así que
# importarlo sin esto dejaría el WhatsApp del tenant sin configurar -- antes se
# reescribían a mano en la UI después de cada import.
WHATSAPP_SECRETS="${TENANT_ROOT}/secrets/whatsapp.env"
WHATSAPP_ESTADO="no encontrado -> se importan los REPLACE_* (WhatsApp quedará sin configurar)"
if [[ -r "$WHATSAPP_SECRETS" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$WHATSAPP_SECRETS"
  set +a
  faltan=()
  for v in WHATSAPP_PHONE_NUMBER_ID WHATSAPP_VERIFY_TOKEN WHATSAPP_APP_SECRET; do
    [[ -n "${!v:-}" ]] || faltan+=("$v")
  done
  if [[ ${#faltan[@]} -eq 0 ]]; then
    WHATSAPP_ESTADO="se rellenan desde ${WHATSAPP_SECRETS}"
  else
    WHATSAPP_ESTADO="incompleto en ${WHATSAPP_SECRETS}: faltan ${faltan[*]}"
  fi
elif [[ -e "$WHATSAPP_SECRETS" ]]; then
  WHATSAPP_ESTADO="sin permiso para leer ${WHATSAPP_SECRETS} (¿sudo?)"
fi

# Los `id` de credencial del tenant. n8n resuelve las credenciales por id y NO
# por nombre (el README heredado decía lo contrario y es falso: falla con
# "Credential with ID ... does not exist" aunque exista una con ese nombre), así
# que el id tiene que ser el bueno de ESTE n8n. Se lee de su propio export, del
# que solo se sacan id y nombre -- el blob cifrado no sale del contenedor.
AEGORA_CREDENTIALS='{}'
CREDS_ESTADO="n8n no consultado (solo en --apply se necesita)"
if [[ "$(docker inspect --format '{{.State.Status}}' "$N8N_CONTAINER" 2>/dev/null)" == "running" ]]; then
  if AEGORA_CREDENTIALS="$(
      docker exec "$N8N_CONTAINER" sh -c '
        rm -f /tmp/aegora-creds.json
        n8n export:credentials --all --output=/tmp/aegora-creds.json >/dev/null 2>&1 || exit 1
        node -e "
          const c = require(\"/tmp/aegora-creds.json\");
          const m = {};
          for (const x of c) m[x.name] = x.id;
          console.log(JSON.stringify(m));
        "
        rm -f /tmp/aegora-creds.json
      ' 2>/dev/null)"; then
    CREDS_ESTADO="$(printf '%s' "$AEGORA_CREDENTIALS" | python3 -c \
      'import json,sys; d=json.load(sys.stdin); print(", ".join(sorted(d)) or "(ninguna)")')"
  else
    AEGORA_CREDENTIALS='{}'
    CREDS_ESTADO="ERROR: no se pudieron leer de ${N8N_CONTAINER}"
  fi
fi
export AEGORA_CREDENTIALS

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

Credenciales en su n8n:
  ${CREDS_ESTADO}

Secretos de WhatsApp:
  ${WHATSAPP_ESTADO}

Publicación:
  se publican todos tras importar, en orden de dependencias (n8n no publica
  un workflow cuyos sub-workflows no lo estén), menos: SESSION · Cleanup
  Después se REINICIA ${N8N_CONTAINER}: el CLI no afecta al proceso en marcha.

Salida:
  ${OUT}   (modo 700: puede contener secretos)

Modo:
  $([[ "$APPLY" == true ]] && echo apply || echo plan)

============================================================

PLAN

rm -rf "$OUT"
mkdir -p "$OUT"
# Lo renderizado lleva los secretos de WhatsApp en claro: no es un /tmp público.
chmod 700 "$OUT"
python3 "$TOKENS" render "$SRC" "$OUT"

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. Los ficheros renderizados están en ${OUT}; no se ha importado nada."
  log "Revisa uno antes de aplicar, p.ej.: grep -n 'http://' ${OUT}/06-CONTACT-Get.json"
  exit 0
fi

[[ "$(docker inspect --format '{{.State.Status}}' "$N8N_CONTAINER" 2>/dev/null)" == "running" ]] ||
  fail "n8n no está running: ${N8N_CONTAINER}"

# Si no se pudieron leer, el render fallaría diciendo que faltan las cinco
# credenciales -- que es falso y manda a crear duplicados. Mejor parar aquí.
[[ "$CREDS_ESTADO" != ERROR:* ]] ||
  fail "No se pudieron leer las credenciales de ${N8N_CONTAINER}.
Sin sus 'id' los workflows quedarían apuntando a credenciales inexistentes.
Comprueba: docker exec ${N8N_CONTAINER} n8n export:credentials --all --output=/tmp/c.json"

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

# -----------------------------------------------------------------------------
# Publicar. En n8n 2.x importar NO publica, y un workflow sin publicar no se
# ejecuta ni registra su webhook ("Workflow is not active and cannot be
# executed") -- así que esto no es cosmética: sin ello Lucía se queda sin
# herramientas y WhatsApp deja de entrar.
#
# Dos detalles que costaron un rato:
#   - `publish:workflow --all` está deprecado ("no longer supported"), así que
#     va uno a uno por --id. (`update:workflow --active=true` es ya solo un
#     alias de publish; también deprecado.)
#   - **El orden importa**: n8n no publica un workflow cuyos sub-workflows no lo
#     estén. Por nombre de fichero sale mal (`AGENT-Lucia-Core-v2` va antes que
#     `LUCIA-TOOL-*` y depende de las siete), así que el orden lo calcula
#     workflow-order.py con el grafo real de llamadas.
#
# Menos los de NO_PUBLICAR: SESSION · Cleanup tiene un trigger de schedule que
# borra sesiones y nunca se ha probado.
# -----------------------------------------------------------------------------
NO_PUBLICAR=(aegoraSessionCleanup)

mapfile -t IDS < <(python3 "$ORDER" "$OUT")
[[ ${#IDS[@]} -gt 0 ]] || fail "No se pudo calcular el orden de publicación."

log "Publicando ${#IDS[@]} workflows en orden de dependencias…"
PUBLICADOS=0
SALTADOS=()
FALLIDOS=()
for fila in "${IDS[@]}"; do
  wid="${fila%%$'\t'*}"
  wname="${fila#*$'\t'}"
  saltar=false
  for excluido in "${NO_PUBLICAR[@]}"; do
    if [[ "$wid" == "$excluido" ]]; then
      saltar=true
    fi
  done
  if [[ "$saltar" == true ]]; then
    SALTADOS+=("$wname")
    continue
  fi
  # La salida se guarda, no se tira: la primera versión de esto la mandaba a
  # /dev/null y escondió justo el aviso que hacía falta leer.
  if salida="$(docker exec "$N8N_CONTAINER" n8n publish:workflow --id="$wid" 2>&1)"; then
    PUBLICADOS=$((PUBLICADOS + 1))
  else
    FALLIDOS+=("${wname} (${wid}): ${salida}")
  fi
done

log "Publicados: ${PUBLICADOS}"
if [[ ${#SALTADOS[@]} -gt 0 ]]; then
  log "Sin publicar a propósito: ${SALTADOS[*]}"
fi
if [[ ${#FALLIDOS[@]} -gt 0 ]]; then
  log "ERROR: no se pudieron publicar:"
  for x in "${FALLIDOS[@]}"; do log "    ${x}"; done
  fail "Quedan workflows sin publicar. Uno sin publicar no se ejecuta ni registra su webhook."
fi

# -----------------------------------------------------------------------------
# Reiniciar. El CLI escribe en la base de datos, pero el proceso en marcha no se
# entera: lo dice él mismo ("Changes will not take effect if n8n is running").
# Sin esto el import parece correcto y el webhook sigue devolviendo 404.
# -----------------------------------------------------------------------------
log "Reiniciando ${N8N_CONTAINER} (el CLI no afecta al proceso en marcha)…"
docker restart "$N8N_CONTAINER" >/dev/null

log "Esperando a que n8n responda…"
LISTO=false
for _ in $(seq 1 45); do
  if docker exec "$N8N_CONTAINER" node -e \
      "fetch('http://127.0.0.1:5678/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" \
      >/dev/null 2>&1; then
    LISTO=true
    break
  fi
  sleep 2
done

if [[ "$LISTO" == true ]]; then
  log "n8n responde."
else
  log "AVISO: n8n no respondía a /healthz tras 90s. Revisa: docker logs --tail 50 ${N8N_CONTAINER}"
fi

cat <<DONE

============================================================
IMPORTADO
============================================================

Comprueba que el webhook quedó registrado (404 = no):

  docker exec ${N8N_CONTAINER} node -e "fetch('http://127.0.0.1:5678/webhook/whatsapp',\\
    {method:'POST',headers:{'content-type':'application/json'},body:'{}'})\\
    .then(r=>console.log('status',r.status))"

Y borra ${OUT} cuando termines: lleva los secretos de WhatsApp en claro.

============================================================

DONE
