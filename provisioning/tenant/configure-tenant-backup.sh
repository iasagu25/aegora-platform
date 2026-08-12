#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora - Configure tenant backup
#
# Responsabilidad:
#   - resolver un tenant managed ya provisionado;
#   - crear o reutilizar su bucket S3 privado;
#   - crear / validar restic.env específico del tenant;
#   - inicializar y comprobar el repositorio Restic;
#   - marcar tenant.env como backup configurado.
#
# NO hace:
#   - backups de datos;
#   - restore tests;
#   - retención;
#   - timers systemd;
#   - eliminación de buckets remotos.
#
# Seguridad:
#   - para tenants reales, se recomienda proporcionar credenciales S3
#     dedicadas mediante --s3-credentials-file;
#   - el uso de las credenciales S3 globales queda permitido únicamente
#     para tenant "demo" salvo confirmación explícita.
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly GLOBAL_BOOTSTRAP_CONFIG="/opt/aegora/secrets/restic.env"

TENANT=""
APPLY=false
ALLOW_SHARED_S3_CREDENTIALS=false

S3_REGION="${S3_REGION:-fsn1}"
S3_ENDPOINT="${S3_ENDPOINT:-fsn1.your-objectstorage.com}"
S3_CREDENTIALS_FILE=""
BUCKET=""

TENANT_ROOT=""
TENANT_CONFIG=""
TENANT_SECRETS_DIR=""
TENANT_RESTIC_CONFIG=""

TENANT_ID=""
EXPECTED_REPOSITORY=""

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

  configure-tenant-backup.sh \
    --tenant TENANT \
    [--bucket BUCKET] \
    [--s3-region REGION] \
    [--s3-endpoint ENDPOINT] \
    [--s3-credentials-file PATH] \
    [--allow-shared-s3-credentials] \
    [--apply]

Sin --apply:
  muestra el plan y no modifica nada.

Credenciales:

  --s3-credentials-file PATH
      Fichero shell con:
        AWS_ACCESS_KEY_ID=...
        AWS_SECRET_ACCESS_KEY=...
        AWS_DEFAULT_REGION=...

      Recomendado para clientes reales.

  Sin --s3-credentials-file:
      utiliza /opt/aegora/secrets/restic.env únicamente como fuente
      de credenciales AWS.

      Para "demo" está permitido.
      Para otros tenants requiere:
        --allow-shared-s3-credentials

Ejemplo demo:

  sudo /usr/bin/bash \
    /opt/aegora/platform/provisioning/tenant/configure-tenant-backup.sh \
    --tenant demo \
    --apply

Ejemplo cliente real con credencial dedicada:

  sudo /usr/bin/bash \
    /opt/aegora/platform/provisioning/tenant/configure-tenant-backup.sh \
    --tenant cliente-x \
    --s3-credentials-file /root/cliente-x-s3.env \
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

validate_bucket_name() {
  local value="$1"

  [[ "$value" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
    fail "Nombre de bucket inválido: ${value}"

  [[ "$value" != *".."* ]] ||
    fail "Nombre de bucket inválido: ${value}"

  [[ "$value" != *".-"* && "$value" != *"-."* ]] ||
    fail "Nombre de bucket inválido: ${value}"
}

validate_endpoint() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] ||
    fail "Endpoint S3 inválido: $1"
}

