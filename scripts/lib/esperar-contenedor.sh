#!/usr/bin/env bash
# =============================================================================
# esperar-contenedor.sh — la ÚNICA forma de esperar a Directus / n8n / booking.
#
#   source "<raíz>/scripts/lib/esperar-contenedor.sh"
#   esperar_healthy     CONTENEDOR [TIMEOUT_S]   # antes de hablar con él
#   reiniciar_y_esperar CONTENEDOR [TIMEOUT_S]   # docker restart + esperar
#
# Por qué existe (25/sep/2026): cada script traía su propia espera y medían cosas
# distintas. Unos sondeaban /server/ping, otros exigían `healthy` de Docker SIN
# esperar, y el siguiente de la cadena abortaba con "Directus no está healthy:
# starting" teniendo delante un Directus que ya respondía. Son dos relojes: la API
# contesta a los ~24 s de un reinicio, pero el healthcheck de Docker solo pasa a
# `healthy` en su siguiente sondeo (cada 15 s en las plantillas). Quien mire el
# primero y el siguiente mire el segundo se cruzan justo en ese hueco.
#
# Así que se espera SIEMPRE a lo mismo -- `running` + `healthy` de Docker, lo más
# estricto de los dos -- y en un solo sitio:
#   - `starting`, `restarting` y hasta `unhealthy` son de paso: se sigue esperando.
#     Un `unhealthy` justo tras un arranque lento no es definitivo, y abortar ahí
#     es exactamente el fallo que esto viene a quitar.
#   - `exited`, `dead` o que el contenedor no exista SÍ son definitivos: se para.
#   - Sin healthcheck definido basta con `running` (no es el caso de los nuestros).
#
# Nunca `sleep N` a ciegas: falla en cuanto el servicio tarda N+1.
# =============================================================================

_esperar_log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

_esperar_fallo() {
  _esperar_log "ERROR: $*" >&2
  exit 1
}

esperar_healthy() {
  local contenedor="$1"
  local timeout="${2:-${ESPERA_HEALTHY_TIMEOUT:-240}}"
  local inicio=$SECONDS
  local estado salud anterior=""

  [[ -n "$contenedor" ]] || _esperar_fallo "esperar_healthy: falta el contenedor."

  while :; do
    estado="$(docker inspect --format '{{.State.Status}}' "$contenedor" 2>/dev/null || echo ausente)"
    salud="$(docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}sin-healthcheck{{end}}' \
      "$contenedor" 2>/dev/null || echo ausente)"

    if [[ "$estado" == "running" && ( "$salud" == "healthy" || "$salud" == "sin-healthcheck" ) ]]; then
      (( SECONDS - inicio > 0 )) && _esperar_log "${contenedor}: healthy tras $((SECONDS - inicio))s."
      return 0
    fi

    case "$estado" in
      exited|dead|ausente)
        _esperar_fallo "${contenedor}: status=${estado}. Revisa: docker logs --tail 50 ${contenedor}"
        ;;
    esac

    if (( SECONDS - inicio >= timeout )); then
      _esperar_fallo "Timeout (${timeout}s) esperando a ${contenedor}: status=${estado}, health=${salud}. Revisa: docker logs --tail 50 ${contenedor}"
    fi

    # Una línea por cambio de estado, no una cada 3 s.
    if [[ "${estado}/${salud}" != "$anterior" ]]; then
      _esperar_log "Esperando a ${contenedor}: status=${estado}, health=${salud}…"
      anterior="${estado}/${salud}"
    fi
    sleep 3
  done
}

reiniciar_y_esperar() {
  local contenedor="$1"
  _esperar_log "Reiniciando ${contenedor}…"
  docker restart "$contenedor" >/dev/null || _esperar_fallo "No se pudo reiniciar ${contenedor}."
  esperar_healthy "$contenedor" "${2:-}"
}
