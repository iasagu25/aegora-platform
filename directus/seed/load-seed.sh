#!/usr/bin/env bash

set -Eeuo pipefail

# Espera única a los contenedores (ver el fichero): nunca sleep ni un healthy exigido sin esperar.
# shellcheck source=/dev/null
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../scripts/lib/esperar-contenedor.sh"
IFS=$'\n\t'

# =============================================================================
# Aegora · carga un conjunto de datos de demostración en un tenant
#
#   load-seed.sh --tenant TENANT --set gestoria [--apply]
#
# Las referencias entre colecciones van por `_ref` / `@ref` y NO por UUID: los
# identificadores los genera Directus al insertar, así que un seed con UUIDs
# dentro solo valdría para un tenant y una vez.
#
# Idempotente por nombre natural: una segunda pasada no duplica. Lo que ya
# existe se REUTILIZA (se toma su id para resolver las referencias) y no se
# modifica -- si alguien ajustó un horario durante una demo, esto no se lo pisa.
#
# NO borra nada. Reiniciar un tenant de demo ensuciado es otra operación, con
# otros riesgos (las citas de prueba cuelgan de estos servicios), y merece su
# propio comando en vez de una bandera escondida aquí.
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly SEED_DIR="${PLATFORM_ROOT}/directus/seed"

TENANT=""
CONJUNTO=""
APPLY=false

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  load-seed.sh --tenant TENANT --set CONJUNTO [--apply]

Sin --apply:  dice qué crearía y qué ya existe. No toca nada.
Con --apply:  crea lo que falte. Nunca modifica ni borra lo que ya está.

Conjuntos disponibles: los .json de directus/seed/ (p. ej. `gestoria`).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant) [[ $# -ge 2 ]] || fail "Falta valor para --tenant."; TENANT="$2"; shift 2 ;;
    --set)    [[ $# -ge 2 ]] || fail "Falta valor para --set.";    CONJUNTO="$2"; shift 2 ;;
    --apply)  APPLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Opción desconocida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ -n "$CONJUNTO" ]] || fail "Falta --set. Disponibles: $(cd "$SEED_DIR" && ls *.json 2>/dev/null | sed 's/\.json$//' | tr '\n' ' ')"
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"
[[ "$CONJUNTO" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || fail "Conjunto inválido: ${CONJUNTO}"

SEED="${SEED_DIR}/${CONJUNTO}.json"
[[ -f "$SEED" ]] || fail "No existe el conjunto: ${SEED}"

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"
PROVISIONING_SECRET="${TENANT_ROOT}/secrets/directus-provisioning.env"

for f in "$TENANT_CONFIG" "$PROVISIONING_SECRET"; do
  if [[ ! -r "$f" ]]; then
    if [[ $EUID -eq 0 ]]; then
      fail "No existe ${f}"
    fi
    fail "No se puede leer ${f}
O no existe, o es cuestión de permisos (los secretos del tenant son de root).
Prueba con sudo."
  fi
done

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
# shellcheck disable=SC1090
source "$PROVISIONING_SECRET"
set +a

: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"
: "${DIRECTUS_PROVISIONING_TOKEN:?Falta DIRECTUS_PROVISIONING_TOKEN}"

esperar_healthy "$DIRECTUS_CONTAINER"

cat <<PLAN

============================================================
AEGORA · DATOS DE DEMOSTRACIÓN
============================================================

Tenant:
  ${TENANT}   (${DIRECTUS_CONTAINER})

Conjunto:
  ${SEED}

Modo:
  $([[ "$APPLY" == true ]] && printf 'APPLY' || printf 'PLAN')

============================================================

PLAN

docker exec -i \
  -e AEGORA_APPLY="$APPLY" \
  -e DIRECTUS_PROVISIONING_TOKEN="$DIRECTUS_PROVISIONING_TOKEN" \
  -e AEGORA_SEED="$(cat "$SEED")" \
  "$DIRECTUS_CONTAINER" \
  node --input-type=module <<'NODE'
const BASE = 'http://127.0.0.1:8055';
const token = process.env.DIRECTUS_PROVISIONING_TOKEN;
const aplicar = process.env.AEGORA_APPLY === 'true';
const seed = JSON.parse(process.env.AEGORA_SEED);

async function api(method, path, body) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      Accept: 'application/json',
      Authorization: `Bearer ${token}`,
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const texto = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${texto.slice(0, 400)}`);
  return texto ? JSON.parse(texto) : null;
}

// Orden de dependencias: una referencia solo se puede resolver si lo apuntado
// ya está insertado. No se calcula, se declara -- son siete colecciones y un
// grafo aquí sería más difícil de leer que la lista.
const ORDEN = [
  ['locations', ['name']],
  ['employees', ['first_name', 'last_name']],
  ['resources', ['name']],
  ['services', ['name']],
  ['knowledge', ['title']],
  ['availability_rules', ['resource_id', 'day_of_week', 'start_time']],
  ['service_resources', ['service_id', 'resource_id']],
];

const ids = {};           // _ref -> uuid
const resumen = [];

// Sustituye "@ref" por el uuid ya conocido. Un @ref sin resolver es un error
// del seed, no algo que se pueda ignorar: dejaría una fila colgando.
function resolver(fila, coleccion) {
  const salida = {};
  for (const [k, v] of Object.entries(fila)) {
    if (k === '_ref') continue;
    if (typeof v === 'string' && v.startsWith('@')) {
      const destino = ids[v.slice(1)];
      if (!destino) throw new Error(`${coleccion}: referencia sin resolver ${v}`);
      salida[k] = destino;
    } else {
      salida[k] = v;
    }
  }
  return salida;
}

for (const [coleccion, naturales] of ORDEN) {
  const filas = seed[coleccion] || [];
  if (filas.length === 0) continue;

  let creadas = 0, existentes = 0;

  for (const cruda of filas) {
    const fila = resolver(cruda, coleccion);

    // ¿Existe ya? Se busca por su clave natural, no por id.
    const filtro = {};
    for (const campo of naturales) filtro[campo] = { _eq: fila[campo] };
    const params = new URLSearchParams({
      filter: JSON.stringify(filtro),
      fields: 'id',
      limit: '1',
    });
    const encontrado = await api('GET', `/items/${coleccion}?${params}`);
    const ya = (encontrado.data || [])[0];

    if (ya) {
      existentes += 1;
      if (cruda._ref) ids[cruda._ref] = ya.id;
      continue;
    }

    if (!aplicar) {
      creadas += 1;
      // En plan no hay id real; se inventa uno para que las referencias
      // posteriores se puedan resolver y el plan llegue hasta el final.
      if (cruda._ref) ids[cruda._ref] = '00000000-0000-4000-8000-000000000000';
      continue;
    }

    const nuevo = await api('POST', `/items/${coleccion}`, fila);
    creadas += 1;
    if (cruda._ref) ids[cruda._ref] = nuevo.data.id;
  }

  resumen.push(`${coleccion.padEnd(20)} ${String(creadas).padStart(3)} ${aplicar ? 'creadas' : 'por crear'}, ${existentes} ya estaban`);
}

console.log(resumen.join('\n'));
NODE

printf '\n'
if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha creado nada. Añade --apply para cargarlo."
else
  log "Cargado. Comprueba en el panel que los servicios tienen recursos asociados:"
  log "  sin filas en 'Recursos del servicio', /api/availability devuelve vacío y no dice por qué."
fi
