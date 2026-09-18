#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Aegora · cuánta memoria cuesta un tenant cuando de verdad se usa
#
# Las cifras de `docker stats` en reposo son un SUELO, no una media: los tenants
# actuales están prácticamente vacíos. Esto manda conversaciones simultáneas por
# webchat y mide qué pasa con la memoria mientras y, sobre todo, DESPUÉS.
#
# La pregunta que responde no es "cuánto sube" sino **"cuánto baja al terminar"**.
# Un proceso que va a estar meses levantado y no devuelve la memoria acaba
# decidiendo él solo cuántos tenants caben en la VPS.
#
# Por qué webchat y no WhatsApp: no pasa por Meta, así que no cuesta mensajes ni
# molesta a nadie, y recorre exactamente la misma cadena (Entry -> Core v2 ->
# tools -> Directus).
#
# NO es gratis: cada turno es una llamada real al LLM y deja una fila en
# `conversation_sessions`. El plan dice cuántas antes de lanzarlas.
#
# Sin --apply solo enseña el plan.
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly PLATFORM_ROOT="/opt/aegora/platform"

TENANT=""
CONCURRENCIA=10
RONDAS=3
APPLY=false
TIMEOUT=120
# Una pregunta de conocimiento: una tool, solo lectura, sin escribir nada en
# Directus. Reservar citas de mentira dejaría basura que luego hay que limpiar.
MENSAJE="¿cuál es vuestro horario de atención?"

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Uso:
  webchat-load.sh --tenant TENANT [--concurrency N] [--rounds R] [--apply]

  --concurrency N   conversaciones simultáneas (por defecto 10)
  --rounds R        turnos por conversación (por defecto 3)
  --message TEXTO   qué se pregunta (por defecto, el horario: solo lectura)
  --timeout SEG     espera máxima por turno (por defecto 120)

