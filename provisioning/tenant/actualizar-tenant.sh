#!/usr/bin/env bash
# =============================================================================
# Aegora · lleva un tenant a la versión del checkout (un release, o la rama en `dev`)
#
#   sudo provisioning/tenant/actualizar-tenant.sh --tenant X            # PLAN
#   sudo provisioning/tenant/actualizar-tenant.sh --tenant X --apply    # aplicar
#
# Es la cadena que hasta el 27/nov/2026 se ejecutaba a mano leyendo el CLAUDE.md,
# escrita una sola vez. No reimplementa nada: llama a los scripts de siempre, en el
# orden que importa, y PARA en el primero que falla. Por qué existe y qué decide:
# docs/VERSIONADO.md (fase 2).
#
# Orden (y por qué no es intercambiable):
#    1  backup                   punto de vuelta (no en `dev`, que no tiene datos de valor)
#    2  config                   compose/.env/manifiesto; recrear solo con --recrear
#    3  extensiones              antes del esquema: el CLI de Directus las carga
#    4  esquema                  apply-schema --apply
#    5  reinicio de Directus     caché de ESQUEMA: los configure-* hablan por la API
#    6  vistas, ui, presets, español, rol gestor, rol n8n, insights
#    7  reinicio de Directus     caché de PERMISOS
#    8  booking                  la versión de release.env
#    9  workflows                render COMPLETO, nunca --only
#   10  plantillas de WhatsApp   solo si el tenant tiene WhatsApp; no para la cadena
#   11  pruebas de humo          los tres contenedores sanos
#   12  registro                 state/version, solo si TODO salió bien
#
# Antes de tocar nada, con --apply se ejecuta el PLAN de todos los pasos y se para si:
#   - el tenant no es `dev` y el checkout no está exactamente en un tag, o tiene cambios;
#   - el tenant no es `dev` y ese release no consta ENTERO en `dev` ("dev primero" deja
#     de ser una costumbre: el registro de dev lo dice);
#   - el esquema propone BORRAR algo (salvo --permitir-borrados);
#   - la configuración del tenant cambia y no se ha pedido --recrear (recrear corta el
#     servicio unos segundos: es una decisión con horario);
#   - cualquier PLAN falla (credenciales de n8n que faltan, Directus caído...).
#
# Lo que NO hace, y la nota del release (releases/<tag>.md) lo recuerda en el PLAN:
# credenciales de n8n, paneles de Meta y Retell, aprobar plantillas, DNS.
#
# Volver a lanzarlo es seguro: todos los pasos son idempotentes. Un tenant que se queda a
# medias se ve a medias en scripts/aegora-estado.sh, porque cada script registra lo suyo
# y state/version no se mueve hasta el final.
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

RAIZ="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
# shellcheck source=/dev/null
source "${RAIZ}/scripts/lib/esperar-contenedor.sh"
# shellcheck source=/dev/null
source "${RAIZ}/scripts/lib/registrar-despliegue.sh"

TENANTS_ROOT="${AEGORA_TENANTS_ROOT:-/opt/aegora/tenants}"
TENANT_PRUEBAS="${AEGORA_TENANT_PRUEBAS:-dev}"

TENANT=""
APPLY=false
PERMITIR_BORRADOS=false
RECREAR=false
SIN_BACKUP=false
VERBOSE=false

