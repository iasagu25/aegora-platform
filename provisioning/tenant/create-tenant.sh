#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora tenant provisioning
#
# Esta fase crea la infraestructura CORE de un tenant:
#
#   - filesystem runtime
#   - secretos
#   - roles PostgreSQL
#   - bases PostgreSQL
#   - red Docker privada
#   - configuración Directus
#   - configuración n8n
#   - tenant.env
#   - backup.manifest.json
#
# NO hace todavía:
#
#   - despliegue de contenedores
#   - configuración Caddy
#   - creación del bucket S3
#   - inicialización Restic
#   - timers systemd
#
# Esas acciones se realizarán en fases posteriores.
# =============================================================================

# =============================================================================
# Paths
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly TEMPLATE_ROOT="${PLATFORM_ROOT}/templates/tenant-stack"
readonly RENDERER="${PLATFORM_ROOT}/provisioning/tenant/render-template.py"

readonly POSTGRES_CONTAINER="aegora-postgres"

# =============================================================================
# Defaults versionados
# =============================================================================

readonly DEFAULT_DIRECTUS_VERSION="11.17.4"
readonly DEFAULT_N8N_VERSION="2.31.7"

DIRECTUS_VERSION="${DIRECTUS_VERSION:-$DEFAULT_DIRECTUS_VERSION}"
N8N_VERSION="${N8N_VERSION:-$DEFAULT_N8N_VERSION}"

# =============================================================================
# Argumentos
# =============================================================================

TENANT_ID=""
TENANT_NAME=""
BASE_DOMAIN=""
DIRECTUS_ADMIN_EMAIL=""

APPLY=false
COMMITTED=false

# =============================================================================
# Estado para rollback
# =============================================================================

CREATED_TENANT_ROOT=false
CREATED_DIRECTUS_ROLE=false
CREATED_N8N_ROLE=false
CREATED_BOOKING_ROLE=false

CREATED_DIRECTUS_DB=false
CREATED_N8N_DB=false
CREATED_BOOKING_DB=false

CREATED_NETWORK=false
POSTGRES_CONNECTED_TO_NETWORK=false

# =============================================================================
# Variables derivadas
# =============================================================================

TENANT_SQL_ID=""

TENANT_ROOT=""
TENANT_CONFIG_ROOT=""
TENANT_DATA_ROOT=""
TENANT_SECRETS_DIR=""
TENANT_BACKUP_DIR=""
TENANT_COMPOSE_ROOT=""

DIRECTUS_DATA_DIR=""
N8N_DATA_DIR=""
BOOKING_DATA_DIR=""

TENANT_BACKEND_NETWORK=""

DIRECTUS_CONTAINER=""
N8N_CONTAINER=""
BOOKING_CONTAINER=""

DIRECTUS_HOST=""
N8N_HOST=""
BOOKING_HOST=""

POSTGRES_DIRECTUS_DB=""
POSTGRES_N8N_DB=""
POSTGRES_BOOKING_DB=""

POSTGRES_DIRECTUS_USER=""
POSTGRES_N8N_USER=""
POSTGRES_BOOKING_USER=""

BACKUP_HOST=""
BACKUP_TAG_TENANT=""
BACKUP_TAG_ENVIRONMENT=""

# =============================================================================
# Secretos generados
# =============================================================================

DIRECTUS_KEY=""
DIRECTUS_SECRET=""
DIRECTUS_ADMIN_PASSWORD=""

N8N_ENCRYPTION_KEY=""

POSTGRES_DIRECTUS_PASSWORD=""
POSTGRES_N8N_PASSWORD=""
POSTGRES_BOOKING_PASSWORD=""

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

  create-tenant.sh \
    --tenant ID \
    --name "Nombre cliente" \
    --domain example.es \
    --admin-email admin@example.es \
    [--apply]

Sin --apply:
  muestra el plan y no modifica el sistema.

Con --apply:
  - genera secretos;
  - crea estructura runtime;
  - crea roles PostgreSQL;
  - crea bases PostgreSQL;
  - crea una red Docker privada;
  - conecta PostgreSQL a esa red;
  - genera tenant.env;
  - genera backup.manifest.json;
  - genera Compose Directus;
  - genera Compose n8n;
  - valida ambos Compose.

No despliega todavía los contenedores.

Ejemplo:

  sudo /usr/bin/bash \
    /opt/aegora/platform/provisioning/tenant/create-tenant.sh \
    --tenant gestoria-demo \
    --name "Gestoría Demo" \
    --domain gestoria-demo.example \
    --admin-email admin@gestoria-demo.example \
    --apply