Sin --apply: enseña el plan, incluido cuántas llamadas al LLM va a costar.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)      [[ $# -ge 2 ]] || fail "Falta valor para --tenant."; TENANT="$2"; shift 2 ;;
    --concurrency) [[ $# -ge 2 ]] || fail "Falta valor para --concurrency."; CONCURRENCIA="$2"; shift 2 ;;
    --rounds)      [[ $# -ge 2 ]] || fail "Falta valor para --rounds."; RONDAS="$2"; shift 2 ;;
    --message)     [[ $# -ge 2 ]] || fail "Falta valor para --message."; MENSAJE="$2"; shift 2 ;;
    --timeout)     [[ $# -ge 2 ]] || fail "Falta valor para --timeout."; TIMEOUT="$2"; shift 2 ;;
    --apply)       APPLY=true; shift ;;
    --help|-h)     usage; exit 0 ;;
    *) fail "Opción desconocida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ "$CONCURRENCIA" =~ ^[0-9]+$ && "$CONCURRENCIA" -ge 1 && "$CONCURRENCIA" -le 200 ]] ||
  fail "--concurrency fuera de rango (1-200)."
[[ "$RONDAS" =~ ^[0-9]+$ && "$RONDAS" -ge 1 && "$RONDAS" -le 20 ]] ||
  fail "--rounds fuera de rango (1-20)."
command -v docker >/dev/null 2>&1 || fail "Falta docker."
command -v python3 >/dev/null 2>&1 || fail "Falta python3."

TENANT_CONFIG="${TENANTS_ROOT}/${TENANT}/config/tenant.env"
MOTOR="${PLATFORM_ROOT}/scripts/loadtest/webchat-load.py"

if [[ ! -r "$TENANT_CONFIG" ]]; then
  if [[ $EUID -eq 0 ]]; then
    fail "No existe ${TENANT_CONFIG}"
  fi
  fail "No se puede leer ${TENANT_CONFIG}
O no existe, o es cuestión de permisos (los secretos del tenant son de root).
Prueba con sudo."
fi
[[ -f "$MOTOR" ]] || fail "No existe ${MOTOR}"

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${WEBHOOK_HOST:?Falta WEBHOOK_HOST}"
: "${N8N_CONTAINER:?Falta N8N_CONTAINER}"
: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"

URL="https://${WEBHOOK_HOST}/webhook/webchat"
TOTAL_LLAMADAS=$((CONCURRENCIA * RONDAS))
ETIQUETA="load-$(date +%s)"

# Los contenedores que se vigilan: los del tenant más el Postgres compartido,
# porque es donde se vería si la carga de un tenant salpica a los demás.
VIGILADOS=("$N8N_CONTAINER" "$DIRECTUS_CONTAINER" "aegora-postgres")
[[ -n "${BOOKING_CONTAINER:-}" ]] && docker inspect "$BOOKING_CONTAINER" >/dev/null 2>&1 &&
  VIGILADOS+=("$BOOKING_CONTAINER")

cat <<PLAN

============================================================
AEGORA · ENSAYO DE CARGA POR WEBCHAT
============================================================

Tenant:
  ${TENANT_ID}

Destino:
  ${URL}

Carga:
  ${CONCURRENCIA} conversaciones simultáneas x ${RONDAS} turnos
  = ${TOTAL_LLAMADAS} turnos, cada uno una llamada REAL al LLM

Mensaje (solo lectura, no reserva nada):
  "${MENSAJE}"

Deja detrás:
  ${CONCURRENCIA} filas en conversation_sessions con clave 'webchat:${ETIQUETA}-*'
  (el comando para borrarlas sale al final)

Se vigila la memoria de:
  ${VIGILADOS[*]}

Modo:
  $([[ "$APPLY" == true ]] && echo apply || echo plan)

============================================================

PLAN

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha lanzado ninguna petición."
  exit 0
fi

# ---------------------------------------------------------------------------
# Muestreo de memoria. `docker stats --no-stream` cuesta ~1s, así que se lanza
# en bucle a parte y se queda con el máximo por contenedor.
# ---------------------------------------------------------------------------
MUESTRAS="$(mktemp)"
trap 'rm -f "$MUESTRAS"' EXIT

muestrear() {
  while :; do
    docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' "${VIGILADOS[@]}" 2>/dev/null |
      awk '{print $1, $2}' >> "$MUESTRAS"
    sleep 2
  done
}

resumen_memoria() {
  local titulo="$1"
  printf '\n  %s\n' "$titulo"
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' "${VIGILADOS[@]}" 2>/dev/null |
    awk '{printf "    %-28s %s\n", $1, $2}'
}

resumen_memoria "MEMORIA EN REPOSO (antes)"
docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' "${VIGILADOS[@]}" 2>/dev/null |
  awk '{print $1, $2}' > "${MUESTRAS}.antes"

log "Lanzando ${TOTAL_LLAMADAS} turnos con ${CONCURRENCIA} en paralelo…"
muestrear &
MUESTREADOR=$!

set +e
RESULTADO="$(python3 "$MOTOR" "$URL" "$CONCURRENCIA" "$RONDAS" "$MENSAJE" "$TIMEOUT" "$ETIQUETA")"
CODIGO=$?
set -e

kill "$MUESTREADOR" 2>/dev/null || true
wait "$MUESTREADOR" 2>/dev/null || true

[[ $CODIGO -eq 0 ]] || fail "El motor de carga falló con código ${CODIGO}."

printf '\n  RESULTADO DE LAS PETICIONES\n'
python3 - "$RESULTADO" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
print(f"    peticiones correctas  {d['peticiones_ok']}")
print(f"    errores               {d['errores']}" +
      (f"  {d['detalle_errores']}" if d['errores'] else ""))
print(f"    duración total        {d['segundos_total']} s")
print(f"    latencia p50 / p95    {d['p50']} s / {d['p95']} s   (máx {d['max']} s)")
PY

printf '\n  PICO DE MEMORIA DURANTE LA CARGA\n'
awk '{ if ($2 > pico[$1]) pico[$1] = $2 } END { for (c in pico) printf "    %-28s %s\n", c, pico[c] }' \
  "$MUESTRAS" | sort

# El número que importa: pasada la carga, ¿vuelve? Y sobre todo: CUÁNDO.
#
# La primera versión miraba una sola vez a los 60 s y eso engaña. En la tanda del
# 18/sep la tercera pasada arrancó en 428 MiB cuando la segunda había "acabado"
# en 645: n8n había devuelto 217 MiB en los minutos intermedios. Con una única
# muestra a los 60 s se habría concluido que hay fuga donde solo hay un GC que no
# tiene prisa en devolver al SO. Por eso ahora se mira varias veces.
for ESPERA in 30 60 120 180; do
  sleep 30
  resumen_memoria "MEMORIA A LOS ${ESPERA} s"
done

printf '\n  QUÉ MIRAR\n'
printf '    La CURVA de las cuatro muestras, no una sola: n8n tarda minutos en\n'
printf '    devolver memoria al SO. Si a los 180 s sigue bajando, espera más antes\n'
printf '    de concluir nada.\n'
printf '    Lo medido el 18/sep/2026 en demo: n8n = ~430 MiB en reposo + unos\n'
printf '    12 MiB por conversación simultánea. 40 a la vez -> 942 MiB de pico,\n'
printf '    sin un solo error y sin tocar el límite de conexiones de Postgres.\n'

cat <<LIMPIEZA

  LIMPIAR LAS SESIONES DE PRUEBA

    docker exec aegora-postgres psql -U postgres -d directus_${TENANT_ID} \\
      -c "delete from conversation_sessions where session_key like 'webchat:${ETIQUETA}-%'"

LIMPIEZA
