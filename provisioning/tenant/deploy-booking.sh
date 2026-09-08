#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora · Booking API — build + deploy por tenant
#
# Responsabilidad:
#   - mantener un checkout de aegora-booking en el VPS (opción A, build local);
#   - construir la imagen  aegora-booking:<git-sha>;
#   - renderizar el stack booking del tenant desde templates/tenant-stack/booking;
#   - desplegar el contenedor y esperar GET /api/health.
#
# NO hace:
#   - crear el tenant, bases ni redes;
#   - generar el BOOKING_API_TOKEN (usa provision-booking-access.sh);
#   - configurar Caddy (usa publish-tenant.sh).
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly TEMPLATE_ROOT="${PLATFORM_ROOT}/templates/tenant-stack/booking"
readonly RENDERER="${PLATFORM_ROOT}/provisioning/tenant/render-template.py"

readonly POSTGRES_CONTAINER="aegora-postgres"
readonly PROXY_NETWORK="aegora_proxy"

readonly BOOKING_REPO_URL="${BOOKING_REPO_URL:-https://github.com/iasagu25/aegora-booking.git}"
readonly BOOKING_SRC_DIR="${BOOKING_SRC_DIR:-/opt/aegora/src/aegora-booking}"

readonly HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-120}"
readonly HEALTH_INTERVAL_SECONDS="${HEALTH_INTERVAL_SECONDS:-4}"

TENANT=""
REF="main"
APPLY=false

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
warn() { log "AVISO: $*" >&2; }
fail() { log "ERROR: $*" >&2; exit 1; }

trap 'fail "Fallo en la línea ${LINENO}: ${BASH_COMMAND}"' ERR

usage() {
  cat <<'EOF'
Uso:
  deploy-booking.sh --tenant TENANT [--ref GIT_REF] [--apply]

Sin --apply:
  preflight + plan. No construye ni despliega.

Con --apply:
  actualiza el checkout a GIT_REF (rama, tag o sha; por defecto main),
  construye la imagen, renderiza el stack y despliega el contenedor.

Variables opcionales:
  BOOKING_REPO_URL         (por defecto github.com/iasagu25/aegora-booking.git)
  BOOKING_SRC_DIR          (por defecto /opt/aegora/src/aegora-booking)
  HEALTH_TIMEOUT_SECONDS   (por defecto 120)
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Falta el comando requerido: $1"
}
require_file() { [[ -f "$1" ]] || fail "Falta el fichero requerido: $1"; }
container_running() {
  [[ "$(docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null)" == "running" ]]
}
container_health() {
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null
}
network_exists() { docker network inspect "$1" >/dev/null 2>&1; }

