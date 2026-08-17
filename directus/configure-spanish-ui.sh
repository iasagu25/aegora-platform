#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora - Configure Directus Data Studio in Spanish (Spain)
#
# Responsabilidad:
#   - añadir traducciones es-ES a collections y fields del schema Aegora;
#   - traducir las etiquetas visibles de los dropdowns manteniendo los values
#     internos en inglés;
#   - establecer es-ES como idioma por defecto del proyecto;
#   - establecer es-ES para el usuario administrador usado por este script.
#
# No modifica:
#   - nombres físicos de tablas/columnas;
#   - IDs;
#   - relaciones;
#   - valores almacenados de enums;
#   - contenido de negocio.
#
# Ejemplo:
#
#   contacts.status sigue almacenando:
#       active / inactive
#
#   pero Data Studio muestra:
#       Activo / Inactivo
#
# Seguridad:
#   - PLAN por defecto;
#   - --apply requerido para modificar Directus;
#   - solo opera sobre las cuatro collections base de Aegora;
#   - conserva traducciones existentes de otros idiomas;
#   - conserva el resto de metadata/opciones de cada field;
#   - no imprime credenciales ni access tokens.
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly TARGET_LANGUAGE="es-ES"

TENANT=""
APPLY=false

TENANT_ROOT=""
TENANT_CONFIG=""

TENANT_ID=""
DIRECTUS_CONTAINER=""
DECLARED_DIRECTUS_VERSION=""
ACTUAL_DIRECTUS_VERSION=""
DIRECTUS_HEALTH=""

# =============================================================================
# Logging
# =============================================================================

log() {
  printf '[%s] %s\n' \
    "$(date --iso-8601=seconds)" \
    "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

# =============================================================================
# Help
# =============================================================================

usage() {
  cat <<'EOF'
Uso:

  configure-spanish-ui.sh \
    --tenant TENANT \
    [--apply]

Sin --apply:
  valida Directus y muestra el plan.

Con --apply:
  configura Data Studio en español de España (es-ES).

Ejemplo:

  sudo /usr/bin/bash \
    /opt/aegora/platform/directus/configure-spanish-ui.sh \
    --tenant demo \
    --apply
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

container_running() {
  [[ "$(
    docker inspect \
      --format '{{.State.Status}}' \
      "$1" \
      2>/dev/null
  )" == "running" ]]
}

container_health() {
  docker inspect \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}' \
    "$1" \
    2>/dev/null
}

# =============================================================================
# Arguments
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
# Preflight
# =============================================================================

[[ -n "$TENANT" ]] ||
  fail "Falta --tenant."

[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] ||
  fail "Tenant inválido: ${TENANT}"

[[ "$TENANT" != "aegora" ]] ||
  fail "El tenant legacy 'aegora' no se modifica con este script."

require_command docker

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"

require_file "$TENANT_CONFIG"

set -a

# shellcheck disable=SC1090
source "$TENANT_CONFIG"

set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"
: "${DIRECTUS_VERSION:?Falta DIRECTUS_VERSION}"

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail \
    "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

DECLARED_DIRECTUS_VERSION="$DIRECTUS_VERSION"

docker inspect "$DIRECTUS_CONTAINER" >/dev/null 2>&1 ||
  fail "No existe el contenedor Directus: ${DIRECTUS_CONTAINER}"

container_running "$DIRECTUS_CONTAINER" ||
  fail "Directus no está running: ${DIRECTUS_CONTAINER}"

DIRECTUS_HEALTH="$(
  container_health "$DIRECTUS_CONTAINER"
)"

[[ "$DIRECTUS_HEALTH" == "healthy" ]] ||
  fail "Directus no está healthy: ${DIRECTUS_HEALTH}"

ACTUAL_DIRECTUS_VERSION="$(
  docker exec \
    "$DIRECTUS_CONTAINER" \
    node \
      -p \
      "require('/directus/package.json').version" |
    tr -d '\r\n'
)"

[[ "$ACTUAL_DIRECTUS_VERSION" == "$DECLARED_DIRECTUS_VERSION" ]] ||
  fail \
    "Versión Directus inconsistente. Declarada=${DECLARED_DIRECTUS_VERSION}, contenedor=${ACTUAL_DIRECTUS_VERSION}"

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
# Plan
# =============================================================================

cat <<EOF

============================================================
AEGORA DIRECTUS · SPANISH UI
============================================================

Tenant:
  ${TENANT_ID}

Directus:
  container: ${DIRECTUS_CONTAINER}
  version:   ${ACTUAL_DIRECTUS_VERSION}
  health:    ${DIRECTUS_HEALTH}

Idioma:
  ${TARGET_LANGUAGE}

Collections:
  contacts       -> Contactos
  contact_phones -> Teléfonos
  tasks          -> Tareas
  appointments   -> Citas

Project default language:
  ${TARGET_LANGUAGE}

Usuario bootstrap/admin:
  ${TARGET_LANGUAGE}

Identificadores físicos/API:
  SE MANTIENEN EN INGLÉS

