#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora tenant deployment
#
# Responsabilidad:
#
#   - validar un tenant previamente provisionado;
#   - validar Docker Compose;
#   - descargar las imágenes fijadas;
#   - preparar permisos de datos persistentes;
#   - desplegar Directus;
#   - desplegar n8n;
#   - esperar healthchecks;
#   - validar conectividad interna.
#
# NO hace:
#
#   - creación de tenant;
#   - creación de bases PostgreSQL;
#   - creación de secretos;
#   - configuración DNS;
#   - configuración Caddy;
#   - configuración S3/Restic;
#   - timers systemd.
# =============================================================================

# =============================================================================
# Paths
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"

readonly POSTGRES_CONTAINER="aegora-postgres"
readonly PROXY_NETWORK="aegora_proxy"

# =============================================================================
# Defaults
# =============================================================================

TENANT=""
APPLY=false

HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-180}"
HEALTH_INTERVAL_SECONDS="${HEALTH_INTERVAL_SECONDS:-5}"

# =============================================================================
# Runtime
# =============================================================================

TENANT_ROOT=""
TENANT_CONFIG_ROOT=""
TENANT_CONFIG=""
TENANT_COMPOSE_ROOT=""

DIRECTUS_COMPOSE=""
DIRECTUS_ENV=""

N8N_COMPOSE=""
N8N_ENV=""

DIRECTUS_CREATED_THIS_RUN=false
N8N_CREATED_THIS_RUN=false

DEPLOY_COMMITTED=false

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

  deploy-tenant.sh \
    --tenant TENANT \
    [--apply]

Sin --apply:
  realiza preflight y muestra el plan, pero no despliega.

Con --apply:
  - valida configuración;
  - descarga imágenes;
  - prepara ownership de datos persistentes;
  - despliega Directus;
  - espera healthcheck;
  - despliega n8n;
  - espera healthcheck;
  - valida la conectividad;
  - conserva los datos y bases existentes.

Variables opcionales:

  HEALTH_TIMEOUT_SECONDS
      Tiempo máximo para esperar cada healthcheck.
      Por defecto: 180

  HEALTH_INTERVAL_SECONDS
      Intervalo entre comprobaciones.
      Por defecto: 5

Ejemplo:

  sudo /usr/bin/bash \
    /opt/aegora/platform/provisioning/tenant/deploy-tenant.sh \
    --tenant gestoria-demo \
    --apply
EOF
}

# =============================================================================
# Helpers generales
# =============================================================================

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "Falta el comando requerido: $1"
}

require_file() {
  [[ -f "$1" ]] ||
    fail "Falta el fichero requerido: $1"
}