wait_for_healthy() {
  local container="$1" elapsed=0 status health
  log "Esperando healthcheck de '${container}'."
  while (( elapsed < HEALTH_TIMEOUT_SECONDS )); do
    status="$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo missing)"
    health="$(container_health "$container")"
    log "${container}: status=${status}, health=${health}, espera=${elapsed}s"
    [[ "$status" == "running" && "$health" == "healthy" ]] && return 0
    if [[ "$status" == "exited" || "$status" == "dead" || "$health" == "unhealthy" ]]; then
      warn "Diagnóstico de ${container}:"
      docker logs --tail 100 "$container" 2>&1 || true
      fail "El contenedor '${container}' no arrancó correctamente."
    fi
    sleep "$HEALTH_INTERVAL_SECONDS"
    elapsed=$((elapsed + HEALTH_INTERVAL_SECONDS))
  done
  docker logs --tail 100 "$container" 2>&1 || true
  fail "Timeout esperando healthcheck de '${container}'."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      [[ $# -ge 2 ]] || fail "Falta valor para --tenant."
      TENANT="$2"; shift 2 ;;
    --ref)
      [[ $# -ge 2 ]] || fail "Falta valor para --ref."
      REF="$2"; shift 2 ;;
    --apply)
      APPLY=true; shift ;;
    --help|-h)
      usage; trap - ERR; exit 0 ;;
    *)
      fail "Opción desconocida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"
[[ "$TENANT" != "aegora" ]] || fail "El tenant heredado 'aegora' está protegido."
[[ "$REF" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] || fail "Ref inválida: ${REF}"

require_command docker
require_command git
require_command python3
require_file "$RENDERER"
require_file "${TEMPLATE_ROOT}/compose.yml.tpl"
require_file "${TEMPLATE_ROOT}/.env.tpl"

readonly TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
readonly TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"
readonly POSTGRES_SECRET="${TENANT_ROOT}/secrets/postgres.env"
readonly BOOKING_SECRET="${TENANT_ROOT}/secrets/booking.env"

require_file "$TENANT_CONFIG"
require_file "$POSTGRES_SECRET"
[[ -f "$BOOKING_SECRET" ]] ||
  fail "Falta ${BOOKING_SECRET}. Ejecuta antes: provision-booking-access.sh --tenant ${TENANT} --apply"

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
# shellcheck disable=SC1090
source "$POSTGRES_SECRET"
# shellcheck disable=SC1090
source "$BOOKING_SECRET"
set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${BOOKING_CONTAINER:?Falta BOOKING_CONTAINER}"
: "${TENANT_BACKEND_NETWORK:?Falta TENANT_BACKEND_NETWORK}"
: "${TENANT_COMPOSE_ROOT:?Falta TENANT_COMPOSE_ROOT}"
: "${POSTGRES_DIRECTUS_DB:?Falta POSTGRES_DIRECTUS_DB}"
: "${POSTGRES_DIRECTUS_USER:?Falta POSTGRES_DIRECTUS_USER}"
: "${POSTGRES_DIRECTUS_PASSWORD:?Falta POSTGRES_DIRECTUS_PASSWORD}"
: "${BOOKING_API_TOKEN:?Falta BOOKING_API_TOKEN}"

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

# =============================================================================
# Preflight
# =============================================================================

container_running "$POSTGRES_CONTAINER" || fail "Postgres no está running: ${POSTGRES_CONTAINER}"
network_exists "$TENANT_BACKEND_NETWORK" || fail "No existe la red del tenant: ${TENANT_BACKEND_NETWORK}"
network_exists "$PROXY_NETWORK" || fail "No existe la red proxy: ${PROXY_NETWORK}"

docker network inspect "$TENANT_BACKEND_NETWORK" \
  --format '{{range .Containers}}{{println .Name}}{{end}}' 2>/dev/null |
  grep -Fxq "$POSTGRES_CONTAINER" ||
  fail "${POSTGRES_CONTAINER} no está conectado a ${TENANT_BACKEND_NETWORK}; el Booking API no podría alcanzar la BD."

POSTGRES_ADMIN_USER="$(docker exec "$POSTGRES_CONTAINER" printenv POSTGRES_USER | tr -d '\r\n')"
[[ -n "$POSTGRES_ADMIN_USER" ]] || fail "No se pudo detectar POSTGRES_USER."

db_present="$(
  docker exec "$POSTGRES_CONTAINER" psql \
    --username="$POSTGRES_ADMIN_USER" --dbname=postgres \
    --tuples-only --no-align \
    --command="SELECT 1 FROM pg_database WHERE datname = '${POSTGRES_DIRECTUS_DB}';" |
    tr -d '[:space:]'
)"
[[ "$db_present" == "1" ]] || fail "No existe la BD de negocio: ${POSTGRES_DIRECTUS_DB}"

# =============================================================================
# Checkout + imagen
# =============================================================================

if [[ ! -d "${BOOKING_SRC_DIR}/.git" ]]; then
  if [[ "$APPLY" != true ]]; then
    log "PLAN: se clonaría ${BOOKING_REPO_URL} en ${BOOKING_SRC_DIR}"
  else
    install -d -m 755 "$(dirname "$BOOKING_SRC_DIR")"
    log "Clonando ${BOOKING_REPO_URL}"
    git clone "$BOOKING_REPO_URL" "$BOOKING_SRC_DIR"
  fi
fi

RESOLVED_SHA=""
if [[ -d "${BOOKING_SRC_DIR}/.git" ]]; then
  git -C "$BOOKING_SRC_DIR" fetch --prune --tags origin
  if git -C "$BOOKING_SRC_DIR" rev-parse --verify --quiet "origin/${REF}" >/dev/null; then
    [[ "$APPLY" != true ]] || git -C "$BOOKING_SRC_DIR" checkout -B "$REF" "origin/${REF}"
    RESOLVED_SHA="$(git -C "$BOOKING_SRC_DIR" rev-parse --short=12 "origin/${REF}")"
  else
    [[ "$APPLY" != true ]] || git -C "$BOOKING_SRC_DIR" checkout --detach "$REF"
    RESOLVED_SHA="$(git -C "$BOOKING_SRC_DIR" rev-parse --short=12 "$REF")"
  fi
fi
[[ -n "$RESOLVED_SHA" ]] || RESOLVED_SHA="pending"

BOOKING_IMAGE="aegora-booking:${RESOLVED_SHA}"

# =============================================================================
# Variables de render
# =============================================================================

ENC_USER="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$POSTGRES_DIRECTUS_USER")"
ENC_PASS="$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$POSTGRES_DIRECTUS_PASSWORD")"

