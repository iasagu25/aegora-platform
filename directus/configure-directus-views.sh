#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora · navegación de Directus (orden del menú y qué se ve en él)
#
# Sin esto Directus ordena las colecciones alfabéticamente, que mezcla el
# trabajo diario con la configuración: "Appointment Resources" y "Availability
# Rules" acaban por encima de "Citas".
#
# Dos mecanismos, los dos en directus_collections.meta:
#   - sort:   orden en el menú. Primero el día a día, luego la configuración.
#   - hidden: fuera del menú PARA TODOS, incluido el admin. Es lo correcto para
#             las tablas puente: se editan desde su colección padre, nunca
#             navegando a ellas. Siguen accesibles por URL y por el modelo de
#             datos, así que no se pierde nada.
#
# Esto es esquema: después de aplicarlo hay que capturarlo en base.yaml
# (schema snapshot) o se pierde en el próximo tenant.
#
# La VISTA por defecto de cada colección (calendario en citas, Aegora Tasks en
# tareas) NO se configura aquí: eso es un preset y no es esquema.
#
# Idempotente. Sin --apply solo enseña el plan.
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"

TENANT=""
APPLY=false

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  configure-directus-views.sh --tenant TENANT [--apply]

Sin --apply:  muestra el plan.
Con --apply:  ordena el menú y oculta las tablas puente.
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
command -v docker >/dev/null 2>&1 || fail "Falta docker."

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"
PROVISIONING_SECRET="${TENANT_ROOT}/secrets/directus-provisioning.env"

[[ -f "$TENANT_CONFIG" ]] || fail "No existe ${TENANT_CONFIG}"
[[ -f "$PROVISIONING_SECRET" ]] ||
  fail "Falta la credencial técnica: ${PROVISIONING_SECRET}
Créala con: directus/provision-directus-access.sh --tenant ${TENANT} --apply"

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
# shellcheck disable=SC1090
source "$PROVISIONING_SECRET"
set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"
: "${DIRECTUS_PROVISIONING_TOKEN:?Falta DIRECTUS_PROVISIONING_TOKEN}"

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

[[ "$(docker inspect --format '{{.State.Status}}' "$DIRECTUS_CONTAINER" 2>/dev/null)" == "running" ]] ||
  fail "Directus no está running: ${DIRECTUS_CONTAINER}"

cat <<EOF

============================================================
AEGORA · NAVEGACIÓN DE DIRECTUS
============================================================

Tenant:
  ${TENANT_ID}

Orden del menú:
   1  Citas                    (appointments)
   2  Tareas                   (tasks)
   3  Contactos                (contacts)
   4  Knowledge                (knowledge)
  ---- configuración, al fondo ----
  10  Servicios                (services)
  11  Empleados                (employees)
  12  Recursos                 (resources)
  13  Ubicaciones              (locations)
  14  Calendarios              (calendars)
  15  Reglas de disponibilidad (availability_rules)
  16  Excepciones              (availability_exceptions)

Cómo se nombra cada registro al referenciarlo (hoy salen UUIDs):
  employees -> {{first_name}} {{last_name}}
  services / resources / calendars / locations -> {{name}}

Fuera del menú (para todos, admin incluido):
  appointment_resources   tabla puente, se edita desde la cita
  service_resources       tabla puente, se edita desde el servicio
  conversation_sessions   estado interno de la capa omnicanal
  contact_phones          ya oculta: se edita dentro del contacto
  languages               ya oculta: tabla de sistema

Modo:
  $([[ "$APPLY" == true ]] && echo apply || echo plan)

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha modificado nada."
  exit 0
fi

docker exec -i \
  -e DIRECTUS_PROVISIONING_TOKEN="$DIRECTUS_PROVISIONING_TOKEN" \
  "$DIRECTUS_CONTAINER" \
  node --input-type=module <<'NODE'
const BASE = 'http://127.0.0.1:8055';
const token = process.env.DIRECTUS_PROVISIONING_TOKEN;

// Primero el trabajo diario, luego la configuración. El hueco entre 4 y 10 deja
// sitio para meter algo en medio sin renumerar todo.
const orden = {
  appointments: 1,
  tasks: 2,
  contacts: 3,
  knowledge: 4,

  services: 10,
  employees: 11,
  resources: 12,
  locations: 13,
  calendars: 14,
  availability_rules: 15,
  availability_exceptions: 16,
};

// Cómo se nombra un registro cuando se le referencia desde otro sitio. Sin esto
// Directus pinta el UUID: el responsable de una tarea salía como
// "3778d1f3-2778-4..." en vez de por su nombre.
const comoSeLlaman = {
  employees: '{{first_name}} {{last_name}}',
  services: '{{name}}',
  resources: '{{name}}',
  calendars: '{{name}}',
  locations: '{{name}}',
};

// Fuera del menú. No es un permiso: siguen accesibles por URL y desde el modelo
// de datos, simplemente no se navega a ellas.
const ocultas = [
  'appointment_resources',
  'service_resources',
  'conversation_sessions',
  'contact_phones',
  'languages',
];

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
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
}

const existentes = new Set(
  ((await api('GET', '/collections?limit=-1')).data ?? []).map(c => c.collection)
);

for (const [collection, sort] of Object.entries(orden)) {
  if (!existentes.has(collection)) {
    console.log(`AVISO: no existe la colección ${collection}, se omite.`);
    continue;
  }
  await api('PATCH', `/collections/${collection}`, { meta: { sort, hidden: false } });
  console.log(`Orden ${String(sort).padStart(2)}  ${collection}`);
}

for (const [collection, display_template] of Object.entries(comoSeLlaman)) {
  if (!existentes.has(collection)) continue;
  await api('PATCH', `/collections/${collection}`, { meta: { display_template } });
  console.log(`Nombre      ${collection} -> ${display_template}`);
}

for (const collection of ocultas) {
  if (!existentes.has(collection)) {
    console.log(`AVISO: no existe la colección ${collection}, se omite.`);
    continue;
  }
  await api('PATCH', `/collections/${collection}`, { meta: { hidden: true } });
  console.log(`Oculta      ${collection}`);
}
NODE

cat <<EOF

============================================================
HECHO
============================================================

Esto es esquema. Para que no se pierda ni le falte al próximo tenant:

  1) snapshot en el contenedor (sin tuberías, que truncan a 64 KiB):
       docker exec ${DIRECTUS_CONTAINER} sh -c \\
         "node /directus/cli.js schema snapshot --yes \\
          | grep -vE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\]' > /tmp/base-nuevo.yaml"
  2) docker cp ${DIRECTUS_CONTAINER}:/tmp/base-nuevo.yaml /tmp/base-nuevo.yaml
  3) comparar wc -l dentro y fuera, y llevarlo al repo local para revisar el diff.

============================================================

EOF
