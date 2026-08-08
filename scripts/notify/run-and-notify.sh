#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# Configuración
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly NOTIFY_EVENT_SCRIPT="${PLATFORM_ROOT}/scripts/notify/notify-event.sh"

TENANT="${TENANT:-aegora}"

TASK=""
NOTIFY_SUCCESS=false

declare -a COMMAND=()

STARTED_AT_EPOCH=""
STARTED_AT_ISO=""

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

  run-and-notify.sh \
    --task backup|prune|restore-test|health \
    [--notify-success] \
    -- COMANDO [ARGUMENTOS...]

Comportamiento:

  - ejecuta el comando indicado;
  - conserva su exit code;
  - genera un evento tipificado;
  - notifica siempre los fallos;
  - solo notifica éxitos con --notify-success;
  - si falla el Notification Center, no altera el resultado
    de la tarea principal.

Eventos:

  backup:
    success -> BACKUP_SUCCESS
    failure -> BACKUP_FAILED

  prune:
    success -> PRUNE_SUCCESS
    failure -> PRUNE_FAILED

  restore-test:
    success -> RESTORE_TEST_SUCCESS
    failure -> RESTORE_TEST_FAILED

  health:
    success -> BACKUP_HEALTHY
    failure -> BACKUP_UNHEALTHY
EOF
}

require_file() {
  [[ -f "$1" ]] ||
    fail "Falta el fichero requerido: $1"
}

format_duration() {
  local total_seconds="$1"

  local hours=$((total_seconds / 3600))
  local minutes=$(((total_seconds % 3600) / 60))
  local seconds=$((total_seconds % 60))

  if (( hours > 0 )); then
    printf '%dh %dm %ds' \
      "$hours" \
      "$minutes" \
      "$seconds"
  elif (( minutes > 0 )); then
    printf '%dm %ds' \
      "$minutes" \
      "$seconds"
  else
    printf '%ds' "$seconds"
  fi
}

success_event_for_task() {
  case "$1" in
    backup)
      printf 'BACKUP_SUCCESS'
      ;;
    prune)
      printf 'PRUNE_SUCCESS'
      ;;
    restore-test)
      printf 'RESTORE_TEST_SUCCESS'
      ;;
    health)
      printf 'BACKUP_HEALTHY'
      ;;
    *)
      return 1
      ;;
  esac
}

failure_event_for_task() {
  case "$1" in
    backup)
      printf 'BACKUP_FAILED'
      ;;
    prune)
      printf 'PRUNE_FAILED'
      ;;
    restore-test)
      printf 'RESTORE_TEST_FAILED'
      ;;
    health)
      printf 'BACKUP_UNHEALTHY'
      ;;
    *)
      return 1
      ;;
  esac
}

source_for_task() {
  case "$1" in
    backup)
      printf 'backup'
      ;;
    prune)
      printf 'backup-retention'
      ;;
    restore-test)
      printf 'restore-test'
      ;;
    health)
      printf 'backup-health'
      ;;
    *)
      return 1
      ;;
  esac
}

summary_for_success() {
  case "$1" in
    backup)
      printf 'Backup completado correctamente'
      ;;
    prune)
      printf 'Política de retención completada correctamente'
      ;;
    restore-test)
      printf 'Restore test completado correctamente'
      ;;
    health)
      printf 'Sistema de backups saludable'
      ;;
    *)
      return 1
      ;;
  esac
}

summary_for_failure() {
  case "$1" in
    backup)
      printf 'El backup ha fallado'
      ;;
    prune)
      printf 'La retención de backups ha fallado'
      ;;
    restore-test)
      printf 'El restore test ha fallado'
      ;;
    health)
      printf 'El sistema de backups no está saludable'
      ;;
    *)
      return 1
      ;;
  esac
}

notify_event_safely() {
  local event="$1"
  local summary="$2"
  local source="$3"
  local status="$4"
  local duration="$5"
  local started_at="$6"
  local finished_at="$7"

  if [[ ! -f "$NOTIFY_EVENT_SCRIPT" ]]; then
    log "AVISO: Notification Center no disponible: ${NOTIFY_EVENT_SCRIPT}"
    return 0
  fi

  local -a args=(
    /usr/bin/bash
    "$NOTIFY_EVENT_SCRIPT"
    --event "$event"
    --tenant "$TENANT"
    --source "$source"
    --summary "$summary"
    --field "exit_code=${status}"
    --field "duration=${duration}"
    --field "started_at=${started_at}"
    --field "finished_at=${finished_at}"
  )

  if ! "${args[@]}"; then
    log "AVISO: falló el envío del evento '${event}'." >&2
  fi

  return 0
}

# =============================================================================
# Argumentos
# =============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)
      [[ $# -ge 2 ]] ||
        fail "Falta valor para --task"

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

[[ "$TENANT" =~ ^[a-zA-Z0-9_-]+$ ]] ||
  fail "Tenant inválido: ${TENANT}"

require_file "$NOTIFY_EVENT_SCRIPT"

# =============================================================================
# Ejecución
# =============================================================================

STARTED_AT_EPOCH="$(date +%s)"
STARTED_AT_ISO="$(date --iso-8601=seconds)"

log "Ejecutando tarea '${TASK}' para tenant '${TENANT}'."

set +e
"${COMMAND[@]}"
command_status=$?
set -e

finished_at_epoch="$(date +%s)"
finished_at_iso="$(date --iso-8601=seconds)"

duration_seconds=$(
  (
    finished_at_epoch - STARTED_AT_EPOCH
  )
)

duration="$(
  format_duration "$duration_seconds"
)"

source="$(
  source_for_task "$TASK"
)"

# =============================================================================
# Éxito
# =============================================================================

if [[ $command_status -eq 0 ]]; then
  log "Tarea '${TASK}' finalizada correctamente."

  if [[ "$NOTIFY_SUCCESS" == true ]]; then
    event="$(
      success_event_for_task "$TASK"
    )"

    summary="$(
      summary_for_success "$TASK"
    )"

    notify_event_safely \
      "$event" \
      "$summary" \
      "$source" \
      "$command_status" \
      "$duration" \
      "$STARTED_AT_ISO" \
      "$finished_at_iso"
  fi

  exit 0
fi

# =============================================================================
# Fallo
# =============================================================================

log "ERROR: la tarea '${TASK}' terminó con código ${command_status}." >&2

event="$(
  failure_event_for_task "$TASK"
)"

summary="$(
  summary_for_failure "$TASK"
)"

notify_event_safely \
  "$event" \
  "$summary" \
  "$source" \
  "$command_status" \
  "$duration" \
  "$STARTED_AT_ISO" \
  "$finished_at_iso"

exit "$command_status"
