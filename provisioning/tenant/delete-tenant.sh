#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora tenant deletion
#
# Responsabilidad:
#
#   - retirar publicación Caddy del tenant;
#   - detener y eliminar contenedores del tenant;
#   - eliminar bases PostgreSQL;
#   - eliminar roles PostgreSQL;
#   - desconectar PostgreSQL de la red privada;
#   - eliminar red privada;
#   - eliminar runtime local del tenant.
#
# NO elimina:
#
#   - repositorios/buckets S3;
#   - snapshots Restic remotos;
#   - infraestructura compartida;
#   - PostgreSQL compartido;
#   - Caddy compartido;
#   - tenant "aegora".
#
# El borrado remoto de backups debe ser siempre una operación separada.
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"

readonly POSTGRES_CONTAINER="aegora-postgres"

readonly CADDY_CONTAINER="aegora-caddy"
readonly CADDY_CONFIG="/etc/caddy/Caddyfile"
readonly CADDY_RUNTIME_SITES_HOST="/opt/aegora/data/caddy/sites"

TENANT=""
APPLY=false
ASSUME_YES=false

TENANT_ROOT=""
TENANT_CONFIG=""
TENANT_COMPOSE_ROOT=""

TENANT_ID=""
TENANT_SQL_ID=""

DIRECTUS_CONTAINER=""
N8N_CONTAINER=""
BOOKING_CONTAINER=""

POSTGRES_DIRECTUS_DB=""
POSTGRES_N8N_DB=""
POSTGRES_BOOKING_DB=""

POSTGRES_DIRECTUS_USER=""
POSTGRES_N8N_USER=""
POSTGRES_BOOKING_USER=""

TENANT_BACKEND_NETWORK=""

CADDY_SITE_FILE=""
CADDY_SITE_BACKUP=""

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

  delete-tenant.sh \
    --tenant TENANT \
    [--apply] \
    [--yes]

Sin --apply:
  muestra únicamente el plan.

Con --apply:
  requiere confirmación interactiva:

    DELETE-<tenant>

Con --yes:
  omite la confirmación interactiva.
  Debe utilizarse solo en automatizaciones controladas.

El script elimina:

  - publicación Caddy runtime del tenant;
  - contenedores Directus/n8n/Booking del tenant;
  - bases PostgreSQL del tenant;
  - roles PostgreSQL del tenant;
  - red Docker privada;
  - /opt/aegora/tenants/<tenant>.

El script NO elimina:

  - backups remotos;
  - buckets S3;
  - snapshots Restic;
  - servicios compartidos.

Ejemplo:

  sudo /usr/bin/bash \
    /opt/aegora/platform/provisioning/tenant/delete-tenant.sh \
    --tenant gestoria-demo \
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

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

container_running() {
  local container="$1"

  [[ "$(
    docker inspect \
      --format '{{.State.Status}}' \
      "$container" 2>/dev/null
  )" == "running" ]]
}

network_exists() {
  docker network inspect "$1" >/dev/null 2>&1
}

sql_identifier() {
  printf '%s' "$1" |
    tr '-' '_' |
    tr -cd 'a-zA-Z0-9_'
}

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

validate_caddy() {
  docker exec \
    "$CADDY_CONTAINER" \
    caddy validate \
      --config "$CADDY_CONFIG" \
      --adapter caddyfile
}

reload_caddy() {
  docker exec \
    -w /etc/caddy \
    "$CADDY_CONTAINER" \
    caddy reload \
      --config Caddyfile \
      --adapter caddyfile
}

# =============================================================================
# Caddy
# =============================================================================

remove_caddy_site() {
  [[ -f "$CADDY_SITE_FILE" ]] || {
    log "No existe fragmento Caddy del tenant; se omite."
    return 0
  }

  if ! container_exists "$CADDY_CONTAINER"; then
    fail \
      "Existe fragmento Caddy pero no existe ${CADDY_CONTAINER}; no se elimina automáticamente."
  fi

  if ! container_running "$CADDY_CONTAINER"; then
    fail \
      "Existe fragmento Caddy pero ${CADDY_CONTAINER} no está running."
  fi

  CADDY_SITE_BACKUP="$(
    mktemp \
      "${CADDY_RUNTIME_SITES_HOST}/.${TENANT}.delete.XXXXXX.backup"
  )"

  cp \
    --preserve=mode,timestamps \
    "$CADDY_SITE_FILE" \
    "$CADDY_SITE_BACKUP"

  rm -f "$CADDY_SITE_FILE"

  log "Validando Caddy sin el tenant '${TENANT}'."

  if ! validate_caddy; then
    warn "Caddy no valida después de retirar el tenant."

    mv \
      "$CADDY_SITE_BACKUP" \
      "$CADDY_SITE_FILE"

    CADDY_SITE_BACKUP=""

    fail \
      "Se ha restaurado el fragmento Caddy original."
  fi

  log "Recargando Caddy."

  if ! reload_caddy; then
    warn "Falló el reload de Caddy."

    mv \
      "$CADDY_SITE_BACKUP" \
      "$CADDY_SITE_FILE"

    CADDY_SITE_BACKUP=""

    warn "Restaurando configuración Caddy anterior."

    reload_caddy || true

    fail \
      "No se ha podido retirar de forma segura la publicación."
  fi

  rm -f "$CADDY_SITE_BACKUP"
  CADDY_SITE_BACKUP=""

  log "Publicación Caddy retirada."
}

