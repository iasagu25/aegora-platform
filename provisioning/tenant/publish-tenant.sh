#!/usr/bin/env bash

set -Eeuo pipefail

# Espera única a los contenedores (ver el fichero): nunca sleep ni un healthy exigido sin esperar.
# shellcheck source=/dev/null
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../scripts/lib/esperar-contenedor.sh"
IFS=$'\n\t'

# =============================================================================
# Aegora tenant publication
#
# Responsabilidad:
#
#   - validar tenant desplegado;
#   - comprobar Directus/n8n healthy;
#   - generar fragmento Caddy;
#   - validar configuración completa;
#   - aplicar reload sin downtime;
#   - rollback del fragmento si el reload falla.
#
# NO hace:
#
#   - DNS;
#   - provisioning CORE;
#   - deploy de servicios;
#   - S3/Restic;
#   - timers;
#   - Booking.
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"

readonly CADDY_CONTAINER="aegora-caddy"
readonly CADDY_CONFIG="/etc/caddy/Caddyfile"

readonly CADDY_RUNTIME_SITES_HOST="/opt/aegora/data/caddy/sites"
readonly CADDY_RUNTIME_SITES_CONTAINER="/etc/caddy/runtime-sites"

readonly PROXY_NETWORK="aegora_proxy"
readonly MANAGED_DOMAIN="aegora.es"

TENANT=""

MODE="plan"
ALLOW_CUSTOM_DOMAIN=false

TENANT_ROOT=""
TENANT_CONFIG=""
SITE_FILE=""
BACKUP_SITE_FILE=""

SITE_CHANGED=false
PUBLISH_COMMITTED=false

# =============================================================================
# Utilidades
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

usage() {
  cat <<'EOF'
Uso:

  publish-tenant.sh \
    --tenant TENANT \
    [--validate-only | --apply] \
    [--allow-custom-domain]

Modos:

  sin opción:
      muestra el PLAN.

  --validate-only:
      instala temporalmente el fragmento,
      valida la configuración completa de Caddy
      y restaura el estado anterior.
      No hace reload.

  --apply:
      instala el fragmento,
      valida Caddy,
      ejecuta caddy reload.

Por defecto únicamente se permiten dominios bajo aegora.es.

Ejemplo real:

  sudo /usr/bin/bash \
    /opt/aegora/platform/provisioning/tenant/publish-tenant.sh \
    --tenant gestoria-lopez \
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

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
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

is_managed_hostname() {
  local hostname="$1"

  [[ "$hostname" == "$MANAGED_DOMAIN" ||
     "$hostname" == *".${MANAGED_DOMAIN}" ]]
}

validate_hostname() {
  local hostname="$1"

  [[ "$hostname" =~ ^[A-Za-z0-9.-]+$ ]] ||
    fail "Hostname inválido: ${hostname}"

  [[ "$hostname" == *.* ]] ||
    fail "Hostname incompleto: ${hostname}"

  [[ "$hostname" != .* ]] ||
    fail "Hostname inválido: ${hostname}"

  [[ "$hostname" != *. ]] ||
    fail "Hostname inválido: ${hostname}"
}

validate_service() {
  local label="$1"
  local container="$2"

  container_exists "$container" ||
    fail "${label}: no existe el contenedor ${container}"

  # Se ESPERA a que esté sano, no se exige: publicar justo tras un despliegue o
  # un reinicio lo encontraba en "starting" y abortaba.
  esperar_healthy "$container"

  network_has_container \
    "$PROXY_NETWORK" \
    "$container" ||
    fail "${label}: ${container} no pertenece a ${PROXY_NETWORK}"

  log "${label}: running + healthy + proxy network OK."
}

validate_caddy() {
  log "Validando configuración completa de Caddy."

  docker exec \
    "$CADDY_CONTAINER" \
    caddy validate \
      --config "$CADDY_CONFIG" \
      --adapter caddyfile
}

reload_caddy() {
  log "Recargando Caddy sin detener el servicio."

  docker exec \
    -w /etc/caddy \
    "$CADDY_CONTAINER" \
    caddy reload \
      --config Caddyfile \
      --adapter caddyfile
}

restore_previous_site() {
  if [[ "$SITE_CHANGED" != true ]]; then
    return 0
  fi

  if [[ -n "$BACKUP_SITE_FILE" &&
        -f "$BACKUP_SITE_FILE" ]]; then

    mv \
      "$BACKUP_SITE_FILE" \
      "$SITE_FILE"

    log "Fragmento Caddy anterior restaurado."
  else
    rm -f "$SITE_FILE"

    log "Fragmento Caddy nuevo eliminado."
  fi

  SITE_CHANGED=false
}

rollback() {
  local exit_code=$?

  trap - EXIT

  if [[ $exit_code -eq 0 ||
        "$PUBLISH_COMMITTED" == true ]]; then
    exit "$exit_code"
  fi

  warn "Publicación incompleta. Ejecutando rollback."

  restore_previous_site || true

  warn "Rollback de publicación finalizado."

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

    --validate-only)
      [[ "$MODE" == "plan" ]] ||
        fail "Solo puede seleccionarse un modo."

      MODE="validate"
      shift
      ;;

    --apply)
      [[ "$MODE" == "plan" ]] ||
        fail "Solo puede seleccionarse un modo."

      MODE="apply"
      shift
      ;;

    --allow-custom-domain)
      ALLOW_CUSTOM_DOMAIN=true
      shift
      ;;

    --help|-h)
      usage
      PUBLISH_COMMITTED=true
      exit 0
      ;;

    *)
      fail "Opción desconocida: $1"
      ;;
  esac
