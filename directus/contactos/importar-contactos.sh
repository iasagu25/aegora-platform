#!/usr/bin/env bash

set -Eeuo pipefail

# Espera única a los contenedores (ver el fichero): nunca sleep ni un healthy exigido sin esperar.
# shellcheck source=/dev/null
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../scripts/lib/esperar-contenedor.sh"
IFS=$'\n\t'

# =============================================================================
# Aegora · importa una agenda de contactos (TSV/CSV) en el Directus de un tenant
#
#   importar-contactos.sh --tenant TENANT --fichero RUTA --origen "texto" [--apply]
#
# El fichero lo lee `leer-agenda.py` (reglas de nombres, teléfonos y repetidos, ahí).
# Aquí se decide contra lo que YA hay en el tenant:
#   - Un contacto con algún teléfono que ya está en `contact_phones` NO se crea: ya existe
#     (lo creó Lucía, el gestor o una pasada anterior). Tampoco se modifica.
#   - Uno sin teléfonos se da por existente si coincide nombre, apellidos, empresa y email.
# Así una segunda pasada no duplica nada, y se puede re-ejecutar tras corregir el fichero.
#
# NO borra ni modifica nada. Los datos NO pasan por Git: el fichero se deja en el VPS
# (permisos 600) solo mientras dura la importación.
# =============================================================================

readonly PLATFORM_ROOT="/opt/aegora/platform"
readonly TENANTS_ROOT="/opt/aegora/tenants"
readonly AQUI="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

TENANT=""
FICHERO=""
ORIGEN=""
APPLY=false

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso:
  importar-contactos.sh --tenant TENANT --fichero RUTA --origen "texto" [--apply]

  --origen   De dónde salen, para la nota de cada ficha ("la agenda de Arturo").