# =============================================================================
# Docker
# =============================================================================

remove_container() {
  local container="$1"

  if ! container_exists "$container"; then
    log "Contenedor ausente; se omite: ${container}"
    return 0
  fi

  if container_running "$container"; then
    log "Deteniendo contenedor: ${container}"

    docker stop \
      --time 60 \
      "$container" \
      >/dev/null
  fi

  log "Eliminando contenedor: ${container}"

  docker rm \
    "$container" \
    >/dev/null
}

# =============================================================================
# PostgreSQL
# =============================================================================

drop_database() {
  local database="$1"
  local admin_user="$2"

  if [[ "$(database_exists "$database" "$admin_user")" != "1" ]]; then
    log "Base ausente; se omite: ${database}"
    return 0
  fi

  log "Eliminando base PostgreSQL: ${database}"

  docker exec "$POSTGRES_CONTAINER" \
    dropdb \
      --username="$admin_user" \
      --force \
      --if-exists \
      "$database"
}

drop_role() {
  local role="$1"
  local admin_user="$2"

  if [[ "$(role_exists "$role" "$admin_user")" != "1" ]]; then
    log "Rol ausente; se omite: ${role}"
    return 0
  fi

  log "Eliminando rol PostgreSQL: ${role}"

  docker exec "$POSTGRES_CONTAINER" \
    dropuser \
      --username="$admin_user" \
      --if-exists \
      "$role"
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

    --yes)
      ASSUME_YES=true
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

[[ -n "$TENANT" ]] ||
  fail "Falta --tenant."

[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] ||
  fail "Tenant inválido: ${TENANT}"

[[ "$TENANT" != "aegora" ]] ||
  fail "El tenant 'aegora' está protegido y no puede eliminarse."

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"
TENANT_COMPOSE_ROOT="${TENANT_ROOT}/config/compose"

[[ "$TENANT_ROOT" == "${TENANTS_ROOT}/"* ]] ||
  fail "Ruta de tenant inválida."

require_command docker
require_command mktemp
require_command rm

container_exists "$POSTGRES_CONTAINER" ||
  fail "No existe el PostgreSQL compartido."

container_running "$POSTGRES_CONTAINER" ||
  fail "PostgreSQL compartido no está running."

POSTGRES_ADMIN_USER="$(postgres_admin_user)"

[[ -n "$POSTGRES_ADMIN_USER" ]] ||
  fail "No se pudo detectar POSTGRES_USER."

# =============================================================================
# Resolver recursos
# =============================================================================

if [[ -f "$TENANT_CONFIG" ]]; then
  log "Cargando configuración del tenant."

  set -a

  # shellcheck disable=SC1090
  source "$TENANT_CONFIG"

  set +a

  [[ "${TENANT_ID:-}" == "$TENANT" ]] ||
    fail \
      "TENANT_ID de tenant.env no coincide con --tenant."

  : "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"
  : "${N8N_CONTAINER:?Falta N8N_CONTAINER}"
  : "${BOOKING_CONTAINER:?Falta BOOKING_CONTAINER}"

  : "${POSTGRES_DIRECTUS_DB:?Falta POSTGRES_DIRECTUS_DB}"
  : "${POSTGRES_N8N_DB:?Falta POSTGRES_N8N_DB}"
  : "${POSTGRES_BOOKING_DB:?Falta POSTGRES_BOOKING_DB}"

  : "${TENANT_BACKEND_NETWORK:?Falta TENANT_BACKEND_NETWORK}"

