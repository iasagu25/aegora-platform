#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora - Managed Directus extensions
#
# Responsabilidad:
#   - instalar en cada tenant las extensiones Directus gestionadas por Aegora;
#   - copiar únicamente artefactos runtime (package.json + dist/);
#   - hacerlo de forma idempotente;
#   - no eliminar extensiones ajenas/no gestionadas.
#
# Source of truth:
#   /opt/aegora/platform/directus/extensions/
#
# Destino:
#   <DIRECTUS_DATA_DIR>/extensions/
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly EXTENSIONS_SOURCE_ROOT="${PLATFORM_ROOT}/directus/extensions"

readonly MANAGED_EXTENSIONS=(
  "directus-extension-aegora-phone-display"
  "directus-extension-aegora-tasks-layout"
)

TENANT=""
APPLY=false

TENANT_ROOT=""
TENANT_CONFIG=""
TENANT_ID=""
DIRECTUS_DATA_DIR=""
TARGET_EXTENSIONS_ROOT=""

CHANGES_REQUIRED=0
CHANGES_APPLIED=0

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  configure-directus-extensions.sh --tenant TENANT [--apply]

Sin --apply:
  valida las extensiones gestionadas y muestra qué se instalaría/actualizaría.

Con --apply:
  sincroniza package.json + dist/ desde el repositorio hacia el directorio
  persistente de extensiones Directus del tenant.

No elimina extensiones no gestionadas por Aegora.
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

require_directory() {
  [[ -d "$1" ]] ||
    fail "Falta el directorio requerido: $1"
}

validate_extension_source() {
  local extension="$1"
  local source_dir="${EXTENSIONS_SOURCE_ROOT}/${extension}"
  local package_file="${source_dir}/package.json"
  local dist_dir="${source_dir}/dist"

  require_directory "$source_dir"
  require_file "$package_file"
  require_directory "$dist_dir"

  [[ -n "$(find "$dist_dir" -type f -print -quit)" ]] ||
    fail "La extensión '${extension}' no contiene artefactos en dist/."

  grep -Eq \
    "\"name\"[[:space:]]*:[[:space:]]*\"${extension}\"" \
    "$package_file" ||
    fail "package.json de '${extension}' no declara name='${extension}'."

  grep -Eq \
    '"directus:extension"[[:space:]]*:' \
    "$package_file" ||
    fail "package.json de '${extension}' no declara directus:extension."
}

runtime_file_list() {
  local root="$1"

  {
    [[ -f "${root}/package.json" ]] &&
      printf '%s\n' "package.json"

    if [[ -d "${root}/dist" ]]; then
      find "${root}/dist" -type f -print |
        sed "s#^${root}/##"
    fi
  } | sort
}

extension_is_current() {
  local source_dir="$1"
  local target_dir="$2"

  [[ -d "$target_dir" ]] ||
    return 1

  local source_list
  local target_list
  local relative

  source_list="$(runtime_file_list "$source_dir")"
  target_list="$(runtime_file_list "$target_dir")"

  [[ "$source_list" == "$target_list" ]] ||
    return 1

  while IFS= read -r relative; do
    [[ -n "$relative" ]] ||
      continue

    cmp -s \
      "${source_dir}/${relative}" \
      "${target_dir}/${relative}" ||
      return 1
  done <<< "$source_list"

  return 0
}

install_extension() {
  local extension="$1"
  local source_dir="${EXTENSIONS_SOURCE_ROOT}/${extension}"
  local target_dir="${TARGET_EXTENSIONS_ROOT}/${extension}"

  if extension_is_current "$source_dir" "$target_dir"; then
    printf '  %-48s %s\n' "$extension" "OK"
    return 0
  fi

  CHANGES_REQUIRED=$((CHANGES_REQUIRED + 1))

  if [[ "$APPLY" != true ]]; then
    printf '  %-48s %s\n' "$extension" "CAMBIO PENDIENTE"
    return 0
  fi

  rm -rf "$target_dir"

  install -d -m 755 "$target_dir"

  install \
    -m 644 \
    "${source_dir}/package.json" \
    "${target_dir}/package.json"

  cp -a \
    "${source_dir}/dist" \
    "${target_dir}/dist"

  find "${target_dir}/dist" \
    -type d \
    -exec chmod 755 {} +

  find "${target_dir}/dist" \
    -type f \
    -exec chmod 644 {} +

  extension_is_current "$source_dir" "$target_dir" ||
    fail "La verificación posterior falló para '${extension}'."

  CHANGES_APPLIED=$((CHANGES_APPLIED + 1))

  printf '  %-48s %s\n' "$extension" "INSTALADA/ACTUALIZADA"
}

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

[[ "$TENANT" != "aegora" ]] ||
  fail "El tenant legacy 'aegora' está protegido."

require_command find
require_command sed
require_command grep
require_command cmp
require_command cp
require_command install

require_directory "$EXTENSIONS_SOURCE_ROOT"

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"

require_file "$TENANT_CONFIG"

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${DIRECTUS_DATA_DIR:?Falta DIRECTUS_DATA_DIR}"

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

require_directory "$DIRECTUS_DATA_DIR"

TARGET_EXTENSIONS_ROOT="${DIRECTUS_DATA_DIR}/extensions"

for extension in "${MANAGED_EXTENSIONS[@]}"; do
  validate_extension_source "$extension"
done

cat <<EOF

============================================================
AEGORA · DIRECTUS EXTENSIONS
============================================================

Tenant:
  ${TENANT_ID}

Source:
  ${EXTENSIONS_SOURCE_ROOT}

Destino:
  ${TARGET_EXTENSIONS_ROOT}

Extensiones gestionadas:
$(printf '  - %s\n' "${MANAGED_EXTENSIONS[@]}")

Política:
  solo package.json + dist/
  no se eliminan extensiones no gestionadas

Modo:
  $([[ "$APPLY" == true ]] && printf 'APPLY' || printf 'DRY RUN')

============================================================

EOF

if [[ "$APPLY" == true ]]; then
  [[ $EUID -eq 0 ]] ||
    fail "--apply debe ejecutarse como root."

  install -d -m 755 "$TARGET_EXTENSIONS_ROOT"
fi

for extension in "${MANAGED_EXTENSIONS[@]}"; do
  install_extension "$extension"
done

echo

if [[ "$APPLY" != true ]]; then
  if [[ "$CHANGES_REQUIRED" -eq 0 ]]; then
    log "DRY RUN: extensiones gestionadas ya sincronizadas."
  else
    log "DRY RUN: ${CHANGES_REQUIRED} extensión(es) requieren instalación/actualización."
  fi
  exit 0
fi

log "Extensiones Directus sincronizadas. Cambios aplicados: ${CHANGES_APPLIED}."

cat <<EOF

============================================================
DIRECTUS EXTENSIONS CONFIGURADAS
============================================================

Tenant:
  ${TENANT_ID}

Cambios aplicados:
  ${CHANGES_APPLIED}

Estado:
  OK

============================================================
EOF
