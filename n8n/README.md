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

| tipo | nombre | uso |
|---|---|---|
| Header Auth | `Directus · demo` | `Authorization: Bearer <token Directus>` |
| Header Auth | `Booking API` | `Authorization: Bearer <BOOKING_API_TOKEN>` (`secrets/booking.env`) |

Al importar en otro tenant, n8n intenta re-mapear por **nombre**; crea las
credenciales con el mismo nombre y re-selecciónalas en los nodos HTTP.

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

### Requisitos en el tenant

1. Credenciales n8n: `Booking API` (Header Auth), `Directus · demo` (Header
   Auth), `OpenAi account`, `Postgres account`.
2. Nodo `Config` del Core: ajustar `booking_base_url` / `directus_base_url` /
   `tenant_timezone`. Reenvía `booking_base_url` a los tools.
3. Tabla pgvector `documentos_lucia` (rama de conocimiento) — **no existe
   post-reconstrucción**; hay que montarla (esquema pgvector + contenido +
   ingesta de embeddings con `client_id` en metadata). Hasta entonces la rama
   `knowledge` responde "no tengo información".
4. Tras importar: en cada nodo HTTP/`Execute Workflow`/agente, re-seleccionar la
   credencial correspondiente (los `id` del JSON son placeholders o del export
   de demo).

### A validar en el VPS (hand-authored, no probado en local)

- Schemas de nodos langchain (`agent` v3, `lmChatOpenAi` v1.3, `vectorStorePGVector`).
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
