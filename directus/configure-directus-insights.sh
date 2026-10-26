#!/usr/bin/env bash

set -Eeuo pipefail

# Espera única a los contenedores (ver el fichero): nunca sleep ni un healthy exigido sin esperar.
# shellcheck source=/dev/null
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../scripts/lib/esperar-contenedor.sh"
IFS=$'\n\t'

# =============================================================================
# Aegora · informe del gestor en Insights (el panel de "Resumen")
#
# Un dashboard de Insights con lo que hace Lucía (mensajes, conversaciones, citas
# reservadas, minutos al teléfono) y lo que tiene pendiente el despacho (tareas,
# vencidas, llamadas por devolver, hilos esperando a una persona, próximas citas).
#
# Los dashboards y sus paneles NO son esquema (no salen en base.yaml), así que van por
# API y hay que ejecutarlo por tenant, como los presets. El gestor los ve con SUS
# permisos: necesita `read` sobre directus_dashboards y directus_panels, que da
# configure-tenant-role.sh.
#
# Idempotente: el dashboard se encuentra por su nombre, y sus paneles se borran y se
# vuelven a crear enteros (un panel no tiene clave natural por la que reconocerlo).
# Cualquier cambio a mano en ESTE dashboard se pierde al volver a ejecutarlo; si alguien
# quiere otro informe, que cree un dashboard aparte.
#
# Sin --apply solo enseña el plan.
# =============================================================================

readonly TENANTS_ROOT="/opt/aegora/tenants"

TENANT=""
APPLY=false

log() { printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }


usage() {
  cat <<'EOF'
Uso:
  configure-directus-insights.sh --tenant TENANT [--apply]

Sin --apply:  muestra el plan.
Con --apply:  crea o rehace el dashboard "Resumen" y sus paneles.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant) [[ $# -ge 2 ]] || fail "Falta valor para --tenant."; TENANT="$2"; shift 2 ;;
    --apply)  APPLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Opción desconocida: $1" ;;
  esac
done

[[ -n "$TENANT" ]] || fail "Falta --tenant."
[[ "$TENANT" =~ ^[a-z][a-z0-9-]{2,30}$ ]] || fail "Tenant inválido: ${TENANT}"
command -v docker >/dev/null 2>&1 || fail "Falta docker."

TENANT_ROOT="${TENANTS_ROOT}/${TENANT}"
TENANT_CONFIG="${TENANT_ROOT}/config/tenant.env"
PROVISIONING_SECRET="${TENANT_ROOT}/secrets/directus-provisioning.env"

# Sin permiso para atravesar el directorio, "no existe" y "no puedo leerlo" son
# indistinguibles desde aquí -- y los secretos del tenant son de root. Así que se
# dicen las dos posibilidades en vez de mandar a buscar un fichero que sí está.
if [[ ! -r "$TENANT_CONFIG" ]]; then
  if [[ $EUID -eq 0 ]]; then
    fail "No existe ${TENANT_CONFIG}"
  fi
  fail "No se puede leer ${TENANT_CONFIG}
O no existe, o es cuestión de permisos (los secretos del tenant son de root).
Prueba con sudo."
fi
[[ -f "$PROVISIONING_SECRET" ]] ||
  fail "Falta la credencial técnica: ${PROVISIONING_SECRET}"

set -a
# shellcheck disable=SC1090
source "$TENANT_CONFIG"
# shellcheck disable=SC1090
source "$PROVISIONING_SECRET"
set +a

: "${TENANT_ID:?Falta TENANT_ID}"
: "${DIRECTUS_CONTAINER:?Falta DIRECTUS_CONTAINER}"
: "${DIRECTUS_PROVISIONING_TOKEN:?Falta DIRECTUS_PROVISIONING_TOKEN}"

[[ "$TENANT_ID" == "$TENANT" ]] ||
  fail "TENANT_ID (${TENANT_ID}) no coincide con --tenant (${TENANT})."

esperar_healthy "$DIRECTUS_CONTAINER"

cat <<EOF

============================================================
AEGORA · INFORME DEL GESTOR (Insights)
============================================================

Tenant:
  ${TENANT_ID}

Dashboard "Resumen", de arriba abajo:
  Lucía, últimos 30 días   mensajes respondidos · conversaciones · citas reservadas
                           · llamadas · minutos al teléfono
  Pendiente ahora          tareas pendientes · vencidas · llamadas por devolver
                           · hilos esperando a una persona · citas en 7 días
  Listas                   próximas citas · tareas pendientes
  Gráficas, 30 días        mensajes de Lucía por día · conversaciones por canal
                           · citas reservadas por Lucía por día · llamadas por día

Si el dashboard ya existe, sus paneles se rehacen enteros.

CSS del proyecto: un bloque marcado para que la leyenda de las gráficas siga el tema
(en modo oscuro no se veía). El resto del CSS propio, si lo hay, no se toca.

Modo:
  $([[ "$APPLY" == true ]] && echo apply || echo plan)

============================================================

EOF

if [[ "$APPLY" != true ]]; then
  log "PLAN ONLY. No se ha modificado nada."
  exit 0
fi

docker exec -i \
  -e DIRECTUS_PROVISIONING_TOKEN="$DIRECTUS_PROVISIONING_TOKEN" \
  "$DIRECTUS_CONTAINER" \
  node --input-type=module <<'NODE'
const BASE = 'http://127.0.0.1:8055';
const token = process.env.DIRECTUS_PROVISIONING_TOKEN;

const NOMBRE = 'Resumen';
const DIAS30 = '$NOW(-30 days)';
const AZUL = '#3399FF', VERDE = '#2ECDA7', MORADO = '#8866FF', NARANJA = '#FFA439', ROJO = '#E35169';
const ACTIVAS = { status: { _in: ['scheduled', 'confirmed'] } };
const DE_LUCIA = [{ direccion: { _eq: 'saliente' } }, { autor: { _eq: 'lucia' } }];
const y = (...c) => ({ _and: c });

// Un número grande, del color de su tema (azul conversaciones, verde citas, morado
// llamadas, naranja tareas). Con `alerta`, verde a cero y rojo en cuanto hay algo. En el
// panel de Directus gana la ÚLTIMA regla que cumple, por eso el rojo va detrás.
// Los nombres son cortos a propósito: el panel mide 12 de ancho y corta con "…" lo que no
// cabe junto al icono de la nota. El detalle va en la nota.
const metrica = (x, yy, name, icon, color, note, options, alerta = false) => ({
  type: 'metric', name, icon, color, note, show_header: true,
  position_x: x, position_y: yy, width: 12, height: 6,
  options: {
    function: 'count', field: 'id', numberStyle: 'decimal', notation: 'standard',
    maximumFractionDigits: 0, fontSize: 'auto', fontWeight: '800', textAlign: 'center',
    conditionalFormatting: alerta
      ? [{ operator: '>=', value: '0', color: VERDE }, { operator: '>', value: '0', color: ROJO }]
      : [{ operator: '>=', value: '0', color }],
    ...options,
  },
});

const serie = (x, yy, name, icon, color, collection, dateField, filter) => ({
  type: 'time-series', name, icon, color, show_header: true,
  position_x: x, position_y: yy, width: 30, height: 16,
  options: {
    collection, dateField, valueField: 'id', function: 'count', precision: 'day',
    range: '1 month', color, curveType: 'smooth', fillType: 'gradient', missingData: '0',
    decimals: 0, showXAxis: true, showYAxis: true, filter,
  },
});

const paneles = [
  // --- Lucía, últimos 30 días ------------------------------------------------
  metrica(1, 1, 'Mensajes de Lucía', 'chat', AZUL, 'Mensajes que ha respondido Lucía en los últimos 30 días, en todos los canales.',
    { collection: 'conversation_messages', filter: y(...DE_LUCIA, { created_at: { _gte: DIAS30 } }) }),
  metrica(13, 1, 'Conversaciones', 'forum', AZUL, 'Conversaciones con algún mensaje de un cliente en los últimos 30 días.',
    { collection: 'conversation_messages', function: 'countDistinct', field: 'session_id',
      filter: y({ direccion: { _eq: 'entrante' } }, { created_at: { _gte: DIAS30 } }) }),
  metrica(25, 1, 'Citas de Lucía', 'event_available', VERDE, 'Citas que ha reservado Lucía en los últimos 30 días, por WhatsApp, chat o teléfono.',
    { collection: 'appointments', filter: y({ source: { _eq: 'ai' } }, { created_at: { _gte: DIAS30 } }) }),
  metrica(37, 1, 'Llamadas', 'call', MORADO, 'Llamadas atendidas en los últimos 30 días.',
    { collection: 'call_notes', filter: { start_at: { _gte: DIAS30 } } }),
  metrica(49, 1, 'Minutos al teléfono', 'timer', MORADO, 'Minutos de llamada en los últimos 30 días. Cada llamada cuenta por minutos enteros, redondeando hacia arriba.',
    { collection: 'call_notes', function: 'sum', field: 'duracion_minutos', suffix: ' min',
      filter: { start_at: { _gte: DIAS30 } } }),

  // --- lo que está pendiente ahora --------------------------------------------
  metrica(1, 7, 'Tareas pendientes', 'task_alt', NARANJA, 'Tareas sin terminar, de todo el equipo.',
    { collection: 'tasks', filter: { status: { _eq: 'pending' } } }),
  metrica(13, 7, 'Tareas vencidas', 'alarm', NARANJA, 'Pendientes con la fecha límite ya pasada.',
    { collection: 'tasks', filter: y({ status: { _eq: 'pending' } }, { due_at: { _lt: '$NOW' } }) }, true),
  metrica(25, 7, 'Por devolver', 'phone_callback', MORADO, 'Llamadas marcadas con "requiere seguimiento": alguien tiene que devolverlas.',
    { collection: 'call_notes', filter: { requiere_seguimiento: { _eq: true } } }, true),
  metrica(37, 7, 'En manos del equipo', 'support_agent', AZUL, 'Conversaciones en modo humano: Lucía no contesta en ellas hasta que alguien las devuelva a automático.',
    { collection: 'conversation_sessions', filter: { modo: { _eq: 'humano' } } }, true),
  metrica(49, 7, 'Citas en 7 días', 'calendar_month', VERDE, 'Citas programadas o confirmadas desde ahora hasta dentro de 7 días.',
    { collection: 'appointments', filter: y(ACTIVAS, { start_at: { _gte: '$NOW' } }, { start_at: { _lte: '$NOW(+7 days)' } }) }),

  // --- listas -----------------------------------------------------------------
  { type: 'list', name: 'Próximas citas', icon: 'event', color: VERDE, show_header: true,
    position_x: 1, position_y: 13, width: 30, height: 14,
    options: { collection: 'appointments', limit: 10, sortField: 'start_at', sortDirection: 'asc',
      displayTemplate: '{{start_at}} · {{contact_id.first_name}} {{contact_id.last_name}} · {{service_id.name}}',
      linkToItem: true, filter: y(ACTIVAS, { start_at: { _gte: '$NOW' } }) } },
  { type: 'list', name: 'Tareas pendientes', icon: 'checklist', color: NARANJA, show_header: true,
    position_x: 31, position_y: 13, width: 30, height: 14,
    note: 'Ordenadas por fecha límite: las que vencen antes, arriba; las que no tienen plazo, al final.',
    options: { collection: 'tasks', limit: 10, sortField: 'due_at', sortDirection: 'asc',
      displayTemplate: '{{title}}', linkToItem: true, filter: { status: { _eq: 'pending' } } } },

  // --- gráficas, últimos 30 días ---------------------------------------------------
  serie(1, 27, 'Mensajes de Lucía por día', 'show_chart', AZUL, 'conversation_messages', 'created_at', y(...DE_LUCIA)),
  { type: 'pie-chart', name: 'Conversaciones por canal', icon: 'donut_large', color: AZUL, show_header: true,
    position_x: 31, position_y: 27, width: 30, height: 16,
    note: 'Mensajes de clientes en los últimos 30 días, por canal.',
    options: { collection: 'conversation_messages', column: 'canal', function: 'count', donut: true,
      showLabels: true, legend: 'right',
      conditionalFill: [
        { operator: '=', value: 'whatsapp', color: '#25D366' },
        { operator: '=', value: 'webchat', color: AZUL },
        { operator: '=', value: 'voz', color: MORADO },
      ],
      filter: y({ direccion: { _eq: 'entrante' } }, { created_at: { _gte: DIAS30 } }) } },
  serie(1, 43, 'Citas de Lucía por día', 'event_available', VERDE, 'appointments', 'created_at', { source: { _eq: 'ai' } }),
  serie(31, 43, 'Llamadas por día', 'call', MORADO, 'call_notes', 'start_at', null),
];

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
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
}

