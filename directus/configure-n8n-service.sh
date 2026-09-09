#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora - Configure Directus service identity for n8n
#
# Result:
#
#   n8n-service-<tenant>@aegora.es
#          |
#          v
#   Role: Aegora · n8n Service
#          |
#          v
#   Policy: Aegora · n8n Service
#          |
#          +-- contacts        create/read/update · all fields
#          +-- contact_phones  create/read/update · all fields
#          +-- tasks           create/read/update · all fields
#          +-- appointments    create/read/update · all fields
#
# Directus 12.2.0 in this installation rejects nested policy relation writes
# with HTTP 403. The role<->policy assignment is therefore written directly
# and idempotently to directus_access. All other resources are managed via API.
#
# Explicitly NOT granted:
#   delete
#   share
#   admin_access
#   app_access
#
# Secret:
#   /opt/aegora/tenants/<tenant>/secrets/directus-n8n.env
#
# The static token is never printed.
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly POLICY_NAME="Aegora · n8n Service"
readonly ROLE_NAME="Aegora · n8n Service"
readonly SECRET_FILENAME="directus-n8n.env"
readonly POSTGRES_ADMIN_USER="postgres"

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

DB_HOST=""
DB_DATABASE=""

POLICY_ID=""
ROLE_ID=""
USER_ID=""

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
  crea/actualiza policy, permisos, role, usuario técnico y static token.

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

get_container_env() {
  local container="$1"
  local key="$2"

  docker inspect \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
    "$container" |
    awk -F= -v key="$key" '
      $1 == key {
        sub(/^[^=]*=/, "")
        print
        exit
      }
    '
}