EOF
}

# =============================================================================
# Prerrequisitos
# =============================================================================

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "Falta el comando requerido: $1"
}

require_file() {
  [[ -f "$1" ]] ||
    fail "Falta el fichero requerido: $1"
}

# =============================================================================
# Generación de secretos
# =============================================================================

generate_hex() {
  local bytes="$1"

  openssl rand -hex "$bytes"
}

generate_password() {
  # Hex evita caracteres problemáticos en .env, SQL y shell.
  openssl rand -hex 32
}

# =============================================================================
# Normalización
# =============================================================================

sql_identifier() {
  printf '%s' "$1" |
    tr '-' '_' |
    tr -cd 'a-zA-Z0-9_'
}

# =============================================================================
# Docker
# =============================================================================

docker_network_exists() {
  docker network inspect "$1" >/dev/null 2>&1
}

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

# =============================================================================
# PostgreSQL
# =============================================================================

postgres_admin_user() {
  docker exec "$POSTGRES_CONTAINER" \
    printenv POSTGRES_USER |
    tr -d '\r\n'
}

database_exists() {
  local database="$1"
  local admin_user="$2"

  docker exec "$POSTGRES_CONTAINER" \
    psql \
      --username="$admin_user" \
      --dbname=postgres \
      --tuples-only \
      --no-align \
      --command="
        SELECT 1
        FROM pg_database
        WHERE datname = '${database}';
      " \
    2>/dev/null |
    tr -d '[:space:]'
}

role_exists() {
  local role="$1"
  local admin_user="$2"

  docker exec "$POSTGRES_CONTAINER" \
    psql \
      --username="$admin_user" \
      --dbname=postgres \
      --tuples-only \
      --no-align \
      --command="
        SELECT 1
        FROM pg_roles
        WHERE rolname = '${role}';
      " \
    2>/dev/null |
    tr -d '[:space:]'
}

create_role() {
  local role="$1"
  local password="$2"
  local admin_user="$3"

  [[ "$role" =~ ^[a-zA-Z0-9_]+$ ]] ||
    fail "Nombre de rol PostgreSQL inválido: ${role}"

  [[ "$password" =~ ^[a-f0-9]+$ ]] ||
    fail "Password PostgreSQL generado con formato inesperado."

  if [[ "$(role_exists "$role" "$admin_user")" == "1" ]]; then
    fail "El rol PostgreSQL ya existe: ${role}"
  fi

  docker exec "$POSTGRES_CONTAINER" \
    psql \
      --username="$admin_user" \
      --dbname=postgres \
      --set=ON_ERROR_STOP=1 \
      --command="
        CREATE ROLE \"${role}\"
        LOGIN
        PASSWORD '${password}';
      " \
    >/dev/null
}

create_database() {
  local database="$1"
  local owner="$2"
  local admin_user="$3"

  [[ "$database" =~ ^[a-zA-Z0-9_]+$ ]] ||
    fail "Nombre de base PostgreSQL inválido: ${database}"

  [[ "$owner" =~ ^[a-zA-Z0-9_]+$ ]] ||
    fail "Owner PostgreSQL inválido: ${owner}"

  if [[ "$(database_exists "$database" "$admin_user")" == "1" ]]; then
    fail "La base PostgreSQL ya existe: ${database}"
  fi

  docker exec "$POSTGRES_CONTAINER" \
    createdb \
      --username="$admin_user" \
      --owner="$owner" \
      "$database"
}

drop_database_if_created() {
  local database="$1"
  local admin_user="$2"
  local created="$3"

  [[ "$created" == true ]] ||
    return 0

  docker exec "$POSTGRES_CONTAINER" \
    dropdb \
      --username="$admin_user" \
      --if-exists \
      "$database" \
    >/dev/null 2>&1 || true
}

drop_role_if_created() {
  local role="$1"
  local admin_user="$2"
  local created="$3"

  [[ "$created" == true ]] ||
    return 0

  docker exec "$POSTGRES_CONTAINER" \
    dropuser \
      --username="$admin_user" \
      --if-exists \
      "$role" \
    >/dev/null 2>&1 || true
}

# =============================================================================
# Rollback
# =============================================================================