else
  warn \
    "tenant.env ausente. Se derivarán los nombres a partir del tenant."

  TENANT_ID="$TENANT"
  TENANT_SQL_ID="$(sql_identifier "$TENANT")"

  DIRECTUS_CONTAINER="${TENANT}-directus"
  N8N_CONTAINER="${TENANT}-n8n"
  BOOKING_CONTAINER="${TENANT}-booking"

  POSTGRES_DIRECTUS_DB="directus_${TENANT_SQL_ID}"
  POSTGRES_N8N_DB="n8n_${TENANT_SQL_ID}"
  POSTGRES_BOOKING_DB="booking_${TENANT_SQL_ID}"

  TENANT_BACKEND_NETWORK="tenant_${TENANT_SQL_ID}_backend"
fi

TENANT_SQL_ID="$(sql_identifier "$TENANT")"

POSTGRES_DIRECTUS_USER="directus_${TENANT_SQL_ID}"
POSTGRES_N8N_USER="n8n_${TENANT_SQL_ID}"
POSTGRES_BOOKING_USER="booking_${TENANT_SQL_ID}"

CADDY_SITE_FILE="${CADDY_RUNTIME_SITES_HOST}/${TENANT}.caddy"

# =============================================================================
# Estado / PLAN
# =============================================================================

directus_exists=false
n8n_exists=false
booking_exists=false
network_present=false
runtime_present=false
caddy_present=false

container_exists "$DIRECTUS_CONTAINER" &&
  directus_exists=true

container_exists "$N8N_CONTAINER" &&
  n8n_exists=true

container_exists "$BOOKING_CONTAINER" &&
  booking_exists=true

network_exists "$TENANT_BACKEND_NETWORK" &&
  network_present=true

[[ -d "$TENANT_ROOT" ]] &&
  runtime_present=true

[[ -f "$CADDY_SITE_FILE" ]] &&
  caddy_present=true

directus_db_exists="$(
  database_exists \
    "$POSTGRES_DIRECTUS_DB" \
    "$POSTGRES_ADMIN_USER"
)"

n8n_db_exists="$(
  database_exists \
    "$POSTGRES_N8N_DB" \
    "$POSTGRES_ADMIN_USER"
)"

booking_db_exists="$(
  database_exists \
    "$POSTGRES_BOOKING_DB" \
    "$POSTGRES_ADMIN_USER"
)"

directus_role_exists="$(
  role_exists \
    "$POSTGRES_DIRECTUS_USER" \
    "$POSTGRES_ADMIN_USER"
)"

n8n_role_exists="$(
  role_exists \
    "$POSTGRES_N8N_USER" \
    "$POSTGRES_ADMIN_USER"
)"

booking_role_exists="$(
  role_exists \
    "$POSTGRES_BOOKING_USER" \
    "$POSTGRES_ADMIN_USER"
)"

cat <<EOF

============================================================
AEGORA TENANT DELETION
============================================================

Tenant:
  ${TENANT}

Runtime:
  ${TENANT_ROOT}
  existe: ${runtime_present}

Contenedores:
  ${DIRECTUS_CONTAINER}: ${directus_exists}
  ${N8N_CONTAINER}: ${n8n_exists}
  ${BOOKING_CONTAINER}: ${booking_exists}

Bases:
  ${POSTGRES_DIRECTUS_DB}: ${directus_db_exists:-0}
  ${POSTGRES_N8N_DB}: ${n8n_db_exists:-0}
  ${POSTGRES_BOOKING_DB}: ${booking_db_exists:-0}

Roles:
  ${POSTGRES_DIRECTUS_USER}: ${directus_role_exists:-0}
  ${POSTGRES_N8N_USER}: ${n8n_role_exists:-0}
  ${POSTGRES_BOOKING_USER}: ${booking_role_exists:-0}

Red:
  ${TENANT_BACKEND_NETWORK}: ${network_present}

Caddy:
  ${CADDY_SITE_FILE}
  existe: ${caddy_present}

Backups remotos:
  NO SE ELIMINARÁN

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha eliminado ningún recurso."
  log "Añade --apply para ejecutar la eliminación."
  exit 0
fi

# =============================================================================
# Confirmación
# =============================================================================

warn "OPERACIÓN DESTRUCTIVA."
warn "Se eliminarán datos locales y bases del tenant '${TENANT}'."

if [[ "$ASSUME_YES" != true ]]; then
  printf '\nEscribe exactamente DELETE-%s para continuar: ' "$TENANT"

  read -r confirmation

  [[ "$confirmation" == "DELETE-${TENANT}" ]] ||
    fail "Confirmación incorrecta. No se ha eliminado nada."
