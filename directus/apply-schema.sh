#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora - Apply Directus schema
#
# Aplica el schema Directus versionado de Aegora a un tenant managed.
#
# Seguridad:
#   - PLAN / dry-run por defecto.
#   - --apply requerido para modificar Directus.
#   - valida tenant, contenedor, health y versión.
#   - copia temporalmente el snapshot dentro del contenedor.
#   - elimina siempre el fichero temporal.
#
# Uso:
#
#   apply-schema.sh --tenant demo
#   apply-schema.sh --tenant demo --apply
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly SCHEMA_FILE="${PLATFORM_ROOT}/directus/schema/base.yaml"
readonly EXPECTED_DIRECTUS_VERSION="12.2.0"

TENANT=""
APPLY=false

TENANT_ROOT=""
TENANT_CONFIG=""
TENANT_ID=""
DIRECTUS_CONTAINER=""
DIRECTUS_VERSION=""
DIRECTUS_HEALTH=""

CONTAINER_SCHEMA="/tmp/aegora-schema.yaml"

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

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
  local exit_code=$?

  trap - EXIT

  if [[ -n "${DIRECTUS_CONTAINER:-}" ]] &&
     docker inspect "$DIRECTUS_CONTAINER" >/dev/null 2>&1; then

    docker exec \
      "$DIRECTUS_CONTAINER" \
      rm -f "$CONTAINER_SCHEMA" \
      >/dev/null 2>&1 || true
  fi

  exit "$exit_code"
}

trap cleanup EXIT
trap 'fail "Fallo en la línea ${LINENO}: ${BASH_COMMAND}"' ERR

# =============================================================================
# Helpers
# =============================================================================

usage() {
  cat <<'EOF'
Uso:

  apply-schema.sh \
    --tenant TENANT \
    [--apply]

Sin --apply:
  valida el tenant y ejecuta Directus schema apply --dry-run.

Con --apply:
  aplica directus/schema/base.yaml al tenant.

Ejemplos:

  sudo /usr/bin/bash \
    /opt/aegora/platform/directus/apply-schema.sh \
    --tenant demo

  sudo /usr/bin/bash \
    /opt/aegora/platform/directus/apply-schema.sh \
    --tenant demo \
    --apply
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

require_command docker
require_file "$SCHEMA_FILE"

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"

require_file "$TENANT_CONFIG"

# =============================================================================
# Tenant context
# =============================================================================

set -a

# shellcheck disable=SC1090
source "$TENANT_CONFIG"

set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail \
    "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

docker inspect "$DIRECTUS_CONTAINER" >/dev/null 2>&1 ||
  fail "No existe el contenedor Directus: ${DIRECTUS_CONTAINER}"

container_running "$DIRECTUS_CONTAINER" ||
  fail "Directus no está running: ${DIRECTUS_CONTAINER}"

DIRECTUS_HEALTH="$(
  container_health "$DIRECTUS_CONTAINER"
)"

[[ "$DIRECTUS_HEALTH" == "healthy" ]] ||
  fail "Directus no está healthy: ${DIRECTUS_HEALTH}"

DIRECTUS_VERSION="$(
  docker exec \
    "$DIRECTUS_CONTAINER" \
    node \
      -p \
      "require('/directus/package.json').version" |
    tr -d '\r\n'
)"

[[ "$DIRECTUS_VERSION" == "$EXPECTED_DIRECTUS_VERSION" ]] ||
  fail \
    "Versión Directus incorrecta. Esperada=${EXPECTED_DIRECTUS_VERSION}, actual=${DIRECTUS_VERSION}"

# =============================================================================
# Copiar schema al contenedor
# =============================================================================

log "Copiando schema versionado al contenedor."

docker cp \
  "$SCHEMA_FILE" \
  "${DIRECTUS_CONTAINER}:${CONTAINER_SCHEMA}"

# =============================================================================
# Estado
# =============================================================================

cat <<EOF

============================================================
AEGORA DIRECTUS SCHEMA
============================================================

Tenant:
  ${TENANT_ID}

Directus:
  container: ${DIRECTUS_CONTAINER}
  version:   ${DIRECTUS_VERSION}
  health:    ${DIRECTUS_HEALTH}

Schema:
  ${SCHEMA_FILE}

Modo:
  $([[ "$APPLY" == true ]] && printf 'APPLY' || printf 'DRY RUN')

============================================================

EOF

# =============================================================================
# Dry-run
# =============================================================================

if [[ "$APPLY" != true ]]; then
  log "Calculando diferencias de schema. No se realizarán cambios."

  docker exec \
    "$DIRECTUS_CONTAINER" \
    node /directus/cli.js \
    schema apply \
    --dry-run \
    "$CONTAINER_SCHEMA"

  log "Dry-run completado correctamente."
  exit 0
fi

# =============================================================================
# Apply
# =============================================================================

[[ $EUID -eq 0 ]] ||
  fail "--apply debe ejecutarse como root."

log "Aplicando schema al tenant '${TENANT_ID}'."

docker exec \
  "$DIRECTUS_CONTAINER" \
  node /directus/cli.js \
  schema apply \
    --yes \
    "$CONTAINER_SCHEMA"

log "Schema aplicado correctamente."

# =============================================================================
# Verificación de idempotencia
# =============================================================================

log "Verificando estado posterior mediante dry-run."

docker exec \
  "$DIRECTUS_CONTAINER" \
  node /directus/cli.js \
  schema apply \
    --dry-run \
    "$CONTAINER_SCHEMA"

log "Verificación posterior completada."

cat <<EOF

============================================================
DIRECTUS SCHEMA APLICADO
============================================================

Tenant:
  ${TENANT_ID}

Schema:
  ${SCHEMA_FILE}

Estado:
  OK

============================================================
EOF