const dashboard = {
  name: NOMBRE, icon: 'insights', color: AZUL,
  note: 'Lo que ha hecho Lucía y lo que tiene pendiente el despacho. Lo mantiene Aegora: los cambios a mano en este informe se pierden.',
};
const filtro = encodeURIComponent(JSON.stringify({ name: { _eq: NOMBRE } }));
const existentes = (await api('GET', `/dashboards?filter=${filtro}&fields=id&limit=2`)).data ?? [];
if (existentes.length > 1) throw new Error(`Hay ${existentes.length} dashboards llamados "${NOMBRE}": deja uno.`);

let id;
if (existentes.length) {
  id = existentes[0].id;
  await api('PATCH', `/dashboards/${id}`, dashboard);
  const viejos = (await api('GET', `/panels?filter=${encodeURIComponent(JSON.stringify({ dashboard: { _eq: id } }))}&fields=id&limit=-1`)).data ?? [];
  if (viejos.length) await api('DELETE', '/panels', viejos.map(p => p.id));
  console.log(`Dashboard "${NOMBRE}" ya existía: ${viejos.length} paneles quitados.`);
} else {
  id = (await api('POST', '/dashboards', dashboard)).data.id;
  console.log(`Dashboard "${NOMBRE}" creado.`);
}

await api('POST', '/panels', paneles.map(p => ({ ...p, dashboard: id })));
console.log(`${paneles.length} paneles creados.`);

