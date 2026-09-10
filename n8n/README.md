# n8n — workflows versionados

Snapshot de los workflows de dominio del tenant `demo` (exportados con
`n8n export:workflow --all --separate`, normalizados: sin `pinData`,
timestamps ni `versionId`). Se conservan `id`, `name`, `nodes`,
`connections`, `settings`.

> Importación **manual** por ahora. No hay automatización en el provisioning.

## Convención

`NN-CATEGORIA-Nombre.json`, con `NN` = número del workflow (handover §9).
`CORE`/`CONTACT`/`TASK`/`APPOINTMENT` = lógica de dominio; `TOOL` = wrappers
que el agente principal invoca (validan y llaman a la lógica).

| # | | # | |
|---|---|---|---|
| 00 | CORE · Resolve Contact by Phone | 13 | TASK · Update |
| 01 | CONTACT · Upsert | 14 | CONTACT · Phone Upsert |
| 02 | TASK · Create | 15 | TASK · Cancel |
| 03 | APPOINTMENT · Create | 16 | CORE · Contact Context |
| 04 | TASK · Complete | 17 | CORE · Resolve + Context |
| 05 | APPOINTMENT · Update Status | 18 | TOOL · Contact Context |
| 06 | CONTACT · Get | 19 | TOOL · Task Create |
| 07 | CONTACT · Search | 20 | TOOL · Task List |
| 08 | TASK · List Pending | 21 | TOOL · Task Complete |
| 09 | APPOINTMENT · List Upcoming | 22 | TOOL · Appointment Create |
| 10 | APPOINTMENT · Get | 23 | TOOL · Appointment List |
| 11 | APPOINTMENT · Reschedule | 24 | TOOL · Appointment Reschedule |
| 12 | TASK · Get | 25 | TOOL · Appointment Cancel |

`APPOINTMENT_Availability.json` — herramienta P4 (mantenida a mano, no
exportada). Ver sección al final.

Descartados en el export: `My workflow` (scratch), un `05` con 0 nodos y un
`23 TOOL` stub de 2 nodos (los reales son los que están aquí).

## Credenciales (n8n, por tenant — NO en Git)

| tipo | nombre | id (demo) | uso |
|---|---|---|---|
| Header Auth | `Directus · demo` | `CFY5g7INvQxRg8EB` | `Authorization: Bearer <token Directus>` |
| Header Auth | `Booking API` | `au21q2D0g1ZQLV6E` | `Authorization: Bearer <BOOKING_API_TOKEN>` (`secrets/booking.env`) |
| OpenAI | `OpenAI account` | `EFrzfrCY52epDU2a` | modelos del Core |
| Postgres | `Postgres account` | `IAtHlC09QTN4mgc2` | `Postgres Chat Memory` del Core (BD `n8n_demo`) |

Los `id` de arriba son los de **demo** y van fijados en los JSON, así que en
demo el import no pide reseleccionar nada. En **otro tenant** los `id` serán
distintos: crea las credenciales con el **mismo nombre** y n8n re-mapea por
nombre; si algún nodo queda en blanco, reselecciónalo una vez.

## Migración a Booking API (handover §12.3)

Objetivo: `create/reschedule/cancel` dejan de escribir en Directus y pasan
por el Booking API (revalidación de disponibilidad + advisory lock).

| workflow | estado |
|---|---|
| `03 · APPOINTMENT · Create` | **→ `POST /api/book`**. Inputs nuevos: `service_id`✔ + `start_at`✔ + `contact_id`✔ (+ `primary_resource_id`, `location_id`, `calendar_id`, `title`, `notes`, `source`, `idempotency_key`). Se van `title` obligatorio, `end_at`, `status`, `external_provider/event_id`: el API calcula `end_at` desde `service.duration_minutes`, crea siempre `scheduled` y valida disponibilidad + advisory lock. |
| `05 · APPOINTMENT · Update Status` | Rama nueva: `status=cancelled` → **`POST /api/cancel`**; el resto de estados sigue con `PATCH` a Directus. |
| `11 · APPOINTMENT · Reschedule` | **→ `POST /api/reschedule`**. `end_at` se ignora (lo recalcula el API). Nodo `Config` + credencial `Booking API`. |
| `22 · TOOL · Appointment Create` | Contrato nuevo: `service_id`✔ + `start_at`✔ + identificador de contacto; sin `title`/`end_at`/`status`. Sigue resolviendo contacto (WF17). **El schema de la herramienta en el agente hay que actualizarlo.** |
| `24 / 25` (wrappers) | Sin cambios; el cerebro ya los llama tras resolver el `appointment_id` vía `23`. |