require_directory() {
  [[ -d "$1" ]] ||
    fail "Falta el directorio requerido: $1"
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

network_exists() {
  docker network inspect "$1" >/dev/null 2>&1
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

network_has_container() {
  local network="$1"
  local container="$2"

  docker network inspect \
    "$network" \
    --format '{{range .Containers}}{{println .Name}}{{end}}' \
    2>/dev/null |
    grep -Fxq "$container"
}

compose_config() {
  local env_file="$1"
  local compose_file="$2"

  docker compose \
    --env-file "$env_file" \
    -f "$compose_file" \
    config \
    >/dev/null
}

compose_pull() {
  local env_file="$1"
  local compose_file="$2"

  docker compose \
    --env-file "$env_file" \
    -f "$compose_file" \
    pull
}

compose_up() {
  local env_file="$1"
  local compose_file="$2"

  docker compose \
    --env-file "$env_file" \
    -f "$compose_file" \
    up \
    -d \
    --remove-orphans
}

compose_rm() {
  local env_file="$1"
  local compose_file="$2"

  docker compose \
    --env-file "$env_file" \
    -f "$compose_file" \
    down \
    --remove-orphans \
    >/dev/null 2>&1 || true
}

show_container_diagnostics() {
  local container="$1"

  warn "Diagnóstico del contenedor ${container}:"

  docker inspect \
    "$container" \
    --format '
status={{.State.Status}}
health={{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}
exit_code={{.State.ExitCode}}
error={{.State.Error}}
started={{.State.StartedAt}}
finished={{.State.FinishedAt}}
' \
    2>/dev/null || true

  warn "Últimas líneas de log de ${container}:"

  docker logs \
    --tail 100 \
    "$container" \
    2>&1 || true
}

# =============================================================================
# Espera de healthcheck
# =============================================================================

wait_for_healthy() {
  local container="$1"

  local elapsed=0
  local status=""
  local health=""

  log "Esperando healthcheck de '${container}'."

  while (( elapsed < HEALTH_TIMEOUT_SECONDS )); do
    if ! container_exists "$container"; then
      fail "El contenedor '${container}' ha desaparecido."
    fi

    status="$(
      docker inspect \
        --format '{{.State.Status}}' \
        "$container"
    )"

    health="$(
      container_health "$container"
    )"

    log \
      "${container}: status=${status}, health=${health}, espera=${elapsed}s"

    if [[ "$status" == "exited" ||
          "$status" == "dead" ]]; then

      show_container_diagnostics "$container"

      fail \
        "El contenedor '${container}' terminó durante el arranque."
    fi

    if [[ "$status" == "running" &&
          "$health" == "healthy" ]]; then

      log "Contenedor healthy: ${container}"
      return 0
    fi

    if [[ "$health" == "unhealthy" ]]; then
      show_container_diagnostics "$container"

      fail \
        "El contenedor '${container}' está unhealthy."
    fi

    sleep "$HEALTH_INTERVAL_SECONDS"

    elapsed=$((elapsed + HEALTH_INTERVAL_SECONDS))
  done

  show_container_diagnostics "$container"

  fail \
    "Timeout esperando healthcheck de '${container}' después de ${HEALTH_TIMEOUT_SECONDS}s."
}

# =============================================================================
# Determinar UID/GID de la imagen
# =============================================================================

get_image_uid() {
  local image="$1"

  docker run \
    --rm \
    --entrypoint /usr/bin/id \
    "$image" \
    -u \
    2>/dev/null |
    tr -d '\r\n'
}

get_image_gid() {
  local image="$1"

  docker run \
    --rm \
    --entrypoint /usr/bin/id \
    "$image" \
    -g \
    2>/dev/null |
    tr -d '\r\n'
}

prepare_data_ownership() {
  local service="$1"
  local image="$2"
  local path="$3"

  require_directory "$path"

  log "Detectando UID/GID runtime para ${service}."

  local uid
  local gid

  uid="$(get_image_uid "$image")"
  gid="$(get_image_gid "$image")"

  [[ "$uid" =~ ^[0-9]+$ ]] ||
    fail "No se pudo detectar UID para ${image}."

  [[ "$gid" =~ ^[0-9]+$ ]] ||
    fail "No se pudo detectar GID para ${image}."

  log \
    "${service}: runtime UID=${uid}, GID=${gid}"

  log \
    "Ajustando ownership de ${path}."

  chown -R \
    "${uid}:${gid}" \
    "$path"
}

# =============================================================================
# Rollback del despliegue
# =============================================================================

rollback() {
  local exit_code=$?

  trap - EXIT

  if [[ $exit_code -eq 0 ||
        "$DEPLOY_COMMITTED" == true ]]; then
    exit "$exit_code"
  fi

  warn "Deploy incompleto. Ejecutando rollback de contenedores."

  # Solo eliminamos servicios que NO existían antes de esta ejecución.
  # No tocamos:
  #
  # - PostgreSQL
  # - bases de datos
  # - secretos
  # - configuración
  # - datos persistentes
  # - redes
  #
  # para conservar diagnóstico.

  if [[ "$N8N_CREATED_THIS_RUN" == true &&
        -n "${N8N_ENV:-}" &&
        -n "${N8N_COMPOSE:-}" ]]; then

    warn "Eliminando n8n creado en esta ejecución."

    compose_rm \
      "$N8N_ENV" \
      "$N8N_COMPOSE"
  fi

  if [[ "$DIRECTUS_CREATED_THIS_RUN" == true &&
        -n "${DIRECTUS_ENV:-}" &&
        -n "${DIRECTUS_COMPOSE:-}" ]]; then

    warn "Eliminando Directus creado en esta ejecución."

    compose_rm \
      "$DIRECTUS_ENV" \
      "$DIRECTUS_COMPOSE"
  fi

  warn "Rollback de despliegue finalizado."
  warn "Bases, secretos, configuración y datos se conservan."

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
      DEPLOY_COMMITTED=true
      exit 0
      ;;

    *)
      fail "Opción desconocida: $1"
      ;;
  esac
done

# =============================================================================
# Validación básica
# =============================================================================

[[ -n "$TENANT" ]] ||
  fail "Falta --tenant."

[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] ||
  fail "Tenant inválido: ${TENANT}"

[[ "$TENANT" != "aegora" ]] ||
  fail \
    "El tenant heredado 'aegora' no se despliega mediante este script."

is_positive_integer "$HEALTH_TIMEOUT_SECONDS" ||
  fail "HEALTH_TIMEOUT_SECONDS debe ser entero positivo."

is_positive_integer "$HEALTH_INTERVAL_SECONDS" ||
  fail "HEALTH_INTERVAL_SECONDS debe ser entero positivo."

# =============================================================================
# Prerrequisitos
# =============================================================================

require_command docker
require_command grep
require_command chown
require_command sleep

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG_ROOT="${TENANT_ROOT}/config"
TENANT_CONFIG="${TENANT_CONFIG_ROOT}/tenant.env"
TENANT_COMPOSE_ROOT="${TENANT_CONFIG_ROOT}/compose"

DIRECTUS_COMPOSE="${TENANT_COMPOSE_ROOT}/directus/compose.yml"
DIRECTUS_ENV="${TENANT_COMPOSE_ROOT}/directus/.env"

N8N_COMPOSE="${TENANT_COMPOSE_ROOT}/n8n/compose.yml"
N8N_ENV="${TENANT_COMPOSE_ROOT}/n8n/.env"

require_directory "$TENANT_ROOT"
require_directory "$TENANT_CONFIG_ROOT"

require_file "$TENANT_CONFIG"

require_file "$DIRECTUS_COMPOSE"
require_file "$DIRECTUS_ENV"

require_file "$N8N_COMPOSE"
require_file "$N8N_ENV"

# =============================================================================
# Cargar tenant.env
# =============================================================================

set -a

# shellcheck disable=SC1090
source "$TENANT_CONFIG"

set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${ENVIRONMENT:?Falta ENVIRONMENT}"

: "${DIRECTUS_VERSION:?Falta DIRECTUS_VERSION}"
: "${N8N_VERSION:?Falta N8N_VERSION}"

: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"
: "${N8N_CONTAINER:?Falta N8N_CONTAINER}"

: "${DIRECTUS_DATA_DIR:?Falta DIRECTUS_DATA_DIR}"
: "${N8N_DATA_DIR:?Falta N8N_DATA_DIR}"

: "${TENANT_BACKEND_NETWORK:?Falta TENANT_BACKEND_NETWORK}"

: "${POSTGRES_DIRECTUS_DB:?Falta POSTGRES_DIRECTUS_DB}"
: "${POSTGRES_N8N_DB:?Falta POSTGRES_N8N_DB}"

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail \
    "TENANT_ID del fichero (${TENANT_ID}) no coincide con --tenant (${TENANT})."

# =============================================================================
# Imágenes
# =============================================================================

readonly DIRECTUS_IMAGE="directus/directus:${DIRECTUS_VERSION}"
readonly N8N_IMAGE="n8nio/n8n:${N8N_VERSION}"

# =============================================================================
# Preflight PostgreSQL
# =============================================================================

container_exists "$POSTGRES_CONTAINER" ||
  fail "No existe PostgreSQL: ${POSTGRES_CONTAINER}"

container_running "$POSTGRES_CONTAINER" ||
  fail "PostgreSQL no está en ejecución."

POSTGRES_ADMIN_USER="$(
  docker exec "$POSTGRES_CONTAINER" \
    printenv POSTGRES_USER |
    tr -d '\r\n'
)"

