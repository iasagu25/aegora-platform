#!/usr/bin/env bash

set -Eeuo pipefail

# Espera única a los contenedores (ver el fichero): nunca sleep ni un healthy exigido sin esperar.
# shellcheck source=/dev/null
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../scripts/lib/esperar-contenedor.sh"
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

esperar_healthy "$DIRECTUS_CONTAINER"

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
  17  Recursos del servicio    (service_resources)

Orden de campos al abrir una cita:
  Estado · Título · Notas · Contacto · Inicio/Fin · Origen · ...
  (los identificadores y las marcas de tiempo, al final)

Estado de las citas, en color tanto en la lista como al editar:
  Programada (azul) · Confirmada (verde) · Completada (gris)
  Cancelada (rojo) · No presentado (ámbar)

Cómo se nombra cada registro al referenciarlo (hoy salen UUIDs):
  employees -> {{first_name}} {{last_name}}
  services / resources / calendars / locations -> {{name}}
  conversation_sessions -> {{session_key}}

En el menú, conversaciones:
  conversation_sessions   el hilo: se abre y se lee entero
  conversation_messages   lista plana: qué ha entrado hoy en todos los hilos

Fuera del menú (para todos, admin incluido):
  appointment_resources   la crea el Booking API; nadie la edita a mano
  contact_phones          ya oculta: se edita dentro del contacto
  languages               ya oculta: tabla de sistema

  (service_resources SÍ se ve: es donde se asocia servicio <-> recurso,
   y no hay campo inverso en ninguna de las dos colecciones)

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
  // Se entra por la conversación. La lista plana de mensajes está oculta: ver
  // `ocultas` más abajo.
  conversation_sessions: 5,
  // Las llamadas, justo detrás de las conversaciones escritas: es el mismo
  // trabajo del gestor, solo que por otro canal.
  call_notes: 7,
  // Justo detrás de las llamadas: es desde donde se decide bloquear a alguien.
  numeros_bloqueados: 8,

  services: 10,
  employees: 11,
  resources: 12,
  locations: 13,
  calendars: 14,
  availability_rules: 15,
  availability_exceptions: 16,
  service_resources: 17,
};

// Cómo se nombra un registro cuando se le referencia desde otro sitio. Sin esto
// Directus pinta el UUID: el responsable de una tarea salía como
// "3778d1f3-2778-4..." en vez de por su nombre.
// Cómo se escribe un contacto cuando se le nombra. Una sola definición porque se
// usa en DOS sitios que tienen que decir lo mismo: el display_template de la
// colección y el display `related-values` de cada campo que la referencia.
// La empresa va dentro porque en una gestoría a la gente se la conoce por ella.
// OJO: sin empresa queda un " · " colgando -- Directus no hace condicionales en
// una plantilla, y es preferible a no ver de qué empresa es nadie.
// Empresa primero: en una gestoría a la gente se la conoce por su empresa antes
// que por su nombre, y así la lista de contactos se agrupa sola. Ya estaba
// decidido en base.yaml antes de hoy; se mantiene.
// Tiene que coincidir con el display_template de `contacts` -- y coincide porque
// lo pone este mismo fichero, un poco más abajo.
const PLANTILLA_CONTACTO = '{{company}} · {{first_name}} {{last_name}}';

const comoSeLlaman = {
  contacts: PLANTILLA_CONTACTO,
  // session_key ya lleva el canal delante ("webchat:xxxx"), así que se basta
  // solo. No se mete el contacto: cuando es null, la plantilla deja un " · "
  // suelto y parece que algo se ha roto. El contacto va como columna.
  conversation_sessions: '{{session_key}}',
  // Sin esto, "Atendida por" en una cita enseña el UUID de la fila puente en vez
  // del nombre de quien atiende, que es el único motivo de que el campo exista.
  appointment_resources: '{{resource_id}}',
  employees: '{{first_name}} {{last_name}}',
  numeros_bloqueados: '{{telefono}}',
  services: '{{name}}',
  resources: '{{name}}',
  calendars: '{{name}}',
  locations: '{{name}}',
};