## Cerebro de Lucía — `AGENT-Lucia-Core.json` + `26 · TOOL · Resolve Service`

Reconstrucción del "Lucia Cerebro v5" (66 nodos, contra APIs/colecciones
muertas). **Dirección A**: `AI Agent - Core` solo interpreta → JSON; un router
determinista (`Switch` sobre `intent`) llama a los workflows versionados vía
`Execute Workflow`. El LLM **nunca** inventa UUIDs: el `service_id` lo resuelve
`26 · TOOL · Resolve Service` contra Directus `services` (single / multiple /
not_found), el `contact_id` lo resuelven los propios tools (WF17).

- Prompt del Core: `n8n/prompts/lucia-core.md` (genérico por sector; el catálogo
  de servicios y el conocimiento son del tenant).
- `26 · TOOL · Resolve Service`: `service_query` (texto) → `service_id`. Sin
  query y un solo servicio activo → ese; varios → preguntar.
- Ramas del router: `knowledge` (RAG pgvector), `list_availability`
  (→ `26` → `APPOINTMENT_Availability` → `Redacta horarios`), `create_appointment`
  (→ `26` → `Construir start_at` → `22`), `create_task` (→ `19`),
  `reschedule_appointment` / `cancel_appointment` (→ `23` → `Emparejar cita` por
  `appointment_date`/`appointment_time` → `24` / `25`), `null`/genérico
  (respuesta directa).
- `26`/`Emparejar cita` nunca inventan IDs: `service_id` sale del catálogo
  Directus; `appointment_id` sale de las citas próximas del contacto (WF23).
- El Core distingue `appointment_date`/`appointment_time` (localizar la cita
  a tocar) de `date`/`time` (nuevo hueco al reprogramar).
- **Contrato de entrada/salida congelado**: `n8n/CONTRACT-lucia-core.md`. Todas
  las ramas pasan por `Código · outcome` → `Redactor` (LLM `gpt-4o-mini` que
  solo reescribe el borrador determinista con tono natural, sin cambiar datos;
  cae al borrador si falla) → `Salida · normalizar`, que fija la forma exacta (`ok`, `intent`, `reply_to_user`, `needs_user_reply`, `flujo_activo`,
  `contact_id`, `result`) y aplica la regla única de `flujo_activo`.

## Capa omnicanal — `AGENT-Lucia-Entry` + adapters por canal

`adapter de canal → AGENT-Lucia-Entry → AGENT-Lucia-Core`. El adapter
normaliza el payload del canal a un contrato fijo y hace el dispatch de la
respuesta; Entry gestiona el estado de sesión y llama al Core.

- **`AGENT-Lucia-Entry.json`** (id `aegoraAgentLuciaEntry`): trigger
  `Executed by Another Workflow` con `canal`, `session_key`, `message`,
  `from` {phone,name,handle}, `tenant`, `reply_to`. Flujo: `Config` →
  `Validar entrada` → `HTTP · Cargar sesión` (GET `conversation_sessions`
  por `session_key`) → `Preparar contexto` (arma el input del Core;
  `sessionID = session_key`, `flujo_activo` de la sesión) →
  `Execute · AGENT-Lucia-Core` → `Fusionar resultado` → `¿Sesión existe?`
  → `HTTP · Actualizar / Crear sesión` (persiste `flujo_activo` + `contact_id`)
  → `Salida Entry` `{ ok, intent, reply, needs_user_reply, session_key, canal, to }`.
- **Entry es dueño de `canal` + `session_key`**; nunca el LLM.
- Estado en `conversation_sessions` (Directus): sólo operativo. La conversación
  vive en `Postgres Chat Memory` del Core.
- Rate-limit por `session_key` (`state.rl`, `rl_max`/`rl_window_ms` en Config):
  **dentro de Entry**, tras cargar la sesión, antes de gastar OpenAI.
- Allowlist de `Origin`: en el adapter (es puramente HTTP).
- Credencial: `Directus · demo` (Header Auth) en los nodos HTTP de Entry.

### `WEBCHAT-Adapter.json` (id `aegoraWebchatAdapter`)

