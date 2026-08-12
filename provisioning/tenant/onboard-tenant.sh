#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora - Tenant onboarding orchestrator
#
# Orquesta el ciclo de alta utilizando los scripts especializados:
#
#   create-tenant.sh
#   deploy-tenant.sh
#   configure-tenant-backup.sh
#   activate-tenant-operations.sh
#   publish-tenant.sh
#
# Modos:
#
#   prepare
#       create -> deploy -> backup -> operations
#
#   publish
#       publica el tenant en Caddy
#
#   all
#       prepare -> publish
#
# DNS NO se modifica desde este script.
#
# Para proveedores DNS externos, el flujo recomendado es:
#
#   1. onboard-tenant.sh --stage prepare --apply
#   2. crear/verificar DNS
#   3. onboard-tenant.sh --stage publish --apply
#
# El script es deliberadamente conservador:
#   - no elimina recursos;
#   - no modifica DNS;
#   - no reemplaza credenciales S3 existentes;
#   - no toca el tenant legacy "aegora";
#   - reutiliza los controles/idempotencia de cada subscript.
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"

readonly CREATE_SCRIPT="${PLATFORM_ROOT}/provisioning/tenant/create-tenant.sh"
readonly DEPLOY_SCRIPT="${PLATFORM_ROOT}/provisioning/tenant/deploy-tenant.sh"
readonly PUBLISH_SCRIPT="${PLATFORM_ROOT}/provisioning/tenant/publish-tenant.sh"
readonly BACKUP_SCRIPT="${PLATFORM_ROOT}/provisioning/tenant/configure-tenant-backup.sh"
readonly OPERATIONS_SCRIPT="${PLATFORM_ROOT}/provisioning/tenant/activate-tenant-operations.sh"

TENANT=""
TENANT_NAME=""
BASE_DOMAIN=""
ADMIN_EMAIL=""

STAGE="prepare"
APPLY=false

S3_CREDENTIALS_FILE=""
ALLOW_SHARED_S3_CREDENTIALS=false
ALLOW_CUSTOM_DOMAIN=false

# =============================================================================
# Utilidades
# =============================================================================

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
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

  onboard-tenant.sh \
    --tenant TENANT \
    --name "Nombre cliente" \
    --domain tenant.aegora.es \
    --admin-email admin@example.es \
    [--stage prepare|publish|all] \
    [--s3-credentials-file PATH] \
    [--allow-shared-s3-credentials] \
    [--allow-custom-domain] \
    [--apply]

Etapas:

  prepare
      create
      deploy
      configure backup
      activate operations

  publish
      publish Caddy

  all
      prepare + publish

Sin --apply:
  muestra y valida el plan mediante los scripts especializados.

Con --apply:
  ejecuta las etapas seleccionadas.

DNS:
  este script NO crea ni modifica registros DNS.

Flujo recomendado para clientes reales:

  1. Preparar infraestructura:

     onboard-tenant.sh \
       --tenant cliente \
       --name "Cliente" \
       --domain cliente.aegora.es \
       --admin-email admin@cliente.es \
       --s3-credentials-file /root/cliente-s3.env \
       --stage prepare \
       --apply

  2. Crear/verificar DNS.

  3. Publicar:

     onboard-tenant.sh \
       --tenant cliente \
       --name "Cliente" \
       --domain cliente.aegora.es \
       --admin-email admin@cliente.es \
       --stage publish \
       --apply

Demo:

  onboard-tenant.sh \
    --tenant demo \
    --name "Aegora Demo" \
    --domain demo.aegora.es \
    --admin-email admin@aegora.es \
    --stage all \
    --apply
EOF
}

require_file() {
  [[ -f "$1" ]] ||
    fail "Falta el fichero requerido: $1"
}

validate_tenant_id() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{2,30}$ ]] ||
    fail "Tenant inválido: $1"
}

validate_domain() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
    fail "Dominio inválido: $1"
}

validate_email() {
  [[ "$1" == *@*.* ]] ||
    fail "Email inválido: $1"
}

run_script() {
  local label="$1"
  shift

  log "============================================================"
  log "${label}"
  log "============================================================"

  "$@"
}

tenant_exists() {
  [[ -f "${TENANTS_ROOT}/${TENANT}/config/tenant.env" ]]
}

