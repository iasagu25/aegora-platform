#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora · captura los workflows de un tenant, en la forma que va a Git
#
# La inversa de render-workflows.sh. Exporta del n8n del tenant, les devuelve el
# nombre que tienen en el repo, y sustituye por tokens todo lo que ata el
# workflow a ese tenant (URLs, id de tenant, sufijos de credencial).
#
# Esta dirección es la mitad barata y es la que impide la regresión: sin ella,
# el próximo export vuelve a meter `<tenant>-directus` en Git y no se nota
# hasta que falla un tenant nuevo. Por eso, si después de normalizar sigue
# apareciendo el id del tenant, el script FALLA y enseña dónde.
#
# NO escribe en el checkout del VPS: el VPS nunca hace push y su repo se resetea
# duro. Escribe a un directorio aparte para traérselo con scp, igual que
# snapshot-schema.sh con el esquema. El diff se revisa en local antes de
# commitear.
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly PLATFORM_ROOT="/opt/aegora/platform"

TENANT=""
OUT=""
ALLOW_RESIDUE=false

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Uso:
  export-workflows.sh --tenant TENANT [--out DIR] [--allow-residue]

Captura los workflows del tenant en la forma del repo (con tokens) y los deja
listos para traérselos con scp y revisar el diff en local.

--allow-residue: seguir aunque quede el id del tenant suelto. Solo si son
                 apariciones legítimas en prosa de un comentario.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant) [[ $# -ge 2 ]] || fail "Falta valor para --tenant."; TENANT="$2"; shift 2 ;;
    --out)    [[ $# -ge 2 ]] || fail "Falta valor para --out.";    OUT="$2";    shift 2 ;;
    --allow-residue) ALLOW_RESIDUE=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Opción desconocida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"
command -v docker >/dev/null 2>&1 || fail "Falta docker."
command -v python3 >/dev/null 2>&1 || fail "Falta python3."

OUT="${OUT:-/tmp/aegora-workflows-export-${TENANT}}"
RAW="${OUT}.raw"

TENANT_CONFIG="${TENANTS_ROOT}/${TENANT}/config/tenant.env"
REPO_WF="${PLATFORM_ROOT}/n8n/workflows"
TOKENS="${PLATFORM_ROOT}/n8n/workflow-tokens.py"

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
[[ -d "$REPO_WF" ]] || fail "No existe ${REPO_WF}"
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

export DIRECTUS_BASE_URL="http://${DIRECTUS_CONTAINER}:8055"
export BOOKING_BASE_URL="http://${BOOKING_CONTAINER}:3000"
export PRIVACY_POLICY_URL="${PRIVACY_POLICY_URL:-https://aegora.es/politica-privacidad}"

[[ "$(docker inspect --format '{{.State.Status}}' "$N8N_CONTAINER" 2>/dev/null)" == "running" ]] ||
  fail "n8n no está running: ${N8N_CONTAINER}"

# Igual que en el import: los flags se comprueban contra el binario, no contra
# lo que decía la documentación.
log "Comprobando los flags de 'n8n export:workflow'…"
EXPORT_HELP="$(docker exec "$N8N_CONTAINER" n8n export:workflow --help 2>&1 || true)"
for flag in --all --separate --output; do
  grep -q -- "$flag" <<<"$EXPORT_HELP" ||
    fail "'n8n export:workflow' no reconoce ${flag} en esta versión. Salida de --help:
${EXPORT_HELP}"
done

log "Exportando desde ${N8N_CONTAINER}…"
docker exec "$N8N_CONTAINER" sh -c \
  'rm -rf /tmp/aegora-export && mkdir -p /tmp/aegora-export &&
   n8n export:workflow --all --separate --pretty --output=/tmp/aegora-export' >/dev/null

rm -rf "$RAW" "$OUT"
mkdir -p "$RAW"
docker cp "${N8N_CONTAINER}:/tmp/aegora-export/." "$RAW/"
docker exec "$N8N_CONTAINER" rm -rf /tmp/aegora-export

# -----------------------------------------------------------------------------
# El export nombra los ficheros por `id`; el repo los nombra por la convención
# NN-CATEGORIA-Nombre.json. El puente es el propio `id`, que va dentro del JSON.
#
# Un id que el repo no conoce NO se inventa un nombre: se lista y lo decide una
# persona. En el n8n de demo conviven workflows de usar y tirar (un `My
# workflow`, un `05` con 0 nodos, un stub de `23`) que nunca deben entrar.
# -----------------------------------------------------------------------------
STAGED="${OUT}.staged"
rm -rf "$STAGED"
mkdir -p "$STAGED"

python3 - "$REPO_WF" "$RAW" "$STAGED" <<'PY'
import json, sys
from pathlib import Path

repo, raw, staged = (Path(p) for p in sys.argv[1:4])

por_id = {}
for f in sorted(repo.glob("*.json")):
    try:
        por_id[json.loads(f.read_text(encoding="utf-8"))["id"]] = f.name
    except (KeyError, json.JSONDecodeError):
        print(f"AVISO: {f.name} no tiene un id legible; se ignora en el mapeo.")

vistos, desconocidos = set(), []
for f in sorted(raw.glob("*.json")):
    data = json.loads(f.read_text(encoding="utf-8"))
    wid = data.get("id")
    nombre = por_id.get(wid)
    if not nombre:
        desconocidos.append((wid, data.get("name", "?"), len(data.get("nodes", []))))
        continue
    (staged / nombre).write_text(f.read_text(encoding="utf-8"), encoding="utf-8")
    vistos.add(wid)

faltan = [(i, n) for i, n in por_id.items() if i not in vistos]

print(f"\nMapeados por id: {len(vistos)}")
if desconocidos:
    print("\nEn el tenant pero NO en el repo (no se capturan; decide si alguno debe entrar,")
    print("y entonces créalo en el repo con el nombre de la convención):")
    for wid, nombre, nodos in desconocidos:
        print(f"    {wid}  {nombre}  ({nodos} nodos)")
if faltan:
    print("\nEn el repo pero NO en el tenant (se quedan como están en Git):")
    for wid, nombre in faltan:
        print(f"    {nombre}  ({wid})")
PY

log "Normalizando a la forma del repo…"
NORM_FLAGS=(--from-export)
[[ "$ALLOW_RESIDUE" == true ]] && NORM_FLAGS+=(--allow-residue)
python3 "$TOKENS" normalize "$STAGED" "$OUT" "${NORM_FLAGS[@]}"

rm -rf "$RAW" "$STAGED"

CAMBIADOS="$(diff -rq "$REPO_WF" "$OUT" 2>/dev/null | grep -c '^Files' || true)"

cat <<DONE

============================================================
EXPORT LISTO
============================================================

Fichero(s):
  ${OUT}   ($(find "$OUT" -name '*.json' | wc -l | tr -d ' ') workflows)

Frente al checkout de este VPS:
  ${CAMBIADOS} workflows con cambios
  (el checkout del VPS puede ir por detrás de tu rama; el diff bueno es el de local)

Siguiente paso, desde tu máquina:
  scp -r ${USER}@<vps>:${OUT}/. n8n/workflows/
  git diff n8n/workflows

Revisa el diff ANTES de commitear: esto arrastra TODO lo que se haya tocado en
el tenant, no solo lo que creías estar capturando.

============================================================

DONE
