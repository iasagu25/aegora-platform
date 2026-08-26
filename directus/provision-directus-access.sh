#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly TECHNICAL_EMAIL="directus-provisioning@aegora.es"

TENANT=""
APPLY=false

log() {
  printf '[%s] %s\n' \
    "$(date --iso-8601=seconds)" \
    "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Uso:

  provision-directus-access.sh \
    --tenant TENANT \
    [--apply]

Sin --apply:
  valida el estado actual y muestra las acciones necesarias.

Con --apply:
  garantiza una credencial técnica estable para el provisioning
  de Directus y la guarda en:

    <tenant>/secrets/directus-provisioning.env
EOF
}

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

[[ -n "$TENANT" ]] ||
  fail "Falta --tenant."

[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] ||
  fail "Tenant inválido: ${TENANT}"

[[ "$TENANT" != "aegora" ]] ||
  fail "El tenant legacy 'aegora' está protegido."

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"
PROVISIONING_SECRET="${TENANT_ROOT}/secrets/directus-provisioning.env"

[[ -f "$TENANT_CONFIG" ]] ||
  fail "Falta ${TENANT_CONFIG}"

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

docker inspect "$DIRECTUS_CONTAINER" >/dev/null 2>&1 ||
  fail "No existe el contenedor ${DIRECTUS_CONTAINER}."

[[ "$(
  docker inspect \
    --format '{{.State.Status}}' \
    "$DIRECTUS_CONTAINER"
)" == "running" ]] ||
  fail "Directus no está running."

cat <<EOF

============================================================
AEGORA · DIRECTUS TECHNICAL ACCESS
============================================================

Tenant:
  ${TENANT_ID}

Directus:
  ${DIRECTUS_CONTAINER}

Usuario técnico:
  ${TECHNICAL_EMAIL}

Secret:
  ${PROVISIONING_SECRET}

Modo:
  $([[ "$APPLY" == true ]] && echo APPLY || echo PLAN)

============================================================

EOF

#
# Existing managed credential
#

if [[ -f "$PROVISIONING_SECRET" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$PROVISIONING_SECRET"
  set +a

  : "${DIRECTUS_PROVISIONING_TOKEN:?Falta DIRECTUS_PROVISIONING_TOKEN}"

  docker exec \
    -e DIRECTUS_PROVISIONING_TOKEN="$DIRECTUS_PROVISIONING_TOKEN" \
    -e EXPECTED_EMAIL="$TECHNICAL_EMAIL" \
    "$DIRECTUS_CONTAINER" \
    node - <<'NODE'
const base = 'http://127.0.0.1:8055';

async function main() {
  const token = process.env.DIRECTUS_PROVISIONING_TOKEN;
  const expected = process.env.EXPECTED_EMAIL;

  const response = await fetch(
    `${base}/users/me?fields=id,email,status`,
    {
      headers: {
        Authorization: `Bearer ${token}`
      }
    }
  );

  if (!response.ok) {
    throw new Error(
      `Credencial técnica inválida: HTTP ${response.status}`
    );
  }

  const body = await response.json();

  if (body?.data?.email !== expected) {
    throw new Error(
      `La credencial pertenece a ${body?.data?.email ?? 'usuario desconocido'}`
    );
  }

  if (body?.data?.status !== 'active') {
    throw new Error(
      'El usuario técnico no está activo.'
    );
  }

  console.log(
    `Credencial técnica Directus: OK (${body.data.email})`
  );
}

main().catch(error => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
NODE

  log "Provisioning técnico ya configurado."
  exit 0
fi

#
# No managed credential yet
#

if [[ "$APPLY" != true ]]; then
  log "PLAN: no existe credencial técnica administrada."
  log "PLAN: en APPLY se creará o adoptará el usuario técnico y se generará su token."
  exit 0
fi

#
# Bootstrap credentials stay inside Directus container.
#

BOOTSTRAP_STATE="$(
  docker exec \
    "$DIRECTUS_CONTAINER" \
    sh -c '
      if [ -n "${ADMIN_EMAIL:-}" ] &&
         [ -n "${ADMIN_PASSWORD:-}" ]; then
        printf loaded
      else
        printf missing
      fi
    '
)"

[[ "$BOOTSTRAP_STATE" == "loaded" ]] ||
  fail "Las credenciales bootstrap no están disponibles en Directus."

#
# Generate token on host. It will never be printed.
#

DIRECTUS_PROVISIONING_TOKEN="$(
  openssl rand -hex 32
)"

#
# Bootstrap through Directus API.
#

docker exec \
  -i \
  -e TECHNICAL_EMAIL="$TECHNICAL_EMAIL" \
  -e NEW_STATIC_TOKEN="$DIRECTUS_PROVISIONING_TOKEN" \
  "$DIRECTUS_CONTAINER" \
  node - <<'NODE'
'use strict';

const base = 'http://127.0.0.1:8055';

async function parse(response) {
  const text = await response.text();

  if (!text) return null;

  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

async function main() {
  const technicalEmail = process.env.TECHNICAL_EMAIL;
  const staticToken = process.env.NEW_STATIC_TOKEN;

  const adminEmail = process.env.ADMIN_EMAIL;
  const adminPassword = process.env.ADMIN_PASSWORD;

  if (!adminEmail || !adminPassword) {
    throw new Error(
      'Credenciales bootstrap no disponibles.'
    );
  }

  const login = await fetch(`${base}/auth/login`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      email: adminEmail,
      password: adminPassword
    })
  });

  const loginBody = await parse(login);

  if (!login.ok) {
    throw new Error(
      `Login bootstrap fallido: HTTP ${login.status}`
    );
  }

  const adminToken = loginBody?.data?.access_token;

  if (!adminToken) {
    throw new Error(
      'Directus no devolvió access_token bootstrap.'
    );
  }

  const headers = {
    Authorization: `Bearer ${adminToken}`,
    'Content-Type': 'application/json'
  };

  const rolesResponse = await fetch(
    `${base}/roles?filter[name][_eq]=Administrator&fields=id,name`,
    { headers }
  );

  const rolesBody = await parse(rolesResponse);

  if (!rolesResponse.ok) {
    throw new Error(
      `No se pudo localizar rol Administrator: HTTP ${rolesResponse.status}`
    );
  }

  if (!Array.isArray(rolesBody?.data) ||
      rolesBody.data.length !== 1) {
    throw new Error(
      'No existe exactamente un rol Administrator.'
    );
  }

  const administratorRole = rolesBody.data[0].id;

  const usersResponse = await fetch(
    `${base}/users?filter[email][_eq]=${encodeURIComponent(technicalEmail)}&fields=id,email,status,role`,
    { headers }
  );

  const usersBody = await parse(usersResponse);

  if (!usersResponse.ok) {
    throw new Error(
      `No se pudo consultar usuario técnico: HTTP ${usersResponse.status}`
    );
  }

  let technicalUser;

  if (usersBody.data.length === 0) {
    const createResponse = await fetch(
      `${base}/users`,
      {
        method: 'POST',
        headers,
        body: JSON.stringify({
          email: technicalEmail,
          status: 'active',
          role: administratorRole,
          token: staticToken
        })
      }
    );

    const createBody = await parse(createResponse);

    if (!createResponse.ok) {
      throw new Error(
        `USER CREATE HTTP ${createResponse.status}: ${
          typeof createBody === 'string'
            ? createBody
            : JSON.stringify(createBody)
        }`
      );
    }

    technicalUser = createBody.data;

    console.log(
      `Usuario técnico creado: ${technicalEmail}`
    );
  } else if (usersBody.data.length === 1) {
    technicalUser = usersBody.data[0];

    const patchResponse = await fetch(
      `${base}/users/${technicalUser.id}`,
      {
        method: 'PATCH',
        headers,
        body: JSON.stringify({
          status: 'active',
          role: administratorRole,
          token: staticToken
        })
      }
    );

    const patchBody = await parse(patchResponse);

    if (!patchResponse.ok) {
      throw new Error(
        `USER PATCH HTTP ${patchResponse.status}: ${
          typeof patchBody === 'string'
            ? patchBody
            : JSON.stringify(patchBody)
        }`
      );
    }

    console.log(
      `Usuario técnico adoptado: ${technicalEmail}`
    );
  } else {
    throw new Error(
      'Existe más de un usuario con el email técnico.'
    );
  }

  const verify = await fetch(
    `${base}/users/me?fields=id,email,status`,
    {
      headers: {
        Authorization: `Bearer ${staticToken}`
      }
    }
  );

  const verifyBody = await parse(verify);

  if (!verify.ok) {
    throw new Error(
      `Verificación del static token falló: HTTP ${verify.status}`
    );
  }

  if (verifyBody?.data?.email !== technicalEmail ||
      verifyBody?.data?.status !== 'active') {
    throw new Error(
      'La identidad técnica verificada no coincide.'
    );
  }

  console.log(
    `Static token verificado: ${technicalEmail}`
  );
}

