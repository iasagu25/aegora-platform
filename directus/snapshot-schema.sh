#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora · captura del esquema de Directus, lista para commitear
#
# Sustituye al procedimiento a mano, que tenía dos trampas:
#
#   1. Canalizar la salida del CLI lo TRUNCA en 64 KiB exactos (Node no vacía
#      stdout asíncrono antes de salir). El YAML resultante parsea, pero llega
#      hasta la mitad: 54 campos en vez de 160 y sin `relations`. Aquí se escribe
#      a fichero, que además evita las líneas `INFO:` del CLI.
#
#   2. Los displays que aportan NUESTRAS extensiones hay que dejarlos a null:
#      los gestiona configure-directus-ui.sh, y un tenant nuevo puede no tener
#      la extensión instalada cuando se aplica el esquema. Antes se quitaban a
#      mano en cada captura; ahora la lista se deduce de directus/extensions/,
#      así que añadir una extensión la cubre sola.
#
# El fichero sale limpio y verificado. Llevarlo al repo local con scp y revisar
# el diff antes de commitear: el snapshot arrastra TODO lo que haya cambiado en
# el tenant, no solo lo que creías estar capturando.
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly PLATFORM_ROOT="/opt/aegora/platform"

TENANT=""
OUT="/tmp/base-nuevo.yaml"

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  snapshot-schema.sh --tenant TENANT [--out FICHERO]

Captura el esquema del tenant, quita los displays que aportan las extensiones
de Aegora y verifica que no esté truncado.

Por defecto escribe en /tmp/base-nuevo.yaml.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant) [[ $# -ge 2 ]] || fail "Falta valor para --tenant."; TENANT="$2"; shift 2 ;;
    --out)    [[ $# -ge 2 ]] || fail "Falta valor para --out.";    OUT="$2";    shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Opción desconocida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"
command -v docker >/dev/null 2>&1 || fail "Falta docker."

TENANT_CONFIG="${TENANTS_ROOT}/${TENANT}/config/tenant.env"
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

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
set +a

: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"

[[ "$(docker inspect --format '{{.State.Status}}' "$DIRECTUS_CONTAINER" 2>/dev/null)" == "running" ]] ||
  fail "Directus no está running: ${DIRECTUS_CONTAINER}"

# ---------------------------------------------------------------------------
# Qué displays aporta una extensión nuestra. El id que usa Directus es el
# nombre del paquete sin el prefijo `directus-extension-`, así que basta con
# mirar qué hay en el repo: añadir una extensión queda cubierto sin tocar esto.
# ---------------------------------------------------------------------------
EXT_DIR="${PLATFORM_ROOT}/directus/extensions"
DISPLAYS_PROPIOS=""
if [[ -d "$EXT_DIR" ]]; then
  for d in "$EXT_DIR"/directus-extension-*; do
    [[ -d "$d" ]] || continue
    DISPLAYS_PROPIOS+="$(basename "$d" | sed 's/^directus-extension-//'),"
  done
fi
[[ -n "$DISPLAYS_PROPIOS" ]] || log "AVISO: no se han encontrado extensiones en ${EXT_DIR}."

log "Extensiones detectadas: ${DISPLAYS_PROPIOS:-(ninguna)}"
log "Generando snapshot dentro de ${DIRECTUS_CONTAINER}…"

docker exec "$DIRECTUS_CONTAINER" \
  node /directus/cli.js schema snapshot --yes /tmp/aegora-snapshot.yaml >/dev/null

docker exec -i -e DISPLAYS_PROPIOS="$DISPLAYS_PROPIOS" "$DIRECTUS_CONTAINER" \
  node --input-type=module <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs';

const propios = new Set(
  (process.env.DISPLAYS_PROPIOS || '').split(',').map(s => s.trim()).filter(Boolean)
);

const lineas = readFileSync('/tmp/aegora-snapshot.yaml', 'utf8').split('\n');
const salida = [];
let seccion = null, col = null, fld = null, saltando = false;
const quitados = [];
const conteo = {};

for (const ln of lineas) {
  // Secciones de primer nivel: collections / fields / relations.
  const sec = ln.match(/^(\w+):\s*$/);
  if (sec) { seccion = sec[1]; col = fld = null; }

  const mc = ln.match(/^  - collection: (\S+)$/);
  if (mc) {
    col = mc[1];
    fld = null;
    conteo[seccion] = (conteo[seccion] || 0) + 1;
  } else {
    const mf = ln.match(/^    field: (\S+)$/);
    if (mf) fld = mf[1];
  }

  // Saltar el bloque anidado de un display_options ya anulado.
  if (saltando) {
    if (/^        /.test(ln)) continue;
    saltando = false;
  }

  // Trabajo del texto, no del YAML parseado: así el formato del CLI se conserva
  // intacto y el diff en git sigue siendo legible.
  const md = ln.match(/^      display: (\S+)$/);
  if (md && propios.has(md[1])) {
    salida.push('      display: null');
    quitados.push(`${col}.${fld} (${md[1]})`);
    continue;
  }
  if (quitados.length && /^      display_options:/.test(ln) &&
      quitados[quitados.length - 1].startsWith(`${col}.${fld} `) &&
      ln.trim() !== 'display_options: null') {
    salida.push('      display_options: null');
    saltando = true;
    continue;
  }

  salida.push(ln);
}

writeFileSync('/tmp/aegora-snapshot-limpio.yaml', salida.join('\n'));

console.log('CONTEO ' + JSON.stringify(conteo));
console.log('QUITADOS ' + JSON.stringify(quitados));
NODE

docker cp "${DIRECTUS_CONTAINER}:/tmp/aegora-snapshot-limpio.yaml" "$OUT" >/dev/null

DENTRO="$(docker exec "$DIRECTUS_CONTAINER" wc -l < /tmp/aegora-snapshot-limpio.yaml 2>/dev/null ||
          docker exec "$DIRECTUS_CONTAINER" sh -c 'wc -l < /tmp/aegora-snapshot-limpio.yaml')"
FUERA="$(wc -l < "$OUT")"

DENTRO="$(printf '%s' "$DENTRO" | tr -d ' \r')"
FUERA="$(printf '%s' "$FUERA" | tr -d ' \r')"

[[ "$DENTRO" == "$FUERA" ]] ||
  fail "El fichero se ha truncado al copiarlo: ${DENTRO} líneas dentro, ${FUERA} fuera."

# Un snapshot completo termina cerrando una relación; si acaba a media clave es
# que algo lo cortó (el fallo que tuvimos con la tubería).
tail -n 2 "$OUT" | grep -qE '^\s+\w+:' ||
  fail "El final de ${OUT} no tiene pinta de snapshot completo. Revísalo antes de usarlo."

cat <<EOF

============================================================
SNAPSHOT LISTO
============================================================

Fichero:
  ${OUT}   (${FUERA} líneas, idénticas dentro y fuera del contenedor)

Siguiente paso, desde tu máquina:
  scp ${USER}@<vps>:${OUT} /tmp/base-nuevo.yaml

Y revisar el diff contra directus/schema/base.yaml ANTES de commitear: un
snapshot arrastra todo lo que haya cambiado en el tenant, no solo lo que
creías estar capturando.

============================================================

EOF
