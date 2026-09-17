#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora · vistas por defecto de Directus (presets globales)
#
# Cuando abres una colección, Directus decide qué vista enseñar mirando
# directus_presets. Un preset con `user` y `role` a NULL es el DEFECTO GLOBAL:
# lo hereda todo el mundo, incluidos los usuarios que se creen mañana.
#
# Los presets que crea la UI al toquetear una vista llevan tu `user` puesto, así
# que solo te afectan a ti. Por eso el gestor veía la tabla aunque tú tuvieras
# configurado el calendario.
#
# Esto NO es esquema (no sale en base.yaml), así que va por API y hay que
# ejecutarlo por tenant.
#
# Los valores salen de la configuración real de `demo`, no inventados: se leyó
# lo que Directus había guardado y se quitó lo que no debe fijarse.
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
  configure-directus-presets.sh --tenant TENANT [--apply]

Sin --apply:  muestra el plan.
Con --apply:  crea/actualiza los presets globales.
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
[[ -f "$PROVISIONING_SECRET" ]] ||
  fail "Falta la credencial técnica: ${PROVISIONING_SECRET}"

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
AEGORA · VISTAS POR DEFECTO
============================================================

Tenant:
  ${TENANT_ID}

Citas (appointments):
  vista            Calendario, semana, empezando en lunes
  evento           {{contact_id.first_name}} · {{status}}
  fechas           start_at -> end_at
  auto-refresco    30 s   (Lucía reserva en vivo)

Tareas (tasks):
  vista            Aegora Tasks
  auto-refresco    10 s

Contactos (contacts):
  vista            Tabla: nombre, apellidos, empresa, email, teléfonos

Alcance:
  presets GLOBALES (user y role a NULL): los hereda todo el mundo, también
  los usuarios que se creen después. No tocan los presets personales que
  cada uno ya tenga -- esos siguen ganando para esa persona.

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

// Formas tomadas de lo que Directus guardó de verdad en demo, no inventadas.
// Se omite a propósito `viewInfo`: guarda la semana concreta que estabas mirando
// y fijarla dejaría a todo el mundo anclado a septiembre de 2026.
const presets = [
  {
    collection: 'appointments',
    layout: 'calendar',
    layout_query: null,
    layout_options: {
      calendar: {
        template: '{{contact_id.first_name}} · {{status}}',
        startDateField: 'start_at',
        endDateField: 'end_at',
        firstDay: 1,
      },
    },
    refresh_interval: 30,
  },
  {
    collection: 'tasks',
    layout: 'aegora-tasks-layout',
    layout_query: null,
    layout_options: null,
    refresh_interval: 10,
  },
  {
    collection: 'contacts',
    layout: 'tabular',
    layout_query: {
      tabular: { fields: ['first_name', 'last_name', 'company', 'email', 'phones'] },
    },
    layout_options: { tabular: { spacing: 'compact' } },
    refresh_interval: null,
  },
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

const todos = (await api('GET', '/presets?limit=-1&fields=id,user,role,collection,bookmark')).data ?? [];

for (const preset of presets) {
  // El global es el que no tiene dueño: ni usuario, ni rol, ni marcador.
  const actual = todos.find(
    p => p.collection === preset.collection && !p.user && !p.role && !p.bookmark
  );

  if (actual) {
    await api('PATCH', `/presets/${actual.id}`, preset);
    console.log(`Actualizado  ${preset.collection} -> ${preset.layout}`);
  } else {
    await api('POST', '/presets', { ...preset, user: null, role: null, bookmark: null });
    console.log(`Creado       ${preset.collection} -> ${preset.layout}`);
  }
}

const personales = todos.filter(p => p.user && presets.some(x => x.collection === p.collection));
if (personales.length) {
  console.log('');
  console.log(`AVISO: hay ${personales.length} presets personales sobre estas colecciones.`);
  console.log('Quien los tenga seguirá viendo SU vista, no la global. Para comprobar el');
  console.log('defecto, entra con un usuario que no haya tocado nunca esa colección.');
}
NODE

cat <<EOF

============================================================
HECHO
============================================================

Para comprobarlo: entra con un usuario nuevo (rol Aegora · Gestor) y abre
Citas y Tareas. Debe salir el calendario y la vista Aegora Tasks sin tocar
nada. Con tu propio usuario NO se nota: tus presets personales mandan.

============================================================

EOF
