#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"

readonly CREATE_SCRIPT="${PLATFORM_ROOT}/provisioning/tenant/create-tenant.sh"
readonly DEPLOY_SCRIPT="${PLATFORM_ROOT}/provisioning/tenant/deploy-tenant.sh"

readonly APPLY_SCHEMA_SCRIPT="${PLATFORM_ROOT}/directus/apply-schema.sh"
readonly DIRECTUS_ACCESS_SCRIPT="${PLATFORM_ROOT}/directus/provision-directus-access.sh"
readonly DIRECTUS_UI_SCRIPT="${PLATFORM_ROOT}/directus/configure-directus-ui.sh"
readonly SPANISH_UI_SCRIPT="${PLATFORM_ROOT}/directus/configure-spanish-ui.sh"

readonly PUBLISH_SCRIPT="${PLATFORM_ROOT}/provisioning/tenant/publish-tenant.sh"
readonly BACKUP_SCRIPT="${PLATFORM_ROOT}/provisioning/tenant/configure-tenant-backup.sh"
readonly OPERATIONS_SCRIPT="${PLATFORM_ROOT}/provisioning/tenant/activate-tenant-operations.sh"

readonly DIRECTUS_HEALTH_TIMEOUT_SECONDS=180
readonly DIRECTUS_HEALTH_INTERVAL_SECONDS=2

TENANT=""
TENANT_NAME=""
BASE_DOMAIN=""
ADMIN_EMAIL=""
STAGE="prepare"
APPLY=false
S3_CREDENTIALS_FILE=""
ALLOW_SHARED_S3_CREDENTIALS=false
ALLOW_CUSTOM_DOMAIN=false

log() {
  printf '[%s] %s\n' \
    "$(date --iso-8601=seconds)" \
    "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "Falta el comando requerido: $1"
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

usage() {
  cat <<'USAGE'
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

prepare:
  create
  -> deploy
  -> apply Directus schema
  -> restart Directus + wait healthy
  -> provision Directus technical access
  -> configure managed Directus UI
  -> configure Spanish UI
  -> backup
  -> operations

publish:
  publish Caddy

all:
  prepare + publish

DNS no se modifica desde este script.
USAGE
}

run_script() {
  local label="$1"
  shift

  log "============================================================"
  log "$label"
  log "============================================================"

  "$@"
}

tenant_exists() {
  [[ -f "${TENANTS_ROOT}/${TENANT}/config/tenant.env" ]]
}

tenant_config_file() {
  printf '%s\n' \
    "${TENANTS_ROOT}/${TENANT}/config/tenant.env"
}

read_tenant_config_value() {
  local variable="$1"
  local config

  config="$(tenant_config_file)"

  require_file "$config"

  bash -c "
    set -a
    source '$config'
    set +a
    printf '%s' \"\${${variable}:-}\"
  "
}

validate_existing_tenant_identity() {
  local config
  local existing_id
  local existing_name
  local existing_domain

  config="$(tenant_config_file)"
  require_file "$config"

  existing_id="$(
    read_tenant_config_value TENANT_ID
  )"

  existing_name="$(
    read_tenant_config_value TENANT_NAME
  )"

  existing_domain="$(
    read_tenant_config_value BASE_DOMAIN
  )"

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

directus_health() {
  local container="$1"

  docker inspect \
    --format \
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}' \
    "$container" \
    2>/dev/null
}

wait_for_directus_healthy() {
  local container="$1"
  local elapsed=0
  local health=""

  while (( elapsed < DIRECTUS_HEALTH_TIMEOUT_SECONDS )); do
    health="$(
      directus_health "$container" ||
      true
    )"

    if [[ "$health" == "healthy" ]]; then
      log "Directus healthy: ${container}"
      return 0
    fi

    log \
      "Esperando Directus: container=${container}, health=${health:-unknown}"

    sleep "$DIRECTUS_HEALTH_INTERVAL_SECONDS"

    elapsed=$((
      elapsed + DIRECTUS_HEALTH_INTERVAL_SECONDS
    ))
  done

  fail \
    "Timeout esperando Directus healthy: container=${container}, health=${health:-unknown}"
}