Sin --apply:  dice qué crearía, qué ya existe y qué problemas hay en el fichero.
Con --apply:  crea lo que falte. Nunca modifica ni borra.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)  [[ $# -ge 2 ]] || fail "Falta valor para --tenant.";  TENANT="$2"; shift 2 ;;
    --fichero) [[ $# -ge 2 ]] || fail "Falta valor para --fichero."; FICHERO="$2"; shift 2 ;;
    --origen)  [[ $# -ge 2 ]] || fail "Falta valor para --origen.";  ORIGEN="$2"; shift 2 ;;
    --apply)   APPLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Opción desconocida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ -n "$FICHERO" ]] || fail "Falta --fichero."
[[ -n "$ORIGEN" ]] || fail "Falta --origen (p. ej. \"la agenda de Arturo\")."
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"
[[ -r "$FICHERO" ]] || fail "No se puede leer ${FICHERO}"

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"
PROVISIONING_SECRET="${TENANT_ROOT}/secrets/directus-provisioning.env"

for f in "$TENANT_CONFIG" "$PROVISIONING_SECRET"; do
  if [[ ! -r "$f" ]]; then
    [[ $EUID -eq 0 ]] && fail "No existe ${f}"
    fail "No se puede leer ${f}
O no existe, o es cuestión de permisos (los secretos del tenant son de root).
Prueba con sudo."
  fi
done

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
# shellcheck disable=SC1090
source "$PROVISIONING_SECRET"
set +a

: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"
: "${DIRECTUS_PROVISIONING_TOKEN:?Falta DIRECTUS_PROVISIONING_TOKEN}"

# El fichero ya leído viaja por stdin, nunca por variable de entorno: son datos
# personales (no deben verse en `ps` ni en `docker inspect`) y pasan de los 128 KiB.
DATOS="$(mktemp)"
chmod 600 "$DATOS"
trap 'rm -f "$DATOS"' EXIT
python3 -I "${AQUI}/leer-agenda.py" "$FICHERO" "$ORIGEN" > "$DATOS"

esperar_healthy "$DIRECTUS_CONTAINER"

cat <<PLAN

============================================================
AEGORA · IMPORTAR CONTACTOS
============================================================

Tenant:   ${TENANT}   (${DIRECTUS_CONTAINER})
Fichero:  ${FICHERO}
Origen:   ${ORIGEN}
Modo:     $([[ "$APPLY" == true ]] && printf 'APPLY' || printf 'PLAN')

============================================================

PLAN

docker exec -i \
  -e AEGORA_APPLY="$APPLY" \
  -e DIRECTUS_PROVISIONING_TOKEN="$DIRECTUS_PROVISIONING_TOKEN" \
  "$DIRECTUS_CONTAINER" \
  node --input-type=module -e "$(cat <<'NODE'
const BASE = 'http://127.0.0.1:8055';
const token = process.env.DIRECTUS_PROVISIONING_TOKEN;
const aplicar = process.env.AEGORA_APPLY === 'true';

let entrada = '';
for await (const trozo of process.stdin) entrada += trozo;
const { contactos, problemas } = JSON.parse(entrada);

async function api(method, path, body) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      Accept: 'application/json',
      Authorization: `Bearer ${token}`,
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const texto = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${texto.slice(0, 300)}`);
  return texto ? JSON.parse(texto) : null;
}

// Lo que ya hay, de una vez: dos consultas en vez de una por fila.
const telefonosYa = new Set(
  ((await api('GET', '/items/contact_phones?fields=phone_normalized&limit=-1')).data || [])
    .map((t) => t.phone_normalized));
const clave = (c) => [c.first_name, c.last_name, c.company, c.email]
  .map((v) => String(v ?? '').trim().toLowerCase()).join('|');
const yaEnTenant = (await api('GET', '/items/contacts?fields=first_name,last_name,company,email&limit=-1')).data || [];
const contactosYa = new Set(yaEnTenant.map(clave));

const totalAntes = yaEnTenant.length;
let creados = 0, existentes = 0, sinTelefono = 0, telefonos = 0;
const fallos = [];

for (const c of contactos) {
  const ya = c.phones.length
    ? c.phones.some((t) => telefonosYa.has(t.phone_normalized))
    : contactosYa.has(clave(c));
  if (ya) { existentes += 1; continue; }

  if (aplicar) {
    try {
      await api('POST', '/items/contacts', {
        first_name: c.first_name,
        last_name: c.last_name,
        company: c.company,
        email: c.email,
        notes: c.notes,
        status: 'active',
        trato: 'normal',
        phones: c.phones,
      });
    } catch (e) {
      fallos.push(`línea ${c.linea}: ${e.message}`);
      continue;
    }
  }
  creados += 1;
  telefonos += c.phones.length;
  if (!c.phones.length) sinTelefono += 1;
  // Para que una fila repetida más abajo en el mismo fichero cuente como existente.
  c.phones.forEach((t) => telefonosYa.add(t.phone_normalized));
  contactosYa.add(clave(c));
}

const porTipo = {};
for (const p of problemas) (porTipo[p.tipo] ||= []).push(p);
const TITULOS = {
  sin_nombre: 'Filas SIN NOMBRE (no se importan; si interesan, ponles nombre y vuelve a pasar)',
  telefono_repetido: 'Teléfonos REPETIDOS (el número se queda en la primera ficha; la otra lleva una nota)',
  telefono_no_valido: 'Teléfonos que no se pudieron leer (van a las notas de la ficha)',
  email_no_valido: 'Emails sin formato de email (van a las notas de la ficha)',
};

console.log(`Contactos en el tenant antes:   ${totalAntes}`);
console.log(`Filas con contacto en el fichero: ${contactos.length}`);
console.log(`  ya existían (no se tocan):     ${existentes}`);
console.log(`  ${aplicar ? 'creados' : 'por crear'}:${' '.repeat(aplicar ? 23 : 21)}${creados}  (${telefonos} teléfonos; ${sinTelefono} sin teléfono)`);
if (fallos.length) {
  console.log(`\nFALLOS (${fallos.length}) -- no se crearon, el resto sí:`);
  fallos.forEach((f) => console.log(`  ${f}`));
}
for (const [tipo, lista] of Object.entries(porTipo)) {
  console.log(`\n${TITULOS[tipo] || tipo}: ${lista.length}`);
  lista.forEach((p) => console.log(`  línea ${p.linea}: ${p.detalle}`));
}
if (fallos.length) process.exitCode = 1;
NODE
)" < "$DATOS"

printf '\n'
if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha creado nada. Añade --apply para importar."
else
  log "Importado. Borra el fichero de la agenda del VPS si ya no lo necesitas: son datos personales."
fi