rollback() {
  local exit_code=$?

  trap - EXIT

  if [[ $exit_code -eq 0 || "$COMMITTED" == true ]]; then
    exit "$exit_code"
  fi

  warn "Provisioning incompleto. Ejecutando rollback."

  local admin_user=""

  if container_exists "$POSTGRES_CONTAINER"; then
    admin_user="$(postgres_admin_user 2>/dev/null || true)"
  fi

  if [[ -n "$admin_user" ]]; then
    drop_database_if_created \
      "$POSTGRES_BOOKING_DB" \
      "$admin_user" \
      "$CREATED_BOOKING_DB"

    drop_database_if_created \
      "$POSTGRES_N8N_DB" \
      "$admin_user" \
      "$CREATED_N8N_DB"

    drop_database_if_created \
      "$POSTGRES_DIRECTUS_DB" \
      "$admin_user" \
      "$CREATED_DIRECTUS_DB"

    drop_role_if_created \
      "$POSTGRES_BOOKING_USER" \
      "$admin_user" \
      "$CREATED_BOOKING_ROLE"

    drop_role_if_created \
      "$POSTGRES_N8N_USER" \
      "$admin_user" \
      "$CREATED_N8N_ROLE"

    drop_role_if_created \
      "$POSTGRES_DIRECTUS_USER" \
      "$admin_user" \
      "$CREATED_DIRECTUS_ROLE"
  fi

  if [[ "$POSTGRES_CONNECTED_TO_NETWORK" == true ]]; then
    docker network disconnect \
      "$TENANT_BACKEND_NETWORK" \
      "$POSTGRES_CONTAINER" \
      >/dev/null 2>&1 || true
  fi

  if [[ "$CREATED_NETWORK" == true ]]; then
    docker network rm \
      "$TENANT_BACKEND_NETWORK" \
      >/dev/null 2>&1 || true
  fi

  if [[
    "$CREATED_TENANT_ROOT" == true &&
    -n "$TENANT_ROOT" &&
    "$TENANT_ROOT" == "${TENANTS_ROOT}/"*
  ]]; then
    rm -rf "$TENANT_ROOT"
  fi

  warn "Rollback finalizado."
  exit "$exit_code"
}

trap rollback EXIT

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
# Validación de argumentos
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
    "TENANT_ID debe empezar por letra y usar solo minúsculas, números y guiones."