restart_directus_after_schema() {
  local container

  container="$(
    read_tenant_config_value DIRECTUS_CONTAINER
  )"

  [[ -n "$container" ]] ||
    fail \
      "DIRECTUS_CONTAINER no está definido para ${TENANT}."

  docker inspect "$container" >/dev/null 2>&1 ||
    fail \
      "No existe el contenedor Directus: ${container}"

  log \
    "Reiniciando Directus después de aplicar schema para refrescar metadata y permisos."

  docker restart \
    "$container" \
    >/dev/null

  wait_for_directus_healthy \
    "$container"

  log \
    "Directus reiniciado correctamente después del schema."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      [[ $# -ge 2 ]] ||
        fail "Falta valor para --tenant"

      TENANT="$2"
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

      ADMIN_EMAIL="$2"
      shift 2
      ;;

    --stage)
      [[ $# -ge 2 ]] ||
        fail "Falta valor para --stage"

      STAGE="$2"
      shift 2
      ;;

    --s3-credentials-file)
      [[ $# -ge 2 ]] ||
        fail "Falta valor para --s3-credentials-file"

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

[[ -n "$TENANT" ]] ||
  fail "Falta --tenant."

[[ -n "$TENANT_NAME" ]] ||
  fail "Falta --name."

[[ -n "$BASE_DOMAIN" ]] ||
  fail "Falta --domain."

[[ -n "$ADMIN_EMAIL" ]] ||
  fail "Falta --admin-email."

validate_tenant_id "$TENANT"
validate_domain "$BASE_DOMAIN"
validate_email "$ADMIN_EMAIL"

[[ "$TENANT" != "aegora" ]] ||
  fail \
    "El tenant legacy 'aegora' está protegido."

case "$STAGE" in
  prepare|publish|all)
    ;;
  *)
    fail \
      "--stage debe ser prepare, publish o all."
    ;;
esac

require_command docker

for required_script in \
  "$CREATE_SCRIPT" \
  "$DEPLOY_SCRIPT" \
  "$APPLY_SCHEMA_SCRIPT" \
  "$DIRECTUS_ACCESS_SCRIPT" \
  "$DIRECTUS_UI_SCRIPT" \
  "$SPANISH_UI_SCRIPT" \
  "$PUBLISH_SCRIPT" \
  "$BACKUP_SCRIPT" \
  "$OPERATIONS_SCRIPT"; do

  require_file "$required_script"
done

[[ -z "$S3_CREDENTIALS_FILE" ]] ||
  require_file "$S3_CREDENTIALS_FILE"

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

Directus locale:
  es-ES

Directus UI:
  overlay administrado después del schema

DNS:
  NO gestionado por este script

============================================================

EOF

if [[ "$STAGE" == "prepare" ||
      "$STAGE" == "all" ]]; then

  if tenant_exists; then
    log \
      "Tenant ya provisionado. Validando identidad."

    validate_existing_tenant_identity

    log \
      "Identidad del tenant existente: OK."

    log \
      "Se omite create-tenant.sh."
  else
    create_args=(
      /usr/bin/bash
      "$CREATE_SCRIPT"
      --tenant "$TENANT"
      --name "$TENANT_NAME"
      --domain "$BASE_DOMAIN"
      --admin-email "$ADMIN_EMAIL"
    )

    [[ "$APPLY" != true ]] ||
      create_args+=(--apply)

    run_script \
      "1/8 · CREATE TENANT" \
      "${create_args[@]}"
  fi

  if [[ "$APPLY" != true &&
        ! -f "${TENANTS_ROOT}/${TENANT}/config/tenant.env" ]]; then

    log \
      "PLAN: el tenant aún no existe."

    log \
      "Los pasos deploy/schema/restart/directus-access/ui/spanish-ui/backup/operations se ejecutarán después de create en modo APPLY."

    [[ "$STAGE" != "prepare" ]] ||
      exit 0

  else
    deploy_args=(
      /usr/bin/bash
      "$DEPLOY_SCRIPT"
      --tenant "$TENANT"
    )

    [[ "$APPLY" != true ]] ||
      deploy_args+=(--apply)

    run_script \
      "2/8 · DEPLOY TENANT" \
      "${deploy_args[@]}"

    schema_args=(
      /usr/bin/bash
      "$APPLY_SCHEMA_SCRIPT"
      --tenant "$TENANT"
    )

    [[ "$APPLY" != true ]] ||
      schema_args+=(--apply)

    run_script \
      "3/8 · APPLY DIRECTUS SCHEMA" \
      "${schema_args[@]}"

    if [[ "$APPLY" == true ]]; then
      log \
        "============================================================"

      log \
        "DIRECTUS POST-SCHEMA RESTART"

      log \
        "============================================================"

      restart_directus_after_schema
    else
      log \
        "PLAN: Directus se reiniciará después del schema en modo APPLY."
    fi

    directus_access_args=(
      /usr/bin/bash
      "$DIRECTUS_ACCESS_SCRIPT"
      --tenant "$TENANT"
    )

    [[ "$APPLY" != true ]] ||
      directus_access_args+=(--apply)

    run_script \
      "4/8 · PROVISION DIRECTUS TECHNICAL ACCESS" \
      "${directus_access_args[@]}"

    directus_ui_args=(
      /usr/bin/bash
      "$DIRECTUS_UI_SCRIPT"
      --tenant "$TENANT"
    )

    [[ "$APPLY" != true ]] ||
      directus_ui_args+=(--apply)

    run_script \
      "5/8 · CONFIGURE DIRECTUS UI" \
      "${directus_ui_args[@]}"

    spanish_ui_args=(
      /usr/bin/bash
      "$SPANISH_UI_SCRIPT"
      --tenant "$TENANT"
    )

    [[ "$APPLY" != true ]] ||
      spanish_ui_args+=(--apply)

    run_script \
      "6/8 · CONFIGURE DIRECTUS SPANISH UI" \
      "${spanish_ui_args[@]}"

    backup_args=(
      /usr/bin/bash
      "$BACKUP_SCRIPT"
      --tenant "$TENANT"
    )

    [[ -z "$S3_CREDENTIALS_FILE" ]] ||
      backup_args+=(
        --s3-credentials-file
        "$S3_CREDENTIALS_FILE"
      )

    [[ "$ALLOW_SHARED_S3_CREDENTIALS" != true ]] ||
      backup_args+=(
        --allow-shared-s3-credentials
      )

    [[ "$APPLY" != true ]] ||
      backup_args+=(--apply)

    run_script \
      "7/8 · CONFIGURE BACKUP" \
      "${backup_args[@]}"

    operations_args=(
      /usr/bin/bash
      "$OPERATIONS_SCRIPT"
      --tenant "$TENANT"
    )

    [[ "$APPLY" != true ]] ||
      operations_args+=(--apply)

    run_script \
      "8/8 · ACTIVATE OPERATIONS" \
      "${operations_args[@]}"
  fi
fi

if [[ "$STAGE" == "publish" ||
      "$STAGE" == "all" ]]; then

  tenant_exists ||
    fail \
      "No se puede publicar: el tenant todavía no está provisionado."

  validate_existing_tenant_identity

  publish_args=(
    /usr/bin/bash
    "$PUBLISH_SCRIPT"
    --tenant "$TENANT"
  )

  [[ "$ALLOW_CUSTOM_DOMAIN" != true ]] ||
    publish_args+=(
      --allow-custom-domain
    )

  [[ "$APPLY" != true ]] ||
    publish_args+=(--apply)

  run_script \
    "PUBLISH TENANT" \
    "${publish_args[@]}"
fi

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

Estado:
  flujo solicitado completado

Directus:
  schema aplicado
  restart post-schema realizado en APPLY
  acceso técnico de provisioning configurado
  UI overlay configurado
  locale es-ES configurado

============================================================
EOF