// Cómo se pinta un campo concreto. El estado de una cita en monocromo no dice
// nada de un vistazo; con etiquetas de color se lee la agenda de un golpe.
// Los cinco estados, con su texto en español y colores coherentes: azul lo que
// está por venir, verde lo confirmado, gris lo ya pasado, rojo lo anulado y
// ámbar el plantón, que no es un fallo pero hay que verlo.
// Orden y ancho de los campos al abrir una cita. Lo primero que quiere ver quien
// la abre es EN QUÉ ESTADO está, y con quién es. Los identificadores técnicos y
// las marcas de tiempo, al final.
const ordenDeCampos = {
  appointments: [
    ['id', 'full'],
    ['status', 'half'],
    // Quién atiende va arriba, junto al estado: al abrir una cita es de lo
    // primero que se quiere ver, y si no aparece en esta lista el script
    // reordena todo lo demás y lo deja caído en medio del formulario.
    ['recursos', 'half'],
    ['title', 'full'],
    ['notes', 'full'],
    ['contact_id', 'full'],
    ['start_at', 'half'],
    ['end_at', 'half'],
    ['source', 'half'],
    ['service_id', 'full'],
    ['calendar_id', 'full'],
    ['location_id', 'full'],
    ['external_provider', 'half'],
    ['external_event_id', 'full'],
    ['created_at', 'half'],
    ['updated_at', 'half'],
    ['idempotency_key', 'full'],
  ],

  // Abrir una conversación es para LEERLA: el hilo va arriba del todo, justo
  // debajo de con quién es. El estado interno de la máquina, al final.
  conversation_sessions: [
    ['canal', 'half'],
    ['contact_id', 'half'],
    ['mensajes', 'full'],
    ['modo', 'half'],
    ['ventana_hasta', 'half'],
    ['session_key', 'full'],
    ['flujo_activo', 'half'],
    ['updated_at', 'half'],
    ['created_at', 'half'],
    ['state', 'full'],
    ['id', 'full'],
  ],

  // Lo primero que quiere ver el gestor de una llamada es cuándo fue, de quién y
  // para qué; la duración y los identificadores, al final.
  numeros_bloqueados: [
    ['telefono', 'half'],
    ['created_at', 'half'],
    ['motivo', 'full'],
    ['user_created', 'half'],
    ['id', 'full'],
  ],

  call_notes: [
    ['start_at', 'half'],
    ['telefono', 'half'],
    ['contact_id', 'full'],
    ['motivo', 'full'],
    ['resultado', 'full'],
    ['resumen', 'full'],
    ['requiere_seguimiento', 'half'],
    ['duracion_segundos', 'half'],
    ['direccion', 'half'],
    ['session_key', 'full'],
    ['call_id', 'full'],
    ['created_at', 'half'],
    ['id', 'full'],
  ],

  conversation_messages: [
    ['created_at', 'half'],
    ['autor', 'half'],
    ['texto', 'full'],
    ['direccion', 'half'],
    ['canal', 'half'],
    ['estado_envio', 'half'],
    ['error', 'full'],
    ['session_id', 'full'],
    ['contact_id', 'full'],
    ['canal_message_id', 'full'],
    ['id', 'full'],
  ],
};