done

# =============================================================================
# Prerrequisitos
# =============================================================================

[[ -n "$TENANT" ]] ||
  fail "Falta --tenant."

[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] ||
  fail "Tenant inválido: ${TENANT}"

[[ "$TENANT" != "aegora" ]] ||
  fail "Aegora se publica mediante configuración estática."

require_command docker
require_command install
require_command grep
require_command mktemp

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"

require_file "$TENANT_CONFIG"

# =============================================================================
# Cargar tenant
# =============================================================================

set -a

# shellcheck disable=SC1090
source "$TENANT_CONFIG"

set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${BASE_DOMAIN:?Falta BASE_DOMAIN}"

: "${DIRECTUS_HOST:?Falta DIRECTUS_HOST}"
: "${N8N_HOST:?Falta N8N_HOST}"

: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"
: "${N8N_CONTAINER:?Falta N8N_CONTAINER}"

# Booking es opcional: solo se publica si el tenant lo tiene desplegado.
BOOKING_HOST="${BOOKING_HOST:-}"
BOOKING_CONTAINER="${BOOKING_CONTAINER:-}"
BOOKING_PUBLISH=false
if [[ -n "$BOOKING_HOST" && -n "$BOOKING_CONTAINER" ]] &&
   container_exists "$BOOKING_CONTAINER"; then
  BOOKING_PUBLISH=true
fi

# Hostname neutro de cara a los canales (WhatsApp, webchat...). Apunta al mismo
# n8n pero SOLO expone /webhook/*: el editor no debe quedar accesible ahí.
WEBHOOK_HOST="${WEBHOOK_HOST:-}"
WEBHOOK_PUBLISH=false
if [[ -n "$WEBHOOK_HOST" ]]; then
  WEBHOOK_PUBLISH=true
fi

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail "TENANT_ID no coincide con --tenant."

validate_hostname "$DIRECTUS_HOST"
validate_hostname "$N8N_HOST"
[[ "$BOOKING_PUBLISH" != true ]] || validate_hostname "$BOOKING_HOST"
[[ "$WEBHOOK_PUBLISH" != true ]] || validate_hostname "$WEBHOOK_HOST"