export BOOKING_IMAGE
export BOOKING_DATABASE_URL="postgres://${ENC_USER}:${ENC_PASS}@${POSTGRES_CONTAINER}:5432/${POSTGRES_DIRECTUS_DB}"
export BOOKING_API_TOKEN
export TENANT_ID BOOKING_CONTAINER TENANT_BACKEND_NETWORK

BOOKING_DIR="${TENANT_COMPOSE_ROOT}/booking"
BOOKING_COMPOSE="${BOOKING_DIR}/compose.yml"
BOOKING_ENV="${BOOKING_DIR}/.env"

cat <<EOF

============================================================
AEGORA · BOOKING DEPLOY
============================================================

Tenant:        ${TENANT_ID}
Ref:           ${REF}  ->  ${RESOLVED_SHA}
Imagen:        ${BOOKING_IMAGE}
Fuente:        ${BOOKING_SRC_DIR}
Contenedor:    ${BOOKING_CONTAINER}
BD negocio:    ${POSTGRES_DIRECTUS_DB} (usuario ${POSTGRES_DIRECTUS_USER})
Red privada:   ${TENANT_BACKEND_NETWORK}
Compose:       ${BOOKING_COMPOSE}
Modo:          $([[ "$APPLY" == true ]] && printf 'APPLY' || printf 'PLAN')

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha construido ni desplegado nada."
  trap - ERR
  exit 0
fi

[[ $EUID -eq 0 ]] || fail "--apply debe ejecutarse como root."

# =============================================================================
# Build
# =============================================================================

log "Construyendo ${BOOKING_IMAGE}."
docker build \
  --build-arg DATABASE_URL="postgres://build:build@127.0.0.1:5432/build" \
  -t "$BOOKING_IMAGE" \
  "$BOOKING_SRC_DIR"

# =============================================================================
# Render
# =============================================================================

install -d -m 755 "$BOOKING_DIR"

python3 "$RENDERER" "${TEMPLATE_ROOT}/compose.yml.tpl" "$BOOKING_COMPOSE"
python3 "$RENDERER" "${TEMPLATE_ROOT}/.env.tpl" "$BOOKING_ENV"

chmod 644 "$BOOKING_COMPOSE"
chmod 600 "$BOOKING_ENV"

docker compose -f "$BOOKING_COMPOSE" --env-file "$BOOKING_ENV" config >/dev/null
log "Compose booking válido."

# =============================================================================
# Deploy
# =============================================================================

log "Desplegando ${BOOKING_CONTAINER}."
docker compose -f "$BOOKING_COMPOSE" --env-file "$BOOKING_ENV" up -d --remove-orphans

wait_for_healthy "$BOOKING_CONTAINER"

docker exec "$BOOKING_CONTAINER" wget --spider -q http://127.0.0.1:3000/api/health ||
  fail "La validación HTTP interna del Booking API ha fallado."

for network in "$TENANT_BACKEND_NETWORK" "$PROXY_NETWORK"; do
  docker network inspect "$network" \
    --format '{{range .Containers}}{{println .Name}}{{end}}' 2>/dev/null |
    grep -Fxq "$BOOKING_CONTAINER" ||
    fail "El Booking API no está conectado a ${network}."
done

trap - ERR

cat <<EOF

============================================================
BOOKING API DESPLEGADO
============================================================

Tenant:      ${TENANT_ID}
Imagen:      ${BOOKING_IMAGE}
Contenedor:  ${BOOKING_CONTAINER}  (healthy)
Endpoint:    http://${BOOKING_CONTAINER}:3000  (interno)
Publicación: pendiente de publish-tenant.sh (${BOOKING_HOST:-reservas.<dominio>})

============================================================
EOF