else
  warn "Confirmación interactiva omitida mediante --yes."
fi

# =============================================================================
# 1. Retirar publicación
# =============================================================================

remove_caddy_site

# =============================================================================
# 2. Eliminar contenedores
#
# Booking primero por dependencia potencial.
# =============================================================================

remove_container "$BOOKING_CONTAINER"
remove_container "$N8N_CONTAINER"
remove_container "$DIRECTUS_CONTAINER"

# =============================================================================
# 3. Eliminar bases
# =============================================================================

drop_database \
  "$POSTGRES_BOOKING_DB" \
  "$POSTGRES_ADMIN_USER"

drop_database \
  "$POSTGRES_N8N_DB" \
  "$POSTGRES_ADMIN_USER"

drop_database \
  "$POSTGRES_DIRECTUS_DB" \
  "$POSTGRES_ADMIN_USER"

# =============================================================================
# 4. Eliminar roles
# =============================================================================

drop_role \
  "$POSTGRES_BOOKING_USER" \
  "$POSTGRES_ADMIN_USER"

drop_role \
  "$POSTGRES_N8N_USER" \
  "$POSTGRES_ADMIN_USER"

drop_role \
  "$POSTGRES_DIRECTUS_USER" \
  "$POSTGRES_ADMIN_USER"

# =============================================================================
# 5. Red
# =============================================================================

if network_exists "$TENANT_BACKEND_NETWORK"; then
  log "Desconectando PostgreSQL de la red del tenant."

  docker network disconnect \
    "$TENANT_BACKEND_NETWORK" \
    "$POSTGRES_CONTAINER" \
    >/dev/null 2>&1 || true

  log "Eliminando red: ${TENANT_BACKEND_NETWORK}"

  docker network rm \
    "$TENANT_BACKEND_NETWORK" \
    >/dev/null
else
  log "Red ausente; se omite."
fi

# =============================================================================
# 6. Runtime
# =============================================================================

if [[ -d "$TENANT_ROOT" ]]; then
  log "Eliminando runtime: ${TENANT_ROOT}"

  rm -rf --one-file-system \
    "$TENANT_ROOT"
else
  log "Runtime ausente; se omite."
fi

# =============================================================================
# Verificación final
# =============================================================================

errors=0

if container_exists "$DIRECTUS_CONTAINER"; then
  warn "Continúa existiendo ${DIRECTUS_CONTAINER}"
  errors=$((errors + 1))
fi

if container_exists "$N8N_CONTAINER"; then
  warn "Continúa existiendo ${N8N_CONTAINER}"
  errors=$((errors + 1))
fi

if container_exists "$BOOKING_CONTAINER"; then
  warn "Continúa existiendo ${BOOKING_CONTAINER}"
  errors=$((errors + 1))
fi

if network_exists "$TENANT_BACKEND_NETWORK"; then
  warn "Continúa existiendo ${TENANT_BACKEND_NETWORK}"
  errors=$((errors + 1))
fi

if [[ -e "$TENANT_ROOT" ]]; then
  warn "Continúa existiendo ${TENANT_ROOT}"
  errors=$((errors + 1))
fi

for database in \
  "$POSTGRES_DIRECTUS_DB" \
  "$POSTGRES_N8N_DB" \
  "$POSTGRES_BOOKING_DB"; do

  if [[ "$(
    database_exists \
      "$database" \
      "$POSTGRES_ADMIN_USER"
  )" == "1" ]]; then

    warn "Continúa existiendo DB ${database}"
    errors=$((errors + 1))
  fi
done

for role in \
  "$POSTGRES_DIRECTUS_USER" \
  "$POSTGRES_N8N_USER" \
  "$POSTGRES_BOOKING_USER"; do

  if [[ "$(
    role_exists \
      "$role" \
      "$POSTGRES_ADMIN_USER"
  )" == "1" ]]; then

    warn "Continúa existiendo rol ${role}"
    errors=$((errors + 1))
  fi
done

if (( errors > 0 )); then
  fail \
    "El tenant se eliminó parcialmente; quedan ${errors} recursos."
fi

cat <<EOF

============================================================
TENANT ELIMINADO
============================================================

Tenant:
  ${TENANT}

Contenedores:
  eliminados

Bases PostgreSQL:
  eliminadas

Roles PostgreSQL:
  eliminados

Red privada:
  eliminada

Runtime:
  eliminado

Caddy:
  retirado o no existía

Backups remotos:
  conservados

Estado:
  DEPROVISIONED

============================================================
EOF