[[ -n "$POSTGRES_ADMIN_USER" ]] ||
  fail "No se pudo detectar POSTGRES_USER."

for database in \
  "$POSTGRES_DIRECTUS_DB" \
  "$POSTGRES_N8N_DB"; do

  database_exists="$(
    docker exec "$POSTGRES_CONTAINER" \
      psql \
        --username="$POSTGRES_ADMIN_USER" \
        --dbname=postgres \
        --tuples-only \
        --no-align \
        --command="
          SELECT 1
          FROM pg_database
          WHERE datname = '${database}';
        " |
      tr -d '[:space:]'
  )"

  [[ "$database_exists" == "1" ]] ||
    fail \
      "Falta la base PostgreSQL requerida: ${database}"
done

# =============================================================================
# Preflight redes
# =============================================================================

network_exists "$TENANT_BACKEND_NETWORK" ||
  fail \
    "No existe la red privada del tenant: ${TENANT_BACKEND_NETWORK}"

network_exists "$PROXY_NETWORK" ||
  fail \
    "No existe la red proxy compartida: ${PROXY_NETWORK}"

network_has_container \
  "$TENANT_BACKEND_NETWORK" \
  "$POSTGRES_CONTAINER" ||
  fail \
    "PostgreSQL no está conectado a ${TENANT_BACKEND_NETWORK}"