Modo:
  $([[ "$APPLY" == true ]] && printf 'APPLY' || printf 'PLAN')

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. Directus no ha sido modificado."
  log "Añade --apply para configurar el frontend."
  exit 0
fi

[[ $EUID -eq 0 ]] ||
  fail "--apply debe ejecutarse como root."

# =============================================================================
# Apply through Directus API
# =============================================================================

log "Configurando traducciones y locale mediante la API de Directus."

docker exec \
  -i \
  "$DIRECTUS_CONTAINER" \
  node - <<'NODE'
'use strict';

const BASE_URL = 'http://127.0.0.1:8055';
const LANGUAGE = 'es-ES';

let accessToken = null;

// =============================================================================
// Desired translations
// =============================================================================

const collectionTranslations = {
  contacts: {
    singular: 'Contacto',
    plural: 'Contactos',
    translation: 'Contactos',
  },

  contact_phones: {
    singular: 'Teléfono',
    plural: 'Teléfonos',
    translation: 'Teléfonos',
  },

  tasks: {
    singular: 'Tarea',
    plural: 'Tareas',
    translation: 'Tareas',
  },

  appointments: {
    singular: 'Cita',
    plural: 'Citas',
    translation: 'Citas',
  },
};

const fieldTranslations = {
  contacts: {
    id: 'ID',
    first_name: 'Nombre',
    last_name: 'Apellidos',
    company: 'Empresa',
    email: 'Correo electrónico',
    status: 'Estado',
    notes: 'Notas',
    created_at: 'Fecha de creación',
    updated_at: 'Última modificación',
    phones: 'Teléfonos',
    tasks: 'Tareas',
    appointments: 'Citas',
  },

  contact_phones: {
    id: 'ID',
    contact_id: 'Contacto',
    phone_number: 'Teléfono',
    phone_normalized: 'Teléfono normalizado',
    label: 'Tipo',
    is_primary: 'Principal',
    can_whatsapp: 'WhatsApp',
    created_at: 'Fecha de creación',
    updated_at: 'Última modificación',
  },

  tasks: {
    id: 'ID',
    contact_id: 'Contacto',
    title: 'Título',
    description: 'Descripción',
    status: 'Estado',
    priority: 'Prioridad',
    due_at: 'Fecha límite',
    completed_at: 'Fecha de finalización',
    source: 'Origen',
    created_at: 'Fecha de creación',
    updated_at: 'Última modificación',
  },

  appointments: {
    id: 'ID',
    contact_id: 'Contacto',
    title: 'Título',
    start_at: 'Inicio',
    end_at: 'Fin',
    status: 'Estado',
    notes: 'Notas',
    source: 'Origen',
    external_provider: 'Proveedor externo',
    external_event_id: 'ID del evento externo',
    created_at: 'Fecha de creación',
    updated_at: 'Última modificación',
  },
};

// Choice texts are presentation labels only.
// Stored values remain unchanged in English.
const choiceTranslations = {
  'contacts.status': {
    active: 'Activo',
    inactive: 'Inactivo',
  },

  'contact_phones.label': {
    mobile: 'Móvil',
    work: 'Trabajo',
    home: 'Casa',
    other: 'Otro',
  },

  'tasks.status': {
    pending: 'Pendiente',
    completed: 'Completada',
    cancelled: 'Cancelada',
  },

  'tasks.priority': {
    low: 'Baja',
    normal: 'Normal',
    high: 'Alta',
    urgent: 'Urgente',
  },

  'tasks.source': {
    manual: 'Manual',
    ai: 'IA',
    system: 'Sistema',
  },

  'appointments.status': {
    scheduled: 'Programada',
    confirmed: 'Confirmada',
    cancelled: 'Cancelada',
    completed: 'Completada',
    no_show: 'No presentado',
  },

  'appointments.source': {
    manual: 'Manual',
    ai: 'IA',
    system: 'Sistema',
  },
};

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

  const text = await response.text();

  let payload = null;

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
// Translation helpers
// =============================================================================

function upsertLanguageTranslation(existing, spanish) {
  const translations =
    Array.isArray(existing)
      ? existing.filter(
          (entry) =>
            entry &&
            entry.language &&
            entry.language !== LANGUAGE
        )
      : [];

  translations.push({
    language: LANGUAGE,
    ...spanish,
  });

  return translations;
}

function translateChoices(options, mapping) {
  if (!options || !Array.isArray(options.choices)) {
    throw new Error(
      'El field esperado no contiene options.choices.'
    );
  }

  return {
    ...options,

    choices: options.choices.map((choice) => {
      if (!choice || typeof choice !== 'object') {
        return choice;
      }

      const translatedText =
        Object.prototype.hasOwnProperty.call(mapping, choice.value)
          ? mapping[choice.value]
          : choice.text;

      return {
        ...choice,
        text: translatedText,
      };
    }),
  };
}

// =============================================================================
// Collections
// =============================================================================

