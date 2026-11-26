#!/usr/bin/env bash
# =============================================================================
# registrar-despliegue.sh — apunta en el tenant qué se le ha aplicado y desde qué versión.
#
#   source "<raíz>/scripts/lib/registrar-despliegue.sh"
#   registrar_despliegue TENANT COMPONENTE [PARCIAL] [DETALLE]
#
# Lo llama cada script que modifica un tenant, al terminar BIEN su --apply (nunca en
# PLAN). Añade una línea a /opt/aegora/tenants/<tenant>/state/despliegues.jsonl:
#
#   {"fecha": "...", "componente": "workflows", "release": "v2026.11.26",
#    "commit": "f67591d0a1b2", "sucio": false, "parcial": null,
#    "detalle": null, "usuario": "aegora"}
#
# - `release` es el tag `v*` en el que está el checkout, o null si no está en ninguno
#   (lo normal al iterar en `dev`). Con cambios sin commitear en ficheros versionados va
#   `sucio: true` y `release: null`: eso ya no es el release, aunque el tag apunte ahí.
# - `parcial` guarda lo que acotó la pasada (p. ej. el `--only` de render-workflows). Un
#   parcial NO cuenta como versión de la capa: lo pinta aparte `scripts/aegora-estado.sh`.
# - `detalle` es libre (p. ej. la versión de aegora-booking desplegada).
#
# El registro es solo de añadir: nunca se reescribe ni se borra una línea. No contiene
# secretos, así que el directorio queda legible para que aegora-estado.sh funcione sin
# sudo.
#
# NUNCA hace fallar a quien lo llama: el despliegue ya está hecho cuando se llega aquí,
# y abortar por no poder escribir el registro sería peor que no tenerlo. Si falla, lo
# dice en voz alta.
#
# Por qué existe y cómo se lee: docs/VERSIONADO.md.
# =============================================================================

_REGISTRO_RAIZ_PLATAFORMA="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

_registro_aviso() {
  printf '[%s] AVISO: %s\n' "$(date --iso-8601=seconds)" "$*" >&2
}

# git como root sobre un checkout de `aegora` da "dubious ownership" y no contesta nada.
# Nunca devuelve error: un fallo es una salida vacía. Así no dispara la trampa ERR que
# llevan varios scripts (heredada por `set -E` también dentro de un $(...)).
_registro_git() {
  git -c safe.directory='*' -C "$_REGISTRO_RAIZ_PLATAFORMA" "$@" 2>/dev/null || true
}

registrar_despliegue() {
  local tenant="${1:-}" componente="${2:-}" parcial="${3:-}" detalle="${4:-}"
  local raiz_tenants="${AEGORA_TENANTS_ROOT:-/opt/aegora/tenants}"
  local dir_estado="${raiz_tenants}/${tenant}/state"
  local fichero="${dir_estado}/despliegues.jsonl"
  local release="" commit="" sucio="false" usuario="${SUDO_USER:-${USER:-desconocido}}"

  if [[ -z "$tenant" || -z "$componente" ]]; then
    _registro_aviso "registrar_despliegue sin tenant o componente: no se registra nada."
    return 0
  fi
  if [[ ! -d "${raiz_tenants}/${tenant}" ]]; then
    _registro_aviso "No existe ${raiz_tenants}/${tenant}: el despliegue de '${componente}' no queda registrado."
    return 0
  fi

  commit="$(_registro_git rev-parse --short=12 HEAD)"
  release="$(_registro_git describe --tags --exact-match --match 'v*' HEAD)"
  if [[ -n "$(_registro_git status --porcelain --untracked-files=no)" ]]; then
    sucio="true"
    release=""
  fi

  if ! mkdir -p "$dir_estado" 2>/dev/null; then
    _registro_aviso "No se puede crear ${dir_estado}: el despliegue de '${componente}' NO queda registrado."
    return 0
  fi
  chmod 755 "$dir_estado" 2>/dev/null || true

  if ! python3 - "$fichero" "$componente" "$release" "$commit" "$sucio" "$parcial" "$detalle" "$usuario" <<'PY'
import json, sys, datetime
fichero, componente, release, commit, sucio, parcial, detalle, usuario = sys.argv[1:9]
linea = {
    "fecha": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "componente": componente,
    "release": release or None,
    "commit": commit or None,
    "sucio": sucio == "true",
    "parcial": parcial or None,
    "detalle": detalle or None,
    "usuario": usuario,
}
with open(fichero, "a", encoding="utf-8") as f:
    f.write(json.dumps(linea, ensure_ascii=False) + "\n")
PY
  then
    _registro_aviso "No se pudo escribir ${fichero}: el despliegue de '${componente}' NO queda registrado."
    return 0
  fi
  chmod 644 "$fichero" 2>/dev/null || true

  local version="${release:-${commit:-?}}"
  if [[ "$sucio" == "true" ]]; then version="${version} (con cambios sin commitear)"; fi
  printf '[%s] Registrado en %s: %s = %s%s\n' "$(date --iso-8601=seconds)" "$tenant" "$componente" \
    "$version" "${parcial:+ (parcial: ${parcial})}"
  return 0
}