# =============================================================================
# Validar Compose
# =============================================================================

log "Validando Compose Directus."

compose_config \
  "$DIRECTUS_ENV" \
  "$DIRECTUS_COMPOSE"

log "Compose Directus válido."

log "Validando Compose n8n."

compose_config \
  "$N8N_ENV" \
  "$N8N_COMPOSE"

log "Compose n8n válido."

# =============================================================================
# Estado previo
# =============================================================================

DIRECTUS_EXISTED_BEFORE=false
N8N_EXISTED_BEFORE=false

if container_exists "$DIRECTUS_CONTAINER"; then
  DIRECTUS_EXISTED_BEFORE=true
fi

if container_exists "$N8N_CONTAINER"; then
  N8N_EXISTED_BEFORE=true
fi

# =============================================================================
# PLAN
# =============================================================================

cat <<EOF

============================================================
AEGORA TENANT DEPLOYMENT
============================================================

Tenant:
  ${TENANT_ID}

Entorno:
  ${ENVIRONMENT}

Imágenes:
  Directus: ${DIRECTUS_IMAGE}
  n8n:      ${N8N_IMAGE}

Contenedores:
  Directus: ${DIRECTUS_CONTAINER}
  n8n:      ${N8N_CONTAINER}

Datos:
  Directus: ${DIRECTUS_DATA_DIR}
  n8n:      ${N8N_DATA_DIR}

Red privada:
  ${TENANT_BACKEND_NETWORK}

Red proxy:
  ${PROXY_NETWORK}

Estado previo:
  Directus existente: ${DIRECTUS_EXISTED_BEFORE}
  n8n existente:      ${N8N_EXISTED_BEFORE}

Health timeout:
  ${HEALTH_TIMEOUT_SECONDS}s

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha desplegado ningún servicio."
  log "Añade --apply para ejecutar el deploy."

  DEPLOY_COMMITTED=true
  exit 0
fi

# =============================================================================
# Pull imágenes
# =============================================================================

log "Descargando/verificando imagen Directus."

compose_pull \
  "$DIRECTUS_ENV" \
  "$DIRECTUS_COMPOSE"

log "Descargando/verificando imagen n8n."

compose_pull \
  "$N8N_ENV" \
  "$N8N_COMPOSE"

# =============================================================================
# Ownership persistencia
# =============================================================================

prepare_data_ownership \
  "Directus" \
  "$DIRECTUS_IMAGE" \
  "$DIRECTUS_DATA_DIR"

prepare_data_ownership \
  "n8n" \
  "$N8N_IMAGE" \
  "$N8N_DATA_DIR"