# -----------------------------------------------------------------------------
# Comprobación de DNS
#
# Arriba se valida que el hostname tenga forma correcta y pertenezca al dominio
# gestionado, pero no que RESUELVA. Resultado: el onboarding terminaba diciendo
# que todo fue bien y dejaba un tenant inalcanzable, con Caddy incapaz de pedir
# certificado porque nadie llega hasta él. Pasó con `dev`: el síntoma aparece
# dos días después y no se parece en nada a su causa.
#
# No es fatal -- el DNS puede estar propagando y la publicación en sí es
# correcta -- pero se dice, y se dice donde se ve.
# -----------------------------------------------------------------------------
ip_del_servidor() {
  ip route get 1.1.1.1 2>/dev/null |
    awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

resuelve_a() {
  getent ahostsv4 "$1" 2>/dev/null | awk '{ print $1; exit }'
}

IP_SERVIDOR="$(ip_del_servidor || true)"

# OJO: esta función se usa dentro de $( ), o sea en una subshell. No puede
# acumular nada en una variable del shell padre -- se perdería al volver. Solo
# devuelve texto; el recuento lo hace `hosts_sin_dns` aparte, en el shell bueno.
estado_dns() {
  local host="$1"
  local ip
  ip="$(resuelve_a "$host" || true)"

  if [[ -z "$ip" ]]; then
    printf 'NO RESUELVE'
  elif [[ -n "$IP_SERVIDOR" && "$ip" != "$IP_SERVIDOR" ]]; then
    printf 'apunta a %s' "$ip"
  else
    printf 'ok'
  fi
}

# Los hostnames que hoy NO llevan a esta máquina. Se repite la consulta, que ya
# está en caché y cuesta nada, a cambio de no depender de efectos colaterales.
hosts_sin_dns() {
  local host ip
  for host in "$@"; do
    [[ -n "$host" ]] || continue
    ip="$(resuelve_a "$host" || true)"
    if [[ -z "$ip" ]]; then
      printf '  %s: no resuelve\n' "$host"
    elif [[ -n "$IP_SERVIDOR" && "$ip" != "$IP_SERVIDOR" ]]; then
      printf '  %s: resuelve a %s, no a %s\n' "$host" "$ip" "$IP_SERVIDOR"
    fi
  done
}


# =============================================================================
# Política de dominios
# =============================================================================

if [[ "$ALLOW_CUSTOM_DOMAIN" != true ]]; then
  is_managed_hostname "$DIRECTUS_HOST" ||
    fail \
      "DIRECTUS_HOST no pertenece a ${MANAGED_DOMAIN}: ${DIRECTUS_HOST}"

  is_managed_hostname "$N8N_HOST" ||
    fail \
      "N8N_HOST no pertenece a ${MANAGED_DOMAIN}: ${N8N_HOST}"

  [[ "$BOOKING_PUBLISH" != true ]] ||
    is_managed_hostname "$BOOKING_HOST" ||
    fail \
      "BOOKING_HOST no pertenece a ${MANAGED_DOMAIN}: ${BOOKING_HOST}"

  [[ "$WEBHOOK_PUBLISH" != true ]] ||
    is_managed_hostname "$WEBHOOK_HOST" ||
    fail \
      "WEBHOOK_HOST no pertenece a ${MANAGED_DOMAIN}: ${WEBHOOK_HOST}"
fi

# =============================================================================
# Preflight Caddy
# =============================================================================

container_exists "$CADDY_CONTAINER" ||
  fail "No existe ${CADDY_CONTAINER}"

container_running "$CADDY_CONTAINER" ||
  fail "${CADDY_CONTAINER} no está running"

docker network inspect \
  "$PROXY_NETWORK" \
  >/dev/null 2>&1 ||
  fail "No existe ${PROXY_NETWORK}"

validate_service \
  "Directus" \
  "$DIRECTUS_CONTAINER"

validate_service \
  "n8n" \
  "$N8N_CONTAINER"

if [[ "$BOOKING_PUBLISH" == true ]]; then
  validate_service \
    "Booking" \
    "$BOOKING_CONTAINER"
fi

# =============================================================================
# Fragmento
# =============================================================================

SITE_FILE="${CADDY_RUNTIME_SITES_HOST}/${TENANT}.caddy"

if [[ "$BOOKING_PUBLISH" == true ]]; then
  BOOKING_PLAN_BLOCK="
Booking:
  https://${BOOKING_HOST}   [DNS: $(estado_dns "$BOOKING_HOST")]
  -> ${BOOKING_CONTAINER}:3000"
  BOOKING_SUMMARY_BLOCK="
Booking:
  https://${BOOKING_HOST}"
else
  BOOKING_PLAN_BLOCK="
Booking:
  (no desplegado; se omite su ruta)"
  BOOKING_SUMMARY_BLOCK=""
fi

if [[ "$WEBHOOK_PUBLISH" == true ]]; then
  WEBHOOK_PLAN_BLOCK="
Webhooks (canales):
  https://${WEBHOOK_HOST}/webhook/*   [DNS: $(estado_dns "$WEBHOOK_HOST")]
  -> ${N8N_CONTAINER}:5678  (resto de rutas: 404)"
  WEBHOOK_SUMMARY_BLOCK="
Webhooks (canales):
  https://${WEBHOOK_HOST}/webhook/..."
else
  WEBHOOK_PLAN_BLOCK="
Webhooks (canales):
  (sin WEBHOOK_HOST; se omite)"
  WEBHOOK_SUMMARY_BLOCK=""
fi

cat <<EOF

============================================================
AEGORA TENANT PUBLICATION
============================================================

Tenant:
  ${TENANT_ID}

Directus:
  https://${DIRECTUS_HOST}   [DNS: $(estado_dns "$DIRECTUS_HOST")]
  -> ${DIRECTUS_CONTAINER}:8055

n8n:
  https://${N8N_HOST}   [DNS: $(estado_dns "$N8N_HOST")]
  -> ${N8N_CONTAINER}:5678
${BOOKING_PLAN_BLOCK}
${WEBHOOK_PLAN_BLOCK}

Fragmento:
  ${SITE_FILE}

Modo:
  ${MODE}

Dominio administrado:
  ${MANAGED_DOMAIN}

Custom domain permitido:
  ${ALLOW_CUSTOM_DOMAIN}

============================================================

EOF

if [[ "$MODE" == "plan" ]]; then
  log "PLAN ONLY. No se ha modificado Caddy."

  PUBLISH_COMMITTED=true
  exit 0
fi

mkdir -p "$CADDY_RUNTIME_SITES_HOST"
chmod 700 "$CADDY_RUNTIME_SITES_HOST"

# =============================================================================
# Backup del fragmento anterior
# =============================================================================

if [[ -f "$SITE_FILE" ]]; then
  BACKUP_SITE_FILE="$(
    mktemp \
      "${CADDY_RUNTIME_SITES_HOST}/.${TENANT}.XXXXXX.backup"
  )"

  cp \
    --preserve=mode,timestamps \
    "$SITE_FILE" \
    "$BACKUP_SITE_FILE"
