# n8n — workflows versionados

Los workflows de dominio, **sin tenant dentro**: en Git llevan tokens
(`__DIRECTUS_BASE_URL__`, `__TENANT_ID__`…) que se resuelven al desplegar.
Normalizados: sin `pinData`, timestamps, `versionId` ni `active`; se conservan
`id`, `name`, `nodes`, `connections`, `settings`, con formato canónico (el que
produce el exportador) para que los diffs sean de contenido.

**`active` no se versiona.** En n8n 2.x publicar es un acto explícito por id
(`publish:workflow --id=…`, porque `--all` está deprecado) y **un workflow sin
publicar no se ejecuta ni registra su webhook**. Un `active: false` viajando en
Git despublicaría herramientas que funcionan. Quién está publicado lo decide el
despliegue: `render-workflows.sh --apply` publica todo lo que importa, menos
`SESSION · Cleanup` (schedule que borra sesiones, sin probar).

Dos cosas que hay que hacer bien o el import queda a medias sin decirlo:
- **Orden.** n8n no publica un workflow cuyos sub-workflows no lo estén. Por
  nombre de fichero sale mal — `AGENT-Lucia-Core-v2` va antes que
  `LUCIA-TOOL-*` y depende de las siete — así que el orden lo calcula
  `workflow-order.py` del grafo real de nodos `executeWorkflow`/`toolWorkflow`.
- **Reinicio.** El CLI escribe en la BD y el proceso en marcha no se entera
  (lo avisa él: *"Changes will not take effect if n8n is running"*). Sin
  reiniciar, el import parece correcto y el webhook sigue en 404.

## Desplegar y capturar

```bash
# VPS · Git -> tenant (sin --apply solo renderiza y enseña el plan)
/opt/aegora/platform/n8n/render-workflows.sh --tenant demo --apply

# VPS · tenant -> forma de Git (nunca escribe en el checkout del VPS)
/opt/aegora/platform/n8n/export-workflows.sh --tenant demo
# Local · traerse el resultado y revisar el diff ANTES de commitear
scp -r aegora@<vps>:/tmp/aegora-workflows-export-demo/. n8n/workflows/
git diff n8n/workflows
```

Las reglas de sustitución viven **una sola vez**, en `workflow-tokens.py`, que
es quien hace las dos direcciones. Ahí está también el razonamiento de por qué
tokens y no un nodo `Config` por workflow.

`export-workflows.sh` **falla** si después de normalizar sigue apareciendo el id
del tenant: es lo que impide que la próxima captura devuelva el hardcode a Git
sin que nadie se entere. Mapea los ficheros por `id`, así que un workflow que
solo existe en el tenant (los de usar y tirar) se lista y no se captura hasta
que alguien le da un nombre de la convención.

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
| Header Auth | `Directus` | `CFY5g7INvQxRg8EB` | `Authorization: Bearer <token Directus>` |
| Header Auth | `Booking API` | `au21q2D0g1ZQLV6E` | `Authorization: Bearer <BOOKING_API_TOKEN>` (`secrets/booking.env`) |
| OpenAI | `OpenAI account` | `EFrzfrCY52epDU2a` | modelos del Core |
| Postgres | `Postgres account` | `IAtHlC09QTN4mgc2` | `Postgres Chat Memory` del Core (BD `n8n_<tenant>`) |
| Header Auth | `WhatsApp` | — | Cloud API de Meta (`secrets/whatsapp.env`) |

**Los nombres no llevan el tenant a propósito.** Cada tenant tiene su propia
instancia de n8n, así que `Directus · demo` era ruido: se llaman `Directus` y
`WhatsApp` en todos.

**n8n resuelve las credenciales por `id`, NO por nombre.** Una versión anterior
de este README decía lo contrario; es falso, y se vio al importar el adapter de
WhatsApp: `Credential with ID "REPLACE_WHATSAPP_CRED" does not exist`, con la
credencial `WhatsApp` creada y a la vista. Por eso en Git el `id` es un token
derivado del nombre (`__CRED_DIRECTUS__`, `__CRED_BOOKING_API__`…) y
`render-workflows.sh` lo rellena preguntándole a ese n8n qué id tiene cada una.
Si falta alguna, se para y las lista con su nombre y su tipo.