# =============================================================================
# Deploy Directus
# =============================================================================

if [[ "$DIRECTUS_EXISTED_BEFORE" == false ]]; then
  DIRECTUS_CREATED_THIS_RUN=true
fi

log "Desplegando Directus."

compose_up \
  "$DIRECTUS_ENV" \
  "$DIRECTUS_COMPOSE"

wait_for_healthy \
  "$DIRECTUS_CONTAINER"

# =============================================================================
# Validar redes Directus
# =============================================================================

network_has_container \
  "$TENANT_BACKEND_NETWORK" \
  "$DIRECTUS_CONTAINER" ||
  fail \
    "Directus no está conectado a la red privada."

network_has_container \
  "$PROXY_NETWORK" \
  "$DIRECTUS_CONTAINER" ||
  fail \
    "Directus no está conectado a aegora_proxy."

log "Redes Directus: OK."

# =============================================================================
# Deploy n8n
# =============================================================================

if [[ "$N8N_EXISTED_BEFORE" == false ]]; then
  N8N_CREATED_THIS_RUN=true
fi

log "Desplegando n8n."

compose_up \
  "$N8N_ENV" \
  "$N8N_COMPOSE"

wait_for_healthy \
  "$N8N_CONTAINER"

# =============================================================================
# Validar redes n8n
# =============================================================================

network_has_container \
  "$TENANT_BACKEND_NETWORK" \
  "$N8N_CONTAINER" ||
  fail \
    "n8n no está conectado a la red privada."

network_has_container \
  "$PROXY_NETWORK" \
  "$N8N_CONTAINER" ||
  fail \
    "n8n no está conectado a aegora_proxy."

log "Redes n8n: OK."

# =============================================================================
# Validaciones HTTP internas
# =============================================================================

log "Validando Directus desde su propia red HTTP."

docker exec \
  "$DIRECTUS_CONTAINER" \
  wget \
    --spider \
    -q \
    http://127.0.0.1:8055/server/info ||
  fail \
    "La validación HTTP interna de Directus ha fallado."

log "Directus HTTP: OK."

log "Validando n8n desde su propia red HTTP."

docker exec \
  "$N8N_CONTAINER" \
  wget \
    --spider \
    -q \
    http://127.0.0.1:5678/healthz ||
  fail \
    "La validación HTTP interna de n8n ha fallado."

log "n8n HTTP: OK."

# =============================================================================
# Comprobación final
# =============================================================================

directus_status="$(
  docker inspect \
    --format '{{.State.Status}}' \
    "$DIRECTUS_CONTAINER"
)"

directus_health="$(
  container_health "$DIRECTUS_CONTAINER"
)"

n8n_status="$(
  docker inspect \
    --format '{{.State.Status}}' \
    "$N8N_CONTAINER"
)"

n8n_health="$(
  container_health "$N8N_CONTAINER"
)"

[[ "$directus_status" == "running" &&
   "$directus_health" == "healthy" ]] ||
  fail \
    "Directus no cumple el estado final esperado."

[[ "$n8n_status" == "running" &&
   "$n8n_health" == "healthy" ]] ||
  fail \
    "n8n no cumple el estado final esperado."

# =============================================================================
# Commit lógico
# =============================================================================

DEPLOY_COMMITTED=true

cat <<EOF

============================================================
TENANT DESPLEGADO
============================================================

Tenant:
  ${TENANT_ID}

Directus:
  container: ${DIRECTUS_CONTAINER}
  status:    ${directus_status}
  health:    ${directus_health}

n8n:
  container: ${N8N_CONTAINER}
  status:    ${n8n_status}
  health:    ${n8n_health}

Red privada:
  ${TENANT_BACKEND_NETWORK}

Red proxy:
  ${PROXY_NETWORK}

Estado:
  CORE DESPLEGADO

Pendiente:
  - Caddy
  - DNS
  - S3 / Restic
  - timers
  - Notification Center por tenant
  - Booking

Siguiente fase:
  publish-tenant / Caddy

============================================================
EOF
