#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora · re-renderizar la configuración de un tenant existente
#
# `create-tenant.sh` renderiza `compose/*/.env`, `compose/*/compose.yml` y
# `backup.manifest.json` UNA SOLA VEZ, al crear el tenant. Cuando una plantilla
# mejora, los tenants ya creados se quedan atrás en silencio -- y la diferencia
# se descubre cuando algo falla, normalmente semanas después.
#
# El 18-20/sep/2026 eso fue la causa de seis incidencias distintas: el pruning
# de ejecuciones de n8n, el App Secret de WhatsApp, el manifiesto sin
# `secrets/restic.env`, la variable `$env`... Cada vez se acabó editando un
# fichero del tenant a mano, que es justo lo que este script existe para evitar.
#
# CÓMO CONSIGUE LOS VALORES, por orden:
#   1. `tenant.env`            -- hosts, contenedores, bases, rutas, versiones
#   2. `secrets/*.env`         -- contraseñas y claves
#   3. el fichero .env YA RENDERIZADO -- para lo que no está en los dos primeros
#   4. el contenedor en marcha -- solo para BOOKING_IMAGE, que únicamente vive ahí
#
# El paso 3 es el que hace esto utilizable: `BOOKING_DATABASE_URL` lo calcula
# `deploy-booking.sh` y no vive en ningún fichero estático, así que se conserva
# el que ya había. Ojo: solo funciona en ficheros CLAVE=valor. En un compose.yml
# el valor va dentro del YAML y no se puede recuperar leyendo líneas, que es por
# lo que `BOOKING_IMAGE` se lee del contenedor en marcha.
#
# LA SALVAGUARDA que hace esto seguro: si un valor que hoy NO está vacío
# quedaría vacío tras renderizar, se aborta. Un .env que pierde
# N8N_ENCRYPTION_KEY deja el tenant inservible y sus credenciales ilegibles;
# eso no puede pasar por un descuido de plantilla.
#
# NO reinicia contenedores: dice cuáles habría que reiniciar y se para ahí.
# Reiniciar es una decisión con horario, no un efecto secundario.
#
# Sin --apply solo enseña el diff.
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TEMPLATE_ROOT="${PLATFORM_ROOT}/templates/tenant-stack"
readonly RENDERER="${PLATFORM_ROOT}/provisioning/tenant/render-template.py"

TENANT=""
APPLY=false
SOLO=""

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Uso:
  render-tenant-config.sh --tenant TENANT [--only PIEZA] [--apply]

  --only directus|n8n|booking|manifest
      Re-renderiza solo esa pieza. Por defecto, todas.

Sin --apply: enseña el diff de lo que cambiaría y no toca nada.
Con --apply: escribe, guardando copia de cada fichero que sustituye.

No reinicia contenedores: al final dice cuáles lo necesitan.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant) [[ $# -ge 2 ]] || fail "Falta valor para --tenant."; TENANT="$2"; shift 2 ;;
    --only)   [[ $# -ge 2 ]] || fail "Falta valor para --only.";   SOLO="$2";   shift 2 ;;
    --apply)  APPLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Opción desconocida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"
case "${SOLO:-todas}" in
  todas|directus|n8n|booking|manifest) ;;
  *) fail "--only debe ser directus, n8n, booking o manifest." ;;
esac
command -v python3 >/dev/null 2>&1 || fail "Falta python3."
command -v diff >/dev/null 2>&1 || fail "Falta diff."

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"

if [[ ! -r "$TENANT_CONFIG" ]]; then
  if [[ $EUID -eq 0 ]]; then
    fail "No existe ${TENANT_CONFIG}"
  fi
  fail "No se puede leer ${TENANT_CONFIG}
O no existe, o es cuestión de permisos (los secretos del tenant son de root).
Prueba con sudo."
fi
[[ -f "$RENDERER" ]] || fail "No existe ${RENDERER}"
[[ -d "$TEMPLATE_ROOT" ]] || fail "No existe ${TEMPLATE_ROOT}"

# ---------------------------------------------------------------------------
# 1 y 2 · tenant.env y los secretos
# ---------------------------------------------------------------------------
set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"

for secreto in postgres directus n8n booking restic; do
  fichero="${TENANT_ROOT}/secrets/${secreto}.env"
  if [[ -r "$fichero" ]]; then
    # shellcheck disable=SC1090
    source "$fichero"
  fi
done
set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${TENANT_COMPOSE_ROOT:?Falta TENANT_COMPOSE_ROOT}"
: "${TENANT_CONFIG_ROOT:?Falta TENANT_CONFIG_ROOT}"

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

