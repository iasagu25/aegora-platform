#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora - Directus base schema bootstrap
#
# Responsabilidad:
#
#   Crear el primer schema funcional de Aegora en un tenant Directus vacío:
#
#     contacts
#     contact_phones
#     tasks
#     appointments
#
# Este script está pensado para bootstrap del modelo de referencia.
#
# Después de generar el primer schema:
#
#   Directus demo
#        ↓
#   schema snapshot
#        ↓
#   directus/schema/base.yaml
#
# Los siguientes tenants deben recibir el schema mediante schema apply,
# NO ejecutando nuevamente este bootstrap como mecanismo normal.
#
# Seguridad:
#
#   - PLAN por defecto.
#   - --apply requerido para modificar Directus.
#   - exige Directus 12.2.0.
#   - se niega a ejecutarse si alguna collection objetivo ya existe.
#   - si falla durante el bootstrap, elimina únicamente las collections
#     creadas por esta ejecución.
#   - nunca imprime ADMIN_EMAIL ni ADMIN_PASSWORD.
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"

readonly EXPECTED_DIRECTUS_VERSION="12.2.0"

TENANT=""
APPLY=false

TENANT_ROOT=""
TENANT_CONFIG=""

TENANT_ID=""
DIRECTUS_CONTAINER=""

# =============================================================================
# Logging
# =============================================================================

log() {
  printf '[%s] %s\n' \
    "$(date --iso-8601=seconds)" \
    "$*"
}

warn() {
  log "AVISO: $*" >&2
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

# =============================================================================
# Ayuda
# =============================================================================

usage() {
  cat <<'EOF'
Uso:

  bootstrap-schema.sh \
    --tenant TENANT \
    [--apply]

Sin --apply:
  valida el tenant y muestra el plan.

Con --apply:
  crea:

    contacts
    contact_phones
    tasks
    appointments

  y sus relaciones.

Ejemplo:

  sudo /usr/bin/bash \
    /opt/aegora/platform/directus/bootstrap-schema.sh \
    --tenant demo \
    --apply

Este script requiere:

  - tenant managed;
  - Directus running + healthy;
  - Directus 12.2.0;
  - ADMIN_EMAIL y ADMIN_PASSWORD disponibles dentro del contenedor;
  - ninguna de las cuatro collections previamente existente.
EOF
}

# =============================================================================
# Helpers
# =============================================================================

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "Falta el comando requerido: $1"
}

require_file() {
  [[ -f "$1" ]] ||
    fail "Falta el fichero requerido: $1"
}

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

container_running() {
  local container="$1"

  [[ "$(
    docker inspect \
      --format '{{.State.Status}}' \
      "$container" \
      2>/dev/null
  )" == "running" ]]
}

container_health() {
  local container="$1"

  docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}' \
    "$container" \
    2>/dev/null
}

# =============================================================================
# Argumentos
# =============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      [[ $# -ge 2 ]] ||
        fail "Falta valor para --tenant."

      TENANT="$2"
      shift 2
      ;;

    --apply)
      APPLY=true
      shift
      ;;

    --help|-h)
      usage
      exit 0
      ;;

    *)
      fail "Opción desconocida: $1"
      ;;
  esac
done

# =============================================================================
# Validación de argumentos
# =============================================================================

[[ -n "$TENANT" ]] ||
  fail "Falta --tenant."

[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] ||
  fail "Tenant inválido: ${TENANT}"

[[ "$TENANT" != "aegora" ]] ||
  fail \
    "El tenant legacy 'aegora' no puede usarse como referencia del nuevo schema."

require_command docker

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"

require_file "$TENANT_CONFIG"

# =============================================================================
# Cargar tenant.env
# =============================================================================

set -a

# shellcheck disable=SC1090
source "$TENANT_CONFIG"

set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail \
    "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

# =============================================================================
# Comprobar Directus
# =============================================================================

container_exists "$DIRECTUS_CONTAINER" ||
  fail \
    "No existe el contenedor Directus: ${DIRECTUS_CONTAINER}"

container_running "$DIRECTUS_CONTAINER" ||
  fail \
    "Directus no está running: ${DIRECTUS_CONTAINER}"

DIRECTUS_HEALTH="$(
  container_health "$DIRECTUS_CONTAINER"
)"

[[ "$DIRECTUS_HEALTH" == "healthy" ]] ||
  fail \
    "Directus no está healthy: ${DIRECTUS_HEALTH}"