[[ "$BASE_DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
  fail "Dominio inválido: ${BASE_DOMAIN}"

[[ "$DIRECTUS_ADMIN_EMAIL" == *@*.* ]] ||
  fail "Email inválido: ${DIRECTUS_ADMIN_EMAIL}"

[[ "$TENANT_ID" != "aegora" ]] ||
  fail "El tenant 'aegora' está reservado."

# =============================================================================
# Prerrequisitos del host
# =============================================================================

require_command docker
require_command openssl
require_command python3
require_command install

require_file "$RENDERER"

require_file \
  "${TEMPLATE_ROOT}/directus/compose.yml.tpl"

require_file \
  "${TEMPLATE_ROOT}/directus/.env.tpl"

require_file \
  "${TEMPLATE_ROOT}/n8n/compose.yml.tpl"

require_file \
  "${TEMPLATE_ROOT}/n8n/.env.tpl"

container_exists "$POSTGRES_CONTAINER" ||
  fail "No existe el contenedor PostgreSQL '${POSTGRES_CONTAINER}'."

POSTGRES_ADMIN_USER="$(postgres_admin_user)"

[[ -n "$POSTGRES_ADMIN_USER" ]] ||
  fail "No se pudo detectar POSTGRES_USER."

# =============================================================================
# Variables derivadas
# =============================================================================

TENANT_SQL_ID="$(
  sql_identifier "$TENANT_ID"
)"

[[ -n "$TENANT_SQL_ID" ]] ||
  fail "No se pudo generar el identificador SQL."

TENANT_ROOT="${TENANTS_ROOT}/${TENANT_ID}"

TENANT_CONFIG_ROOT="${TENANT_ROOT}/config"
TENANT_DATA_ROOT="${TENANT_ROOT}/data"
TENANT_SECRETS_DIR="${TENANT_ROOT}/secrets"
TENANT_BACKUP_DIR="${TENANT_ROOT}/backups"

TENANT_COMPOSE_ROOT="${TENANT_CONFIG_ROOT}/compose"

DIRECTUS_DATA_DIR="${TENANT_DATA_ROOT}/directus"
N8N_DATA_DIR="${TENANT_DATA_ROOT}/n8n"
BOOKING_DATA_DIR="${TENANT_DATA_ROOT}/booking"

TENANT_BACKEND_NETWORK="tenant_${TENANT_SQL_ID}_backend"

DIRECTUS_CONTAINER="${TENANT_ID}-directus"
N8N_CONTAINER="${TENANT_ID}-n8n"
BOOKING_CONTAINER="${TENANT_ID}-booking"

DIRECTUS_HOST="panel.${BASE_DOMAIN}"
N8N_HOST="n8n.${BASE_DOMAIN}"
BOOKING_HOST="reservas.${BASE_DOMAIN}"

POSTGRES_DIRECTUS_DB="directus_${TENANT_SQL_ID}"
POSTGRES_N8N_DB="n8n_${TENANT_SQL_ID}"
POSTGRES_BOOKING_DB="booking_${TENANT_SQL_ID}"

POSTGRES_DIRECTUS_USER="directus_${TENANT_SQL_ID}"
POSTGRES_N8N_USER="n8n_${TENANT_SQL_ID}"
POSTGRES_BOOKING_USER="booking_${TENANT_SQL_ID}"

BACKUP_HOST="${TENANT_ID}"
BACKUP_TAG_TENANT="tenant=${TENANT_ID}"
BACKUP_TAG_ENVIRONMENT="environment=production"

# =============================================================================
# PLAN
# =============================================================================

cat <<EOF

============================================================
AEGORA TENANT PROVISIONING — CORE
============================================================

Tenant:
  ID:               ${TENANT_ID}
  Nombre:           ${TENANT_NAME}
  Dominio:          ${BASE_DOMAIN}

Versiones:
  Directus:         ${DIRECTUS_VERSION}
  n8n:              ${N8N_VERSION}

Endpoints previstos:
  Directus:         https://${DIRECTUS_HOST}
  n8n:              https://${N8N_HOST}
  Booking:          https://${BOOKING_HOST}

PostgreSQL:
  Directus DB:      ${POSTGRES_DIRECTUS_DB}
  Directus user:    ${POSTGRES_DIRECTUS_USER}

  n8n DB:           ${POSTGRES_N8N_DB}
  n8n user:         ${POSTGRES_N8N_USER}

  Booking DB:       ${POSTGRES_BOOKING_DB}
  Booking user:     ${POSTGRES_BOOKING_USER}

Docker:
  Directus:         ${DIRECTUS_CONTAINER}
  n8n:              ${N8N_CONTAINER}
  Booking:          ${BOOKING_CONTAINER}
  Backend network:  ${TENANT_BACKEND_NETWORK}

Runtime:
  ${TENANT_ROOT}

Configuración:
  ${TENANT_CONFIG_ROOT}

Datos:
  ${TENANT_DATA_ROOT}

Secretos:
  ${TENANT_SECRETS_DIR}

Backup:
  manifiesto:       ${TENANT_CONFIG_ROOT}/backup.manifest.json
  repositorio S3:   PENDIENTE DE PROVISIONING

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha modificado el sistema."
  log "Añade --apply para ejecutar el provisioning CORE."
  COMMITTED=true
  exit 0
fi

# =============================================================================
# Protección frente a duplicados
# =============================================================================

[[ ! -e "$TENANT_ROOT" ]] ||
  fail "Ya existe el tenant runtime: ${TENANT_ROOT}"

container_exists "$DIRECTUS_CONTAINER" &&
  fail "Ya existe el contenedor ${DIRECTUS_CONTAINER}"

container_exists "$N8N_CONTAINER" &&
  fail "Ya existe el contenedor ${N8N_CONTAINER}"

container_exists "$BOOKING_CONTAINER" &&
  fail "Ya existe el contenedor ${BOOKING_CONTAINER}"

docker_network_exists "$TENANT_BACKEND_NETWORK" &&
  fail "Ya existe la red ${TENANT_BACKEND_NETWORK}"

for database in \
  "$POSTGRES_DIRECTUS_DB" \
  "$POSTGRES_N8N_DB" \
  "$POSTGRES_BOOKING_DB"; do

  [[ "$(database_exists "$database" "$POSTGRES_ADMIN_USER")" != "1" ]] ||
    fail "Ya existe la base PostgreSQL: ${database}"
done

for role in \
  "$POSTGRES_DIRECTUS_USER" \
  "$POSTGRES_N8N_USER" \
  "$POSTGRES_BOOKING_USER"; do

  [[ "$(role_exists "$role" "$POSTGRES_ADMIN_USER")" != "1" ]] ||
    fail "Ya existe el rol PostgreSQL: ${role}"
done

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
# Filesystem
# =============================================================================

log "Creando estructura runtime."

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

CREATED_TENANT_ROOT=true

chmod 700 \
  "$TENANT_ROOT" \
  "$TENANT_CONFIG_ROOT" \
  "$TENANT_SECRETS_DIR" \
  "$TENANT_BACKUP_DIR"

# =============================================================================
# PostgreSQL roles
# =============================================================================

log "Creando rol PostgreSQL para Directus."

create_role \
  "$POSTGRES_DIRECTUS_USER" \
  "$POSTGRES_DIRECTUS_PASSWORD" \
  "$POSTGRES_ADMIN_USER"

CREATED_DIRECTUS_ROLE=true

log "Creando rol PostgreSQL para n8n."

create_role \
  "$POSTGRES_N8N_USER" \
  "$POSTGRES_N8N_PASSWORD" \
  "$POSTGRES_ADMIN_USER"

CREATED_N8N_ROLE=true

log "Creando rol PostgreSQL para Booking."

create_role \
  "$POSTGRES_BOOKING_USER" \
  "$POSTGRES_BOOKING_PASSWORD" \
  "$POSTGRES_ADMIN_USER"

CREATED_BOOKING_ROLE=true

# =============================================================================
# PostgreSQL databases
# =============================================================================

log "Creando base PostgreSQL Directus."

create_database \
  "$POSTGRES_DIRECTUS_DB" \
  "$POSTGRES_DIRECTUS_USER" \
  "$POSTGRES_ADMIN_USER"

CREATED_DIRECTUS_DB=true

log "Creando base PostgreSQL n8n."

create_database \
  "$POSTGRES_N8N_DB" \
  "$POSTGRES_N8N_USER" \
  "$POSTGRES_ADMIN_USER"

CREATED_N8N_DB=true

log "Creando base PostgreSQL Booking."

create_database \
  "$POSTGRES_BOOKING_DB" \
  "$POSTGRES_BOOKING_USER" \
  "$POSTGRES_ADMIN_USER"

CREATED_BOOKING_DB=true

# =============================================================================
# Docker network
# =============================================================================

log "Creando red Docker privada."

docker network create \
  "$TENANT_BACKEND_NETWORK" \
  >/dev/null

CREATED_NETWORK=true

log "Conectando PostgreSQL a la red del tenant."

docker network connect \
  "$TENANT_BACKEND_NETWORK" \
  "$POSTGRES_CONTAINER"

POSTGRES_CONNECTED_TO_NETWORK=true

# =============================================================================
# Variables para templates
# =============================================================================

export \
  TENANT_ID \
  TENANT_NAME \
  BASE_DOMAIN \
  TENANT_ROOT \
  TENANT_CONFIG_ROOT \
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
  BACKUP_HOST \
  BACKUP_TAG_TENANT \
  BACKUP_TAG_ENVIRONMENT

# =============================================================================
# Render Directus
# =============================================================================

log "Generando configuración Directus."

python3 "$RENDERER" \
  "${TEMPLATE_ROOT}/directus/compose.yml.tpl" \
  "${TENANT_COMPOSE_ROOT}/directus/compose.yml"

python3 "$RENDERER" \
  "${TEMPLATE_ROOT}/directus/.env.tpl" \
  "${TENANT_COMPOSE_ROOT}/directus/.env"

# =============================================================================
# Render n8n
# =============================================================================

log "Generando configuración n8n."

python3 "$RENDERER" \
  "${TEMPLATE_ROOT}/n8n/compose.yml.tpl" \
  "${TENANT_COMPOSE_ROOT}/n8n/compose.yml"

python3 "$RENDERER" \
  "${TEMPLATE_ROOT}/n8n/.env.tpl" \
  "${TENANT_COMPOSE_ROOT}/n8n/.env"

chmod 644 \
  "${TENANT_COMPOSE_ROOT}/directus/compose.yml" \
  "${TENANT_COMPOSE_ROOT}/n8n/compose.yml"

chmod 600 \
  "${TENANT_COMPOSE_ROOT}/directus/.env" \
  "${TENANT_COMPOSE_ROOT}/n8n/.env"

# =============================================================================
# tenant.env
# =============================================================================

log "Generando tenant.env."

cat > "${TENANT_CONFIG_ROOT}/tenant.env" <<EOF
TENANT_ID=${TENANT_ID}
TENANT_NAME=${TENANT_NAME}
ENVIRONMENT=production

BASE_DOMAIN=${BASE_DOMAIN}

DIRECTUS_VERSION=${DIRECTUS_VERSION}
N8N_VERSION=${N8N_VERSION}

DIRECTUS_HOST=${DIRECTUS_HOST}
N8N_HOST=${N8N_HOST}
BOOKING_HOST=${BOOKING_HOST}

DIRECTUS_CONTAINER=${DIRECTUS_CONTAINER}
N8N_CONTAINER=${N8N_CONTAINER}
BOOKING_CONTAINER=${BOOKING_CONTAINER}

TENANT_ROOT=${TENANT_ROOT}
TENANT_CONFIG_ROOT=${TENANT_CONFIG_ROOT}
TENANT_DATA_ROOT=${TENANT_DATA_ROOT}
TENANT_COMPOSE_ROOT=${TENANT_COMPOSE_ROOT}
TENANT_SECRETS_DIR=${TENANT_SECRETS_DIR}

DIRECTUS_DATA_DIR=${DIRECTUS_DATA_DIR}
N8N_DATA_DIR=${N8N_DATA_DIR}
BOOKING_DATA_DIR=${BOOKING_DATA_DIR}

TENANT_BACKEND_NETWORK=${TENANT_BACKEND_NETWORK}

POSTGRES_DIRECTUS_DB=${POSTGRES_DIRECTUS_DB}
POSTGRES_N8N_DB=${POSTGRES_N8N_DB}
POSTGRES_BOOKING_DB=${POSTGRES_BOOKING_DB}

BACKUP_HOST=${BACKUP_HOST}
BACKUP_TAG_TENANT=${BACKUP_TAG_TENANT}
BACKUP_TAG_ENVIRONMENT=${BACKUP_TAG_ENVIRONMENT}

BACKUP_REPOSITORY_CONFIGURED=false
EOF

chmod 600 \
  "${TENANT_CONFIG_ROOT}/tenant.env"

# =============================================================================
# Secretos
# =============================================================================

log "Guardando secretos."

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

cat > "${TENANT_CONFIG_ROOT}/backup.manifest.json" <<EOF
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
      "source": "${TENANT_CONFIG_ROOT}/tenant.env",
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
  "${TENANT_CONFIG_ROOT}/backup.manifest.json"

python3 -m json.tool \
  "${TENANT_CONFIG_ROOT}/backup.manifest.json" \
  >/dev/null

# =============================================================================
# Validar Compose
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
# Comprobaciones finales
# =============================================================================

log "Validando ownership PostgreSQL."

for spec in \
  "${POSTGRES_DIRECTUS_DB}:${POSTGRES_DIRECTUS_USER}" \
  "${POSTGRES_N8N_DB}:${POSTGRES_N8N_USER}" \
  "${POSTGRES_BOOKING_DB}:${POSTGRES_BOOKING_USER}"; do

  database="${spec%%:*}"
  expected_owner="${spec#*:}"

  actual_owner="$(
    docker exec "$POSTGRES_CONTAINER" \
      psql \
        --username="$POSTGRES_ADMIN_USER" \
        --dbname=postgres \
        --tuples-only \
        --no-align \
        --command="
          SELECT pg_catalog.pg_get_userbyid(datdba)
          FROM pg_database
          WHERE datname = '${database}';
        " |
      tr -d '[:space:]'
  )"

  [[ "$actual_owner" == "$expected_owner" ]] ||
    fail \
      "Owner incorrecto en ${database}: ${actual_owner}"
done

log "Validando red Docker."

docker network inspect \
  "$TENANT_BACKEND_NETWORK" \
  >/dev/null

# =============================================================================
# Commit lógico
# =============================================================================

COMMITTED=true

cat <<EOF

============================================================
TENANT CORE PROVISIONADO
============================================================

Tenant:
  ${TENANT_ID}

Runtime:
  ${TENANT_ROOT}

Config:
  ${TENANT_CONFIG_ROOT}

Datos:
  ${TENANT_DATA_ROOT}

Secretos:
  ${TENANT_SECRETS_DIR}

Red:
  ${TENANT_BACKEND_NETWORK}

Bases:
  ${POSTGRES_DIRECTUS_DB}
  ${POSTGRES_N8N_DB}
  ${POSTGRES_BOOKING_DB}

Versiones:
  Directus ${DIRECTUS_VERSION}
  n8n ${N8N_VERSION}

Estado:
  CORE CONFIGURADO
  SERVICIOS NO DESPLEGADOS
  BACKUP S3 NO CONFIGURADO
  CADDY NO CONFIGURADO
  TIMERS NO CONFIGURADOS

Siguiente fase:
  deploy-tenant

============================================================
EOF