// La leyenda del donut sale en un gris fijo que la librería de gráficas (ApexCharts) pone
// en línea y que no sigue el tema: en modo oscuro casi no se ve. Se le da el color de texto
// del tema con el CSS propio del proyecto. Solo se toca NUESTRO bloque, entre marcas, para
// no pisar CSS que alguien haya puesto a mano en Ajustes.
const INI = '/* aegora-insights:inicio */', FIN = '/* aegora-insights:fin */';
const CSS = `${INI}
.apexcharts-legend-text { color: var(--theme--foreground) !important; }
${FIN}`;
const actual = ((await api('GET', '/settings?fields=custom_css')).data || {}).custom_css || '';
const sinBloque = actual.includes(INI) && actual.includes(FIN)
  ? (actual.slice(0, actual.indexOf(INI)) + actual.slice(actual.indexOf(FIN) + FIN.length)).trim()
  : actual.trim();
const nuevo = [sinBloque, CSS].filter(Boolean).join('\n\n');
if (nuevo !== actual) {
  await api('PATCH', '/settings', { custom_css: nuevo });
  console.log('CSS del proyecto: leyenda de las gráficas con el color del tema.');
} else {
  console.log('CSS del proyecto: ya estaba.');
}
NODE

cat <<EOF

============================================================
HECHO
============================================================

Para comprobarlo: entra con un usuario del rol Aegora · Gestor y abre Insights
(el icono de gráficas del menú de la izquierda) -> "Resumen". Si no aparece el
icono, falta aplicar configure-tenant-role.sh (permiso de lectura de dashboards).

============================================================

EOF
