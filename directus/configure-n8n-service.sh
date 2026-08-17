#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora - Configure Directus service identity for n8n
#
# Creates/updates a least-privilege Directus service identity for one tenant.
#
# Directus resources:
#   policy: "Aegora · n8n Service"
#   user:   n8n-service-<tenant>@aegora.es
#
# Collection/action permissions:
#   contacts        create/read/update · all fields
#   contact_phones  create/read/update · all fields
#   tasks           create/read/update · all fields
#   appointments    create/read/update · all fields
#
# Explicitly NOT granted:
#   delete
#   share
#   admin_access
#   app_access
#
# IMPORTANT:
# Directus 12.2.0 in this installation rejects field-restricted permission
# rules with:
#
#   custom_permission_rules_enabled is a restricted resource
#
# Therefore this script deliberately uses:
#
#   fields: ['*']
#
# for each explicitly granted collection/action rule.
#
# Secret:
#   /opt/aegora/tenants/<tenant>/secrets/directus-n8n.env
#
# The static token is never printed.
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly POLICY_NAME="Aegora · n8n Service"
readonly SECRET_FILENAME="directus-n8n.env"

TENANT=""
APPLY=false

TENANT_ROOT=""
TENANT_CONFIG=""
TENANT_SECRETS_DIR=""
SECRET_FILE=""

TENANT_ID=""
DIRECTUS_CONTAINER=""
DECLARED_DIRECTUS_VERSION=""
ACTUAL_DIRECTUS_VERSION=""
DIRECTUS_HEALTH=""

SERVICE_EMAIL=""
SERVICE_TOKEN=""
SECRET_CREATED=false

# =============================================================================
# Logging
# =============================================================================

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Uso:

  configure-n8n-service.sh \
    --tenant TENANT \
    [--apply]

Sin --apply:
  valida el tenant y muestra el plan.

Con --apply:
  crea/actualiza una policy Directus de mínimo privilegio,
  un usuario técnico n8n y un static token dedicado.

El token queda en:

  /opt/aegora/tenants/<tenant>/secrets/directus-n8n.env

No se imprime el valor del token.
EOF
}

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

cleanup() {
  local exit_code=$?

  trap - EXIT

  if [[ $exit_code -ne 0 && "$SECRET_CREATED" == true ]]; then
    rm -f "$SECRET_FILE" || true
    log "Se ha eliminado el secreto nuevo porque el provisioning no terminó correctamente." >&2
  fi

  unset SERVICE_TOKEN || true

  exit "$exit_code"
}

trap cleanup EXIT
trap 'fail "Fallo en la línea ${LINENO}: ${BASH_COMMAND}"' ERR

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
require_command openssl

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"
TENANT_SECRETS_DIR="${TENANT_ROOT}/secrets"
SECRET_FILE="${TENANT_SECRETS_DIR}/${SECRET_FILENAME}"

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
SERVICE_EMAIL="n8n-service-${TENANT}@aegora.es"

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
AEGORA · DIRECTUS N8N SERVICE
============================================================

Tenant:
  ${TENANT_ID}

Directus:
  container: ${DIRECTUS_CONTAINER}
  version:   ${ACTUAL_DIRECTUS_VERSION}
  health:    ${DIRECTUS_HEALTH}

Service user:
  ${SERVICE_EMAIL}

Policy:
  ${POLICY_NAME}

Permissions:
  contacts        create / read / update · all fields
  contact_phones  create / read / update · all fields
  tasks           create / read / update · all fields
  appointments    create / read / update · all fields

Not granted:
  delete
  share
  admin access
  Data Studio access

Secret:
  ${SECRET_FILE}

Modo:
  $([[ "$APPLY" == true ]] && printf 'APPLY' || printf 'PLAN')

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. Directus no ha sido modificado."
  exit 0
fi

[[ $EUID -eq 0 ]] ||
  fail "--apply debe ejecutarse como root."

# =============================================================================
# Secret
# =============================================================================

install \
  -d \
  -m 700 \
  -o root \
  -g root \
  "$TENANT_SECRETS_DIR"

