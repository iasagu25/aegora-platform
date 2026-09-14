#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora · variables de configuración de un tenant existente
#
# Responsabilidad:
#   - fijar (crear o reemplazar) claves en <tenant>/config/tenant.env de forma
#     idempotente, sin editar a mano un fichero de root.
#
# Existe porque create-tenant.sh solo escribe tenant.env al crear el tenant:
# cuando se añade una variable nueva a la plataforma (p.ej. WEBHOOK_HOST), los
# tenants ya creados se quedan sin ella. Editarla a mano con sed/tee es
# justamente lo que ha provocado líneas duplicadas y borrados accidentales.
#
# Idempotente: ejecutar dos veces con el mismo valor no cambia nada, y una
# clave repetida en el fichero queda reducida a una sola línea.
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"

TENANT=""
APPLY=false
PAIRS=()

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  set-tenant-config.sh --tenant TENANT --set CLAVE=VALOR [--set CLAVE=VALOR ...] [--apply]

Sin --apply:
  muestra qué cambiaría (valor actual -> valor nuevo) sin tocar nada.

Con --apply:
  escribe los cambios en <tenant>/config/tenant.env, dejando una copia previa
  en tenant.env.bak. Las claves que ya tengan el valor pedido se omiten.

Ejemplo:
  set-tenant-config.sh --tenant demo --set WEBHOOK_HOST=lucia.demo.aegora.es --apply
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      [[ $# -ge 2 ]] || fail "Falta valor para --tenant."
      TENANT="$2"
      shift 2
      ;;
    --set)
      [[ $# -ge 2 ]] || fail "Falta valor para --set."
      [[ "$2" == *=* ]] || fail "--set espera CLAVE=VALOR, recibido: $2"
      PAIRS+=("$2")
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
[[ ${#PAIRS[@]} -gt 0 ]] || fail "Falta al menos un --set CLAVE=VALOR."

readonly TENANT_ENV="${TENANTS_ROOT}/${TENANT}/config/tenant.env"
[[ -f "$TENANT_ENV" ]] || fail "No existe ${TENANT_ENV}"

# -----------------------------------------------------------------------------
# Plan
# -----------------------------------------------------------------------------

current_value() {
  # Última aparición: es la que gana al hacer `source`.
  grep -E "^${1}=" "$TENANT_ENV" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

occurrences() {
  grep -cE "^${1}=" "$TENANT_ENV" 2>/dev/null || true
}

CHANGES=0

cat <<EOF

============================================================
AEGORA TENANT CONFIG
============================================================

Tenant:
  ${TENANT}

Fichero:
  ${TENANT_ENV}

Cambios:
EOF

for pair in "${PAIRS[@]}"; do
  key="${pair%%=*}"
  value="${pair#*=}"

  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] ||
    fail "Clave no válida (se espera MAYUSCULAS_CON_GUION_BAJO): ${key}"

  actual="$(current_value "$key")"
  veces="$(occurrences "$key")"

  if [[ "$actual" == "$value" && "$veces" == "1" ]]; then
    printf '  %-24s sin cambios (%s)\n' "$key" "$value"
  elif [[ -z "$actual" && "$veces" == "0" ]]; then
    printf '  %-24s (ausente) -> %s\n' "$key" "$value"
    CHANGES=$((CHANGES + 1))
  else
    printf '  %-24s %s -> %s' "$key" "${actual:-(vacío)}" "$value"
    [[ "$veces" -le 1 ]] || printf '   [%s líneas duplicadas, quedará 1]' "$veces"
    printf '\n'
    CHANGES=$((CHANGES + 1))
  fi
done

cat <<EOF

Modo:
  $([[ "$APPLY" == true ]] && echo apply || echo plan)

============================================================

EOF

if [[ "$CHANGES" -eq 0 ]]; then
  log "Nada que cambiar."
  exit 0
fi

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha modificado ${TENANT_ENV}."
  exit 0
fi

# -----------------------------------------------------------------------------
# Apply
# -----------------------------------------------------------------------------

cp -a "$TENANT_ENV" "${TENANT_ENV}.bak"
log "Copia previa: ${TENANT_ENV}.bak"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cp -a "$TENANT_ENV" "$tmp"

for pair in "${PAIRS[@]}"; do
  key="${pair%%=*}"
  value="${pair#*=}"

  # Quita TODAS las apariciones previas y añade una sola al final: así una
  # clave duplicada queda saneada en la misma pasada.
  grep -vE "^${key}=" "$tmp" > "${tmp}.new" || true
  mv "${tmp}.new" "$tmp"
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
done

cat "$tmp" > "$TENANT_ENV"
log "Escrito ${TENANT_ENV}"

for pair in "${PAIRS[@]}"; do
  key="${pair%%=*}"
  printf '  %-24s %s\n' "$key" "$(current_value "$key")"
done

log "Hecho. Recuerda republicar si has tocado hostnames: publish-tenant.sh --tenant ${TENANT}"