fi

# =============================================================================
# Generar candidato
# =============================================================================

candidate="$(
  mktemp \
    "${CADDY_RUNTIME_SITES_HOST}/.${TENANT}.XXXXXX.tmp"
)"

cat > "$candidate" <<EOF
# =============================================================================
# Tenant: ${TENANT_ID}
# Managed by: provisioning/tenant/publish-tenant.sh
#
# DO NOT EDIT MANUALLY.
# =============================================================================

${DIRECTUS_HOST} {
	encode zstd gzip

	header {
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		Strict-Transport-Security "max-age=31536000"
		-Server
	}

	reverse_proxy ${DIRECTUS_CONTAINER}:8055

	log {
		output stdout
		format console
	}
}

${N8N_HOST} {
	encode zstd gzip

	header {
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		Strict-Transport-Security "max-age=31536000"
		-Server
	}

	reverse_proxy ${N8N_CONTAINER}:5678 {
		flush_interval -1
	}

	log {
		output stdout
		format console
	}
}
EOF

if [[ "$WEBHOOK_PUBLISH" == true ]]; then
  cat >> "$candidate" <<EOF

${WEBHOOK_HOST} {
	encode zstd gzip

	header {
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		Strict-Transport-Security "max-age=31536000"
		-Server
	}

	# Solo webhooks. El editor de n8n NO se expone en este hostname.
	handle /webhook/* {
		reverse_proxy ${N8N_CONTAINER}:5678 {
			flush_interval -1
		}
	}

	# Modo test del editor. Quitar cuando no se necesite para desarrollo.
	handle /webhook-test/* {
		reverse_proxy ${N8N_CONTAINER}:5678 {
			flush_interval -1
		}
	}

	handle {
		respond 404
	}

	log {
		output stdout
		format console
	}
}
EOF
fi

if [[ "$BOOKING_PUBLISH" == true ]]; then
  cat >> "$candidate" <<EOF

${BOOKING_HOST} {
	encode zstd gzip

	header {
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		Strict-Transport-Security "max-age=31536000"
		-Server
	}

	reverse_proxy ${BOOKING_CONTAINER}:3000

	log {
		output stdout
		format console
	}
}
EOF
fi

chmod 644 "$candidate"

mv \
  "$candidate" \
  "$SITE_FILE"

SITE_CHANGED=true

# =============================================================================
# Validar
# =============================================================================

if ! validate_caddy; then
  warn "La configuración candidata de Caddy es inválida."

  restore_previous_site

  fail "Validación Caddy fallida."
fi

log "Configuración Caddy válida."

# =============================================================================
# Validate only
# =============================================================================

if [[ "$MODE" == "validate" ]]; then
  log "VALIDATE ONLY: restaurando estado previo."

  restore_previous_site

  rm -f "${BACKUP_SITE_FILE:-}"

  PUBLISH_COMMITTED=true

  log "Validación completada. Caddy no se ha recargado."

  exit 0
fi

# =============================================================================
# Aplicar
# =============================================================================

if ! reload_caddy; then
  warn "Caddy reload ha fallado."

  restore_previous_site

  warn "Intentando recargar la configuración anterior."

  reload_caddy || true

  fail "Publicación fallida; configuración anterior restaurada."
fi

SITE_CHANGED=false

rm -f "${BACKUP_SITE_FILE:-}"

# =============================================================================
# Estado final
# =============================================================================

PUBLISH_COMMITTED=true

cat <<EOF

============================================================
TENANT PUBLICADO
============================================================

Tenant:
  ${TENANT_ID}

Directus:
  https://${DIRECTUS_HOST}

n8n:
  https://${N8N_HOST}
${BOOKING_SUMMARY_BLOCK}
Caddy:
  VALIDADO
  RELOAD OK

Fragmento:
  ${SITE_FILE}

Pendiente:
  DNS
  validación TLS externa

============================================================
EOF

# -----------------------------------------------------------------------------
# Lo último que se lee es lo que se recuerda: si el DNS no lleva aquí, el tenant
# está publicado y es inalcanzable, y eso no se nota hasta días después.
# -----------------------------------------------------------------------------
PENDIENTES="$(hosts_sin_dns "$DIRECTUS_HOST" "$N8N_HOST" "${BOOKING_HOST:-}" "${WEBHOOK_HOST:-}")"
if [[ -n "$PENDIENTES" ]]; then
  cat <<AVISO

============================================================
DNS PENDIENTE — EL TENANT NO ES ALCANZABLE TODAVÍA
============================================================

${PENDIENTES}
Hasta que estos nombres apunten a ${IP_SERVIDOR:-esta máquina}, Caddy no puede
emitir certificado y no responderá nada. Lo publicado es correcto; falta el DNS.

Un comodín cubre los cuatro de un tenant:
  *.${BASE_DOMAIN}    A    ${IP_SERVIDOR:-<ip>}

============================================================

AVISO
fi
