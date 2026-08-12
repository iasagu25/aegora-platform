#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Paths
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly TEMPLATE_ROOT="${PLATFORM_ROOT}/templates/tenant-stack"

readonly RENDERER="${PLATFORM_ROOT}/provisioning/tenant/render-template.py"

readonly POSTGRES_CONTAINER="aegora-postgres"

# =============================================================================
# Defaults
# =============================================================================

TENANT_ID=""
TENANT_NAME=""
BASE_DOMAIN=""

DIRECTUS_ADMIN_EMAIL=""

DIRECTUS_VERSION="${DIRECTUS_VERSION:-11}"
N8N_VERSION="${N8N_VERSION:-2.31.7}"

APPLY=false

# =============================================================================
# Utilidades
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

usage() {
  cat <<'EOF'
Uso:

  create-tenant.sh \
    --tenant ID \
    --name "Nombre cliente" \
    --domain example.es \
    --admin-email admin@example.es \
    [--apply]

Sin --apply:
  muestra el plan y no modifica nada.

Con --apply:
  - genera secretos;
  - crea directorios;
  - crea usuario y bases PostgreSQL;
  - crea red Docker privada;
  - conecta PostgreSQL a la red;
  - genera tenant.env;
  - genera backup.manifest.json;
  - genera Compose Directus;
  - genera Compose n8n;
  - no arranca todavía los servicios.

Ejemplo:

  sudo ./create-tenant.sh \
    --tenant gestoria-demo \
    --name "Gestoría Demo" \
    --domain gestoria-demo.es \
    --admin-email admin@gestoria-demo.es \
    --apply
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "Falta el comando requerido: $1"
}

generate_hex() {
  local bytes="$1"

  openssl rand -hex "$bytes"
}

generate_password() {
  openssl rand -base64 36 |
    tr -d '\n'
}

sql_identifier() {
  printf '%s' "$1" |
    tr '-' '_' |
    tr -cd 'a-zA-Z0-9_'
}

database_exists() {
  local database="$1"

  docker exec "$POSTGRES_CONTAINER" \
    psql \
      --username=postgres \
      --dbname=postgres \
      --tuples-only \
      --no-align \
      --command="
        SELECT 1
        FROM pg_database
        WHERE datname = '${database}';
      " |
    tr -d '[:space:]'
}

role_exists() {
  local role="$1"

  docker exec "$POSTGRES_CONTAINER" \
    psql \
      --username=postgres \
      --dbname=postgres \
      --tuples-only \
      --no-align \
      --command="
        SELECT 1
        FROM pg_roles
        WHERE rolname = '${role}';
      " |
    tr -d '[:space:]'
}

create_role() {
  local role="$1"
  local password="$2"

  if [[ "$(role_exists "$role")" == "1" ]]; then
    fail "El rol PostgreSQL ya existe: ${role}"
  fi

  docker exec "$POSTGRES_CONTAINER" \
    psql \
      --username=postgres \
      --dbname=postgres \
      --set=ON_ERROR_STOP=1 \
      --set=role="$role" \
      --set=password="$password" \
      --command="
        CREATE ROLE :\"role\"
        LOGIN
        PASSWORD :'password';
      "
}

create_database() {
  local database="$1"
  local owner="$2"

  if [[ "$(database_exists "$database")" == "1" ]]; then
    fail "La base PostgreSQL ya existe: ${database}"
  fi

  docker exec "$POSTGRES_CONTAINER" \
    createdb \
      --username=postgres \
      --owner="$owner" \
      "$database"
}

