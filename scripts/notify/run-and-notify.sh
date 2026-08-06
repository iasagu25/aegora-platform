#!/usr/bin/env bash

set -uo pipefail
IFS=$'\n\t'

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly NOTIFY_SCRIPT="${PLATFORM_ROOT}/scripts/notify/send-notification.sh"

TENANT="${TENANT:-aegora}"
TASK=""
NOTIFY_SUCCESS=false
COMMAND=()

STARTED_AT_EPOCH=""
STARTED_AT_ISO=""

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

  run-and-notify.sh \
    --task backup|prune|restore-test|health \
    [--notify-success] \
    -- COMANDO [ARGUMENTOS...]

Comportamiento:

  - ejecuta el comando indicado;
  - conserva su código de salida;
  - notifica siempre los fallos;
  - solo notifica éxitos con --notify-success;
  - nunca convierte un fallo del comando en éxito;
  - un fallo del canal de notificación no oculta el resultado del comando.
EOF
}

format_duration() {
  local total_seconds="$1"

  local hours=$((total_seconds / 3600))
  local minutes=$(((total_seconds % 3600) / 60))
  local seconds=$((total_seconds % 60))

  if (( hours > 0 )); then
    printf '%dh %dm %ds' "$hours" "$minutes" "$seconds"
  elif (( minutes > 0 )); then
    printf '%dm %ds' "$minutes" "$seconds"
  else
    printf '%ds' "$seconds"
  fi
}

task_label() {
  case "$1" in
    backup)
      printf 'Backup'
      ;;
    prune)
      printf 'Retención'
      ;;
    restore-test)
      printf 'Restore test'
      ;;
    health)
      printf 'Backup health'
      ;;
    *)
      return 1
      ;;
  esac
}

success_tags() {
  case "$1" in
    backup)
      printf 'white_check_mark,floppy_disk'
      ;;
    prune)
      printf 'white_check_mark,wastebasket'
      ;;
    restore-test)
      printf 'white_check_mark,test_tube'
      ;;
    health)
      printf 'white_check_mark,shield'
      ;;
  esac
}

failure_tags() {
  case "$1" in
    backup)
      printf 'rotating_light,floppy_disk'
      ;;
    prune)
      printf 'rotating_light,wastebasket'
      ;;
    restore-test)
      printf 'rotating_light,test_tube'
      ;;
    health)
      printf 'rotating_light,shield'
      ;;
  esac
}

send_notification_safely() {
  local title="$1"
  local message="$2"
  local severity="$3"
  local tags="$4"

  if [[ ! -f "$NOTIFY_SCRIPT" ]]; then
    log "AVISO: no existe el emisor de notificaciones: ${NOTIFY_SCRIPT}"
    return 0
  fi

  if ! /usr/bin/bash "$NOTIFY_SCRIPT" \
    --title "$title" \
    --message "$message" \
    --severity "$severity" \
    --tags "$tags"; then

    log "AVISO: falló el envío de la notificación." >&2
  fi

  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)
      [[ $# -ge 2 ]] || fail "Falta valor para --task"
      TASK="$2"
      shift 2
      ;;

    --notify-success)
      NOTIFY_SUCCESS=true
      shift
      ;;

    --)
      shift
      COMMAND=("$@")
      break
      ;;

    --help|-h)
      usage
      exit 0
      ;;

    *)
      fail "Opción desconocida antes de --: $1"
      ;;
  esac
done

case "$TASK" in
  backup|prune|restore-test|health)
    ;;
  *)
    fail "Tarea no válida: ${TASK}"
    ;;
esac

[[ ${#COMMAND[@]} -gt 0 ]] ||
  fail "No se ha proporcionado ningún comando."

label="$(task_label "$TASK")"
hostname_value="$(hostname --fqdn 2>/dev/null || hostname)"

STARTED_AT_EPOCH="$(date +%s)"
STARTED_AT_ISO="$(date --iso-8601=seconds)"

log "Ejecutando tarea '${TASK}' para tenant '${TENANT}'."

set +e
"${COMMAND[@]}"
command_status=$?
set -e

finished_at_epoch="$(date +%s)"
finished_at_iso="$(date --iso-8601=seconds)"
duration_seconds=$((finished_at_epoch - STARTED_AT_EPOCH))
duration="$(format_duration "$duration_seconds")"

if [[ $command_status -eq 0 ]]; then
  log "Tarea '${TASK}' finalizada correctamente."

  if [[ "$NOTIFY_SUCCESS" == true ]]; then
    title="Aegora · ${label} OK"

    message="$(
      cat <<EOF
Tenant: ${TENANT}
Host: ${hostname_value}
Estado: HEALTHY
Inicio: ${STARTED_AT_ISO}
Fin: ${finished_at_iso}
Duración: ${duration}
EOF
    )"

    send_notification_safely \
      "$title" \
      "$message" \
      success \
      "$(success_tags "$TASK")"
  fi

  exit 0
fi

log "ERROR: la tarea '${TASK}' terminó con código ${command_status}." >&2

title="Aegora · ${label} FAILED"

message="$(
  cat <<EOF
Tenant: ${TENANT}
Host: ${hostname_value}
Estado: FAILED
Código de salida: ${command_status}
Inicio: ${STARTED_AT_ISO}
Fin: ${finished_at_iso}
Duración: ${duration}

Revisar:
journalctl -u aegora-${TASK}@${TENANT}.service
EOF
)"

send_notification_safely \
  "$title" \
  "$message" \
  critical \
  "$(failure_tags "$TASK")"

exit "$command_status"
