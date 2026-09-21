#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora · vaciar los datos de negocio de un tenant
#
#   reset-tenant-data.sh --tenant TENANT [--apply --yes-destroy-data]
#
# Para qué: cambiar un tenant de demostración de una vertical a otra (no se puede
# enseñar una gestoría con la ficha de un gimnasio dentro), y devolverlo a limpio
# después de una demo en la que el cliente reservó tres citas de prueba.
#
# QUÉ BORRA: contactos, citas, tareas, conversaciones y TODA la configuración de
# negocio (servicios, empleados, recursos, horarios, ubicaciones y la KB).
#
# QUÉ NO TOCA: el esquema, los permisos, los workflows, las credenciales, los
# usuarios de Directus ni la configuración del tenant. Esto vacía tablas, no
# desmonta nada.
#
# Se borra por SQL y no por la API a propósito: es un vaciado masivo y el orden
# de las claves ajenas es la única lógica que hace falta. Por API serían miles de
# llamadas y pasaría por el trigger de supresión de contactos, que aquí no pinta
# nada porque las citas ya no existen cuando les toca.
#
# NO es un backup ni lo sustituye. Si el tenant tiene algo que valga, sácalo
# antes: esto no se puede deshacer.
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly POSTGRES_CONTAINER="aegora-postgres"

# Orden de borrado: de lo que depende hacia lo que sostiene. Cambiarlo rompe por
# claves ajenas, así que la lista ES la lógica del script.
readonly TABLAS=(
  appointment_resources
  appointments
  tasks
  conversation_messages
  conversation_sessions
  contact_phones
  contacts
  availability_exceptions
  availability_rules
  service_resources
  services
  resources
  employees
  calendars
  locations
  knowledge
)

TENANT=""
APPLY=false
CONFIRMADO=false

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  reset-tenant-data.sh --tenant TENANT [--apply --yes-destroy-data]

Sin --apply:  cuenta lo que hay en cada tabla y no toca nada.
Con --apply:  exige ADEMÁS --yes-destroy-data. Borra y no se puede deshacer.

Vacía los datos de negocio de un tenant para cambiarlo de vertical o dejarlo
limpio después de una demostración. No toca esquema, permisos ni workflows.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant) [[ $# -ge 2 ]] || fail "Falta valor para --tenant."; TENANT="$2"; shift 2 ;;
    --apply)  APPLY=true; shift ;;
    --yes-destroy-data) CONFIRMADO=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Opción desconocida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"

# `ops` es el único tenant cuyos datos son de Aegora y valen algo. Que exista una
# orden capaz de vaciarlo por error es peor que la molestia de no poder usarla.
[[ "$TENANT" != "ops" ]] ||
  fail "'ops' lleva los datos del propio negocio. Esta orden no lo vacía nunca.
Si de verdad hay que hacerlo, se hace a mano y con un backup delante."

TENANT_CONFIG="${TENANTS_ROOT}/${TENANT}/config/tenant.env"
if [[ ! -r "$TENANT_CONFIG" ]]; then
  [[ $EUID -eq 0 ]] && fail "No existe ${TENANT_CONFIG}"
  fail "No se puede leer ${TENANT_CONFIG}
O no existe, o es cuestión de permisos (los secretos del tenant son de root).
Prueba con sudo."
fi

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
set +a
: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"

[[ "$(docker inspect --format '{{.State.Status}}' "$DIRECTUS_CONTAINER" 2>/dev/null)" == "running" ]] ||
  fail "Directus no está running: ${DIRECTUS_CONTAINER}"

DB_DATABASE="$(docker exec "$DIRECTUS_CONTAINER" node -p "process.env.DB_DATABASE || ''" | tr -d '\r\n')"
DB_USER="$(docker exec "$DIRECTUS_CONTAINER" node -p "process.env.DB_USER || ''" | tr -d '\r\n')"
DB_PASSWORD="$(docker exec "$DIRECTUS_CONTAINER" node -p "process.env.DB_PASSWORD || ''" | tr -d '\r\n')"
[[ -n "$DB_DATABASE" && -n "$DB_USER" ]] ||
  fail "No se pudieron leer las credenciales de BD del contenedor Directus."

psql_tenant() {
  PGPASSWORD="$DB_PASSWORD" docker exec -i -e PGPASSWORD "$POSTGRES_CONTAINER" \
    psql -v ON_ERROR_STOP=1 --no-psqlrc -U "$DB_USER" -d "$DB_DATABASE" -f -
}

CONTEOS="$( { for t in "${TABLAS[@]}"; do
    printf "SELECT '%s' AS tabla, count(*) AS filas FROM %s UNION ALL\n" "$t" "$t"
  done; printf "SELECT '(total)', 0 ORDER BY 1;\n"; } | psql_tenant -t -A -F ' ' 2>/dev/null )" ||
  fail "No se pudieron contar las filas. ¿Existe el esquema en este tenant?"

cat <<PLAN

============================================================
AEGORA · VACIAR LOS DATOS DE UN TENANT
============================================================

Tenant:
  ${TENANT}   (db ${DB_DATABASE})

Lo que hay ahora:
$(printf '%s\n' "$CONTEOS" | grep -v '^(total)' | awk '{printf "  %-26s %s\n", $1, $2}')

Se borra TODO eso: contactos, citas, tareas, conversaciones y la configuración
de negocio entera (servicios, empleados, recursos, horarios, ubicaciones, KB).

NO se tocan: esquema, permisos, workflows, credenciales ni usuarios.

Modo:
  $([[ "$APPLY" == true ]] && printf 'APPLY' || printf 'PLAN')

============================================================

PLAN

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha borrado nada."
  exit 0
fi

[[ $EUID -eq 0 ]] || fail "--apply debe ejecutarse como root."
[[ "$CONFIRMADO" == true ]] ||
  fail "Falta --yes-destroy-data.
Se pide aparte de --apply a propósito: --apply lo escribes cincuenta veces al día
y esto no se puede deshacer."

log "Vaciando ${TENANT}…"
{
  printf "BEGIN;\n"
  # Todo en una transacción: un fallo a medias dejaría el tenant con servicios sin
  # recursos, que es peor que no haber empezado.
  for t in "${TABLAS[@]}"; do
    printf "DELETE FROM %s;\n" "$t"
  done
  printf "COMMIT;\n"
} | psql_tenant

log "Vaciado."
cat <<FINAL

Siguiente paso, cargar un conjunto:

  sudo ${TENANTS_ROOT%/tenants}/platform/directus/seed/load-seed.sh --tenant ${TENANT} --set gestoria --apply

FINAL