# =============================================================================
# Argumentos
# =============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      [[ $# -ge 2 ]] ||
        fail "Falta valor para --tenant"

      TENANT_ID="$2"
      shift 2
      ;;

    --name)
      [[ $# -ge 2 ]] ||
        fail "Falta valor para --name"

      TENANT_NAME="$2"
      shift 2
      ;;

    --domain)
      [[ $# -ge 2 ]] ||
        fail "Falta valor para --domain"

      BASE_DOMAIN="$2"
      shift 2
      ;;

    --admin-email)
      [[ $# -ge 2 ]] ||
        fail "Falta valor para --admin-email"

      DIRECTUS_ADMIN_EMAIL="$2"
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
# Validación
# =============================================================================

[[ -n "$TENANT_ID" ]] ||
  fail "Falta --tenant."

[[ -n "$TENANT_NAME" ]] ||
  fail "Falta --name."

[[ -n "$BASE_DOMAIN" ]] ||
  fail "Falta --domain."

[[ -n "$DIRECTUS_ADMIN_EMAIL" ]] ||
  fail "Falta --admin-email."

[[ "$TENANT_ID" =~ ^[a-z][a-z0-9-]{2,30}$ ]] ||
  fail \
    "TENANT_ID debe usar minúsculas, números y guiones."

[[ "$BASE_DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
  fail "Dominio inválido: ${BASE_DOMAIN}"

[[ "$DIRECTUS_ADMIN_EMAIL" == *@*.* ]] ||
  fail "Email inválido: ${DIRECTUS_ADMIN_EMAIL}"

[[ "$TENANT_ID" != "aegora" ]] ||
  fail "El tenant 'aegora' está reservado."

require_command docker
require_command openssl
require_command python3

[[ -f "$RENDERER" ]] ||
  fail "Falta renderer: ${RENDERER}"

# =============================================================================
# Variables derivadas
# =============================================================================

tenant_sql_id="$(
  sql_identifier "$TENANT_ID"
)"

TENANT_ROOT="${TENANTS_ROOT}/${TENANT_ID}"
CUSTOMER_ROOT="${PLATFORM_ROOT}/customers/${TENANT_ID}"

TENANT_COMPOSE_ROOT="${CUSTOMER_ROOT}/compose"

DIRECTUS_DATA_DIR="${TENANT_ROOT}/data/directus"
N8N_DATA_DIR="${TENANT_ROOT}/data/n8n"
BOOKING_DATA_DIR="${TENANT_ROOT}/data/booking"

TENANT_DATA_ROOT="${TENANT_ROOT}/data"

TENANT_SECRETS_DIR="${TENANT_ROOT}/secrets"
TENANT_BACKUP_DIR="${TENANT_ROOT}/backups"

TENANT_BACKEND_NETWORK="tenant_${tenant_sql_id}_backend"

DIRECTUS_CONTAINER="${TENANT_ID}-directus"
N8N_CONTAINER="${TENANT_ID}-n8n"
BOOKING_CONTAINER="${TENANT_ID}-booking"

DIRECTUS_HOST="panel.${BASE_DOMAIN}"
N8N_HOST="n8n.${BASE_DOMAIN}"
BOOKING_HOST="reservas.${BASE_DOMAIN}"

POSTGRES_DIRECTUS_DB="directus_${tenant_sql_id}"
POSTGRES_N8N_DB="n8n_${tenant_sql_id}"
POSTGRES_BOOKING_DB="booking_${tenant_sql_id}"

POSTGRES_DIRECTUS_USER="directus_${tenant_sql_id}"
POSTGRES_N8N_USER="n8n_${tenant_sql_id}"
POSTGRES_BOOKING_USER="booking_${tenant_sql_id}"

BACKUP_BUCKET="aegora-${TENANT_ID}-backups"

BACKUP_HOST="${TENANT_ID}"
BACKUP_TAG_TENANT="tenant=${TENANT_ID}"
BACKUP_TAG_ENVIRONMENT="environment=production"

# =============================================================================
# Plan
# =============================================================================

cat <<EOF

============================================================
AEGORA TENANT PROVISIONING
============================================================

Tenant:
  ID:              ${TENANT_ID}
  Nombre:          ${TENANT_NAME}
  Dominio:         ${BASE_DOMAIN}

Endpoints:
  Directus:        https://${DIRECTUS_HOST}
  n8n:             https://${N8N_HOST}
  Booking:         https://${BOOKING_HOST}

PostgreSQL:
  Directus DB:     ${POSTGRES_DIRECTUS_DB}
  n8n DB:          ${POSTGRES_N8N_DB}
  Booking DB:      ${POSTGRES_BOOKING_DB}

Docker:
  Directus:        ${DIRECTUS_CONTAINER}
  n8n:             ${N8N_CONTAINER}
  Booking:         ${BOOKING_CONTAINER}
  Backend network: ${TENANT_BACKEND_NETWORK}

Filesystem:
  ${TENANT_ROOT}

Config:
  ${CUSTOMER_ROOT}

Backup bucket:
  ${BACKUP_BUCKET}

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha modificado el sistema."
  log "Añade --apply para ejecutar el provisioning."
  exit 0
fi

# =============================================================================
# Protección frente a duplicados
# =============================================================================

[[ ! -e "$TENANT_ROOT" ]] ||
  fail "Ya existe ${TENANT_ROOT}"

[[ ! -e "$CUSTOMER_ROOT" ]] ||
  fail "Ya existe ${CUSTOMER_ROOT}"

docker inspect "$DIRECTUS_CONTAINER" >/dev/null 2>&1 &&
  fail "Ya existe ${DIRECTUS_CONTAINER}"

docker inspect "$N8N_CONTAINER" >/dev/null 2>&1 &&
  fail "Ya existe ${N8N_CONTAINER}"

# =============================================================================
# Generar secretos
# =============================================================================

log "Generando secretos."

DIRECTUS_KEY="$(generate_hex 32)"
DIRECTUS_SECRET="$(generate_hex 32)"
DIRECTUS_ADMIN_PASSWORD="$(generate_password)"

N8N_ENCRYPTION_KEY="$(generate_hex 32)"

POSTGRES_DIRECTUS_PASSWORD="$(generate_password)"
POSTGRES_N8N_PASSWORD="$(generate_password)"
POSTGRES_BOOKING_PASSWORD="$(generate_password)"

# =============================================================================
# Crear filesystem
# =============================================================================

log "Creando estructura del tenant."

mkdir -p \
  "${DIRECTUS_DATA_DIR}/uploads" \
  "${DIRECTUS_DATA_DIR}/extensions" \
  "${N8N_DATA_DIR}/storage" \
  "${N8N_DATA_DIR}/files" \
  "$BOOKING_DATA_DIR" \
  "$TENANT_SECRETS_DIR" \
  "$TENANT_BACKUP_DIR" \
  "${TENANT_COMPOSE_ROOT}/directus" \
  "${TENANT_COMPOSE_ROOT}/n8n"

chmod 700 \
  "$TENANT_ROOT" \
  "$TENANT_SECRETS_DIR" \
  "$TENANT_BACKUP_DIR"

# =============================================================================
# PostgreSQL
# =============================================================================

log "Creando roles PostgreSQL."

create_role \
  "$POSTGRES_DIRECTUS_USER" \
  "$POSTGRES_DIRECTUS_PASSWORD"

create_role \
  "$POSTGRES_N8N_USER" \
  "$POSTGRES_N8N_PASSWORD"

create_role \
  "$POSTGRES_BOOKING_USER" \
  "$POSTGRES_BOOKING_PASSWORD"

log "Creando bases PostgreSQL."

create_database \
  "$POSTGRES_DIRECTUS_DB" \
  "$POSTGRES_DIRECTUS_USER"

create_database \
  "$POSTGRES_N8N_DB" \
  "$POSTGRES_N8N_USER"

create_database \
  "$POSTGRES_BOOKING_DB" \
  "$POSTGRES_BOOKING_USER"

# =============================================================================
# Docker network
# =============================================================================

if docker network inspect "$TENANT_BACKEND_NETWORK" >/dev/null 2>&1; then
  fail "La red Docker ya existe: ${TENANT_BACKEND_NETWORK}"
fi

log "Creando red Docker privada."

docker network create \
  "$TENANT_BACKEND_NETWORK" \
  >/dev/null

log "Conectando PostgreSQL a la red del tenant."

docker network connect \
  "$TENANT_BACKEND_NETWORK" \
  "$POSTGRES_CONTAINER"

# =============================================================================
# Exportar variables para templates
# =============================================================================

export \
  TENANT_ID \
  TENANT_NAME \
  BASE_DOMAIN \
  TENANT_ROOT \
  TENANT_DATA_ROOT \
  TENANT_COMPOSE_ROOT \
  TENANT_BACKEND_NETWORK \
  DIRECTUS_VERSION \
  DIRECTUS_CONTAINER \
  DIRECTUS_HOST \
  DIRECTUS_DATA_DIR \
  DIRECTUS_KEY \
  DIRECTUS_SECRET \
  DIRECTUS_ADMIN_EMAIL \
  DIRECTUS_ADMIN_PASSWORD \
  N8N_VERSION \
  N8N_CONTAINER \
  N8N_HOST \
  N8N_DATA_DIR \
  N8N_ENCRYPTION_KEY \
  BOOKING_CONTAINER \
  BOOKING_HOST \
  BOOKING_DATA_DIR \
  POSTGRES_DIRECTUS_DB \
  POSTGRES_DIRECTUS_USER \
  POSTGRES_DIRECTUS_PASSWORD \
  POSTGRES_N8N_DB \
  POSTGRES_N8N_USER \
  POSTGRES_N8N_PASSWORD \
  POSTGRES_BOOKING_DB \
  POSTGRES_BOOKING_USER \
  POSTGRES_BOOKING_PASSWORD \
  BACKUP_BUCKET \
  BACKUP_HOST \
  BACKUP_TAG_TENANT \
  BACKUP_TAG_ENVIRONMENT

# =============================================================================
# Generar Compose
# =============================================================================

log "Generando Compose Directus."

python3 "$RENDERER" \
  "${TEMPLATE_ROOT}/directus/compose.yml.tpl" \
  "${TENANT_COMPOSE_ROOT}/directus/compose.yml"

python3 "$RENDERER" \
  "${TEMPLATE_ROOT}/directus/.env.tpl" \
  "${TENANT_COMPOSE_ROOT}/directus/.env"

log "Generando Compose n8n."

python3 "$RENDERER" \
  "${TEMPLATE_ROOT}/n8n/compose.yml.tpl" \
  "${TENANT_COMPOSE_ROOT}/n8n/compose.yml"

python3 "$RENDERER" \
  "${TEMPLATE_ROOT}/n8n/.env.tpl" \
  "${TENANT_COMPOSE_ROOT}/n8n/.env"

chmod 600 \
  "${TENANT_COMPOSE_ROOT}/directus/.env" \
  "${TENANT_COMPOSE_ROOT}/n8n/.env"

chmod 644 \
  "${TENANT_COMPOSE_ROOT}/directus/compose.yml" \
  "${TENANT_COMPOSE_ROOT}/n8n/compose.yml"

# =============================================================================
# tenant.env
# =============================================================================

log "Generando tenant.env."

cat > "${CUSTOMER_ROOT}/tenant.env" <<EOF
TENANT_ID=${TENANT_ID}
TENANT_NAME=${TENANT_NAME}
ENVIRONMENT=production

BASE_DOMAIN=${BASE_DOMAIN}

DIRECTUS_HOST=${DIRECTUS_HOST}
N8N_HOST=${N8N_HOST}
BOOKING_HOST=${BOOKING_HOST}

DIRECTUS_CONTAINER=${DIRECTUS_CONTAINER}
N8N_CONTAINER=${N8N_CONTAINER}
BOOKING_CONTAINER=${BOOKING_CONTAINER}

TENANT_DATA_ROOT=${TENANT_DATA_ROOT}
TENANT_COMPOSE_ROOT=${TENANT_COMPOSE_ROOT}

DIRECTUS_DATA_DIR=${DIRECTUS_DATA_DIR}
N8N_DATA_DIR=${N8N_DATA_DIR}
BOOKING_DATA_DIR=${BOOKING_DATA_DIR}

TENANT_BACKEND_NETWORK=${TENANT_BACKEND_NETWORK}

POSTGRES_DIRECTUS_DB=${POSTGRES_DIRECTUS_DB}
POSTGRES_N8N_DB=${POSTGRES_N8N_DB}
POSTGRES_BOOKING_DB=${POSTGRES_BOOKING_DB}

BACKUP_BUCKET=${BACKUP_BUCKET}
BACKUP_HOST=${BACKUP_HOST}
BACKUP_TAG_TENANT=${BACKUP_TAG_TENANT}
BACKUP_TAG_ENVIRONMENT=${BACKUP_TAG_ENVIRONMENT}
EOF

chmod 600 \
  "${CUSTOMER_ROOT}/tenant.env"

# =============================================================================
# Secrets internos del tenant
# =============================================================================

cat > "${TENANT_SECRETS_DIR}/postgres.env" <<EOF
POSTGRES_DIRECTUS_USER=${POSTGRES_DIRECTUS_USER}
POSTGRES_DIRECTUS_PASSWORD=${POSTGRES_DIRECTUS_PASSWORD}

POSTGRES_N8N_USER=${POSTGRES_N8N_USER}
POSTGRES_N8N_PASSWORD=${POSTGRES_N8N_PASSWORD}

POSTGRES_BOOKING_USER=${POSTGRES_BOOKING_USER}
POSTGRES_BOOKING_PASSWORD=${POSTGRES_BOOKING_PASSWORD}
EOF

cat > "${TENANT_SECRETS_DIR}/directus.env" <<EOF
DIRECTUS_KEY=${DIRECTUS_KEY}
DIRECTUS_SECRET=${DIRECTUS_SECRET}
DIRECTUS_ADMIN_EMAIL=${DIRECTUS_ADMIN_EMAIL}
DIRECTUS_ADMIN_PASSWORD=${DIRECTUS_ADMIN_PASSWORD}
EOF

cat > "${TENANT_SECRETS_DIR}/n8n.env" <<EOF
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
EOF

chmod 600 \
  "${TENANT_SECRETS_DIR}/postgres.env" \
  "${TENANT_SECRETS_DIR}/directus.env" \
  "${TENANT_SECRETS_DIR}/n8n.env"

# =============================================================================
# Backup manifest
# =============================================================================

log "Generando backup.manifest.json."

cat > "${CUSTOMER_ROOT}/backup.manifest.json" <<EOF
{
  "version": 1,
  "databases": [
    "${POSTGRES_DIRECTUS_DB}",
    "${POSTGRES_N8N_DB}",
    "${POSTGRES_BOOKING_DB}"
  ],
  "persistent_paths": [
    {
      "path": "${DIRECTUS_DATA_DIR}",
      "required": true
    },
    {
      "path": "${N8N_DATA_DIR}",
      "required": true
    },
    {
      "path": "${BOOKING_DATA_DIR}",
      "required": false
    }
  ],
  "configuration_files": [
    {
      "source": "${CUSTOMER_ROOT}/tenant.env",
      "destination": "tenant/tenant.env",
      "required": true,
      "mode": "600"
    },
    {
      "source": "${TENANT_COMPOSE_ROOT}/directus/compose.yml",
      "destination": "compose/directus/compose.yml",
      "required": true,
      "mode": "644"
    },
    {
      "source": "${TENANT_COMPOSE_ROOT}/directus/.env",
      "destination": "compose/directus/.env",
      "required": true,
      "mode": "600"
    },
    {
      "source": "${TENANT_COMPOSE_ROOT}/n8n/compose.yml",
      "destination": "compose/n8n/compose.yml",
      "required": true,
      "mode": "644"
    },
    {
      "source": "${TENANT_COMPOSE_ROOT}/n8n/.env",
      "destination": "compose/n8n/.env",
      "required": true,
      "mode": "600"
    }
  ]
}
EOF

chmod 644 \
  "${CUSTOMER_ROOT}/backup.manifest.json"

python3 -m json.tool \
  "${CUSTOMER_ROOT}/backup.manifest.json" \
  >/dev/null

# =============================================================================
# Validación Compose
# =============================================================================

log "Validando Compose Directus."

docker compose \
  --env-file "${TENANT_COMPOSE_ROOT}/directus/.env" \
  -f "${TENANT_COMPOSE_ROOT}/directus/compose.yml" \
  config \
  >/dev/null

log "Validando Compose n8n."

docker compose \
  --env-file "${TENANT_COMPOSE_ROOT}/n8n/.env" \
  -f "${TENANT_COMPOSE_ROOT}/n8n/compose.yml" \
  config \
  >/dev/null

# =============================================================================
# Resultado
# =============================================================================

cat <<EOF

============================================================
TENANT PROVISIONADO
============================================================

Tenant:
  ${TENANT_ID}

Configuración:
  ${CUSTOMER_ROOT}

Datos:
  ${TENANT_ROOT}

Red:
  ${TENANT_BACKEND_NETWORK}

Bases:
  ${POSTGRES_DIRECTUS_DB}
  ${POSTGRES_N8N_DB}
  ${POSTGRES_BOOKING_DB}

Estado:
  CONFIGURADO, NO DESPLEGADO

Siguiente paso:
  validar configuración y arrancar Directus/n8n.

============================================================
EOF