main().catch(error => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
NODE

#
# Persist only after API verification succeeded.
#

install -d \
  -m 700 \
  "${TENANT_ROOT}/secrets"

umask 077

cat > "$PROVISIONING_SECRET" <<EOF
DIRECTUS_PROVISIONING_TOKEN='${DIRECTUS_PROVISIONING_TOKEN}'
EOF

chmod 600 "$PROVISIONING_SECRET"

#
# Final verification from persisted credential.
#

set -a
# shellcheck disable=SC1090
source "$PROVISIONING_SECRET"
set +a

docker exec \
  -e DIRECTUS_PROVISIONING_TOKEN="$DIRECTUS_PROVISIONING_TOKEN" \
  -e EXPECTED_EMAIL="$TECHNICAL_EMAIL" \
  "$DIRECTUS_CONTAINER" \
  node - <<'NODE'
const base = 'http://127.0.0.1:8055';

async function main() {
  const response = await fetch(
    `${base}/users/me?fields=id,email,status`,
    {
      headers: {
        Authorization:
          `Bearer ${process.env.DIRECTUS_PROVISIONING_TOKEN}`
      }
    }
  );

  if (!response.ok) {
    throw new Error(
      `Verificación final falló: HTTP ${response.status}`
    );
  }

  const body = await response.json();

  if (body?.data?.email !== process.env.EXPECTED_EMAIL ||
      body?.data?.status !== 'active') {
    throw new Error(
      'Identidad técnica final incorrecta.'
    );
  }

  console.log(
    `Verificación final: OK (${body.data.email})`
  );
}

main().catch(error => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
NODE

unset DIRECTUS_PROVISIONING_TOKEN

log "Credencial técnica Directus provisionada correctamente."
