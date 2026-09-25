#!/usr/bin/env bash

set -Eeuo pipefail

# Espera única a los contenedores (ver el fichero): nunca sleep ni un healthy exigido sin esperar.
# shellcheck source=/dev/null
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../scripts/lib/esperar-contenedor.sh"
IFS=$'\n\t'

# =============================================================================
# Aegora · rol de gestor del tenant (el cliente que usa Directus a diario)
#
#   Role: Aegora · Gestor  ->  Policy: Aegora · Gestor
#
# A diferencia del rol de n8n, este SÍ lleva app_access: la persona entra al
# Data Studio. Nunca admin_access.
#
# Qué ve y qué no: Directus oculta del menú lo que el rol no puede leer, así que
# el permiso de lectura ES el control de visibilidad. Ojo con una consecuencia
# que no es obvia: para que se vea un campo relacional hace falta lectura sobre
# la colección DESTINO. Por eso `employees` o `services` están aquí aunque no
# sean de uso diario -- sin ellas, el asignado de una tarea o el servicio de una
# cita salen en blanco.
#
# Este script NO crea usuarios: el admin invita a la gente al rol desde la UI.
#
# Idempotente. Sin --apply solo enseña el plan.
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly POLICY_NAME="Aegora · Gestor"
readonly ROLE_NAME="Aegora · Gestor"
readonly POSTGRES_ADMIN_USER="postgres"

TENANT=""
APPLY=false

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }


