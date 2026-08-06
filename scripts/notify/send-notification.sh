#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly SECRETS_ROOT="/opt/aegora/secrets"
readonly NOTIFY_CONFIG="${SECRETS_ROOT}/notifications.env"

TITLE=""
MESSAGE=""
SEVERITY="info"
TAGS=""
CLICK_URL=""

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

  send-notification.sh \
    --title "Título" \
    --message "Mensaje" \
    [--severity info|success|warning|error|critical] \
    [--tags "tag1,tag2"] \
    [--click-url "https://..."]

El script devuelve:

  0  Notificación enviada o notificaciones desactivadas.
  1  Error de configuración o de envío.
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

sanitize_header() {
  printf '%s' "$1" |
    tr '\r\n' '  ' |
    cut -c1-200
}

priority_for_severity() {
  case "$1" in
    info)
      printf 'default'
      ;;
    success)
      printf 'default'
      ;;
    warning)
      printf 'high'
      ;;
    error)
      printf 'high'
      ;;
    critical)
      printf 'urgent'
      ;;
    *)
      return 1
      ;;
  esac
}

default_tags_for_severity() {
  case "$1" in
    info)
      printf 'information_source'
      ;;
    success)
      printf 'white_check_mark'
      ;;
    warning)
      printf 'warning'
      ;;
    error)
      printf 'x'
      ;;
    critical)
      printf 'rotating_light'
      ;;
    *)
      return 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      [[ $# -ge 2 ]] || fail "Falta valor para --title"
      TITLE="$2"
      shift 2
      ;;

    --message)
      [[ $# -ge 2 ]] || fail "Falta valor para --message"
      MESSAGE="$2"
      shift 2
      ;;

    --severity)
      [[ $# -ge 2 ]] || fail "Falta valor para --severity"
      SEVERITY="$2"
      shift 2
      ;;

    --tags)
      [[ $# -ge 2 ]] || fail "Falta valor para --tags"
      TAGS="$2"
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

[[ -n "$TITLE" ]] ||
  fail "El título no puede estar vacío."

[[ -n "$MESSAGE" ]] ||
  fail "El mensaje no puede estar vacío."

case "$SEVERITY" in
  info|success|warning|error|critical)
    ;;
  *)
    fail "Severidad no válida: ${SEVERITY}"
    ;;
esac

require_command curl
require_file "$NOTIFY_CONFIG"

set -a

# shellcheck disable=SC1090
source "$NOTIFY_CONFIG"

set +a

: "${NOTIFY_ENABLED:?Falta NOTIFY_ENABLED}"
: "${NOTIFY_PROVIDER:?Falta NOTIFY_PROVIDER}"

case "$NOTIFY_ENABLED" in
  true)
    ;;
  false)
    log "Notificaciones desactivadas; no se envía el mensaje."
    exit 0
    ;;
  *)
    fail "NOTIFY_ENABLED debe ser true o false."
    ;;
esac

[[ "$NOTIFY_PROVIDER" == "ntfy" ]] ||
  fail "Proveedor no soportado: ${NOTIFY_PROVIDER}"

: "${NTFY_SERVER:?Falta NTFY_SERVER}"
: "${NTFY_TOPIC:?Falta NTFY_TOPIC}"

NOTIFY_CONNECT_TIMEOUT_SECONDS="${
  NOTIFY_CONNECT_TIMEOUT_SECONDS:-10
}"

NOTIFY_MAX_TIME_SECONDS="${
  NOTIFY_MAX_TIME_SECONDS:-30
}"

[[ "$NOTIFY_CONNECT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  fail "NOTIFY_CONNECT_TIMEOUT_SECONDS debe ser un entero positivo."

[[ "$NOTIFY_MAX_TIME_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
  fail "NOTIFY_MAX_TIME_SECONDS debe ser un entero positivo."

TITLE="$(sanitize_header "$TITLE")"

priority="$(priority_for_severity "$SEVERITY")"

if [[ -z "$TAGS" ]]; then
  TAGS="$(default_tags_for_severity "$SEVERITY")"
fi

endpoint="${NTFY_SERVER%/}/${NTFY_TOPIC}"

curl_args=(
  --fail
  --silent
  --show-error
  --connect-timeout "$NOTIFY_CONNECT_TIMEOUT_SECONDS"
  --max-time "$NOTIFY_MAX_TIME_SECONDS"
  --request POST
  --header "Title: ${TITLE}"
  --header "Priority: ${priority}"
  --header "Tags: ${TAGS}"
  --data-binary "$MESSAGE"
)

if [[ -n "${NTFY_TOKEN:-}" ]]; then
  curl_args+=(
    --header "Authorization: Bearer ${NTFY_TOKEN}"
  )
fi

if [[ -n "$CLICK_URL" ]]; then
  curl_args+=(
    --header "Click: ${CLICK_URL}"
  )
fi

curl "${curl_args[@]}" "$endpoint" >/dev/null

log "Notificación enviada mediante ntfy."