Webhook `POST /webchat` (`responseMode: responseNode`, CORS `allowedOrigins: '*'`
en V1) → `Config` (`allowed_origins`, `tenant`) → `Code · Normalizar` (check
`Origin`, compone `session_key = webchat:<id>`, mintea id si falta) →
`¿Origin permitido?` → `Execute · AGENT-Lucia-Entry` → `Code · Respuesta` →
`Responder 200` `{ reply, needs_user_reply, session_key, client_session_id }`
(rama denegada → `Responder 403`). Activar el workflow para el webhook de
producción. Widget en `n8n/webchat/` (ver su README).

### `SESSION-Cleanup.json` (id `aegoraSessionCleanup`)

Schedule diario 04:00 → purga `conversation_sessions` sin actividad desde hace
`max_age_hours` (24). Filtro `_or`: `updated_at <= cutoff` **o**
(`updated_at` null **y** `created_at <= cutoff`) — cubre las filas recién
creadas por POST, donde el special `date-updated` aún no ha disparado.
Necesita permiso `delete` para la policy n8n sobre `conversation_sessions`.

### Requisitos en el tenant

1. Credenciales n8n: `Booking API` (Header Auth), `Directus · demo` (Header
   Auth), `OpenAi account`, `Postgres account` (BD `n8n_<tenant>` — la usa
   `Postgres Chat Memory` del Core para el historial conversacional; la KB
   `knowledge` NO usa pgvector, va por HTTP a Directus).
2. Nodo `Config` del Core: ajustar `booking_base_url` / `directus_base_url` /
   `tenant_timezone`. Reenvía `booking_base_url` a los tools.
3. Colección Directus `knowledge` (`title`, `body` markdown, `active`, `sort`)
   con contenido del negocio. La rama `knowledge` la lee entera
   (context-stuffing, **sin RAG/embeddings**) y la inyecta al agente de
   conocimiento. Si está vacía, responde "todavía no tiene información".
   RAG (pgvector) solo si una KB crece de verdad — ver fases más abajo.
4. Tras importar: en cada nodo HTTP/`Execute Workflow`/agente, re-seleccionar la
   credencial correspondiente (los `id` del JSON son placeholders o del export
   de demo).

### A validar en el VPS (hand-authored, no probado en local)

- Schemas de nodos langchain (`agent` v3, `lmChatOpenAi` v1.3).
- Expresiones con optional chaining (`$json.contact && $json.contact.phone`).
- Índices de salida del `Switch` (fallback = última salida).
- `DateTime` (luxon) disponible en los Code node de este n8n.

## Deuda conocida

- **Host de Directus hardcodeado** (`http://demo-directus:8055/...`) en los
  workflows `00-25`. Para multi-tenant hay que parametrizarlo (patrón nodo
  `Config` como en `APPOINTMENT_Availability`, `11`, `05`, `03`, `26` y el
  cerebro). Pendiente.

## Importar / exportar

```bash
# exportar el estado actual de un tenant
docker exec <tenant>-n8n sh -c 'rm -rf /tmp/x && mkdir /tmp/x && n8n export:workflow --all --separate --pretty --output=/tmp/x'
docker cp <tenant>-n8n:/tmp/x ./export

# importar uno
docker cp n8n/workflows/03-APPOINTMENT-Create.json <tenant>-n8n:/tmp/wf.json
docker exec <tenant>-n8n n8n import:workflow --input=/tmp/wf.json
```

---

## `APPOINTMENT_Availability.json` (P4)

Herramienta del agente (handover §12.4). Consulta `GET /api/availability`
del Booking API y devuelve una salida compacta. **No decide** disponibilidad.

Entradas (trigger *Executed by Another Workflow*): `service_id`✔, `date`✔
(`YYYY-MM-DD`), `location_id`, `resource_id`, `timezone`,
`exclude_appointment_id`, `booking_base_url`.

Salida:
```json
{ "available": true, "count": 6, "service_id": "…", "date": "…",
  "timezone": "Europe/Madrid", "duration_minutes": 30,
  "slots": [ { "start_at": "…+02:00", "end_at": "…+02:00" }, … ] }
```
o `{ "available": false, "error": "…", "message": "…" }`.

Requisitos en el tenant:
1. Nodo **Config (editar por tenant)**: fallback `http://demo-booking:3000`
   → `http://<tenant>-booking:3000`. (n8n 2.31 bloquea `$env` en nodos.)
2. Credencial `Booking API` (arriba).
3. `<tenant>-n8n` alcanza `<tenant>-booking:3000` por `tenant_<tenant>_backend`.

Probado end-to-end en `demo`. **No** enganchado al agente todavía (§12.4:
solo tras las mutaciones con revalidación).