DIRECTUS_VERSION="$(
  docker exec \
    "$DIRECTUS_CONTAINER" \
    node \
      -p \
      "require('/directus/package.json').version" |
    tr -d '\r\n'
)"

[[ "$DIRECTUS_VERSION" == "$EXPECTED_DIRECTUS_VERSION" ]] ||
  fail \
    "Versión Directus incorrecta. Esperada=${EXPECTED_DIRECTUS_VERSION}, actual=${DIRECTUS_VERSION}"

# =============================================================================
# Comprobar credenciales bootstrap sin mostrarlas
# =============================================================================

ADMIN_STATE="$(
  docker exec \
    "$DIRECTUS_CONTAINER" \
    sh -c '
      if [ -n "${ADMIN_EMAIL:-}" ] &&
         [ -n "${ADMIN_PASSWORD:-}" ]; then
        printf "loaded"
      else
        printf "missing"
      fi
    '
)"

[[ "$ADMIN_STATE" == "loaded" ]] ||
  fail \
    "ADMIN_EMAIL/ADMIN_PASSWORD no están disponibles dentro de ${DIRECTUS_CONTAINER}."

# =============================================================================
# PLAN
# =============================================================================

cat <<EOF

============================================================
AEGORA DIRECTUS SCHEMA BOOTSTRAP
============================================================

Tenant:
  ${TENANT_ID}

Directus:
  container: ${DIRECTUS_CONTAINER}
  version:   ${DIRECTUS_VERSION}
  health:    ${DIRECTUS_HEALTH}

Collections:

  contacts
    UUID primary key
    first_name
    last_name
    company
    email
    status
    notes
    created_at
    updated_at

  contact_phones
    UUID primary key
    contact_id -> contacts.id
    phone_number
    phone_normalized
    label
    is_primary
    can_whatsapp
    created_at
    updated_at

  tasks
    UUID primary key
    contact_id -> contacts.id
    title
    description
    status
    priority
    due_at
    completed_at
    source
    created_at
    updated_at

  appointments
    UUID primary key
    contact_id -> contacts.id
    title
    start_at
    end_at
    status
    notes
    source
    external_provider
    external_event_id
    created_at
    updated_at

Relations:

  contacts -> contact_phones
    1:N
    ON DELETE CASCADE

  contacts -> tasks
    1:N
    ON DELETE SET NULL

  contacts -> appointments
    1:N
    ON DELETE SET NULL

Constraints:

  phone_normalized:
    indexed
    NOT unique

  company:
    indexed
    NOT unique

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. Directus no ha sido modificado."
  log "Añade --apply para crear el schema."
  exit 0
fi

[[ $EUID -eq 0 ]] ||
  fail "--apply debe ejecutarse como root."

# =============================================================================
# Ejecutar bootstrap mediante la API local de Directus
#
# Node se ejecuta DENTRO del contenedor Directus.
#
# Ventajas:
#
#   - ADMIN_PASSWORD nunca sale del contenedor;
#   - no necesitamos Node en el host;
#   - no necesitamos publicar 8055 en el host;
#   - usamos la API oficial de Directus para modificar el Data Model.
# =============================================================================

log "Ejecutando bootstrap mediante la API de Directus."

docker exec \
  -i \
  "$DIRECTUS_CONTAINER" \
  node - <<'NODE'
'use strict';

const BASE_URL = 'http://127.0.0.1:8055';

const TARGET_COLLECTIONS = [
  'contacts',
  'contact_phones',
  'tasks',
  'appointments',
];

const createdCollections = [];

let accessToken = null;

// =============================================================================
// HTTP helpers
// =============================================================================