if [[ -f "$SECRET_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$SECRET_FILE"
  set +a

  : "${DIRECTUS_N8N_TOKEN:?Falta DIRECTUS_N8N_TOKEN en ${SECRET_FILE}}"

  SERVICE_TOKEN="$DIRECTUS_N8N_TOKEN"

  log "Se reutiliza el static token existente del tenant."
else
  SERVICE_TOKEN="$(openssl rand -hex 32)"

  umask 077

  cat > "$SECRET_FILE" <<EOF
DIRECTUS_N8N_TOKEN=${SERVICE_TOKEN}
EOF

  chown root:root "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"

  SECRET_CREATED=true

  log "Static token dedicado generado y almacenado."
fi

# =============================================================================
# Configure Directus
# =============================================================================

log "Configurando policy, permisos y usuario técnico en Directus."

docker exec \
  -i \
  -e AEGORA_N8N_SERVICE_EMAIL="$SERVICE_EMAIL" \
  -e AEGORA_N8N_SERVICE_TOKEN="$SERVICE_TOKEN" \
  -e AEGORA_N8N_POLICY_NAME="$POLICY_NAME" \
  "$DIRECTUS_CONTAINER" \
  node - <<'NODE'
'use strict';

const BASE_URL = 'http://127.0.0.1:8055';

const serviceEmail = process.env.AEGORA_N8N_SERVICE_EMAIL;
const serviceToken = process.env.AEGORA_N8N_SERVICE_TOKEN;
const policyName = process.env.AEGORA_N8N_POLICY_NAME;

let adminToken = null;

// IMPORTANT:
// This is intentionally collection/action-level access with all fields.
// Field-restricted rules trigger Directus' restricted
// custom_permission_rules_enabled feature in this installation.
const permissionModel = {
  contacts: ['create', 'read', 'update'],
  contact_phones: ['create', 'read', 'update'],
  tasks: ['create', 'read', 'update'],
  appointments: ['create', 'read', 'update'],
};

async function rawRequest(
  method,
  path,
  body = undefined,
  token = adminToken
) {
  const headers = {
    Accept: 'application/json',
  };

  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
  }

  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const response = await fetch(`${BASE_URL}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const text = await response.text();

  let payload = null;

  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = text;
    }
  }

  return { response, payload };
}

async function request(
  method,
  path,
  body = undefined,
  token = adminToken
) {
  const { response, payload } = await rawRequest(
    method,
    path,
    body,
    token
  );

  if (!response.ok) {
    throw new Error(
      `${method} ${path} -> HTTP ${response.status}: ${
        typeof payload === 'string'
          ? payload
          : JSON.stringify(payload)
      }`
    );
  }

  return payload;
}

async function loginAdmin() {
  const email = process.env.ADMIN_EMAIL;
  const password = process.env.ADMIN_PASSWORD;

  const { response, payload } = await rawRequest(
    'POST',
    '/auth/login',
    {
      email,
      password,
      mode: 'json',
    },
    null
  );

  if (!response.ok) {
    throw new Error(
      `Login admin fallido: HTTP ${response.status}`
    );
  }

  adminToken = payload?.data?.access_token;

  if (!adminToken) {
    throw new Error(
      'Directus no devolvió access_token admin.'
    );
  }

  console.log('Autenticación admin: OK');
}

async function findOne(path) {
  const result = await request('GET', path);

  const data = result?.data;

  if (!Array.isArray(data)) {
    throw new Error(
      `Respuesta inesperada para ${path}`
    );
  }

  if (data.length > 1) {
    throw new Error(
      `Más de un resultado para ${path}`
    );
  }

  return data[0] ?? null;
}

async function ensurePolicy() {
  let policy = await findOne(
    `/policies?filter[name][_eq]=${encodeURIComponent(policyName)}&limit=2`
  );

  if (!policy) {
    const created = await request(
      'POST',
      '/policies',
      {
        name: policyName,
        icon: 'automation',
        description:
          'Least-privilege server-to-server access for tenant n8n.',
        admin_access: false,
        app_access: false,
        enforce_tfa: false,
      }
    );

    policy = created?.data;

    console.log('Policy creada.');
  } else {
    await request(
      'PATCH',
      `/policies/${encodeURIComponent(policy.id)}`,
      {
        name: policyName,
        description:
          'Least-privilege server-to-server access for tenant n8n.',
        admin_access: false,
        app_access: false,
        enforce_tfa: false,
      }
    );

    console.log('Policy existente validada/actualizada.');
  }

  return policy;
}

async function listPolicyPermissions(policyId) {
  const result = await request(
    'GET',
    `/permissions?filter[policy][_eq]=${encodeURIComponent(policyId)}&limit=-1`
  );

  return Array.isArray(result?.data)
    ? result.data
    : [];
}

async function ensurePermissions(policyId) {
  const existing = await listPolicyPermissions(policyId);
  const targetKeys = new Set();

  for (const [collection, actions] of Object.entries(permissionModel)) {
    for (const action of actions) {
      const key = `${collection}:${action}`;
      targetKeys.add(key);

      const matches = existing.filter(
        (permission) =>
          permission.collection === collection &&
          permission.action === action
      );

      if (matches.length > 1) {
        throw new Error(
          `Hay permisos duplicados para ${key}.`
        );
      }

      const payload = {
        policy: policyId,
        collection,
        action,
        permissions: null,
        validation: null,
        presets: null,
        fields: ['*'],
      };

      if (matches.length === 0) {
        await request(
          'POST',
          '/permissions',
          payload
        );

        console.log(
          `Permiso creado: ${key}`
        );
      } else {
        await request(
          'PATCH',
          `/permissions/${encodeURIComponent(matches[0].id)}`,
          payload
        );

        console.log(
          `Permiso actualizado: ${key}`
        );
      }
    }
  }

  // Remove any unexpected permission rule from the four managed collections.
  // This guarantees that delete/share do not silently remain granted.
  for (const permission of existing) {
    if (
      Object.prototype.hasOwnProperty.call(
        permissionModel,
        permission.collection
      )
    ) {
      const key =
        `${permission.collection}:${permission.action}`;

      if (!targetKeys.has(key)) {
        await request(
          'DELETE',
          `/permissions/${encodeURIComponent(permission.id)}`
        );

        console.log(
          `Permiso no permitido eliminado: ${key}`
        );
      }
    }
  }
}

async function ensureUser(policyId) {
  let user = await findOne(
    `/users?filter[email][_eq]=${encodeURIComponent(serviceEmail)}&limit=2`
  );

  if (!user) {
    // Password is intentionally random and discarded.
    // n8n authenticates exclusively using the static token.
    const password =
      crypto.randomUUID() +
      crypto.randomUUID();

    const created = await request(
      'POST',
      '/users',
      {
        email: serviceEmail,
        password,
        first_name: 'n8n',
        last_name: 'Service',
        status: 'active',
        token: serviceToken,
        role: null,
        policies: [policyId],
      }
    );

    user = created?.data;

    console.log('Usuario técnico creado.');
  } else {
    await request(
      'PATCH',
      `/users/${encodeURIComponent(user.id)}`,
      {
        first_name: 'n8n',
        last_name: 'Service',
        status: 'active',
        token: serviceToken,
        policies: [policyId],
      }
    );

    console.log(
      'Usuario técnico existente actualizado.'
    );
  }

  return user;
}

async function verifyServiceToken() {
  const me = await request(
    'GET',
    '/users/me?fields=id,email,status',
    undefined,
    serviceToken
  );

  if (me?.data?.email !== serviceEmail) {
    throw new Error(
      'El static token no resuelve al usuario técnico esperado.'
    );
  }

  if (me?.data?.status !== 'active') {
    throw new Error(
      'El usuario técnico no está active.'
    );
  }

  const permissions = await request(
    'GET',
    '/permissions/me',
    undefined,
    serviceToken
  );

  for (const [collection, actions] of Object.entries(permissionModel)) {
    for (const action of actions) {
      const access =
        permissions?.data?.[collection]?.[action]?.access;

      if (access !== 'full') {
        throw new Error(
          `Permiso efectivo incorrecto: ${collection}.${action}=${access}`
        );
      }
    }

    for (const forbidden of ['delete', 'share']) {
      const access =
        permissions?.data?.[collection]?.[forbidden]?.access;

      if (
        access !== undefined &&
        access !== null &&
        access !== 'none'
      ) {
        throw new Error(
          `Permiso prohibido detectado: ${collection}.${forbidden}=${access}`
        );
      }
    }
  }

  console.log('Static token: OK');
  console.log('Permisos efectivos C/R/U: OK');
  console.log('Delete/share: NO ACCESS');
}

async function main() {
  await loginAdmin();

  const policy = await ensurePolicy();

  if (!policy?.id) {
    throw new Error(
      'No se pudo resolver el ID de la policy.'
    );
  }

  await ensurePermissions(policy.id);
  await ensureUser(policy.id);
  await verifyServiceToken();

  console.log('');
  console.log('==============================================');
  console.log('DIRECTUS N8N SERVICE READY');
  console.log('==============================================');
}

main().catch((error) => {
  console.error('');
  console.error(`ERROR: ${error.message}`);
  process.exitCode = 1;
});
NODE

log "Identidad técnica n8n configurada correctamente."

# =============================================================================
# Verify secret file without exposing it
# =============================================================================

[[ -s "$SECRET_FILE" ]] ||
  fail "El fichero secreto no existe o está vacío."

[[ "$(stat -c '%U:%G' "$SECRET_FILE")" == "root:root" ]] ||
  fail "Ownership incorrecto en ${SECRET_FILE}"

[[ "$(stat -c '%a' "$SECRET_FILE")" == "600" ]] ||
  fail "Permisos incorrectos en ${SECRET_FILE}"

SECRET_CREATED=false

cat <<EOF

============================================================
DIRECTUS N8N SERVICE CONFIGURADO
============================================================

Tenant:
  ${TENANT_ID}

Service user:
  ${SERVICE_EMAIL}

Policy:
  ${POLICY_NAME}

Permissions:
  create/read/update sobre las cuatro collections
  con todos los fields de cada acción.

No concedido:
  delete
  share
  admin access
  Data Studio access

Token:
  almacenado de forma privada en
  ${SECRET_FILE}

Siguiente paso:
  crear en n8n la credencial HTTP Header Auth
  usando DIRECTUS_N8N_TOKEN.

============================================================
EOF