const displaysDeCampo = [
  // El gestor de un VIP es un empleado: sin display se vería su UUID.
  {
    collection: 'contacts',
    field: 'gestor_id',
    display: 'related-values',
    display_options: { template: '{{first_name}} {{last_name}}' },
  },
  // El display_template de una colección NO basta: si el campo que la referencia
  // no tiene display, Directus pinta el valor crudo -- el UUID. Hay que decirlo
  // campo a campo, y es exactamente lo que faltaba para que la bandeja enseñara
  // "82dd8445-c51f-..." donde debía decir el nombre de una persona.
  ...['conversation_sessions', 'conversation_messages', 'appointments', 'tasks',
    'call_notes'].map(
    (collection) => ({
      collection,
      field: 'contact_id',
      display: 'related-values',
      display_options: { template: PLANTILLA_CONTACTO },
    })
  ),
  // En Europa nadie dice "las 4 y 23 de la tarde": el reloj es de 24 horas. Sin
  // `use24` Directus pinta AM/PM, y en una agenda eso no es solo feo -- "4:00"
  // sin mirar el sufijo son las cuatro de la mañana o las de la tarde, y quien
  // lee una cita de un vistazo se equivoca. Va en las horas que una persona LEE
  // para actuar; los `created_at`/`updated_at` de auditoría se dejan como están.
  ...[
    ['appointments', 'start_at'], ['appointments', 'end_at'],
    ['tasks', 'due_at'], ['tasks', 'completed_at'],
    ['call_notes', 'start_at'],
    // La ventana de 24 h de WhatsApp: si el gestor la lee mal, escribe fuera de
    // plazo y el mensaje no sale.
    ['conversation_sessions', 'ventana_hasta'],
  ].map(([collection, field]) => ({
    collection, field,
    display: 'datetime',
    display_options: { use24: true },
  })),

  {
    // En una bandeja, "hace 5 min" dice más que "21 de septiembre de 2026 12:20"
    // y ocupa un tercio. El orden de la lista ya es por esta columna.
    collection: 'conversation_sessions',
    field: 'updated_at',
    display: 'datetime',
    display_options: { format: 'short', relative: true, suffix: true },
  },

  {
    collection: 'appointments',
    field: 'status',
    display: 'labels',
    // Los mismos colores en el desplegable de edición: al abrir la cita se ve el
    // estado de un golpe, no hay que leerlo. `value` no se toca nunca -- lo que
    // se guarda sigue siendo scheduled/confirmed/... y de eso depende el Booking
    // API y Lucía.
    options: {
      choices: [
        { value: 'scheduled', text: 'Programada',    color: '#3399FF', icon: 'event' },
        { value: 'confirmed', text: 'Confirmada',    color: '#2ECDA7', icon: 'check_circle' },
        { value: 'completed', text: 'Completada',    color: '#A2B5CD', icon: 'task_alt' },
        { value: 'cancelled', text: 'Cancelada',     color: '#E35169', icon: 'cancel' },
        { value: 'no_show',   text: 'No presentado', color: '#FFA439', icon: 'person_off' },
      ],
    },
    display_options: {
      format: false,
      choices: [
        { value: 'scheduled', text: 'Programada',    background: '#3399FF', foreground: '#FFFFFF', icon: 'event' },
        { value: 'confirmed', text: 'Confirmada',    background: '#2ECDA7', foreground: '#FFFFFF', icon: 'check_circle' },
        { value: 'completed', text: 'Completada',    background: '#A2B5CD', foreground: '#FFFFFF', icon: 'task_alt' },
        { value: 'cancelled', text: 'Cancelada',     background: '#E35169', foreground: '#FFFFFF', icon: 'cancel' },
        { value: 'no_show',   text: 'No presentado', background: '#FFA439', foreground: '#FFFFFF', icon: 'person_off' },
      ],
    },
  },
];

// Fuera del menú. No es un permiso: siguen accesibles por URL y desde el modelo
// de datos, simplemente no se navega a ellas.
const ocultas = [
  // La crea el Booking API al reservar; nadie la edita a mano.
  'appointment_resources',
  // Se editan dentro del contacto.
  'contact_phones',
  // Tabla de sistema.
  'languages',
  // La lista plana de mensajes. Desde que la conversación se lee como hilo (el
  // interfaz de `conversation_sessions.mensajes`), esta vista solo repite lo
  // mismo sin el contexto de quién habla con quién, y en el menú del gestor
  // compite con "Conversaciones", que es donde tiene que entrar.
  'conversation_messages',
];

// OJO: service_resources NO va aquí aunque sea una tabla puente. Es el único
// sitio donde se asocia un servicio con los recursos que pueden darlo, y las
// relaciones no tienen campo inverso (`one_field: null`), así que ni `services`
// ni `resources` muestran al otro lado. Ocultarla deja al gestor sin ninguna
// forma de configurar qué recurso presta qué servicio.

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

for (const d of displaysDeCampo) {
  if (!existentes.has(d.collection)) continue;
  const meta = { display: d.display, display_options: d.display_options };
  if (d.options) meta.options = d.options;
  await api('PATCH', `/fields/${d.collection}/${d.field}`, { meta });
  console.log(`Display     ${d.collection}.${d.field} -> ${d.display}`);
}

for (const [collection, campos] of Object.entries(ordenDeCampos)) {
  if (!existentes.has(collection)) continue;
  let n = 0;
  for (const [field, width] of campos) {
    n += 1;
    await api('PATCH', `/fields/${collection}/${field}`, { meta: { sort: n, width } });
  }
  console.log(`Orden campos ${collection} (${n})`);
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

  1) directus/snapshot-schema.sh --tenant ${TENANT_ID}
  2) traérselo a local:  scp <vps>:/tmp/base-nuevo.yaml /tmp/base-nuevo.yaml
  3) revisar el diff contra directus/schema/base.yaml ANTES de commitear.

El CLI a mano NO: canalizar su salida la trunca en 64 KiB exactos y el YAML
resultante parsea pero llega a la mitad, sin relaciones. El script escribe a
fichero y además deja a null los displays de nuestras extensiones.

============================================================

EOF