Los `id` de la tabla son los de **demo**, como referencia; en los JSON van
tokens.

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
- **Aviso de privacidad**: una vez por sesión (`state.privacy_notice_shown`), Entry
  antepone el texto del campo `privacy_notice` de `Config` a la primera respuesta.
  Base legal RGPD: ejecución de medidas precontractuales a petición del interesado
  (crear el contacto al reservar no necesita opt-in); el aviso cubre el deber de
  información. Si algún día se usa el teléfono para marketing, eso sí necesita
  consentimiento explícito aparte — no está montado.
- Estado en `conversation_sessions` (Directus): sólo operativo. La conversación
  vive en `Postgres Chat Memory` del Core.
- Rate-limit por `session_key` (`state.rl`, `rl_max`/`rl_window_ms` en Config):
  **dentro de Entry**, tras cargar la sesión, antes de gastar OpenAI.
- Allowlist de `Origin`: en el adapter (es puramente HTTP).
- Credencial: `Directus` (Header Auth) en los nodos HTTP de Entry.

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

1. Credenciales n8n: `Booking API` (Header Auth), `Directus` (Header
   Auth), `OpenAi account`, `Postgres account` (BD `n8n_<tenant>` — la usa
   `Postgres Chat Memory` del Core para el historial conversacional; la KB
   `knowledge` NO usa pgvector, va por HTTP a Directus).
2. Nodo `Config` del Core: `booking_base_url` / `directus_base_url` ya los
   rellena `render-workflows.sh`; queda ajustar `tenant_timezone` y
   `tenant_display_name`.
3. Colección Directus `knowledge` (`title`, `body` markdown, `active`, `sort`)
   con contenido del negocio. La rama `knowledge` la lee entera
   (context-stuffing, **sin RAG/embeddings**) y la inyecta al agente de
   conocimiento. Si está vacía, responde "todavía no tiene información".
   RAG (pgvector) solo si una KB crece de verdad — ver fases más abajo.
4. Tras importar: si alguna credencial quedó en blanco, reseleccionarla una
   vez. Con los nombres de la tabla de arriba, n8n las re-mapea solo.

### A validar en el VPS (hand-authored, no probado en local)

- Schemas de nodos langchain (`agent` v3, `lmChatOpenAi` v1.3).
- Expresiones con optional chaining (`$json.contact && $json.contact.phone`).
- Índices de salida del `Switch` (fallback = última salida).
- `DateTime` (luxon) disponible en los Code node de este n8n.

## Deuda conocida

- **A verificar en el primer import por CLI**: si `n8n import:workflow`
  respeta `active` (un workflow activo no debería desactivarse al reimportar)
  y si hace falta reactivar los adapters con webhook a mano.

## Importar / exportar un workflow suelto

Para uno o dos workflows el script completo es demasiado: tarda (41 invocaciones del CLI)
y reinicia n8n. El camino corto es renderizar, importar solo ese, y **publicarlo desde la
UI** -- que va por el proceso en marcha y por tanto NO necesita reinicio:

```bash
sudo n8n/render-workflows.sh --tenant demo          # sin --apply: solo renderiza
sudo docker cp /tmp/aegora-workflows-demo/WHATSAPP-Adapter.json demo-n8n:/tmp/wf.json
sudo docker exec demo-n8n n8n import:workflow --input=/tmp/wf.json
# y darle a Publish en la UI
```

El reinicio solo hace falta cuando se publica **por CLI**, que es lo que hace `--apply`.

Para tocar uno a mano sin renderizar:

```bash
docker cp n8n/workflows/03-APPOINTMENT-Create.json <tenant>-n8n:/tmp/wf.json
docker exec <tenant>-n8n n8n import:workflow --input=/tmp/wf.json
```

Ojo: ese fichero lleva **tokens sin resolver**. Para un import a mano hay que
renderizarlo antes (`render-workflows.sh` sin `--apply` los deja en
`/tmp/aegora-workflows-<tenant>/`).

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
1. Nodo **Config (editar por tenant)**: el fallback del Booking API lo
   rellena `render-workflows.sh` desde `__BOOKING_BASE_URL__`. (`$env` no
   sirve: n8n 2.31 lo bloquea en nodos por defecto — comprobado ejecutando,
   `access to env vars denied`.)
2. Credencial `Booking API` (arriba).
3. `<tenant>-n8n` alcanza `<tenant>-booking:3000` por `tenant_<tenant>_backend`.

Probado end-to-end en `demo`. **No** enganchado al agente todavía (§12.4:
solo tras las mutaciones con revalidación).
