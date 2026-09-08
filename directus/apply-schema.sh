#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly SCHEMA_FILE="${PLATFORM_ROOT}/directus/schema/base.yaml"
readonly SQL_INDEXES_FILE="${PLATFORM_ROOT}/directus/sql/booking-indexes.sql"
readonly POSTGRES_CONTAINER="aegora-postgres"

TENANT=""
APPLY=false
TENANT_ROOT=""
TENANT_CONFIG=""
TENANT_ID=""
DIRECTUS_CONTAINER=""
DIRECTUS_VERSION=""
DIRECTUS_HEALTH=""
DECLARED_DIRECTUS_VERSION=""
CONTAINER_SCHEMA="/tmp/aegora-schema.yaml"
DB_DATABASE=""
DB_USER=""
DB_PASSWORD=""

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

cleanup() {
  local exit_code=$?
  trap - EXIT

  if [[ -n "${DIRECTUS_CONTAINER:-}" ]] &&
     docker inspect "$DIRECTUS_CONTAINER" >/dev/null 2>&1; then
    docker exec "$DIRECTUS_CONTAINER" rm -f "$CONTAINER_SCHEMA" >/dev/null 2>&1 || true
  fi

  exit "$exit_code"
}

trap cleanup EXIT
trap 'fail "Fallo en la línea ${LINENO}: ${BASH_COMMAND}"' ERR

usage() {
  cat <<'EOF'
Uso:
  apply-schema.sh --tenant TENANT [--apply]

Sin --apply:
  valida el tenant, ejecuta Directus schema apply --dry-run y valida
  directus/sql/booking-indexes.sql contra la BD del tenant dentro de
  una transacción que se revierte (BEGIN ... ROLLBACK).

Con --apply:
  aplica directus/schema/base.yaml al tenant, verifica el estado base,
  aplica directus/sql/booking-indexes.sql (índices/constraints
  idempotentes) dentro de BEGIN ... COMMIT, y restaura después la
  configuración UI administrada por Aegora.

Nota:
  Los custom displays se gestionan fuera de base.yaml mediante
  configure-directus-ui.sh.
  La capa SQL se ejecuta vía psql en el contenedor aegora-postgres
  usando las credenciales de BD del contenedor Directus.
EOF
}

require_command() { command -v "$1" >/dev/null 2>&1 || fail "Falta el comando requerido: $1"; }
require_file() { [[ -f "$1" ]] || fail "Falta el fichero requerido: $1"; }
container_running() { [[ "$(docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null)" == "running" ]]; }
container_health() {
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}' "$1" 2>/dev/null
}

# Ejecuta SQL_INDEXES_FILE contra la BD del tenant envuelto en una
# transacción. $1 = COMMIT (persistir) | ROLLBACK (validar sin persistir).
# El control de transacción se inyecta aquí, no en el .sql.
run_index_sql() {
  local closer="$1"

  {
    printf "BEGIN;\n"
    printf "SET lock_timeout = '5s';\n"
    cat "$SQL_INDEXES_FILE"
    printf "%s;\n" "$closer"
  } | PGPASSWORD="$DB_PASSWORD" docker exec -i -e PGPASSWORD \
        "$POSTGRES_CONTAINER" \
        psql \
          -v ON_ERROR_STOP=1 \
          --no-psqlrc \
          -U "$DB_USER" \
          -d "$DB_DATABASE" \
          -f -
}

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

require_command docker
require_file "$SCHEMA_FILE"
require_file "$SQL_INDEXES_FILE"

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"
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

docker inspect "$DIRECTUS_CONTAINER" >/dev/null 2>&1 ||
  fail "No existe el contenedor Directus: ${DIRECTUS_CONTAINER}"

container_running "$DIRECTUS_CONTAINER" ||
  fail "Directus no está running: ${DIRECTUS_CONTAINER}"

DIRECTUS_HEALTH="$(container_health "$DIRECTUS_CONTAINER")"

[[ "$DIRECTUS_HEALTH" == "healthy" ]] ||
  fail "Directus no está healthy: ${DIRECTUS_HEALTH}"