log()  { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
warn() { log "AVISO: $*" >&2; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Uso:
  actualizar-tenant.sh --tenant TENANT [--apply] [opciones]

Sin --apply: PLAN de todos los pasos y un resumen. No modifica nada.

Opciones (solo cuentan con --apply):
  --recrear            si la configuración del tenant cambia, escribirla y recrear
                       los contenedores afectados (corta el servicio unos segundos)
  --permitir-borrados  aplicar un esquema que borra campos o colecciones
                       (no se deshace con Git: hay backup en el paso 1)
  --sin-backup         saltar el backup previo (en `dev` se salta siempre)
  --verbose            ver la salida completa de cada paso, no solo el resumen

La salida completa de cada paso queda en
  /opt/aegora/tenants/<tenant>/state/actualizaciones/<fecha>-<plan|apply>/
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)            [[ $# -ge 2 ]] || fail "Falta valor para --tenant."; TENANT="$2"; shift 2 ;;
    --apply)             APPLY=true; shift ;;
    --recrear)           RECREAR=true; shift ;;
    --permitir-borrados) PERMITIR_BORRADOS=true; shift ;;
    --sin-backup)        SIN_BACKUP=true; shift ;;
    --verbose)           VERBOSE=true; shift ;;
    --help|-h)           usage; exit 0 ;;
    *) fail "Opción desconocida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"
[[ "$TENANT" != "aegora" ]] || fail "El id 'aegora' está protegido."
[[ $EUID -eq 0 ]] || fail "Hay que ejecutarlo con sudo: los pasos usan docker y los secretos del tenant."
command -v flock >/dev/null 2>&1 || fail "Falta flock."

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"
[[ -f "$TENANT_CONFIG" ]] || fail "No existe ${TENANT_CONFIG}."

