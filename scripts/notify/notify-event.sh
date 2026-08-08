#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Configuración
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly EVENTS_FILE="${PLATFORM_ROOT}/scripts/notify/events.json"
readonly SEND_SCRIPT="${PLATFORM_ROOT}/scripts/notify/send-notification.sh"

TENANT="${TENANT:-aegora}"

EVENT=""
SUMMARY=""
DETAILS=""
SOURCE=""
RESOURCE=""
EVENT_ID=""
CLICK_URL=""

declare -a FIELDS=()

# =============================================================================
# Utilidades
# =============================================================================

log() {
  printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Uso:

  notify-event.sh \
    --event EVENT_TYPE \
    [--tenant TENANT] \
    [--summary "Resumen"] \
    [--details "Detalle"] \
    [--source COMPONENTE] \
    [--resource RECURSO] \
    [--event-id ID] \
    [--field clave=valor] \
    [--click-url URL]

Ejemplo:

  notify-event.sh \
    --event BACKUP_FAILED \
    --tenant aegora \
    --source backup \
    --summary "El backup diario ha fallado" \
    --field exit_code=1 \
    --field duration="42s"

El evento determina:

  - severidad;
  - título;
  - tags;
  - audiencia lógica.

El transporte se delega a send-notification.sh.
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

# =============================================================================
# Argumentos
# =============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --event)
      [[ $# -ge 2 ]] || fail "Falta valor para --event"
      EVENT="$2"
      shift 2
      ;;

    --tenant)
      [[ $# -ge 2 ]] || fail "Falta valor para --tenant"
      TENANT="$2"
      shift 2
      ;;

    --summary)
      [[ $# -ge 2 ]] || fail "Falta valor para --summary"
      SUMMARY="$2"
      shift 2
      ;;

    --details)
      [[ $# -ge 2 ]] || fail "Falta valor para --details"
      DETAILS="$2"
      shift 2
      ;;

    --source)
      [[ $# -ge 2 ]] || fail "Falta valor para --source"
      SOURCE="$2"
      shift 2
      ;;

    --resource)
      [[ $# -ge 2 ]] || fail "Falta valor para --resource"
      RESOURCE="$2"
      shift 2
      ;;

    --event-id)
      [[ $# -ge 2 ]] || fail "Falta valor para --event-id"
      EVENT_ID="$2"
      shift 2
      ;;

    --field)
      [[ $# -ge 2 ]] || fail "Falta valor para --field"

      [[ "$2" == *=* ]] ||
        fail "--field debe tener formato clave=valor"

      FIELDS+=("$2")
      shift 2
      ;;

    --click-url)
      [[ $# -ge 2 ]] || fail "Falta valor para --click-url"
      CLICK_URL="$2"
      shift 2
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

[[ -n "$EVENT" ]] ||
  fail "Debes indicar --event."

[[ "$EVENT" =~ ^[A-Z][A-Z0-9_]*$ ]] ||
  fail "Formato de evento inválido: ${EVENT}"

[[ "$TENANT" =~ ^[a-zA-Z0-9_-]+$ ]] ||
  fail "Tenant inválido: ${TENANT}"

if [[ -n "$EVENT_ID" ]]; then
  [[ "$EVENT_ID" =~ ^[a-zA-Z0-9_.:-]+$ ]] ||
    fail "Event ID inválido: ${EVENT_ID}"
fi

require_command python3
require_command hostname
require_command date

require_file "$EVENTS_FILE"
require_file "$SEND_SCRIPT"

# =============================================================================
# Cargar definición del evento
# =============================================================================

event_data="$(
  python3 - "$EVENTS_FILE" "$EVENT" <<'PY'
import json
import sys

path = sys.argv[1]
event_name = sys.argv[2]

with open(path, "r", encoding="utf-8") as handle:
    config = json.load(handle)

if config.get("version") != 1:
    raise SystemExit(
        "Versión de events.json no soportada"
    )

events = config.get("events")

if not isinstance(events, dict):
    raise SystemExit(
        "events.json no contiene un catálogo válido"
    )

event = events.get(event_name)

if event is None:
    raise SystemExit(
        f"Evento desconocido: {event_name}"
    )

required = (
    "severity",
    "title",
    "tags",
    "audience",
)

for key in required:
    value = event.get(key)

    if not isinstance(value, str) or not value.strip():
        raise SystemExit(
            f"Evento {event_name}: falta el campo {key}"
        )

if event["severity"] not in {
    "info",
    "success",
    "warning",
    "error",
    "critical",
}:
    raise SystemExit(
        f"Evento {event_name}: severity no válida"
    )

if event["audience"] not in {
    "operations",
    "client",
    "internal",
}:
    raise SystemExit(
        f"Evento {event_name}: audience no válida"
    )

print(event["severity"])
print(event["title"])
print(event["tags"])
print(event["audience"])
PY
)" || fail "No se pudo cargar el evento '${EVENT}'."

mapfile -t event_fields <<< "$event_data"

SEVERITY="${event_fields[0]:-}"
BASE_TITLE="${event_fields[1]:-}"
TAGS="${event_fields[2]:-}"
AUDIENCE="${event_fields[3]:-}"

[[ -n "$SEVERITY" ]] ||
  fail "El evento no define severity."

[[ -n "$BASE_TITLE" ]] ||
  fail "El evento no define title."

[[ -n "$TAGS" ]] ||
  fail "El evento no define tags."

[[ -n "$AUDIENCE" ]] ||
  fail "El evento no define audience."

# =============================================================================
# Contexto
# =============================================================================

hostname_value="$(
  hostname --fqdn 2>/dev/null ||
  hostname
)"

timestamp="$(
  date --iso-8601=seconds
)"

if [[ -z "$EVENT_ID" ]]; then
  EVENT_ID="$(
    python3 - <<'PY'
import secrets

print(secrets.token_hex(8))
PY
  )"
fi

# =============================================================================
# Construcción del mensaje
# =============================================================================

TITLE="Aegora · ${BASE_TITLE}"

message_lines=(
  "Evento: ${EVENT}"
  "Tenant: ${TENANT}"
  "Estado: ${SEVERITY^^}"
)

if [[ -n "$SUMMARY" ]]; then
  message_lines+=(
    "Resumen: ${SUMMARY}"
  )
fi

if [[ -n "$SOURCE" ]]; then
  message_lines+=(
    "Origen: ${SOURCE}"
  )
fi

if [[ -n "$RESOURCE" ]]; then
  message_lines+=(
    "Recurso: ${RESOURCE}"
  )
fi

message_lines+=(
  "Host: ${hostname_value}"
  "Fecha: ${timestamp}"
  "Event ID: ${EVENT_ID}"
)

# =============================================================================
# Campos estructurados adicionales
# =============================================================================

if [[ ${#FIELDS[@]} -gt 0 ]]; then
  message_lines+=("")
  message_lines+=("Datos:")

  for field in "${FIELDS[@]}"; do
    key="${field%%=*}"
    value="${field#*=}"

    [[ "$key" =~ ^[a-zA-Z][a-zA-Z0-9_.-]*$ ]] ||
      fail "Clave de campo inválida: ${key}"

    message_lines+=(
      "- ${key}: ${value}"
    )
  done
fi

# =============================================================================
# Detalle libre
# =============================================================================

if [[ -n "$DETAILS" ]]; then
  message_lines+=("")
  message_lines+=("Detalle:")
  message_lines+=("$DETAILS")
fi

MESSAGE="$(
  printf '%s\n' "${message_lines[@]}"
)"

# =============================================================================
# Envío
# =============================================================================

send_args=(
  /usr/bin/bash
  "$SEND_SCRIPT"
  --title "$TITLE"
  --message "$MESSAGE"
  --severity "$SEVERITY"
  --tags "$TAGS"
)

if [[ -n "$CLICK_URL" ]]; then
  send_args+=(
    --click-url "$CLICK_URL"
  )
fi

"${send_args[@]}"

log "Evento '${EVENT}' enviado."
log "Audiencia lógica: ${AUDIENCE}"
log "Event ID: ${EVENT_ID}"