# BOOKING_IMAGE no está en tenant.env ni en secrets/: la calcula
# deploy-booking.sh al construir, y queda registrada en el contenedor. Esa es su
# fuente autoritativa, así que se lee de ahí.
if [[ -z "${BOOKING_IMAGE:-}" && -n "${BOOKING_CONTAINER:-}" ]] &&
   command -v docker >/dev/null 2>&1; then
  BOOKING_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$BOOKING_CONTAINER" 2>/dev/null || true)"
  if [[ -n "$BOOKING_IMAGE" ]]; then
    export BOOKING_IMAGE
    log "BOOKING_IMAGE tomada del contenedor ${BOOKING_CONTAINER}: ${BOOKING_IMAGE}"
  fi
fi

TRABAJO="$(mktemp -d)"
trap 'rm -rf "$TRABAJO"' EXIT

# ---------------------------------------------------------------------------
# 3 · Lo que falte, del fichero que ya existe
#
# Se leen ANTES de renderizar y se exportan, para que render-template.py las
# encuentre. Solo se toman las que no estén ya definidas: tenant.env y los
# secretos siempre mandan sobre lo renderizado la vez anterior.
# ---------------------------------------------------------------------------
heredar_de() {
  local existente="$1"
  local plantilla="$2"
  local var valor

  [[ -f "$existente" ]] || return 0
  # Solo tiene sentido en ficheros CLAVE=valor. En un compose.yml el valor está
  # dentro del YAML (`image: aegora-booking:sha`) y no se puede recuperar así;
  # para esos casos el valor se busca donde de verdad vive -- ver BOOKING_IMAGE.
  [[ "$existente" == *.env ]] || return 0

  while read -r var; do
    [[ -n "${!var:-}" ]] && continue
    valor="$(sed -n "s/^${var}=//p" "$existente" | head -1)"
    if [[ -n "$valor" ]]; then
      printf -v "$var" '%s' "$valor"
      export "${var?}"
      log "  ${var}: se conserva el valor actual (no está en tenant.env ni en secrets/)."
    fi
  done < <(grep -oE '\$\{[A-Z0-9_]+\}' "$plantilla" | tr -d '${}' | sort -u)
}

# ---------------------------------------------------------------------------
# La salvaguarda: ningún valor no vacío puede quedarse vacío
# ---------------------------------------------------------------------------
comprobar_perdidas() {
  local actual="$1"
  local nuevo="$2"
  local perdidas

  [[ -f "$actual" ]] || return 0

  perdidas="$(python3 - "$actual" "$nuevo" <<'PY'
import sys

def leer(ruta):
    d = {}
    with open(ruta, encoding="utf-8") as f:
        for linea in f:
            linea = linea.strip()
            if not linea or linea.startswith("#") or "=" not in linea:
                continue
            k, _, v = linea.partition("=")
            d[k.strip()] = v.strip()
    return d

antes, ahora = leer(sys.argv[1]), leer(sys.argv[2])
for k, v in antes.items():
    if v and k in ahora and not ahora[k]:
        print(f"    {k}: tenía valor y quedaría vacío")
    elif v and k not in ahora:
        print(f"    {k}: tenía valor y desaparecería")
PY
)"

  if [[ -n "$perdidas" ]]; then
    log "ERROR: renderizar ${actual} perdería valores:"
    printf '%s\n' "$perdidas" >&2
    fail "Abortado. Revisa que tenant.env y secrets/ tengan esos valores."
  fi
}

CAMBIOS=()
REINICIAR=()

procesar() {
  local nombre="$1"
  local plantilla="$2"
  local destino="$3"
  local contenedor="${4:-}"
  # Booking es opcional en el modelo (el manifiesto lo marca así) y su
  # despliegue lo gobierna deploy-booking.sh. Si aquí no se pueden resolver sus
  # variables, se avisa y se sigue: no tiene sentido que un tenant sin booking
  # no pueda actualizar su configuración de Directus y n8n.
  local opcional="${5:-false}"

  [[ -f "$plantilla" ]] || { log "Sin plantilla, se omite: ${nombre}"; return 0; }

  heredar_de "$destino" "$plantilla"

  local nuevo="${TRABAJO}/$(echo "$nombre" | tr '/' '_')"
  if ! python3 "$RENDERER" "$plantilla" "$nuevo" 2>"${nuevo}.err"; then
    if [[ "$opcional" == true ]]; then
      log "AVISO: no se puede renderizar ${nombre}; se omite."
      sed 's/^/         /' "${nuevo}.err" >&2
      log "         Lo gobierna deploy-booking.sh; vuelve a desplegarlo si hace falta."
      return 0
    fi
    log "ERROR renderizando ${nombre}:"
    cat "${nuevo}.err" >&2
    fail "Faltan variables. No se ha tocado nada."
  fi

  # Solo para ficheros de variables; un compose.yml no tiene forma KEY=valor.
  if [[ "$destino" == *.env ]]; then
    comprobar_perdidas "$destino" "$nuevo"
  fi

  if [[ -f "$destino" ]] && diff -q "$destino" "$nuevo" >/dev/null 2>&1; then
    return 0
  fi

  CAMBIOS+=("$nombre")
  if [[ -n "$contenedor" ]]; then
    REINICIAR+=("$contenedor")
  fi

  printf '\n--- %s\n' "$destino"
  if [[ -f "$destino" ]]; then
    # Los .env llevan secretos: se enseña QUÉ claves cambian, nunca sus valores.
    if [[ "$destino" == *.env ]]; then
      diff <(sed 's/=.*/=<valor>/' "$destino") <(sed 's/=.*/=<valor>/' "$nuevo") |
        sed 's/^/    /' || true
      log "  (los .env se comparan por clave: los valores no se imprimen)"
    else
      diff "$destino" "$nuevo" | sed 's/^/    /' || true
    fi
  else
    printf '    (no existía; se crearía)\n'
  fi

  if [[ "$APPLY" == true ]]; then
    install --directory --mode=700 "$(dirname "$destino")"
    if [[ -f "$destino" ]]; then
      cp --preserve=mode,timestamps "$destino" "${destino}.bak-$(date +%Y%m%d%H%M%S)"
    fi
    local modo=600
    [[ "$destino" == *.yml || "$destino" == *.json ]] && modo=644
    install --mode="$modo" "$nuevo" "$destino"
    log "Escrito: ${destino}"
  fi
}