validate_existing_tenant_identity() {
  local config="${TENANTS_ROOT}/${TENANT}/config/tenant.env"

  require_file "$config"

  local existing_id=""
  local existing_name=""
  local existing_domain=""

  (
    set -a
    # shellcheck disable=SC1090
    source "$config"
    set +a

    printf '%s\0%s\0%s\0' \
      "${TENANT_ID:-}" \
      "${TENANT_NAME:-}" \
      "${BASE_DOMAIN:-}"
  ) > "/tmp/aegora-onboard-${TENANT}-identity.$$"

  {
    IFS= read -r -d '' existing_id
    IFS= read -r -d '' existing_name
    IFS= read -r -d '' existing_domain
  } < "/tmp/aegora-onboard-${TENANT}-identity.$$"

  rm -f "/tmp/aegora-onboard-${TENANT}-identity.$$"

  [[ "$existing_id" == "$TENANT" ]] ||
    fail \
      "El tenant existente tiene TENANT_ID=${existing_id}, esperado ${TENANT}."

  [[ "$existing_name" == "$TENANT_NAME" ]] ||
    fail \
      "El tenant existente tiene TENANT_NAME='${existing_name}', esperado '${TENANT_NAME}'."

  [[ "$existing_domain" == "$BASE_DOMAIN" ]] ||
    fail \
      "El tenant existente tiene BASE_DOMAIN=${existing_domain}, esperado ${BASE_DOMAIN}."
}

# =============================================================================
# Argumentos
# =============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      [[ $# -ge 2 ]] || fail "Falta valor para --tenant"
      TENANT="$2"
      shift 2
      ;;

    --name)
      [[ $# -ge 2 ]] || fail "Falta valor para --name"
      TENANT_NAME="$2"
      shift 2
      ;;

    --domain)
      [[ $# -ge 2 ]] || fail "Falta valor para --domain"
      BASE_DOMAIN="$2"
      shift 2
      ;;

    --admin-email)
      [[ $# -ge 2 ]] || fail "Falta valor para --admin-email"
      ADMIN_EMAIL="$2"
      shift 2
      ;;

    --stage)
      [[ $# -ge 2 ]] || fail "Falta valor para --stage"
      STAGE="$2"
      shift 2
      ;;

    --s3-credentials-file)
      [[ $# -ge 2 ]] || fail "Falta valor para --s3-credentials-file"
      S3_CREDENTIALS_FILE="$2"
      shift 2
      ;;

    --allow-shared-s3-credentials)
      ALLOW_SHARED_S3_CREDENTIALS=true
      shift
      ;;

    --allow-custom-domain)
      ALLOW_CUSTOM_DOMAIN=true
      shift
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

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ -n "$TENANT_NAME" ]] || fail "Falta --name."
[[ -n "$BASE_DOMAIN" ]] || fail "Falta --domain."
[[ -n "$ADMIN_EMAIL" ]] || fail "Falta --admin-email."

validate_tenant_id "$TENANT"
validate_domain "$BASE_DOMAIN"
validate_email "$ADMIN_EMAIL"

[[ "$TENANT" != "aegora" ]] ||
  fail "El tenant legacy 'aegora' está protegido."

case "$STAGE" in
  prepare|publish|all)
    ;;
  *)
    fail "--stage debe ser prepare, publish o all."
    ;;
esac

require_file "$CREATE_SCRIPT"
require_file "$DEPLOY_SCRIPT"
require_file "$PUBLISH_SCRIPT"
require_file "$BACKUP_SCRIPT"
require_file "$OPERATIONS_SCRIPT"

if [[ -n "$S3_CREDENTIALS_FILE" ]]; then
  require_file "$S3_CREDENTIALS_FILE"
fi

cat <<EOF

============================================================
AEGORA TENANT ONBOARDING
============================================================

Tenant:
  ${TENANT}

Nombre:
  ${TENANT_NAME}

Dominio:
  ${BASE_DOMAIN}

Admin:
  ${ADMIN_EMAIL}

Etapa:
  ${STAGE}

Modo:
  $([[ "$APPLY" == true ]] && echo APPLY || echo PLAN)

Credenciales S3 dedicadas:
  $([[ -n "$S3_CREDENTIALS_FILE" ]] && echo "$S3_CREDENTIALS_FILE" || echo "no")

Credenciales S3 compartidas permitidas:
  ${ALLOW_SHARED_S3_CREDENTIALS}

Custom domain permitido:
  ${ALLOW_CUSTOM_DOMAIN}

DNS:
  NO gestionado por este script

============================================================

EOF

# =============================================================================
# PREPARE
# =============================================================================

