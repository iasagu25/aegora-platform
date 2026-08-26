#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_DIRECTUS_VERSION="12.2.0"
TENANTS_ROOT="/opt/aegora/tenants"

TENANT=""
APPLY=false

TENANT_ROOT=""
TENANT_CONFIG=""
DIRECTUS_PROVISIONING_SECRET=""
DIRECTUS_PROVISIONING_TOKEN=""

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Uso:
  configure-directus-ui.sh --tenant TENANT [--apply]

Opciones:
  --tenant TENANT   Tenant a configurar.
  --apply           Aplica los cambios. Sin esta opción funciona en DRY RUN.
  -h, --help        Muestra esta ayuda.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      [[ $# -ge 2 ]] || die "Falta valor para --tenant."
      TENANT="$2"
      shift 2
      ;;
    --apply)
      APPLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Argumento desconocido: $1"
      ;;
  esac
done

[[ -n "$TENANT" ]] || die "Debes indicar --tenant."

[[ "$TENANT" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
  || die "Tenant inválido: $TENANT"

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"
DIRECTUS_PROVISIONING_SECRET="${TENANT_ROOT}/secrets/directus-provisioning.env"

[[ -f "$TENANT_CONFIG" ]] \
  || die "Falta configuración del tenant: $TENANT_CONFIG"

[[ -f "$DIRECTUS_PROVISIONING_SECRET" ]] \
  || die "Falta credencial técnica Directus: $DIRECTUS_PROVISIONING_SECRET"

set -a

# shellcheck disable=SC1090
source "$TENANT_CONFIG"

# shellcheck disable=SC1090
source "$DIRECTUS_PROVISIONING_SECRET"

set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"
: "${DIRECTUS_PROVISIONING_TOKEN:?Falta DIRECTUS_PROVISIONING_TOKEN}"

[[ "$TENANT_ID" == "$TENANT" ]] \
  || die "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

docker inspect "$DIRECTUS_CONTAINER" >/dev/null 2>&1 \
  || die "No existe el contenedor $DIRECTUS_CONTAINER."

HEALTH="$(
  docker inspect "$DIRECTUS_CONTAINER" \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
)"

[[ "$HEALTH" == "healthy" ]] \
  || die "Directus no está healthy. Estado=$HEALTH"

ACTUAL_DIRECTUS_VERSION="$(
  docker exec "$DIRECTUS_CONTAINER" \
    node /directus/cli.js --version 2>/dev/null \
    | tail -n 1 \
    | tr -d '\r'
)"

[[ "$ACTUAL_DIRECTUS_VERSION" == "$EXPECTED_DIRECTUS_VERSION" ]] \
  || die "Versión Directus incorrecta. Esperada=$EXPECTED_DIRECTUS_VERSION, actual=$ACTUAL_DIRECTUS_VERSION"

MODE="DRY RUN"
$APPLY && MODE="APPLY"

cat <<EOF_HEADER

============================================================
AEGORA · DIRECTUS UI
============================================================

Tenant:
  $TENANT

Directus:
  container: $DIRECTUS_CONTAINER
  version:   $ACTUAL_DIRECTUS_VERSION
  health:    $HEALTH

UI administrada:

  contacts.phones
    display:         aegora-phone-display
    display_options: null

  employees.phone
    display:         field-actions
    display_options:
      showCopy:       true
      linkPrefix:     tel:
      linkButtonLabel: null
      showLink:       true

Modo:
  $MODE

============================================================

EOF_HEADER

docker exec -i \
  -e AEGORA_APPLY="$APPLY" \
  -e DIRECTUS_PROVISIONING_TOKEN="$DIRECTUS_PROVISIONING_TOKEN" \
  "$DIRECTUS_CONTAINER" \
  node - <<'NODE'
'use strict';

const BASE_URL = 'http://127.0.0.1:8055';
const APPLY = process.env.AEGORA_APPLY === 'true';

const adminToken = process.env.DIRECTUS_PROVISIONING_TOKEN;

if (!adminToken) {
  throw new Error(
    'DIRECTUS_PROVISIONING_TOKEN no está disponible.'
  );
}

const uiModel = [
  {
    collection: 'contacts',
    field: 'phones',
    meta: {
      display: 'aegora-phone-display',
      display_options: null,
    },
  },
  {
    collection: 'employees',
    field: 'phone',
    meta: {
      display: 'field-actions',
      display_options: {
        showCopy: true,
        linkPrefix: 'tel:',
        linkButtonLabel: null,
        showLink: true,
      },
    },
  },
  {
    collection: 'employees',
    field: 'phone_normalized',
    meta: {
      hidden: true,
      readonly: true,
    },
  },
];

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
    body:
      body === undefined
        ? undefined
        : JSON.stringify(body),
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

async function verifyProvisioningAuth() {
  const { response, payload } = await rawRequest(
    'GET',
    '/users/me?fields=id,email,status',
    undefined,
    adminToken
  );

  if (!response.ok) {
    throw new Error(
      `Credencial técnica Directus inválida: HTTP ${response.status}`
    );
  }

  if (payload?.data?.status !== 'active') {
    throw new Error(
      'El usuario técnico Directus no está activo.'
    );
  }

  console.log(
    `Autenticación técnica Directus: OK (${payload.data.email})`
  );
}

async function getField(collection, field) {
  const result = await request(
    'GET',
    `/fields/${encodeURIComponent(collection)}/${encodeURIComponent(field)}`
  );

  if (!result?.data) {
    throw new Error(
      `No se pudo obtener ${collection}.${field}.`
    );
  }

  return result.data;
}

function normalize(value) {
  return value === undefined ? null : value;
}

function getDifferences(field, target) {
  const currentMeta = field.meta ?? {};
  const differences = [];

  for (const [key, expected] of Object.entries(target.meta)) {
    const current = normalize(currentMeta[key]);
    const wanted = normalize(expected);

    if (JSON.stringify(current) !== JSON.stringify(wanted)) {
      differences.push({
        key,
        current,
        expected: wanted,
      });
    }
  }

  return differences;
}

async function configureField(target) {
  const {
    collection,
    field,
  } = target;

  const current = await getField(
    collection,
    field
  );

  const differences = getDifferences(
    current,
    target
  );

  console.log('');
  console.log(`${collection}.${field}`);

  if (differences.length === 0) {
    console.log('  Estado: OK');
    return false;
  }

  for (const diff of differences) {
    console.log(
      `  ${diff.key}: ${JSON.stringify(diff.current)} -> ${JSON.stringify(diff.expected)}`
    );
  }

  if (!APPLY) {
    console.log('  Estado: cambio pendiente');
    return true;
  }

  await request(
    'PATCH',
    `/fields/${encodeURIComponent(collection)}/${encodeURIComponent(field)}`,
    {
      meta: target.meta,
    }
  );

  console.log('  Estado: actualizado');

  return true;
}

async function verifyField(target) {
  const current = await getField(
    target.collection,
    target.field
  );

  const differences = getDifferences(
    current,
    target
  );

  if (differences.length !== 0) {
    throw new Error(
      `Verificación fallida para ${target.collection}.${target.field}: ` +
      differences
        .map(
          (diff) =>
            `${diff.key}=${JSON.stringify(diff.current)} ` +
            `(esperado ${JSON.stringify(diff.expected)})`
        )
        .join(', ')
    );
  }

  console.log(
    `Verificado: ${target.collection}.${target.field}`
  );
}

async function main() {
  await verifyProvisioningAuth();

  let changes = 0;

  for (const target of uiModel) {
    const changed = await configureField(target);

    if (changed) {
      changes += 1;
    }
  }

  console.log('');

  if (!APPLY) {
    if (changes === 0) {
      console.log('DRY RUN: configuración UI ya correcta.');
    } else {
      console.log(
        `DRY RUN: ${changes} campo(s) requieren cambios.`
      );
    }

    return;
  }

  console.log('Verificando configuración aplicada.');

  for (const target of uiModel) {
    await verifyField(target);
  }

  console.log('');
  console.log('==============================================');
  console.log('DIRECTUS UI CONFIGURADA CORRECTAMENTE');
  console.log('==============================================');
}

main().catch((error) => {
  console.error('');
  console.error(`ERROR: ${error.message}`);
  process.exitCode = 1;
});
NODE

log "Configuración UI Directus finalizada."