DIRECTUS_VERSION="$(
  docker exec     "$DIRECTUS_CONTAINER"     node     -p "require('/directus/package.json').version" |
    tr -d '\r\n'
)"

[[ "$DIRECTUS_VERSION" == "$DECLARED_DIRECTUS_VERSION" ]] ||
  fail "Versión Directus inconsistente. Declarada=${DECLARED_DIRECTUS_VERSION}, contenedor=${DIRECTUS_VERSION}"

docker inspect "$POSTGRES_CONTAINER" >/dev/null 2>&1 ||
  fail "No existe el contenedor Postgres: ${POSTGRES_CONTAINER}"

container_running "$POSTGRES_CONTAINER" ||
  fail "Postgres no está running: ${POSTGRES_CONTAINER}"

DB_DATABASE="$(docker exec "$DIRECTUS_CONTAINER" node -p "process.env.DB_DATABASE || ''" | tr -d '\r\n')"
DB_USER="$(docker exec "$DIRECTUS_CONTAINER" node -p "process.env.DB_USER || ''" | tr -d '\r\n')"
DB_PASSWORD="$(docker exec "$DIRECTUS_CONTAINER" node -p "process.env.DB_PASSWORD || ''" | tr -d '\r\n')"

[[ -n "$DB_DATABASE" && -n "$DB_USER" ]] ||
  fail "No se pudieron leer las credenciales de BD del contenedor Directus."

log "Copiando schema versionado al contenedor."

docker cp   "$SCHEMA_FILE"   "${DIRECTUS_CONTAINER}:${CONTAINER_SCHEMA}"

cat <<EOF

============================================================
AEGORA DIRECTUS SCHEMA
============================================================

Tenant:
  ${TENANT_ID}

Directus:
  container: ${DIRECTUS_CONTAINER}
  declared:  ${DECLARED_DIRECTUS_VERSION}
  actual:    ${DIRECTUS_VERSION}
  health:    ${DIRECTUS_HEALTH}

Schema:
  ${SCHEMA_FILE}

SQL:
  ${SQL_INDEXES_FILE}
  -> ${POSTGRES_CONTAINER} / db=${DB_DATABASE} user=${DB_USER}

Modo:
  $([[ "$APPLY" == true ]] && printf 'APPLY' || printf 'DRY RUN')

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "Calculando diferencias de schema. No se realizarán cambios."

  docker exec     "$DIRECTUS_CONTAINER"     node     /directus/cli.js     schema apply     --dry-run     "$CONTAINER_SCHEMA"

  log "Dry-run de schema completado correctamente."

  log "Validando índices/constraints SQL (BEGIN ... ROLLBACK, sin persistir)."

  run_index_sql ROLLBACK

  log "Validación SQL completada."

  cat <<'EOF'

Nota:
  El dry-run puede mostrar diferencias en custom displays mientras
  el overlay UI administrado esté activo. Es esperado.

  La validación SQL ejecuta el fichero dentro de una transacción que
  se revierte: crea los índices y hace ROLLBACK, por lo que en la
  primera pasada puede construirlos y descartarlos. No persiste nada.

EOF

  exit 0
fi

[[ $EUID -eq 0 ]] || fail "--apply debe ejecutarse como root."

log "Aplicando schema al tenant '${TENANT_ID}'."

docker exec   "$DIRECTUS_CONTAINER"   node   /directus/cli.js   schema apply   --yes   "$CONTAINER_SCHEMA"

log "Schema aplicado correctamente."

log "Verificando estado base posterior mediante dry-run."

docker exec   "$DIRECTUS_CONTAINER"   node   /directus/cli.js   schema apply   --dry-run   "$CONTAINER_SCHEMA"

log "Verificación posterior del schema completada."

log "Aplicando índices/constraints SQL idempotentes (BEGIN ... COMMIT)."

run_index_sql COMMIT

log "Índices/constraints SQL aplicados correctamente."

cat <<EOF

============================================================
DIRECTUS SCHEMA APLICADO
============================================================

Tenant:
  ${TENANT_ID}

Schema:
  ${SCHEMA_FILE}

SQL:
  ${SQL_INDEXES_FILE}

Estado:
  OK

============================================================
EOF