async function configureCollectionTranslations() {
  for (const [collection, spanish] of Object.entries(collectionTranslations)) {
    const current = await request(
      'GET',
      `/collections/${encodeURIComponent(collection)}`
    );

    const meta = current?.data?.meta;

    if (!meta) {
      throw new Error(
        `No se pudo leer metadata de collection ${collection}.`
      );
    }

    const translations = upsertLanguageTranslation(
      meta.translations,
      spanish
    );

    await request(
      'PATCH',
      `/collections/${encodeURIComponent(collection)}`,
      {
        meta: {
          translations,
        },
      }
    );

    console.log(
      `Collection traducida: ${collection} -> ${spanish.plural}`
    );
  }
}

// =============================================================================
// Fields
// =============================================================================

async function configureFieldTranslations() {
  for (const [collection, fields] of Object.entries(fieldTranslations)) {
    for (const [field, translation] of Object.entries(fields)) {
      const current = await request(
        'GET',
        `/fields/${encodeURIComponent(collection)}/${encodeURIComponent(field)}`
      );

      const meta = current?.data?.meta;

      if (!meta) {
        throw new Error(
          `No se pudo leer metadata de ${collection}.${field}.`
        );
      }

      const translations = upsertLanguageTranslation(
        meta.translations,
        {
          translation,
        }
      );

      const metaPatch = {
        translations,
      };

      const choiceKey = `${collection}.${field}`;

      if (
        Object.prototype.hasOwnProperty.call(
          choiceTranslations,
          choiceKey
        )
      ) {
        metaPatch.options = translateChoices(
          meta.options,
          choiceTranslations[choiceKey]
        );
      }

      await request(
        'PATCH',
        `/fields/${encodeURIComponent(collection)}/${encodeURIComponent(field)}`,
        {
          meta: metaPatch,
        }
      );

      console.log(
        `Field traducido: ${collection}.${field} -> ${translation}`
      );
    }
  }
}

// =============================================================================
// Project/User locale
// =============================================================================

async function configureProjectLocale() {
  await request(
    'PATCH',
    '/settings',
    {
      default_language: LANGUAGE,
    }
  );

  console.log(
    `Project default language: ${LANGUAGE}`
  );
}

async function configureCurrentUserLocale() {
  await request(
    'PATCH',
    '/users/me',
    {
      language: LANGUAGE,
    }
  );

  console.log(
    `Current admin language: ${LANGUAGE}`
  );
}

// =============================================================================
// Verification
// =============================================================================

async function verify() {
  const settings = await request(
    'GET',
    '/settings'
  );

  if (settings?.data?.default_language !== LANGUAGE) {
    throw new Error(
      `default_language no quedó en ${LANGUAGE}.`
    );
  }

  const me = await request(
    'GET',
    '/users/me?fields=id,email,language'
  );

  if (me?.data?.language !== LANGUAGE) {
    throw new Error(
      `El usuario actual no quedó en ${LANGUAGE}.`
    );
  }

  for (const [collection, spanish] of Object.entries(collectionTranslations)) {
    const result = await request(
      'GET',
      `/collections/${encodeURIComponent(collection)}`
    );

    const translations =
      result?.data?.meta?.translations ?? [];

    const entry = translations.find(
      (item) => item?.language === LANGUAGE
    );

    if (
      !entry ||
      entry.translation !== spanish.translation
    ) {
      throw new Error(
        `No se pudo verificar traducción de collection ${collection}.`
      );
    }
  }

  for (const [collection, fields] of Object.entries(fieldTranslations)) {
    for (const [field, expected] of Object.entries(fields)) {
      const result = await request(
        'GET',
        `/fields/${encodeURIComponent(collection)}/${encodeURIComponent(field)}`
      );

      const translations =
        result?.data?.meta?.translations ?? [];

      const entry = translations.find(
        (item) => item?.language === LANGUAGE
      );

      if (
        !entry ||
        entry.translation !== expected
      ) {
        throw new Error(
          `No se pudo verificar traducción de ${collection}.${field}.`
        );
      }
    }
  }

  console.log('Verificación de traducciones: OK');
  console.log('Verificación de locale: OK');
}

// =============================================================================
// Main
// =============================================================================

async function main() {
  await login();

  await configureCollectionTranslations();
  await configureFieldTranslations();
  await configureProjectLocale();
  await configureCurrentUserLocale();

  await verify();

  console.log('');
  console.log('==============================================');
  console.log('DIRECTUS DATA STUDIO CONFIGURADO EN ES-ES');
  console.log('==============================================');
}

main().catch((error) => {
  console.error('');
  console.error(`ERROR: ${error.message}`);
  process.exitCode = 1;
});
NODE

log "Configuración española de Directus finalizada correctamente."

cat <<EOF

============================================================
DIRECTUS SPANISH UI CONFIGURADO
============================================================

Tenant:
  ${TENANT_ID}

Idioma:
  ${TARGET_LANGUAGE}

Collections:
  Contactos
  Teléfonos
  Tareas
  Citas

Estado:
  OK

Siguiente paso:
  generar un nuevo schema snapshot y sustituir
  directus/schema/base.yaml

============================================================
EOF