cat <<PLAN

============================================================
AEGORA · RE-RENDERIZAR CONFIGURACIÓN DE TENANT
============================================================

Tenant:
  ${TENANT_ID}

Piezas:
  ${SOLO:-todas}

Modo:
  $([[ "$APPLY" == true ]] && echo apply || echo plan)

============================================================
PLAN

quiere() { [[ -z "$SOLO" || "$SOLO" == "$1" ]]; }

quiere directus && {
  procesar "directus/compose.yml" "${TEMPLATE_ROOT}/directus/compose.yml.tpl" \
    "${TENANT_COMPOSE_ROOT}/directus/compose.yml" "${DIRECTUS_CONTAINER:-}"
  procesar "directus/.env" "${TEMPLATE_ROOT}/directus/.env.tpl" \
    "${TENANT_COMPOSE_ROOT}/directus/.env" "${DIRECTUS_CONTAINER:-}"
}

quiere n8n && {
  procesar "n8n/compose.yml" "${TEMPLATE_ROOT}/n8n/compose.yml.tpl" \
    "${TENANT_COMPOSE_ROOT}/n8n/compose.yml" "${N8N_CONTAINER:-}"
  procesar "n8n/.env" "${TEMPLATE_ROOT}/n8n/.env.tpl" \
    "${TENANT_COMPOSE_ROOT}/n8n/.env" "${N8N_CONTAINER:-}"
}

quiere booking && {
  procesar "booking/compose.yml" "${TEMPLATE_ROOT}/booking/compose.yml.tpl" \
    "${TENANT_COMPOSE_ROOT}/booking/compose.yml" "${BOOKING_CONTAINER:-}" true
  procesar "booking/.env" "${TEMPLATE_ROOT}/booking/.env.tpl" \
    "${TENANT_COMPOSE_ROOT}/booking/.env" "${BOOKING_CONTAINER:-}" true
}

# El manifiesto no lo lee ningún contenedor: lo leen los scripts de backup en
# cada ejecución, así que no hay nada que reiniciar.
quiere manifest && {
  procesar "backup.manifest.json" "${TEMPLATE_ROOT}/backup.manifest.json.tpl" \
    "${TENANT_CONFIG_ROOT}/backup.manifest.json"
}

printf '\n============================================================\n'

if [[ ${#CAMBIOS[@]} -eq 0 ]]; then
  log "Nada que cambiar: la configuración del tenant ya coincide con las plantillas."
  exit 0
fi

log "Ficheros con diferencias: ${#CAMBIOS[@]}"
for c in "${CAMBIOS[@]}"; do log "    ${c}"; done

if [[ "$APPLY" != true ]]; then
  printf '\n'
  log "PLAN ONLY. No se ha modificado nada. Añade --apply para escribir."
  exit 0
fi

if [[ ${#REINICIAR[@]} -gt 0 ]]; then
  mapfile -t UNICOS < <(printf '%s\n' "${REINICIAR[@]}" | sort -u)
  cat <<FINAL

  HAY QUE REINICIAR, y no lo hago yo:

    docker restart ${UNICOS[*]}

  Un reinicio corta el servicio del cliente. Cuándo hacerlo es una decisión
  con horario, no un efecto secundario de haber tocado un fichero.

FINAL
fi

log "Copias de los ficheros sustituidos: ${TENANT_COMPOSE_ROOT}/*/*.bak-*"
