#!/usr/bin/env bash
set -Eeuo pipefail

EXPECTED_DIRECTUS_VERSION="12.2.0"

TENANT=""
APPLY=false

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

DIRECTUS_CONTAINER="${TENANT}-directus"

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

Modo:
  $MODE

============================================================

EOF_HEADER

docker exec -i \
  -e AEGORA_APPLY="$APPLY" \
  "$DIRECTUS_CONTAINER" \
  node - <<'NODE'
'use strict';

const BASE_URL = 'http://127.0.0.1:8055';
const APPLY = process.env.AEGORA_APPLY === 'true';

let adminToken = null;

const uiModel = [
  {
    collection: 'contacts',
    field: 'phones',
    meta: {
      display: 'aegora-phone-display',
      display_options: null,
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

async function loginAdmin() {
  const email = process.env.ADMIN_EMAIL;
  const password = process.env.ADMIN_PASSWORD;

  if (!email || !password) {
    throw new Error(
      'ADMIN_EMAIL / ADMIN_PASSWORD no están disponibles en el contenedor.'
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

  console.log('Autenticación Directus: OK');
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
  await loginAdmin();

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