wait_healthy() {
  local container="$1"
  local timeout_seconds="${2:-120}"
  local elapsed=0

  while (( elapsed < timeout_seconds )); do
    local status
    local health

    status="$(
      docker inspect \
        --format '{{.State.Status}}' \
        "$container" \
        2>/dev/null || true
    )"

    health="$(
      docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$container" \
        2>/dev/null || true
    )"

    log "${container}: status=${status:-unknown}, health=${health:-unknown}, espera=${elapsed}s"

    if [[ "$status" == "running" && "$health" == "healthy" ]]; then
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "Timeout esperando health de ${container}."
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      [[ $# -ge 2 ]] || fail "Falta valor para --tenant."
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

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"
[[ "$TENANT" != "aegora" ]] || fail "El tenant legacy 'aegora' no se modifica con este script."

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
  fail "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

DECLARED_DIRECTUS_VERSION="$DIRECTUS_VERSION"
SERVICE_EMAIL="n8n-service-${TENANT}@aegora.es"

docker inspect "$DIRECTUS_CONTAINER" >/dev/null 2>&1 ||
  fail "No existe el contenedor Directus: ${DIRECTUS_CONTAINER}"

container_running "$DIRECTUS_CONTAINER" ||
  fail "Directus no está running: ${DIRECTUS_CONTAINER}"

DIRECTUS_HEALTH="$(container_health "$DIRECTUS_CONTAINER")"

[[ "$DIRECTUS_HEALTH" == "healthy" ]] ||
  fail "Directus no está healthy: ${DIRECTUS_HEALTH}"

ACTUAL_DIRECTUS_VERSION="$(
  docker exec \
    "$DIRECTUS_CONTAINER" \
    node -p "require('/directus/package.json').version" |
    tr -d '\r\n'
)"

[[ "$ACTUAL_DIRECTUS_VERSION" == "$DECLARED_DIRECTUS_VERSION" ]] ||
  fail "Versión Directus inconsistente. Declarada=${DECLARED_DIRECTUS_VERSION}, contenedor=${ACTUAL_DIRECTUS_VERSION}"

ADMIN_STATE="$(
  docker exec \
    "$DIRECTUS_CONTAINER" \
    sh -c '
      if [ -n "${ADMIN_EMAIL:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
        printf "loaded"
      else
        printf "missing"
      fi
    '
)"

[[ "$ADMIN_STATE" == "loaded" ]] ||
  fail "ADMIN_EMAIL/ADMIN_PASSWORD no están disponibles dentro de ${DIRECTUS_CONTAINER}."

DB_HOST="$(get_container_env "$DIRECTUS_CONTAINER" "DB_HOST")"
DB_DATABASE="$(get_container_env "$DIRECTUS_CONTAINER" "DB_DATABASE")"

[[ -n "$DB_HOST" ]] || fail "No se pudo detectar DB_HOST desde ${DIRECTUS_CONTAINER}."
[[ -n "$DB_DATABASE" ]] || fail "No se pudo detectar DB_DATABASE desde ${DIRECTUS_CONTAINER}."

docker inspect "$DB_HOST" >/dev/null 2>&1 ||
  fail "DB_HOST=${DB_HOST} no corresponde a un contenedor Docker accesible desde el host."

docker exec \
  "$DB_HOST" \
  psql \
    --username="$POSTGRES_ADMIN_USER" \
    --dbname="$DB_DATABASE" \
    --set=ON_ERROR_STOP=1 \
    --tuples-only \
    --command='SELECT 1 FROM directus_access LIMIT 1;' \
    >/dev/null

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

Database:
  host:      ${DB_HOST}
  database:  ${DB_DATABASE}

Service user:
  ${SERVICE_EMAIL}

Role:
  ${ROLE_NAME}

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

Direct SQL:
  directus_access role <-> policy
  directus_users.role

Modo:
  $([[ "$APPLY" == true ]] && printf 'APPLY' || printf 'PLAN')

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. Directus no ha sido modificado."
  exit 0
fi

[[ $EUID -eq 0 ]] || fail "--apply debe ejecutarse como root."

install -d -m 700 -o root -g root "$TENANT_SECRETS_DIR"

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
  printf 'DIRECTUS_N8N_TOKEN=%s\n' "$SERVICE_TOKEN" > "$SECRET_FILE"
  chown root:root "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
  SECRET_CREATED=true
  log "Static token dedicado generado y almacenado."
fi

log "Configurando policy, permisos, role y usuario técnico por API."

API_OUTPUT="$(
  docker exec \
    -i \
    -e AEGORA_N8N_SERVICE_EMAIL="$SERVICE_EMAIL" \
    -e AEGORA_N8N_POLICY_NAME="$POLICY_NAME" \
    -e AEGORA_N8N_ROLE_NAME="$ROLE_NAME" \
    "$DIRECTUS_CONTAINER" \
    node - <<'NODE'
'use strict';

const BASE_URL = 'http://127.0.0.1:8055';
const serviceEmail = process.env.AEGORA_N8N_SERVICE_EMAIL;
const policyName = process.env.AEGORA_N8N_POLICY_NAME;
const roleName = process.env.AEGORA_N8N_ROLE_NAME;

let adminToken = null;

const permissionModel = {
  contacts: ['create', 'read', 'update'],
  contact_phones: ['create', 'read', 'update'],
  tasks: ['create', 'read', 'update'],
  appointments: ['create', 'read', 'update'],
  // Config de booking: solo lectura. La capa n8n (workflows / cerebro) la
  // necesita para resolver service_id, recursos, horarios, etc. El Booking API
  // es quien escribe. NOTA: crear siempre con permissions=null, NUNCA {} —
  // Directus 12.2 evalúa un filtro {} como "no matchea nada" y da 403.
  services: ['read'],
  resources: ['read'],
  service_resources: ['read'],
  availability_rules: ['read'],
  availability_exceptions: ['read'],
  calendars: ['read'],
  locations: ['read'],
  // Base de conocimiento del negocio (colección editable por el gestor).
  // La rama `knowledge` del cerebro la lee entera (context-stuffing, sin RAG).
  knowledge: ['read'],
};

async function rawRequest(method, path, body = undefined, token = adminToken) {
  const headers = { Accept: 'application/json' };

  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = `Bearer ${token}`;

  const response = await fetch(`${BASE_URL}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const text = await response.text();

  let payload = null;
  if (text) {
    try { payload = JSON.parse(text); }
    catch { payload = text; }
  }

  return { response, payload };
}

async function request(method, path, body = undefined, token = adminToken) {
  const { response, payload } = await rawRequest(method, path, body, token);

  if (!response.ok) {
    throw new Error(
      `${method} ${path} -> HTTP ${response.status}: ${
        typeof payload === 'string' ? payload : JSON.stringify(payload)
      }`
    );
  }

  return payload;
}

async function loginAdmin() {
  const { response, payload } = await rawRequest(
    'POST',
    '/auth/login',
    {
      email: process.env.ADMIN_EMAIL,
      password: process.env.ADMIN_PASSWORD,
      mode: 'json',
    },
    null
  );

  if (!response.ok) throw new Error(`Login admin fallido: HTTP ${response.status}`);

  adminToken = payload?.data?.access_token;
  if (!adminToken) throw new Error('Directus no devolvió access_token admin.');

  console.log('Autenticación admin: OK');
}

async function findOne(path) {
  const result = await request('GET', path);
  const data = result?.data;

  if (!Array.isArray(data)) throw new Error(`Respuesta inesperada para ${path}`);
  if (data.length > 1) throw new Error(`Más de un resultado para ${path}`);

  return data[0] ?? null;
}

async function ensurePolicy() {
  let policy = await findOne(
    `/policies?filter[name][_eq]=${encodeURIComponent(policyName)}&limit=2`
  );

  if (!policy) {
    policy = (await request('POST', '/policies', {
      name: policyName,
      icon: 'automation',
      description: 'Least-privilege server-to-server access for tenant n8n.',
      admin_access: false,
      app_access: false,
      enforce_tfa: false,
    }))?.data;
    console.log('Policy creada.');
  } else {
    await request('PATCH', `/policies/${encodeURIComponent(policy.id)}`, {
      name: policyName,
      description: 'Least-privilege server-to-server access for tenant n8n.',
      admin_access: false,
      app_access: false,
      enforce_tfa: false,
    });
    console.log('Policy existente validada/actualizada.');
  }

  return policy;
}

async function ensurePermissions(policyId) {
  const existingResult = await request(
    'GET',
    `/permissions?filter[policy][_eq]=${encodeURIComponent(policyId)}&limit=-1`
  );

  const existing = Array.isArray(existingResult?.data) ? existingResult.data : [];
  const targetKeys = new Set();

  for (const [collection, actions] of Object.entries(permissionModel)) {
    for (const action of actions) {
      const key = `${collection}:${action}`;
      targetKeys.add(key);

      const matches = existing.filter(
        p => p.collection === collection && p.action === action
      );

      if (matches.length > 1) throw new Error(`Hay permisos duplicados para ${key}.`);

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
        await request('POST', '/permissions', payload);
        console.log(`Permiso creado: ${key}`);
      } else {
        await request(
          'PATCH',
          `/permissions/${encodeURIComponent(matches[0].id)}`,
          payload
        );
        console.log(`Permiso actualizado: ${key}`);
      }
    }
  }

  for (const permission of existing) {
    if (Object.prototype.hasOwnProperty.call(permissionModel, permission.collection)) {
      const key = `${permission.collection}:${permission.action}`;

      if (!targetKeys.has(key)) {
        await request(
          'DELETE',
          `/permissions/${encodeURIComponent(permission.id)}`
        );
        console.log(`Permiso no permitido eliminado: ${key}`);
      }
    }
  }
}

async function ensureRole() {
  let role = await findOne(
    `/roles?filter[name][_eq]=${encodeURIComponent(roleName)}&limit=2`
  );

  if (!role) {
    role = (await request('POST', '/roles', {
      name: roleName,
      icon: 'automation',
      description: 'Technical role for tenant n8n service identity.',
    }))?.data;
    console.log('Role creado.');
  } else {
    await request('PATCH', `/roles/${encodeURIComponent(role.id)}`, {
      name: roleName,
      icon: 'automation',
      description: 'Technical role for tenant n8n service identity.',
    });
    console.log('Role existente validado/actualizado.');
  }

  return role;
}

async function ensureUser() {
  let user = await findOne(
    `/users?filter[email][_eq]=${encodeURIComponent(serviceEmail)}&limit=2`
  );

  if (!user) {
    user = (await request('POST', '/users', {
      email: serviceEmail,
      password: crypto.randomUUID() + crypto.randomUUID(),
      first_name: 'n8n',
      last_name: 'Service',
      status: 'draft',
    }))?.data;
    console.log('Usuario técnico mínimo creado.');
  } else {
    await request('PATCH', `/users/${encodeURIComponent(user.id)}`, {
      first_name: 'n8n',
      last_name: 'Service',
    });
    console.log('Usuario técnico existente localizado.');
  }

  return user;
}

async function main() {
  await loginAdmin();

  const policy = await ensurePolicy();
  if (!policy?.id) throw new Error('No se pudo resolver el ID de la policy.');

  await ensurePermissions(policy.id);

  const role = await ensureRole();
  if (!role?.id) throw new Error('No se pudo resolver el ID del role.');

  const user = await ensureUser();
  if (!user?.id) throw new Error('No se pudo resolver el ID del usuario técnico.');

  console.log(`AEGORA_STATE\t${policy.id}\t${role.id}\t${user.id}`);
}

main().catch(error => {
  console.error(`ERROR: ${error.message}`);
  process.exitCode = 1;
});
NODE
)"

printf '%s\n' "$API_OUTPUT"

STATE_LINE="$(
  printf '%s\n' "$API_OUTPUT" |
    awk -F '\t' '$1 == "AEGORA_STATE" { line=$0 } END { print line }'
)"

[[ -n "$STATE_LINE" ]] || fail "No se recibió AEGORA_STATE desde Directus."

IFS=$'\t' read -r _state_marker POLICY_ID ROLE_ID USER_ID <<< "$STATE_LINE"

[[ "$POLICY_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || fail "POLICY_ID inválido: ${POLICY_ID}"
[[ "$ROLE_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || fail "ROLE_ID inválido: ${ROLE_ID}"
[[ "$USER_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || fail "USER_ID inválido: ${USER_ID}"

log "Configurando role -> policy y user -> role mediante SQL controlado."

ACCESS_ID="$(cat /proc/sys/kernel/random/uuid)"

docker exec \
  -i \
  "$DB_HOST" \
  psql \
    --username="$POSTGRES_ADMIN_USER" \
    --dbname="$DB_DATABASE" \
    --set=ON_ERROR_STOP=1 \
    --set=access_id="$ACCESS_ID" \
    --set=role_id="$ROLE_ID" \
    --set=policy_id="$POLICY_ID" \
    --set=user_id="$USER_ID" \
    >/dev/null <<'SQL'
BEGIN;

DELETE FROM directus_access
WHERE role = :'role_id'::uuid
  AND policy <> :'policy_id'::uuid;

DELETE FROM directus_access
WHERE "user" = :'user_id'::uuid;

INSERT INTO directus_access (
  id,
  role,
  "user",
  policy,
  sort
)
SELECT
  :'access_id'::uuid,
  :'role_id'::uuid,
  NULL,
  :'policy_id'::uuid,
  1
WHERE NOT EXISTS (
  SELECT 1
  FROM directus_access
  WHERE role = :'role_id'::uuid
    AND policy = :'policy_id'::uuid
    AND "user" IS NULL
);

UPDATE directus_users
SET role = :'role_id'::uuid
WHERE id = :'user_id'::uuid;

COMMIT;
SQL

log "Relación de acceso configurada."

log "Reiniciando Directus para invalidar caché de acceso."
docker restart "$DIRECTUS_CONTAINER" >/dev/null
wait_healthy "$DIRECTUS_CONTAINER" 120

log "Asignando static token, activando usuario y verificando permisos efectivos."

docker exec \
  -i \
  -e AEGORA_N8N_SERVICE_EMAIL="$SERVICE_EMAIL" \
  -e AEGORA_N8N_SERVICE_TOKEN="$SERVICE_TOKEN" \
  -e AEGORA_N8N_EXPECTED_ROLE_ID="$ROLE_ID" \
  "$DIRECTUS_CONTAINER" \
  node - <<'NODE'
'use strict';

const BASE_URL = 'http://127.0.0.1:8055';
const serviceEmail = process.env.AEGORA_N8N_SERVICE_EMAIL;
const serviceToken = process.env.AEGORA_N8N_SERVICE_TOKEN;
const expectedRoleId = process.env.AEGORA_N8N_EXPECTED_ROLE_ID;

const expectedPermissions = {
  contacts: ['create', 'read', 'update'],
  contact_phones: ['create', 'read', 'update'],
  tasks: ['create', 'read', 'update'],
  appointments: ['create', 'read', 'update'],
};

let adminToken = null;

async function rawRequest(method, path, body = undefined, token = adminToken) {
  const headers = { Accept: 'application/json' };

  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = `Bearer ${token}`;

  const response = await fetch(`${BASE_URL}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const text = await response.text();

  let payload = null;
  if (text) {
    try { payload = JSON.parse(text); }
    catch { payload = text; }
  }

  return { response, payload };
}

async function request(method, path, body = undefined, token = adminToken) {
  const { response, payload } = await rawRequest(method, path, body, token);

  if (!response.ok) {
    throw new Error(
      `${method} ${path} -> HTTP ${response.status}: ${
        typeof payload === 'string' ? payload : JSON.stringify(payload)
      }`
    );
  }

  return payload;
}

async function main() {
  const login = await rawRequest(
    'POST',
    '/auth/login',
    {
      email: process.env.ADMIN_EMAIL,
      password: process.env.ADMIN_PASSWORD,
      mode: 'json',
    },
    null
  );

  if (!login.response.ok) {
    throw new Error(`Login admin fallido: HTTP ${login.response.status}`);
  }

  adminToken = login.payload?.data?.access_token;

  const users = await request(
    'GET',
    `/users?filter[email][_eq]=${encodeURIComponent(serviceEmail)}&fields=id,email,status,role.id&limit=2`
  );

  const user = users?.data?.[0];
  if (!user?.id) throw new Error('No se pudo localizar el usuario técnico.');

  const actualRoleId =
    typeof user.role === 'object' ? user.role?.id : user.role;

  if (actualRoleId !== expectedRoleId) {
    throw new Error(
      `Role incorrecto. Esperado=${expectedRoleId}, actual=${actualRoleId}`
    );
  }

  await request(
    'PATCH',
    `/users/${encodeURIComponent(user.id)}`,
    {
      token: serviceToken,
      status: 'active',
      first_name: 'n8n',
      last_name: 'Service',
    }
  );

  const permissions = await request(
    'GET',
    '/permissions/me',
    undefined,
    serviceToken
  );

  for (const [collection, actions] of Object.entries(expectedPermissions)) {
    for (const action of actions) {
      const access = permissions?.data?.[collection]?.[action]?.access;

      if (access !== 'full') {
        throw new Error(
          `Permiso efectivo incorrecto: ${collection}.${action}=${access}`
        );
      }
    }

    for (const forbidden of ['delete', 'share']) {
      const access = permissions?.data?.[collection]?.[forbidden]?.access;

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
  console.log('Role inheritance: OK');
  console.log('Permisos efectivos C/R/U: OK');
  console.log('Delete/share: NO ACCESS');
}

main().catch(error => {
  console.error(`ERROR: ${error.message}`);
  process.exitCode = 1;
});
NODE

[[ -s "$SECRET_FILE" ]] || fail "El fichero secreto no existe o está vacío."
[[ "$(stat -c '%U:%G' "$SECRET_FILE")" == "root:root" ]] || fail "Ownership incorrecto en ${SECRET_FILE}"
[[ "$(stat -c '%a' "$SECRET_FILE")" == "600" ]] || fail "Permisos incorrectos en ${SECRET_FILE}"

SECRET_CREATED=false

log "Identidad técnica n8n configurada correctamente."

cat <<EOF

============================================================
DIRECTUS N8N SERVICE CONFIGURADO
============================================================

Tenant:
  ${TENANT_ID}

Service user:
  ${SERVICE_EMAIL}

Role:
  ${ROLE_NAME}

Policy:
  ${POLICY_NAME}

Permissions:
  create/read/update sobre:
    contacts
    contact_phones
    tasks
    appointments

No concedido:
  delete
  share
  admin access
  Data Studio access

Token:
  ${SECRET_FILE}

Estado:
  OK

============================================================
EOF