# tenant.env se lee en un subshell: define variables (TENANT_ROOT, entre otras) que no
# tienen por qué pisar las de este script.
leer_tenant_env() { bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${!2:-}"' _ "$TENANT_CONFIG" "$1"; }
DIRECTUS_CONTAINER="$(leer_tenant_env DIRECTUS_CONTAINER)"; DIRECTUS_CONTAINER="${DIRECTUS_CONTAINER:-${TENANT}-directus}"
N8N_CONTAINER="$(leer_tenant_env N8N_CONTAINER)";           N8N_CONTAINER="${N8N_CONTAINER:-${TENANT}-n8n}"
BOOKING_CONTAINER="$(leer_tenant_env BOOKING_CONTAINER)";   BOOKING_CONTAINER="${BOOKING_CONTAINER:-${TENANT}-booking}"

ES_PRUEBAS=false
if [[ "$TENANT" == "$TENANT_PRUEBAS" ]]; then ES_PRUEBAS=true; SIN_BACKUP=true; fi

# Dos actualizaciones a la vez sobre el mismo tenant se pisarían los reinicios.
mkdir -p "${TENANT_ROOT}/state"
chmod 755 "${TENANT_ROOT}/state"
exec 9>"${TENANT_ROOT}/state/actualizar.lock"
flock -n 9 || fail "Ya hay una actualización de ${TENANT} en curso."

MODO="$([[ "$APPLY" == true ]] && echo apply || echo plan)"
LOGDIR="${TENANT_ROOT}/state/actualizaciones/$(date +%Y%m%d-%H%M%S)-${MODO}"
mkdir -p "$LOGDIR/plan"
# Los logs pueden llevar nombres de host y rutas de secretos; no sus valores, pero
# tampoco hace falta que los lea cualquiera.
chmod 700 "${TENANT_ROOT}/state/actualizaciones" "$LOGDIR"

# -----------------------------------------------------------------------------
# Versión del checkout
# -----------------------------------------------------------------------------
_git() { git -c safe.directory='*' -C "$RAIZ" "$@" 2>/dev/null || true; }
COMMIT="$(_git rev-parse --short=12 HEAD)"
RELEASE="$(_git describe --tags --exact-match --match 'v*' HEAD)"
ULTIMO_TAG="$(_git tag --list 'v*' --sort=-version:refname | head -n1)"
SUCIO=false
[[ -n "$(_git status --porcelain --untracked-files=no)" ]] && SUCIO=true
BOOKING_REF="$(sed -n 's/^BOOKING_REF=//p' "${RAIZ}/release.env" 2>/dev/null | tail -n1 | tr -d '[:space:]"'"'"'')"

BLOQUEOS=()   # motivos por los que --apply no seguiría
AVISOS=()

if [[ "$ES_PRUEBAS" != true ]]; then
  if [[ -z "$RELEASE" ]]; then
    BLOQUEOS+=("El checkout no está en un tag (HEAD ${COMMIT}). Un tenant que no es ${TENANT_PRUEBAS} solo recibe releases:
      cd ${RAIZ} && git fetch origin --tags && git checkout ${ULTIMO_TAG:-<tag>}")
  fi
  if [[ "$SUCIO" == true ]]; then
    BLOQUEOS+=("El checkout tiene cambios sin commitear en ficheros versionados (git status). Eso no es ningún release.")
  fi
  if [[ -n "$RELEASE" ]]; then
    if ! COMPROBACION="$("${RAIZ}/scripts/aegora-estado.sh" --comprobar "$TENANT_PRUEBAS" "$RELEASE" 2>&1)"; then
      BLOQUEOS+=("${RELEASE} no consta entero en ${TENANT_PRUEBAS} (dev primero):
      ${COMPROBACION}")
    fi
    if [[ -n "$ULTIMO_TAG" && "$RELEASE" != "$ULTIMO_TAG" ]]; then
      AVISOS+=("${RELEASE} no es el último release (${ULTIMO_TAG}). Correcto solo si es una vuelta atrás a propósito.")
    fi
  fi
fi
[[ -n "$BOOKING_REF" ]] || BLOQUEOS+=("${RAIZ}/release.env no define BOOKING_REF.")

# -----------------------------------------------------------------------------
# Ejecutar un paso: salida a su log (y a pantalla con --verbose); si falla, se para.
# -----------------------------------------------------------------------------
N=0
ULTIMO_LOG=""

paso() {
  local dir="$1" nombre="$2"; shift 2
  N=$((N + 1))
  ULTIMO_LOG="${dir}/$(printf '%02d' "$N")-${nombre}.log"
  local inicio=$SECONDS
  printf '[%s] %-34s ' "$(date +%H:%M:%S)" "${N}. ${nombre}"
  [[ "$VERBOSE" == true ]] && printf '\n'
  local rc=0
  if [[ "$VERBOSE" == true ]]; then
    ( "$@" ) 2>&1 | tee "$ULTIMO_LOG" || rc=$?
  else
    ( "$@" ) >"$ULTIMO_LOG" 2>&1 || rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    printf 'FALLO (%ss)\n\n' "$((SECONDS - inicio))"
    tail -n 40 "$ULTIMO_LOG" | sed 's/^/    | /'
    printf '\n'
    log "ERROR: falló el paso ${N} (${nombre}). Log completo: ${ULTIMO_LOG}"
    if [[ "$APPLY" == true && "$dir" != */plan ]]; then
      log "El tenant puede haber quedado a medias: lo dice 'sudo ${RAIZ}/scripts/aegora-estado.sh --tenant ${TENANT}'."
      log "Corregida la causa, volver a lanzar este comando es seguro (cada paso es idempotente)."
    fi
    exit 1
  fi
  printf 'ok (%ss)\n' "$((SECONDS - inicio))"
}

# Igual, pero un fallo NO para la cadena (lo que no es versión de nada).
paso_opcional() {
  local dir="$1" nombre="$2"; shift 2
  N=$((N + 1))
  ULTIMO_LOG="${dir}/$(printf '%02d' "$N")-${nombre}.log"
  printf '[%s] %-34s ' "$(date +%H:%M:%S)" "${N}. ${nombre}"
  if ( "$@" ) >"$ULTIMO_LOG" 2>&1; then
    printf 'ok\n'
  else
    printf 'FALLO (no para la cadena)\n'
    AVISOS+=("${nombre} falló: ${ULTIMO_LOG}")
  fi
}

D="${RAIZ}/directus"
P="${RAIZ}/provisioning/tenant"
CONFIGURE=(
  "vistas:${D}/configure-directus-views.sh"
  "ui:${D}/configure-directus-ui.sh"
  "presets:${D}/configure-directus-presets.sh"
  "espanol:${D}/configure-spanish-ui.sh"
  "rol-gestor:${D}/configure-tenant-role.sh"
  "rol-n8n:${D}/configure-n8n-service.sh"
  "insights:${D}/configure-directus-insights.sh"
)
TIENE_WHATSAPP=false
[[ -f "${TENANT_ROOT}/secrets/whatsapp.env" ]] && TIENE_WHATSAPP=true

# -----------------------------------------------------------------------------
# PLAN de todos los pasos (también con --apply: es la comprobación previa)
# -----------------------------------------------------------------------------
cat <<EOF

============================================================
AEGORA · ACTUALIZAR TENANT (${MODO^^})
============================================================
Tenant:      ${TENANT}$([[ "$ES_PRUEBAS" == true ]] && echo "  (tenant de pruebas: puede ir por la rama)")
Versión:     ${RELEASE:-sin tag} @ ${COMMIT}$([[ "$SUCIO" == true ]] && echo "  CON CAMBIOS SIN COMMITEAR")
Booking API: ${BOOKING_REF:0:12} (release.env)
Logs:        ${LOGDIR}
============================================================

EOF

log "PLAN de cada paso (no modifica nada):"
PL="${LOGDIR}/plan"
paso "$PL" config      "${P}/render-tenant-config.sh" --tenant "$TENANT"
LOG_CONFIG="$ULTIMO_LOG"
paso "$PL" extensiones "${D}/configure-directus-extensions.sh" --tenant "$TENANT"
paso "$PL" esquema     "${D}/apply-schema.sh" --tenant "$TENANT"
LOG_ESQUEMA="$ULTIMO_LOG"
for c in "${CONFIGURE[@]}"; do
  paso "$PL" "${c%%:*}" "${c#*:}" --tenant "$TENANT"
done
paso "$PL" booking     "${P}/deploy-booking.sh" --tenant "$TENANT"
LOG_BOOKING="$ULTIMO_LOG"
paso "$PL" workflows   "${RAIZ}/n8n/render-workflows.sh" --tenant "$TENANT"
LOG_WORKFLOWS="$ULTIMO_LOG"
if [[ "$TIENE_WHATSAPP" == true ]]; then
  paso_opcional "$PL" plantillas-whatsapp "${RAIZ}/n8n/whatsapp-templates.sh" --tenant "$TENANT"
fi

# ----------------------------------------------------------------- resumen
CONFIG_CAMBIA=false
grep -q 'Ficheros con diferencias' "$LOG_CONFIG" && CONFIG_CAMBIA=true
# El diff del CLI de Directus: "  - Create x", "  - Update x", "  - Delete x" a DOS
# espacios; lo de dentro de un Update ("    - Set ...") va a cuatro y no cuenta.
N_CREA="$(grep -cE '^  - Create ' "$LOG_ESQUEMA" || true)"
N_CAMBIA="$(grep -cE '^  - Update ' "$LOG_ESQUEMA" || true)"
BORRADOS="$(grep -E '^  - Delete ' "$LOG_ESQUEMA" | sed 's/^  - Delete /      /' || true)"

printf '\nResumen:\n'
if [[ "$CONFIG_CAMBIA" == true ]]; then
  printf '  config      CAMBIA:\n'
  sed -n '/Ficheros con diferencias/,$p' "$LOG_CONFIG" | grep -E '^\[.*\]     ' | sed 's/^\[[^]]*\] */      /'
  if [[ "$RECREAR" != true ]]; then
    BLOQUEOS+=("La configuración del tenant cambia y hay que recrear contenedores (corte de unos segundos). Repite con --recrear cuando sea buen momento. Detalle: ${LOG_CONFIG}")
  fi
else
  printf '  config      sin cambios\n'
fi
printf '  esquema     %s altas, %s cambios' "$N_CREA" "$N_CAMBIA"
if [[ -n "$BORRADOS" ]]; then
  printf ', BORRA:\n%s\n' "$BORRADOS"
  if [[ "$PERMITIR_BORRADOS" != true ]]; then
    BLOQUEOS+=("El esquema BORRA lo de arriba. Eso no se deshace con Git. Si es lo previsto en la nota del release, repite con --permitir-borrados.")
  fi
else
  printf ', sin borrados\n'
fi
printf '              (detalle: %s)\n' "$LOG_ESQUEMA"
printf '  booking     %s\n' "$(grep -E '^Ref:' "$LOG_BOOKING" | sed 's/^Ref: *//' || echo '?')"
printf '  workflows   render completo'
if grep -q 'INCOMPLETO' "$LOG_WORKFLOWS"; then
  printf '\n'
  grep 'INCOMPLETO' "$LOG_WORKFLOWS" | sed 's/^/      /'
  AVISOS+=("Secretos INCOMPLETOS en el render de workflows (arriba). Si el tenant usa ese canal, no va a funcionar.")
else
  printf ', secretos de WhatsApp y Retell completos\n'
fi
[[ "$TIENE_WHATSAPP" == true ]] || printf '  plantillas  el tenant no tiene WhatsApp: se omite\n'
[[ "$SIN_BACKUP" == true ]] && printf '  backup      NO se hace%s\n' "$([[ "$ES_PRUEBAS" == true ]] && echo " (tenant de pruebas)")"

NOTA="${RAIZ}/releases/${RELEASE}.md"
if [[ -n "$RELEASE" && -f "$NOTA" ]]; then
  for seccion in "Antes de desplegar" "Después de desplegar"; do
    contenido="$(awk -v s="## ${seccion}" '$0 ~ "^"s {f=1; next} /^## / {f=0} f' "$NOTA" | sed '/^\s*$/d')"
    if [[ -n "$contenido" ]]; then
      printf '\n%s (manual, de %s):\n%s\n' "$seccion" "releases/${RELEASE}.md" "$(sed 's/^/  /' <<<"$contenido")"
    fi
  done
elif [[ -n "$RELEASE" ]]; then
  AVISOS+=("No existe releases/${RELEASE}.md: no hay lista de pasos manuales que recordar.")
fi

if [[ ${#AVISOS[@]} -gt 0 ]]; then
  printf '\nAvisos:\n'
  for a in "${AVISOS[@]}"; do printf '  - %s\n' "$a"; done
fi
if [[ ${#BLOQUEOS[@]} -gt 0 ]]; then
  printf '\n--apply NO seguiría:\n'
  for b in "${BLOQUEOS[@]}"; do printf '  - %s\n' "$b"; done
fi
printf '\n'

if [[ "$APPLY" != true ]]; then
  if [[ ${#BLOQUEOS[@]} -gt 0 ]]; then
    log "PLAN ONLY. Hay que resolver lo de arriba antes de aplicar."
    exit 1
  fi
  log "PLAN ONLY. No se ha modificado nada. Para aplicar:"
  printf '    sudo %s --tenant %s --apply%s\n\n' "$0" "$TENANT" \
    "$([[ "$CONFIG_CAMBIA" == true ]] && echo ' --recrear')$([[ -n "$BORRADOS" ]] && echo ' --permitir-borrados')"
  exit 0
fi

[[ ${#BLOQUEOS[@]} -eq 0 ]] || fail "No se aplica nada: resuelve lo de arriba."

# -----------------------------------------------------------------------------
# APPLY
# -----------------------------------------------------------------------------
AP="$LOGDIR"
N=0
log "APPLY:"

if [[ "$SIN_BACKUP" != true ]]; then
  paso "$AP" backup "${RAIZ}/scripts/backup/backup-tenant.sh" --tenant "$TENANT"
fi

paso "$AP" config "${P}/render-tenant-config.sh" --tenant "$TENANT" --apply
# render-tenant-config escribe y DICE qué recrear, pero no recrea: eso lo hace este
# script, solo con --recrear (si no, ya se ha parado antes con la config cambiando).
mapfile -t RECREAR_COMPOSE < <(grep -oE 'docker compose -f [^ ]+/compose\.yml up -d --force-recreate' "$ULTIMO_LOG" \
  | sed -E 's/^docker compose -f ([^ ]+) up.*/\1/' | sort -u)
for compose in "${RECREAR_COMPOSE[@]}"; do
  paso "$AP" "recrear-$(basename "$(dirname "$compose")")" docker compose -f "$compose" up -d --force-recreate
done
if [[ ${#RECREAR_COMPOSE[@]} -gt 0 ]]; then
  paso "$AP" esperar-contenedores bash -c "
    source '${RAIZ}/scripts/lib/esperar-contenedor.sh'
    esperar_healthy '${DIRECTUS_CONTAINER}'
    esperar_healthy '${N8N_CONTAINER}'
    if docker inspect '${BOOKING_CONTAINER}' >/dev/null 2>&1; then esperar_healthy '${BOOKING_CONTAINER}'; fi"
fi

paso "$AP" extensiones "${D}/configure-directus-extensions.sh" --tenant "$TENANT" --apply
paso "$AP" esquema     "${D}/apply-schema.sh" --tenant "$TENANT" --apply
paso "$AP" reinicio-directus reiniciar_y_esperar "$DIRECTUS_CONTAINER"
for c in "${CONFIGURE[@]}"; do
  paso "$AP" "${c%%:*}" "${c#*:}" --tenant "$TENANT" --apply
done
paso "$AP" reinicio-directus reiniciar_y_esperar "$DIRECTUS_CONTAINER"
paso "$AP" booking   "${P}/deploy-booking.sh" --tenant "$TENANT" --apply
paso "$AP" workflows "${RAIZ}/n8n/render-workflows.sh" --tenant "$TENANT" --apply
if [[ "$TIENE_WHATSAPP" == true ]]; then
  paso_opcional "$AP" plantillas-whatsapp "${RAIZ}/n8n/whatsapp-templates.sh" --tenant "$TENANT" --apply
fi
paso "$AP" humo bash -c "
  source '${RAIZ}/scripts/lib/esperar-contenedor.sh'
  esperar_healthy '${DIRECTUS_CONTAINER}' 120
  esperar_healthy '${N8N_CONTAINER}' 120
  esperar_healthy '${BOOKING_CONTAINER}' 120
  docker exec '${DIRECTUS_CONTAINER}' node -e \"fetch('http://127.0.0.1:8055/server/ping').then(r=>r.text()).then(t=>{if(t.trim()!=='pong'){console.error('ping: '+t);process.exit(1)}console.log('directus: pong')}).catch(e=>{console.error(e.message);process.exit(1)})\""

# ----------------------------------------------------------------- registro
python3 - "${TENANT_ROOT}/state/version" "$RELEASE" "$COMMIT" "$BOOKING_REF" "${SUDO_USER:-$USER}" <<'PY'
import json, sys, datetime
fichero, release, commit, booking, usuario = sys.argv[1:6]
with open(fichero, "w", encoding="utf-8") as f:
    json.dump({
        "release": release or None,
        "commit": commit,
        "booking_ref": booking,
        "fecha": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "usuario": usuario,
    }, f, ensure_ascii=False)
    f.write("\n")
PY
chmod 644 "${TENANT_ROOT}/state/version"
registrar_despliegue "$TENANT" actualizacion "" "completa" >/dev/null

printf '\n'
log "${TENANT} actualizado a ${RELEASE:-${COMMIT}} en $((SECONDS / 60)) min."
if [[ ${#AVISOS[@]} -gt 0 ]]; then
  printf '\nAvisos:\n'
  for a in "${AVISOS[@]}"; do printf '  - %s\n' "$a"; done
fi
if [[ -n "$RELEASE" && -f "$NOTA" ]] && grep -q '^## Después de desplegar' "$NOTA"; then
  printf '\nQueda lo manual de "Después de desplegar" en releases/%s.md.\n' "$RELEASE"
fi
printf '\n'