if [[ "$STAGE" == "prepare" || "$STAGE" == "all" ]]; then

  # ---------------------------------------------------------------------------
  # CREATE
  # ---------------------------------------------------------------------------

  if tenant_exists; then
    log "Tenant ya provisionado. Validando identidad."

    validate_existing_tenant_identity

    log "Identidad del tenant existente: OK."
    log "Se omite create-tenant.sh."
  else
    create_args=(
      /usr/bin/bash
      "$CREATE_SCRIPT"
      --tenant "$TENANT"
      --name "$TENANT_NAME"
      --domain "$BASE_DOMAIN"
      --admin-email "$ADMIN_EMAIL"
    )

    if [[ "$APPLY" == true ]]; then
      create_args+=(--apply)
    fi

    run_script \
      "1/4 · CREATE TENANT" \
      "${create_args[@]}"
  fi

  # En PLAN, si el tenant todavía no existe, los pasos siguientes no pueden
  # validar ficheros runtime que aún no han sido creados.
  if [[ "$APPLY" != true && ! -f "${TENANTS_ROOT}/${TENANT}/config/tenant.env" ]]; then
    log "PLAN: el tenant aún no existe."
    log "Los pasos deploy/backup/operations se ejecutarán después de create en modo APPLY."

    if [[ "$STAGE" == "prepare" ]]; then
      log "PLAN de preparación completado."
      exit 0
    fi
  else
    # -------------------------------------------------------------------------
    # DEPLOY
    # -------------------------------------------------------------------------

    deploy_args=(
      /usr/bin/bash
      "$DEPLOY_SCRIPT"
      --tenant "$TENANT"
    )

    if [[ "$APPLY" == true ]]; then
      deploy_args+=(--apply)
    fi

    run_script \
      "2/4 · DEPLOY TENANT" \
      "${deploy_args[@]}"

    # -------------------------------------------------------------------------
    # BACKUP
    # -------------------------------------------------------------------------

    backup_args=(
      /usr/bin/bash
      "$BACKUP_SCRIPT"
      --tenant "$TENANT"
    )

    if [[ -n "$S3_CREDENTIALS_FILE" ]]; then
      backup_args+=(
        --s3-credentials-file
        "$S3_CREDENTIALS_FILE"
      )
    fi

    if [[ "$ALLOW_SHARED_S3_CREDENTIALS" == true ]]; then
      backup_args+=(--allow-shared-s3-credentials)
    fi

    if [[ "$APPLY" == true ]]; then
      backup_args+=(--apply)
    fi

    run_script \
      "3/4 · CONFIGURE BACKUP" \
      "${backup_args[@]}"

    # -------------------------------------------------------------------------
    # OPERATIONS
    # -------------------------------------------------------------------------

    operations_args=(
      /usr/bin/bash
      "$OPERATIONS_SCRIPT"
      --tenant "$TENANT"
    )

    if [[ "$APPLY" == true ]]; then
      operations_args+=(--apply)
    fi

    run_script \
      "4/4 · ACTIVATE OPERATIONS" \
      "${operations_args[@]}"
  fi
fi

# =============================================================================
# PUBLISH
# =============================================================================

if [[ "$STAGE" == "publish" || "$STAGE" == "all" ]]; then
  if ! tenant_exists; then
    fail \
      "No se puede publicar: el tenant todavía no está provisionado."
  fi

  validate_existing_tenant_identity

  publish_args=(
    /usr/bin/bash
    "$PUBLISH_SCRIPT"
    --tenant "$TENANT"
  )

  if [[ "$ALLOW_CUSTOM_DOMAIN" == true ]]; then
    publish_args+=(--allow-custom-domain)
  fi

  if [[ "$APPLY" == true ]]; then
    publish_args+=(--apply)
  fi

  run_script \
    "PUBLISH TENANT" \
    "${publish_args[@]}"
fi

# =============================================================================
# Resultado
# =============================================================================

cat <<EOF

============================================================
ONBOARDING COMPLETADO
============================================================

Tenant:
  ${TENANT}

Etapa:
  ${STAGE}

Modo:
  $([[ "$APPLY" == true ]] && echo APPLY || echo PLAN)

EOF

if [[ "$STAGE" == "prepare" ]]; then
  cat <<EOF
Estado:
  infraestructura preparada
  servicios desplegados
  backup configurado
  operaciones automáticas activadas

Pendiente:
  DNS
  publish
  TLS externo

Siguiente paso:
  configurar/verificar DNS y ejecutar:

  onboard-tenant.sh ... --stage publish --apply
EOF

elif [[ "$STAGE" == "publish" ]]; then
  cat <<EOF
Estado:
  publicación Caddy aplicada

Pendiente:
  validar DNS/TLS desde Internet
EOF

else
  cat <<EOF
Estado:
  preparación + publicación completadas

Pendiente:
  validar DNS/TLS desde Internet
EOF
fi

cat <<EOF

============================================================
EOF