usage() {
  cat <<'EOF'
Uso:
  configure-tenant-role.sh --tenant TENANT [--apply]

Sin --apply:  valida y muestra el plan.
Con --apply:  crea/actualiza policy, permisos y role (como root).

No crea usuarios: invita a la gente al rol desde la UI de Directus.
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

docker inspect "$DIRECTUS_CONTAINER" >/dev/null 2>&1 ||
  fail "No existe el contenedor Directus: ${DIRECTUS_CONTAINER}"

esperar_healthy "$DIRECTUS_CONTAINER"

get_env() {
  docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" |
    awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

DB_HOST="$(get_env "$DIRECTUS_CONTAINER" DB_HOST)"
DB_DATABASE="$(get_env "$DIRECTUS_CONTAINER" DB_DATABASE)"
[[ -n "$DB_HOST" && -n "$DB_DATABASE" ]] ||
  fail "No se pudo detectar DB_HOST/DB_DATABASE desde ${DIRECTUS_CONTAINER}."

cat <<EOF

============================================================
AEGORA · ROL DE GESTOR
============================================================

Tenant:
  ${TENANT_ID}

Directus:
  ${DIRECTUS_CONTAINER}

Role / Policy:
  ${ROLE_NAME}   (app_access: sí · admin_access: no)

Uso diario:
  contacts               create / read / update / delete   (**)
  contact_phones         create / read / update / delete   (se editan dentro del contacto)
  tasks                  create / read / update / delete
  knowledge              create / read / update
  appointments           read / update   (*)

Configuración del negocio:
  services               create / read / update
  employees              create / read / update
  resources              create / read / update
  locations              create / read / update
  availability_rules     create / read / update / delete
  availability_exceptions create / read / update / delete
  service_resources      create / read / update / delete   (junction del pool de recursos)
  calendars              read
  appointment_resources  read

Biblioteca de archivos:
  directus_files         create / read / update   (sin borrar)
  directus_folders       read

Conversaciones de Lucía:
  conversation_sessions  read / update   (update = coger el hilo con 'modo')
  call_notes             read / update   (update = apagar 'requiere seguimiento')
  numeros_bloqueados     create / read / update / delete   (borrar = desbloquear)
  conversation_messages  read / create   (create = contestar; crear el mensaje
                                          ES enviarlo, lo recoge el enviador)
                                         sin update ni delete: el historial no
                                         se reescribe.

Sin permiso (invisibles para el gestor):
  languages

Notas:
  - Borrar solo donde no destruye historial: tareas y reglas de horario.
  (**) Borrar es el derecho de supresión del RGPD, que obliga al negocio. Es
       seguro porque un trigger (directus/sql/contacts-erasure.sql) cancela
       antes sus citas futuras: sin él quedaban huecos reservados para nadie.
       Las citas pasadas se conservan anonimizadas (contact_id a NULL), que es
       justo lo que pide una supresión. Los teléfonos se van con la persona.

  (*) Se quería update solo del campo 'status', para que mover o cancelar pasara
      siempre por el Booking API (el que valida solapes y buffers). Esta edición
      de Directus NO permite permisos por campo, así que el update es completo.
      Impedir que toquen la hora a mano queda para la interfaz, no para aquí.

Modo:
  $([[ "$APPLY" == true ]] && echo apply || echo plan)

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha modificado nada."
  exit 0
fi

[[ $EUID -eq 0 ]] || fail "--apply debe ejecutarse como root."

STATE_LINE="$(
  docker exec -i \
    -e AEGORA_POLICY_NAME="$POLICY_NAME" \
    -e AEGORA_ROLE_NAME="$ROLE_NAME" \
    -e DIRECTUS_PROVISIONING_TOKEN="$DIRECTUS_PROVISIONING_TOKEN" \
    "$DIRECTUS_CONTAINER" \
    node --input-type=module <<'NODE'
const BASE = 'http://127.0.0.1:8055';
const policyName = process.env.AEGORA_POLICY_NAME;
const roleName = process.env.AEGORA_ROLE_NAME;

// Fuente de verdad de lo que ve el gestor. { colección: { acción: campos } }.
// OJO: el saneo de abajo borra las acciones NO listadas de una colección que sí
// esté declarada, así que hay que listar todas las que necesite.
const ALL = ['*'];
const permissionModel = {
  // --- uso diario -----------------------------------------------------------
  // CON delete, y esta vez con la salvaguarda detrás. El derecho de supresión
  // del RGPD es obligación del negocio: sin este permiso no puede cumplirla sin
  // llamarnos, y eso no es aceptable para algo con plazo legal.
  //
  // El primer intento (21/sep/2026) se revirtió el mismo día porque borrar un
  // contacto dejaba sus citas FUTURAS sin dueño: un hueco guardado para nadie,
  // en la agenda, y en silencio. Lo arregla un trigger en
  // `directus/sql/contacts-erasure.sql`, que las cancela ANTES de borrar -- que
  // es lo que dicen a la vez la operativa y la ley: si dejas de tratar sus
  // datos, dejas de guardarle una hora. Las pasadas se quedan anonimizadas.
  //
  // Va en la base y no en un Flow a propósito: es un invariante del dato y se
  // cumple venga el borrado de donde venga, no solo desde la API.
  contacts: { create: ALL, read: ALL, update: ALL, delete: ALL },
  // Un teléfono mal tecleado no es histórico de nada: se quita y ya.
  contact_phones: { create: ALL, read: ALL, update: ALL, delete: ALL },
  tasks: { create: ALL, read: ALL, update: ALL, delete: ALL },
  knowledge: { create: ALL, read: ALL, update: ALL },
  // Aquí queríamos update SOLO del campo 'status', pero esta edición de Directus
  // devuelve 403 'custom_permission_rules_enabled is a restricted resource' en
  // cuanto un permiso lleva campos concretos: los permisos por campo (y los
  // filtros, validaciones y presets propios) están capados. Así que o todo o
  // nada. Se da update completo para que el gestor pueda marcar 'completada' o
  // 'no presentado', que es trabajo diario, y la barrera contra tocar la hora se
  // pone en la interfaz (campos readonly), NO aquí. Es un guardarraíl, no un
  // límite de seguridad: quien llame a la API puede cambiar lo que quiera.
  appointments: { read: ALL, update: ALL },

  // --- configuración del negocio -------------------------------------------
  services: { create: ALL, read: ALL, update: ALL },
  employees: { create: ALL, read: ALL, update: ALL },
  resources: { create: ALL, read: ALL, update: ALL },
  locations: { create: ALL, read: ALL, update: ALL },
  // Vacaciones y cierres: con delete, porque un cierre mal puesto hay que poder
  // quitarlo y es de lo que más se toca.
  availability_rules: { create: ALL, read: ALL, update: ALL, delete: ALL },
  availability_exceptions: { create: ALL, read: ALL, update: ALL, delete: ALL },

  // --- relaciones: lectura necesaria para que los campos no salgan en blanco --
  // service_resources es el pool de recursos de un servicio: se edita desde la
  // ficha del servicio, y sin delete no se puede desasignar un recurso.
  service_resources: { create: ALL, read: ALL, update: ALL, delete: ALL },
  appointment_resources: { read: ALL },
  calendars: { read: ALL },

  // --- conversaciones de Lucía ---------------------------------------------
  // update sobre la sesión es para cambiar `modo` y coger el hilo. Arrastra
  // poder tocar `state` (el JSON interno de la máquina) porque esta edición de
  // Directus no tiene permisos por campo: se pone readonly en la interfaz, que
  // es un guardarraíl y no una barrera -- igual que con la hora de una cita.
  conversation_sessions: { read: ALL, update: ALL },
  // create = contestar. Crear el mensaje ES enviarlo: HUMANO · Enviar pendientes
  // recoge los 'pendiente' cada 30 s.
  // SIN update y SIN delete, a propósito: un historial que se puede editar deja
  // de ser un historial de lo que pasó. Si un envío falla, la fila se queda
  // 'fallido' con el motivo y se manda otro -- no se reescribe el pasado.
  conversation_messages: { read: ALL, create: ALL },
  // Lectura, y update SOLO para poder apagar 'requiere_seguimiento'. Esta edición de
  // Directus no tiene permisos por campo (ver CLAUDE.md), así que dar update aquí deja
  // también editar el resumen. Se acepta a cambio de que el aviso de seguimiento se
  // pueda cerrar: un aviso que no se apaga deja de mirarse a la semana.
  call_notes: { read: ALL, update: ALL },
  // Bloquear y desbloquear es cosa del negocio, sin llamarnos. Borrar = desbloquear.
  numeros_bloqueados: { create: ALL, read: ALL, update: ALL, delete: ALL },

  // --- intercambio de ficheros con Aegora -----------------------------------
  // Para pasarse documentación durante la implantación y luego con los cambios.
  // Sin `delete` a propósito: borrar un fichero que otro esperaba es peor que
  // acumular alguno de más, y no hay papelera de la que recuperarlo.
  directus_files: { create: ALL, read: ALL, update: ALL },
  directus_folders: { read: ALL },
};

// Token estático del usuario técnico de provisioning. NO se usa ADMIN_EMAIL/
// ADMIN_PASSWORD del contenedor: esas variables son las del bootstrap inicial y no
// tienen por qué seguir siendo la contraseña real (en demo ya no lo son).
const token = process.env.DIRECTUS_PROVISIONING_TOKEN;

async function api(method, path, body) {
  const headers = { Accept: 'application/json' };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = `Bearer ${token}`;

  const res = await fetch(`${BASE}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const text = await res.text();
  const json = text ? JSON.parse(text) : null;

  if (!res.ok) {
    throw new Error(`${method} ${path} -> ${res.status}: ${text.slice(0, 300)}`);
  }
  return json;
}

async function findOne(path) {
  const r = await api('GET', path);
  return Array.isArray(r?.data) && r.data.length ? r.data[0] : null;
}

// ---------------------------------------------------------------- policy
let policy = await findOne(
  `/policies?filter[name][_eq]=${encodeURIComponent(policyName)}&limit=2`
);

const policyPayload = {
  name: policyName,
  icon: 'store',
  description: 'Gestor del negocio: agenda, clientes, recados y configuración.',
  // Entra al Data Studio, pero nunca es admin.
  app_access: true,
  admin_access: false,
  enforce_tfa: false,
};

if (!policy) {
  policy = (await api('POST', '/policies', policyPayload)).data;
  console.error('Policy creada.');
} else {
  await api('PATCH', `/policies/${policy.id}`, policyPayload);
  console.error('Policy actualizada.');
}

// ---------------------------------------------------------------- permisos
const existing = (await api(
  'GET',
  `/permissions?filter[policy][_eq]=${policy.id}&limit=-1&fields=id,collection,action`
)).data ?? [];

const deseados = new Set();

for (const [collection, acciones] of Object.entries(permissionModel)) {
  for (const [action, fields] of Object.entries(acciones)) {
    deseados.add(`${collection}:${action}`);

    const payload = {
      policy: policy.id,
      collection,
      action,
      // NUNCA {} -- Directus 12.2 evalúa un filtro vacío como "no matchea nada".
      permissions: null,
      validation: null,
      presets: null,
      fields,
    };

    const match = existing.find(
      p => p.collection === collection && p.action === action
    );

    if (match) {
      await api('PATCH', `/permissions/${match.id}`, payload);
      console.error(`Permiso actualizado: ${collection}:${action}`);
    } else {
      await api('POST', '/permissions', payload);
      console.error(`Permiso creado: ${collection}:${action}`);
    }
  }
}

// Saneo: solo dentro de las colecciones que gestionamos. Una colección que no
// esté en el modelo se deja en paz.
for (const p of existing) {
  if (!Object.prototype.hasOwnProperty.call(permissionModel, p.collection)) continue;
  if (deseados.has(`${p.collection}:${p.action}`)) continue;
  await api('DELETE', `/permissions/${p.id}`);
  console.error(`Permiso no permitido eliminado: ${p.collection}:${p.action}`);
}

// ---------------------------------------------------------------- role
let role = await findOne(
  `/roles?filter[name][_eq]=${encodeURIComponent(roleName)}&limit=2`
);

if (!role) {
  role = (await api('POST', '/roles', {
    name: roleName,
    icon: 'store',
    description: 'Personal del negocio que usa Directus a diario.',
  })).data;
  console.error('Role creado.');
}

process.stdout.write(`STATE\t${policy.id}\t${role.id}\n`);
NODE
)"

POLICY_ID="$(printf '%s' "$STATE_LINE" | awk -F'\t' '$1 == "STATE" { print $2 }')"
ROLE_ID="$(printf '%s' "$STATE_LINE" | awk -F'\t' '$1 == "STATE" { print $3 }')"

[[ -n "$POLICY_ID" && -n "$ROLE_ID" ]] ||
  fail "No se pudieron obtener los ids de policy/role."

# Directus 12.2 rechaza con 403 escribir la relación role<->policy anidada por
# API, así que se escribe directamente y de forma idempotente (mismo motivo y
# mismo patrón que en configure-n8n-service.sh).
ACCESS_ID="$(cat /proc/sys/kernel/random/uuid)"

docker exec -i "$DB_HOST" \
  psql \
    --username="$POSTGRES_ADMIN_USER" \
    --dbname="$DB_DATABASE" \
    --set=ON_ERROR_STOP=1 \
    --set=access_id="$ACCESS_ID" \
    --set=role_id="$ROLE_ID" \
    --set=policy_id="$POLICY_ID" \
    >/dev/null <<'SQL'
BEGIN;

DELETE FROM directus_access
WHERE role = :'role_id'::uuid
  AND policy <> :'policy_id'::uuid;

INSERT INTO directus_access (id, role, "user", policy, sort)
SELECT :'access_id'::uuid, :'role_id'::uuid, NULL, :'policy_id'::uuid, 1
WHERE NOT EXISTS (
  SELECT 1 FROM directus_access
  WHERE role = :'role_id'::uuid
    AND policy = :'policy_id'::uuid
    AND "user" IS NULL
);

COMMIT;
SQL

log "Role y policy enlazados."
log "Reiniciando ${DIRECTUS_CONTAINER} (Directus 12.2 cachea permisos)."
reiniciar_y_esperar "$DIRECTUS_CONTAINER"

cat <<EOF

============================================================
ROL LISTO
============================================================

Siguiente paso (manual, a propósito):
  Directus -> Configuración -> Usuarios -> invitar a la persona
  y asignarle el rol "${ROLE_NAME}".

============================================================

EOF
