#!/usr/bin/env bash

# Shared tenant context resolution for backup/restore operations.
# This file is intended to be sourced by Bash scripts that define fail().

resolve_tenant_context() {
  : "${PLATFORM_ROOT:?PLATFORM_ROOT must be defined before resolve_tenant_context}"
  : "${SECRETS_ROOT:?SECRETS_ROOT must be defined before resolve_tenant_context}"
  : "${TENANT:?TENANT must be defined before resolve_tenant_context}"

  local managed_root="/opt/aegora/tenants/${TENANT}"
  local managed_config="${managed_root}/config/tenant.env"
  local managed_manifest="${managed_root}/config/backup.manifest.json"
  local managed_restic="${managed_root}/secrets/restic.env"
  local managed_postgres="${managed_root}/secrets/postgres.env"

  local legacy_root="${PLATFORM_ROOT}/customers/${TENANT}"
  local legacy_config="${legacy_root}/tenant.env"
  local legacy_manifest="${legacy_root}/backup.manifest.json"

  TENANT_ROOT=""
  TENANT_CONFIG=""
  BACKUP_MANIFEST=""
  RESTIC_CONFIG=""
  TENANT_POSTGRES_SECRETS=""
  CONFIG_LAYOUT=""

  if [[ -f "$managed_config" ]]; then
    CONFIG_LAYOUT="managed"
    TENANT_ROOT="$managed_root"
    TENANT_CONFIG="$managed_config"
    BACKUP_MANIFEST="$managed_manifest"
    RESTIC_CONFIG="$managed_restic"
    TENANT_POSTGRES_SECRETS="$managed_postgres"
    return 0
  fi

  if [[ -f "$legacy_config" ]]; then
    CONFIG_LAYOUT="legacy"
    TENANT_ROOT="$legacy_root"
    TENANT_CONFIG="$legacy_config"
    BACKUP_MANIFEST="$legacy_manifest"
    RESTIC_CONFIG="${SECRETS_ROOT}/restic.env"
    TENANT_POSTGRES_SECRETS=""
    return 0
  fi

  fail "No se encontró configuración para el tenant '${TENANT}'."
}

validate_loaded_tenant_context() {
  : "${TENANT_ID:?Falta TENANT_ID}"

  [[ "$TENANT_ID" == "$TENANT" ]] ||
    fail "TENANT_ID='${TENANT_ID}' no coincide con TENANT='${TENANT}'."

  if [[ "$CONFIG_LAYOUT" == "managed" ]]; then
    local expected_bucket="${BACKUP_BUCKET:-aegora-${TENANT_ID}-backups}"
    local repository="${RESTIC_REPOSITORY:?Falta RESTIC_REPOSITORY}"
    local repository_without_slash="${repository%/}"
    local actual_bucket="${repository_without_slash##*/}"

    [[ "$actual_bucket" == "$expected_bucket" ]] ||
      fail "Repositorio Restic incorrecto para '${TENANT_ID}': bucket '${actual_bucket}', esperado '${expected_bucket}'."
  fi
}

log_tenant_context() {
  log "Layout tenant: ${CONFIG_LAYOUT}"
  log "Configuración tenant: ${TENANT_CONFIG}"
  log "Configuración Restic: ${RESTIC_CONFIG}"
}