write_env_file() {
  local destination="$1"
  shift

  : > "$destination"

  while [[ $# -gt 0 ]]; do
    local key="$1"
    local value="$2"

    printf '%s=%q\n' "$key" "$value" >> "$destination"
    shift 2
  done
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  python3 - "$file" "$key" "$value" <<'PY'
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
prefix = key + "="
replacement = f"{key}={shlex.quote(value)}"

lines = path.read_text(encoding="utf-8").splitlines()
result = []
replaced = False

for line in lines:
    if line.startswith(prefix):
        if not replaced:
            result.append(replacement)
            replaced = True
        continue
    result.append(line)

if not replaced:
    if result and result[-1] != "":
        result.append("")
    result.append(replacement)

path.write_text("\n".join(result) + "\n", encoding="utf-8")
PY
}

load_aws_credentials() {
  local source="$1"

  require_file "$source"

  unset AWS_ACCESS_KEY_ID
  unset AWS_SECRET_ACCESS_KEY
  unset AWS_SESSION_TOKEN
  unset AWS_DEFAULT_REGION

  set -a
  # shellcheck disable=SC1090
  source "$source"
  set +a

  : "${AWS_ACCESS_KEY_ID:?Falta AWS_ACCESS_KEY_ID en ${source}}"
  : "${AWS_SECRET_ACCESS_KEY:?Falta AWS_SECRET_ACCESS_KEY en ${source}}"

  AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$S3_REGION}"
  export AWS_DEFAULT_REGION
}

with_tenant_restic() {
  (
    set -a
    # shellcheck disable=SC1090
    source "$TENANT_RESTIC_CONFIG"
    set +a

    "$@"
  )
}

bucket_accessible() {
  aws \
    --endpoint-url="https://${S3_ENDPOINT}" \
    s3api head-bucket \
    --bucket="$BUCKET" \
    >/dev/null 2>&1
}

create_bucket() {
  log "Creando bucket privado: ${BUCKET}"

  if ! aws \
    --endpoint-url="https://${S3_ENDPOINT}" \
    s3api create-bucket \
    --bucket="$BUCKET" \
    --region="$S3_REGION" \
    >/dev/null; then

    fail \
      "No se pudo crear '${BUCKET}'. Puede existir globalmente o faltar permisos."
  fi

  bucket_accessible ||
    fail "El bucket se creó pero no puede consultarse: ${BUCKET}"
}

repository_initialized() {
  [[ -f "$TENANT_RESTIC_CONFIG" ]] || return 1

  with_tenant_restic \
    restic snapshots \
    >/dev/null 2>&1
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

    --bucket)
      [[ $# -ge 2 ]] || fail "Falta valor para --bucket"
      BUCKET="$2"
      shift 2
      ;;

    --s3-region)
      [[ $# -ge 2 ]] || fail "Falta valor para --s3-region"
      S3_REGION="$2"
      shift 2
      ;;

    --s3-endpoint)
      [[ $# -ge 2 ]] || fail "Falta valor para --s3-endpoint"
      S3_ENDPOINT="$2"
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
# Preflight
# =============================================================================

[[ -n "$TENANT" ]] || fail "Falta --tenant."

[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] ||
  fail "Tenant inválido: ${TENANT}"

[[ "$TENANT" != "aegora" ]] ||
  fail "El tenant legacy 'aegora' no se configura con este script."

validate_endpoint "$S3_ENDPOINT"

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"
TENANT_SECRETS_DIR="${TENANT_ROOT}/secrets"
TENANT_RESTIC_CONFIG="${TENANT_SECRETS_DIR}/restic.env"

require_file "$TENANT_CONFIG"

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
set +a

: "${TENANT_ID:?Falta TENANT_ID}"

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

if [[ -z "$BUCKET" ]]; then
  BUCKET="aegora-${TENANT}-backups"
fi

validate_bucket_name "$BUCKET"

EXPECTED_REPOSITORY="s3:${S3_ENDPOINT}/${BUCKET}"

if [[ -z "$S3_CREDENTIALS_FILE" ]]; then
  S3_CREDENTIALS_FILE="$GLOBAL_BOOTSTRAP_CONFIG"

  if [[ "$TENANT" != "demo" &&
        "$ALLOW_SHARED_S3_CREDENTIALS" != true ]]; then

    fail \
      "Para un tenant real debes proporcionar --s3-credentials-file o confirmar --allow-shared-s3-credentials."
  fi
fi

require_command aws
require_command restic
require_command openssl
require_command python3

require_file "$S3_CREDENTIALS_FILE"

cat <<EOF

============================================================
AEGORA TENANT BACKUP PROVISIONING
============================================================

Tenant:
  ${TENANT}

Bucket:
  ${BUCKET}

Endpoint:
  ${S3_ENDPOINT}

Región:
  ${S3_REGION}

Repositorio Restic:
  ${EXPECTED_REPOSITORY}

Configuración:
  ${TENANT_RESTIC_CONFIG}

Credenciales S3 origen:
  ${S3_CREDENTIALS_FILE}

Credenciales compartidas:
  $([[ "$S3_CREDENTIALS_FILE" == "$GLOBAL_BOOTSTRAP_CONFIG" ]] && echo true || echo false)

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha modificado el sistema."
  exit 0
fi

[[ $EUID -eq 0 ]] ||
  fail "--apply debe ejecutarse como root."

install \
  -d \
  -m 700 \
  -o root \
  -g root \
  "$TENANT_SECRETS_DIR"

# =============================================================================
# Si ya existe restic.env, verificar y hacer la operación idempotente
# =============================================================================

if [[ -f "$TENANT_RESTIC_CONFIG" ]]; then
  log "Ya existe configuración Restic del tenant. Validando."

  existing_repository="$(
    (
      set -a
      # shellcheck disable=SC1090
      source "$TENANT_RESTIC_CONFIG"
      set +a
      printf '%s' "${RESTIC_REPOSITORY:-}"
    )
  )"

  [[ "$existing_repository" == "$EXPECTED_REPOSITORY" ]] ||
    fail \
      "El tenant ya apunta a otro repositorio: ${existing_repository}"

  if repository_initialized; then
    log "Repositorio Restic ya inicializado."
    with_tenant_restic restic check

    set_env_value \
      "$TENANT_CONFIG" \
      "BACKUP_REPOSITORY_CONFIGURED" \
      "true"

    set_env_value \
      "$TENANT_CONFIG" \
      "BACKUP_RESTIC_CONFIG" \
      "$TENANT_RESTIC_CONFIG"

    set_env_value \
      "$TENANT_CONFIG" \
      "BACKUP_BUCKET" \
      "$BUCKET"

    set_env_value \
      "$TENANT_CONFIG" \
      "BACKUP_S3_ENDPOINT" \
      "$S3_ENDPOINT"

    set_env_value \
      "$TENANT_CONFIG" \
      "BACKUP_S3_REGION" \
      "$S3_REGION"

    bash -n "$TENANT_CONFIG"

    log "Backup del tenant ya estaba configurado y es válido."
    exit 0
  fi

  fail \
    "Existe ${TENANT_RESTIC_CONFIG} pero no abre un repositorio Restic válido."
fi

# =============================================================================
# Credenciales S3 y bucket
# =============================================================================

load_aws_credentials "$S3_CREDENTIALS_FILE"

if bucket_accessible; then
  log "Bucket ya existente y accesible: ${BUCKET}"
else
  create_bucket
fi

# =============================================================================
# Crear restic.env del tenant
# =============================================================================

RESTIC_PASSWORD_NEW="$(openssl rand -hex 32)"

write_env_file \
  "$TENANT_RESTIC_CONFIG" \
  "AWS_DEFAULT_REGION" "$S3_REGION" \
  "AWS_ACCESS_KEY_ID" "$AWS_ACCESS_KEY_ID" \
  "AWS_SECRET_ACCESS_KEY" "$AWS_SECRET_ACCESS_KEY" \
  "RESTIC_REPOSITORY" "$EXPECTED_REPOSITORY" \
  "RESTIC_PASSWORD" "$RESTIC_PASSWORD_NEW"

unset RESTIC_PASSWORD_NEW

chown root:root "$TENANT_RESTIC_CONFIG"
chmod 600 "$TENANT_RESTIC_CONFIG"

bash -n "$TENANT_RESTIC_CONFIG"

# =============================================================================
# Inicializar y comprobar Restic
# =============================================================================

log "Inicializando repositorio Restic."

if ! with_tenant_restic restic init; then
  rm -f "$TENANT_RESTIC_CONFIG"

  fail \
    "Restic init ha fallado. Se conserva el bucket para diagnóstico."
fi

log "Comprobando repositorio Restic."

with_tenant_restic restic snapshots
with_tenant_restic restic check

# =============================================================================
# Actualizar tenant.env
# =============================================================================

set_env_value \
  "$TENANT_CONFIG" \
  "BACKUP_REPOSITORY_CONFIGURED" \
  "true"

set_env_value \
  "$TENANT_CONFIG" \
  "BACKUP_RESTIC_CONFIG" \
  "$TENANT_RESTIC_CONFIG"

set_env_value \
  "$TENANT_CONFIG" \
  "BACKUP_BUCKET" \
  "$BUCKET"

set_env_value \
  "$TENANT_CONFIG" \
  "BACKUP_S3_ENDPOINT" \
  "$S3_ENDPOINT"

set_env_value \
  "$TENANT_CONFIG" \
  "BACKUP_S3_REGION" \
  "$S3_REGION"

bash -n "$TENANT_CONFIG"

cat <<EOF

============================================================
BACKUP DEL TENANT CONFIGURADO
============================================================

Tenant:
  ${TENANT}

Bucket:
  ${BUCKET}

Repositorio:
  ${EXPECTED_REPOSITORY}

Restic:
  INIT OK
  CHECK OK

tenant.env:
  BACKUP_REPOSITORY_CONFIGURED=true

Siguiente fase:
  activate-tenant-operations.sh

============================================================
EOF