async function rawRequest(method, path, body = undefined, authenticated = true) {
  const headers = {
    Accept: 'application/json',
  };

  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
  }

  if (authenticated) {
    if (!accessToken) {
      throw new Error(`No hay access token para ${method} ${path}`);
    }

    headers.Authorization = `Bearer ${accessToken}`;
  }

  const response = await fetch(`${BASE_URL}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  let payload = null;
  const text = await response.text();

  if (text.length > 0) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = text;
    }
  }

  return {
    response,
    payload,
  };
}

async function request(method, path, body = undefined) {
  const { response, payload } = await rawRequest(
    method,
    path,
    body,
    true
  );

  if (!response.ok) {
    const rendered =
      typeof payload === 'string'
        ? payload
        : JSON.stringify(payload);

    throw new Error(
      `${method} ${path} -> HTTP ${response.status}: ${rendered}`
    );
  }

  return payload;
}

// =============================================================================
// Authentication
// =============================================================================

async function login() {
  const email = process.env.ADMIN_EMAIL;
  const password = process.env.ADMIN_PASSWORD;

  if (!email || !password) {
    throw new Error(
      'ADMIN_EMAIL o ADMIN_PASSWORD no están definidos.'
    );
  }

  const { response, payload } = await rawRequest(
    'POST',
    '/auth/login',
    {
      email,
      password,
      mode: 'json',
    },
    false
  );

  if (!response.ok) {
    throw new Error(
      `Login Directus fallido: HTTP ${response.status}`
    );
  }

  accessToken = payload?.data?.access_token;

  if (!accessToken) {
    throw new Error(
      'Directus no devolvió access_token.'
    );
  }

  console.log('Autenticación Directus: OK');
}

// =============================================================================
// Schema helpers
// =============================================================================

function uuidPrimaryKey() {
  return {
    field: 'id',
    type: 'uuid',

    meta: {
      hidden: true,
      readonly: true,
      required: true,
      interface: 'input',
      special: ['uuid'],
      sort: 1,
      width: 'full',
    },

    schema: {
      is_primary_key: true,
      is_nullable: false,
      is_unique: true,
      is_indexed: true,
    },
  };
}

function stringField(
  field,
  {
    required = false,
    defaultValue = null,
    indexed = false,
    sort,
    note = null,
    width = 'full',
    choices = null,
  } = {}
) {
  const meta = {
    interface: choices ? 'select-dropdown' : 'input',
    required,
    readonly: false,
    hidden: false,
    sort,
    width,
    note,
  };

  if (choices) {
    meta.options = {
      choices: choices.map(([text, value]) => ({
        text,
        value,
      })),
    };
  }

  return {
    field,
    type: 'string',

    meta,

    schema: {
      is_nullable: !required,
      is_unique: false,
      is_indexed: indexed,
      default_value: defaultValue,
      max_length: 255,
    },
  };
}

function textField(
  field,
  {
    sort,
    note = null,
  } = {}
) {
  return {
    field,
    type: 'text',

    meta: {
      interface: 'input-multiline',
      required: false,
      readonly: false,
      hidden: false,
      sort,
      width: 'full',
      note,
    },

    schema: {
      is_nullable: true,
      is_unique: false,
      is_indexed: false,
      default_value: null,
    },
  };
}

function booleanField(
  field,
  {
    defaultValue = false,
    sort,
    note = null,
  } = {}
) {
  return {
    field,
    type: 'boolean',

    meta: {
      interface: 'boolean',
      required: true,
      readonly: false,
      hidden: false,
      sort,
      width: 'half',
      note,
    },

    schema: {
      is_nullable: false,
      is_unique: false,
      is_indexed: false,
      default_value: defaultValue,
    },
  };
}

function timestampField(
  field,
  {
    required = false,
    sort,
    readonly = false,
    special = null,
    note = null,
  } = {}
) {
  return {
    field,
    type: 'timestamp',

    meta: {
      interface: 'datetime',
      required,
      readonly,
      hidden: false,
      sort,
      width: 'half',
      special,
      note,
    },

    schema: {
      is_nullable: !required,
      is_unique: false,
      is_indexed: false,
      default_value: null,
    },
  };
}

function createdAt(sort) {
  return timestampField('created_at', {
    sort,
    readonly: true,
    special: ['date-created'],
    note: 'Creation timestamp managed by Directus.',
  });
}

function updatedAt(sort) {
  return timestampField('updated_at', {
    sort,
    readonly: true,
    special: ['date-updated'],
    note: 'Last update timestamp managed by Directus.',
  });
}

function contactIdField({
  required,
  sort,
}) {
  return {
    field: 'contact_id',
    type: 'uuid',

    meta: {
      interface: 'select-dropdown-m2o',
      special: ['m2o'],
      required,
      readonly: false,
      hidden: false,
      sort,
      width: 'full',
      note: 'Related contact.',
    },

    schema: {
      is_nullable: !required,
      is_unique: false,
      is_indexed: true,
      default_value: null,
    },
  };
}

function o2mAlias(field, sort) {
  return {
    field,
    type: 'alias',

    meta: {
      interface: 'list-o2m',
      special: ['o2m'],
      required: false,
      readonly: false,
      hidden: false,
      sort,
      width: 'full',
    },
  };
}

// =============================================================================
// Collections
// =============================================================================

const collections = [
  {
    collection: 'contacts',

    meta: {
      collection: 'contacts',
      icon: 'person',
      note: 'People and client contacts.',
      display_template:
        '{{company}} · {{first_name}} {{last_name}}',
      hidden: false,
      singleton: false,
    },

    schema: {
      name: 'contacts',
      comment: 'Aegora contacts',
    },

    fields: [
      uuidPrimaryKey(),

      stringField('first_name', {
        required: true,
        sort: 2,
        width: 'half',
        note: 'Contact first name.',
      }),

      stringField('last_name', {
        required: false,
        sort: 3,
        width: 'half',
        note: 'Contact last name.',
      }),

      stringField('company', {
        required: false,
        indexed: true,
        sort: 4,
        note: 'Company or business used to identify the contact.',
      }),

      stringField('email', {
        required: false,
        sort: 5,
        note: 'Primary email address.',
      }),

      stringField('status', {
        required: true,
        defaultValue: 'active',
        sort: 6,
        width: 'half',
        choices: [
          ['Active', 'active'],
          ['Inactive', 'inactive'],
        ],
      }),

      textField('notes', {
        sort: 7,
        note: 'Free-form operational notes.',
      }),

      createdAt(8),
      updatedAt(9),
    ],
  },

  {
    collection: 'contact_phones',

    meta: {
      collection: 'contact_phones',
      icon: 'phone',
      note: 'Telephone numbers assigned to contacts.',
      display_template: '{{phone_number}}',
      hidden: false,
      singleton: false,
    },

    schema: {
      name: 'contact_phones',
      comment: 'Telephone numbers for Aegora contacts',
    },

    fields: [
      uuidPrimaryKey(),

      contactIdField({
        required: true,
        sort: 2,
      }),

      stringField('phone_number', {
        required: true,
        sort: 3,
        note: 'Human-readable telephone number.',
      }),

      stringField('phone_normalized', {
        required: true,
        indexed: true,
        sort: 4,
        note:
          'Normalized E.164-style number used for matching. Not unique.',
      }),

      stringField('label', {
        required: false,
        sort: 5,
        width: 'half',
        choices: [
          ['Mobile', 'mobile'],
          ['Work', 'work'],
          ['Home', 'home'],
          ['Other', 'other'],
        ],
      }),

      booleanField('is_primary', {
        defaultValue: false,
        sort: 6,
        note: 'Preferred telephone number for this contact.',
      }),

      booleanField('can_whatsapp', {
        defaultValue: false,
        sort: 7,
        note: 'Number can be used for WhatsApp.',
      }),

      createdAt(8),
      updatedAt(9),
    ],
  },

  {
    collection: 'tasks',

    meta: {
      collection: 'tasks',
      icon: 'task_alt',
      note: 'Operational tasks.',
      display_template: '{{title}}',
      hidden: false,
      singleton: false,
    },

    schema: {
      name: 'tasks',
      comment: 'Aegora operational tasks',
    },

    fields: [
      uuidPrimaryKey(),

      contactIdField({
        required: false,
        sort: 2,
      }),

      stringField('title', {
        required: true,
        sort: 3,
        note: 'Short task description.',
      }),

      textField('description', {
        sort: 4,
        note: 'Detailed task description.',
      }),

      stringField('status', {
        required: true,
        defaultValue: 'pending',
        sort: 5,
        width: 'half',
        choices: [
          ['Pending', 'pending'],
          ['Completed', 'completed'],
          ['Cancelled', 'cancelled'],
        ],
      }),

      stringField('priority', {
        required: true,
        defaultValue: 'normal',
        sort: 6,
        width: 'half',
        choices: [
          ['Low', 'low'],
          ['Normal', 'normal'],
          ['High', 'high'],
          ['Urgent', 'urgent'],
        ],
      }),

      timestampField('due_at', {
        required: false,
        sort: 7,
        note: 'Task due date and time.',
      }),

      timestampField('completed_at', {
        required: false,
        sort: 8,
        note: 'Timestamp when the task was completed.',
      }),

      stringField('source', {
        required: true,
        defaultValue: 'manual',
        sort: 9,
        width: 'half',
        choices: [
          ['Manual', 'manual'],
          ['AI', 'ai'],
          ['System', 'system'],
        ],
      }),

      createdAt(10),
      updatedAt(11),
    ],
  },

  {
    collection: 'appointments',

    meta: {
      collection: 'appointments',
      icon: 'event',
      note: 'Appointments and scheduled events.',
      display_template: '{{title}}',
      hidden: false,
      singleton: false,
    },

    schema: {
      name: 'appointments',
      comment: 'Aegora appointments',
    },

    fields: [
      uuidPrimaryKey(),

      contactIdField({
        required: false,
        sort: 2,
      }),

      stringField('title', {
        required: true,
        sort: 3,
        note: 'Appointment title.',
      }),

      timestampField('start_at', {
        required: true,
        sort: 4,
        note: 'Appointment start timestamp.',
      }),

      timestampField('end_at', {
        required: true,
        sort: 5,
        note: 'Appointment end timestamp.',
      }),

      stringField('status', {
        required: true,
        defaultValue: 'scheduled',
        sort: 6,
        width: 'half',
        choices: [
          ['Scheduled', 'scheduled'],
          ['Confirmed', 'confirmed'],
          ['Cancelled', 'cancelled'],
          ['Completed', 'completed'],
          ['No show', 'no_show'],
        ],
      }),

      textField('notes', {
        sort: 7,
        note: 'Appointment notes.',
      }),

      stringField('source', {
        required: true,
        defaultValue: 'manual',
        sort: 8,
        width: 'half',
        choices: [
          ['Manual', 'manual'],
          ['AI', 'ai'],
          ['System', 'system'],
        ],
      }),

      stringField('external_provider', {
        required: false,
        sort: 9,
        width: 'half',
        note:
          'External calendar provider, for example google or outlook.',
      }),

      stringField('external_event_id', {
        required: false,
        indexed: true,
        sort: 10,
        note: 'Event identifier in the external calendar provider.',
      }),

      createdAt(11),
      updatedAt(12),
    ],
  },
];

// =============================================================================
// Preflight
// =============================================================================

async function getExistingCollectionNames() {
  const result = await request(
    'GET',
    '/collections'
  );

  const collections = result?.data;

  if (!Array.isArray(collections)) {
    throw new Error(
      'Directus devolvió una respuesta inesperada al listar collections.'
    );
  }

  return new Set(
    collections
      .map((item) => item?.collection)
      .filter(Boolean)
  );
}

async function assertTargetCollectionsDoNotExist() {
  const existingCollections =
    await getExistingCollectionNames();

  const conflicts = TARGET_COLLECTIONS.filter(
    (collection) =>
      existingCollections.has(collection)
  );

  if (conflicts.length > 0) {
    throw new Error(
      `Bootstrap abortado: ya existen collections objetivo: ${conflicts.join(', ')}`
    );
  }

  console.log('Preflight collections: OK');
}

// =============================================================================
// Creation
// =============================================================================

async function createCollection(definition) {
  console.log(`Creando collection: ${definition.collection}`);

  await request(
    'POST',
    '/collections',
    definition
  );

  createdCollections.push(definition.collection);
}

async function createContactAliases() {
  console.log('Creando aliases O2M en contacts.');

  await request(
    'POST',
    '/fields/contacts',
    o2mAlias('phones', 10)
  );

  await request(
    'POST',
    '/fields/contacts',
    o2mAlias('tasks', 11)
  );

  await request(
    'POST',
    '/fields/contacts',
    o2mAlias('appointments', 12)
  );
}

async function createRelation({
  collection,
  field,
  relatedCollection,
  oneField,
  onDelete,
  deselectAction,
}) {
  console.log(
    `Creando relación: ${collection}.${field} -> ${relatedCollection}.id`
  );

  await request(
    'POST',
    '/relations',
    {
      collection,
      field,
      related_collection: relatedCollection,

      meta: {
        many_collection: collection,
        many_field: field,

        one_collection: relatedCollection,
        one_field: oneField,

        one_allowed_collections: null,
        one_collection_field: null,

        one_deselect_action: deselectAction,

        junction_field: null,
        sort_field: null,
      },

      schema: {
        on_update: 'NO ACTION',
        on_delete: onDelete,
      },
    }
  );
}

async function createRelations() {
  await createRelation({
    collection: 'contact_phones',
    field: 'contact_id',
    relatedCollection: 'contacts',
    oneField: 'phones',
    onDelete: 'CASCADE',
    deselectAction: 'delete',
  });

  await createRelation({
    collection: 'tasks',
    field: 'contact_id',
    relatedCollection: 'contacts',
    oneField: 'tasks',
    onDelete: 'SET NULL',
    deselectAction: 'nullify',
  });

  await createRelation({
    collection: 'appointments',
    field: 'contact_id',
    relatedCollection: 'contacts',
    oneField: 'appointments',
    onDelete: 'SET NULL',
    deselectAction: 'nullify',
  });
}

// =============================================================================
// Verification
// =============================================================================

async function verifyField(collection, field) {
  await request(
    'GET',
    `/fields/${encodeURIComponent(collection)}/${encodeURIComponent(field)}`
  );
}

async function verifyRelation(collection, field) {
  const result = await request(
    'GET',
    `/relations/${encodeURIComponent(collection)}/${encodeURIComponent(field)}`
  );

  const relation = result?.data;

  if (!relation) {
    throw new Error(
      `No se pudo verificar relación ${collection}.${field}`
    );
  }
}

async function verifySchema() {
  console.log('Verificando schema creado.');

  const expectedFields = {
    contacts: [
      'id',
      'first_name',
      'last_name',
      'company',
      'email',
      'status',
      'notes',
      'created_at',
      'updated_at',
      'phones',
      'tasks',
      'appointments',
    ],

    contact_phones: [
      'id',
      'contact_id',
      'phone_number',
      'phone_normalized',
      'label',
      'is_primary',
      'can_whatsapp',
      'created_at',
      'updated_at',
    ],

    tasks: [
      'id',
      'contact_id',
      'title',
      'description',
      'status',
      'priority',
      'due_at',
      'completed_at',
      'source',
      'created_at',
      'updated_at',
    ],

    appointments: [
      'id',
      'contact_id',
      'title',
      'start_at',
      'end_at',
      'status',
      'notes',
      'source',
      'external_provider',
      'external_event_id',
      'created_at',
      'updated_at',
    ],
  };

  for (const [collection, fields] of Object.entries(expectedFields)) {
    await request(
      'GET',
      `/collections/${encodeURIComponent(collection)}`
    );

    for (const field of fields) {
      await verifyField(collection, field);
    }

    console.log(
      `Collection verificada: ${collection} (${fields.length} fields)`
    );
  }

  await verifyRelation(
    'contact_phones',
    'contact_id'
  );

  await verifyRelation(
    'tasks',
    'contact_id'
  );

  await verifyRelation(
    'appointments',
    'contact_id'
  );

  console.log('Relaciones verificadas: 3');
}

// =============================================================================
// Rollback
// =============================================================================

async function rollback() {
  if (!accessToken || createdCollections.length === 0) {
    return;
  }

  console.error(
    'Bootstrap incompleto. Eliminando collections creadas en esta ejecución.'
  );

  for (const collection of [...createdCollections].reverse()) {
    try {
      const { response } = await rawRequest(
        'DELETE',
        `/collections/${encodeURIComponent(collection)}`,
        undefined,
        true
      );

      if (response.ok || response.status === 404) {
        console.error(
          `Rollback: ${collection} eliminada.`
        );
      } else {
        console.error(
          `Rollback: no se pudo eliminar ${collection} (HTTP ${response.status}).`
        );
      }
    } catch (error) {
      console.error(
        `Rollback: error eliminando ${collection}: ${error.message}`
      );
    }
  }
}

// =============================================================================
// Main
// =============================================================================

async function main() {
  await login();

  await assertTargetCollectionsDoNotExist();

  for (const definition of collections) {
    await createCollection(definition);
  }

  await createContactAliases();

  await createRelations();

  await verifySchema();

  console.log('');
  console.log('==============================================');
  console.log('DIRECTUS BASE SCHEMA CREADO CORRECTAMENTE');
  console.log('==============================================');
  console.log('');
  console.log('Collections:');
  console.log('  contacts');
  console.log('  contact_phones');
  console.log('  tasks');
  console.log('  appointments');
  console.log('');
  console.log('Relaciones:');
  console.log('  contacts -> contact_phones : CASCADE');
  console.log('  contacts -> tasks          : SET NULL');
  console.log('  contacts -> appointments   : SET NULL');
}

main()
  .catch(async (error) => {
    console.error('');
    console.error(`ERROR: ${error.message}`);

    await rollback();

    process.exitCode = 1;
  });
NODE

log "Bootstrap del schema Directus finalizado correctamente."

cat <<EOF

============================================================
DIRECTUS SCHEMA BOOTSTRAP COMPLETADO
============================================================

Tenant:
  ${TENANT_ID}

Collections:
  contacts
  contact_phones
  tasks
  appointments

Siguiente paso:

  generar schema snapshot y versionarlo como:

  directus/schema/base.yaml

============================================================
EOF
