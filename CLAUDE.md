# Aegora — Contexto para Claude Code

## Qué es esto
Plataforma multi-tenant (pequeños negocios): Directus (CRM/config visible),
n8n (orquestación + agente conversacional "Lucía"), Booking API (futuro
componente autoritativo de disponibilidad). PostgreSQL y Caddy compartidos
a nivel de plataforma; cada tenant tiene su propio Directus + n8n.

Handover técnico completo (arquitectura, backups, runbooks): ver
`docs/AEGORA_handover_tecnico_post_Lumadock.md` (conversión versionada del
`.docx` original, que es la copia de referencia y no se versiona).

## Contexto crítico: reconstrucción post-incidente
En abril/2026 el proveedor VPS (LumaDock) sufrió un fallo de disco sin
backup contratado. La infraestructura se reconstruyó desde cero sobre un
nuevo VPS. **La documentación heredada (handover, comentarios de scripts)
puede no coincidir con la realidad actual** — varias rutas y secretos ya
han demostrado estar desincronizados. Regla de oro: verificar con
`--help`, `find`, o consultas directas (API/DB) antes de asumir que algo
documentado sigue siendo cierto.

## Git
- Remoto (GitHub) es la fuente canónica. Rama de trabajo: `feature/backup`.
- El VPS **nunca hace push** — solo `git fetch` + `git reset --hard origin/...`
  tras confirmar que no hay cambios locales que conservar.
- Todo commit final sale de local.

## Infraestructura
- VPS: `vm7423` (LumaDock), IP `185.200.244.81`, usuario `aegora`, EPYC VPS.P5.
- Repo en VPS: `/opt/aegora/platform`. Tenants en `/opt/aegora/tenants/<tenant>`.
- Tenants activos: `demo` (uso activo, incluye desarrollo de booking y n8n),
  `aegora-internal`. El id `aegora` está reservado, no usar para tenants nuevos.
- Contenedores: `<tenant>-directus`, `<tenant>-n8n`. Postgres compartido:
  `aegora-postgres`. BD por tenant: `directus_<tenant>`, `n8n_<tenant>`,
  `booking_<tenant>` (ya existe una Booking API con su propia BD, construida
  antes del incidente, **pendiente integrar** con el planteamiento actual).

## Directus — quirks descubiertos (verificados, no asumir lo contrario)
- Apply schema: `directus/apply-schema.sh --tenant TENANT [--apply]` (sin
  `--apply` hace dry-run). Vive en `directus/`, NO en
  `provisioning/tenant/directus/` como decía la doc vieja.
- CLI de snapshot: `node /directus/cli.js schema snapshot --yes` dentro del
  contenedor (NO `npx`). **Ojo:** el CLI escribe líneas `INFO:` a stdout —
  si rediriges a fichero, hay que filtrarlas o el YAML queda corrupto:
  `... | grep -vE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\]' > out.yaml`
- Tenant `demo`: usuarios reales en BD son `admin@aegora.es` y
  `n8n-service-demo@aegora.es`. El usuario técnico de provisioning
  (`directus-provisioning@aegora.es`) **ya existe en demo** (creado con
  `directus/provision-directus-access.sh --tenant demo --apply`; token en
  `/opt/aegora/tenants/demo/secrets/directus-provisioning.env`). También
  en `aegora-internal`. Para llamadas a la API de Directus, usar ese token
  ejecutando `node` dentro del contenedor contra `http://127.0.0.1:8055`
  (evita DNS/permisos del host).
- Directus fijado en 12.2.0 a propósito (no actualizar a 12.3.x todavía,
  hasta estabilizar provisioning).
- Health check: usar `/server/ping`, NO `/server/health` (devuelve 403 en 12.2.0).
- Permisos (12.2): modelo Role → Policies → Permissions. Un permiso `read` con
  `permissions: {}` (filtro vacío, lo que escribe la UI si no tocas el filtro)
  se evalúa como "no matchea nada" → 403 "no tienes permiso o no existe". Usar
  `permissions: null`. Editar `directus_permissions` por API puede dar 403
  incluso con token admin; se arregla por SQL (`UPDATE ... SET permissions =
  NULL`) + reiniciar el contenedor (caché de permisos). El rol n8n
  (`Aegora · n8n Service`, policy `c42ccf84-…` en demo) tiene ahora `read` sobre
  `services/resources/service_resources/availability_rules/availability_exceptions/calendars/locations`;
  `configure-n8n-service.sh` los declara en `permissionModel`.

## Modelo de booking en Directus — decisiones ya tomadas
- Semántica V1 simple: `service_resources` = pool OR de recursos alternativos
  por servicio. `appointment_resources` = recursos asociados a una cita
  (junction plana, sin interfaz M2M — Directus 12.2 tiene un bug conocido con
  M2M inverso sobre la misma junction: "Interfaz list-m2m no encontrada").
  Sin categorías/grupos de recursos en V1.
- Multi-recurso (decidido con el contrato Booking V1): una cita tiene 1..N
  recursos vía `appointment_resources.role` (`primary` | `participant`, default
  `primary`). Solo el `primary` valida disponibilidad; los `participant` no son
  condición AND. AND real (salas/participantes obligatorios) queda para el
  futuro — es evolución del motor, no del modelo.
- `availability_rules` funciona como allow-list: ausencia de regla para un
  día = no disponible ese día (no usar `availability_exceptions` para
  patrones recurrentes como fin de semana, solo para desviaciones puntuales).
- La junction pool-OR se llama `service_resources` (singular). El nombre
  `services_resources` fue un typo; corregido en Directus y en `base.yaml`.
- Estado: Prioridades 1 y 2 CERRADAS. Prioridad 3 EN CURSO.
  - P1 (modelo Directus): 18 relaciones M2O creadas y validadas.
  - P2 (índices/constraints SQL): `directus/sql/booking-indexes.sql` —
    capa idempotente (`CREATE [UNIQUE] INDEX IF NOT EXISTS`) con los índices
    de la sección 12.2 del handover + `uq_appointments_idempotency_key`
    (UNIQUE parcial `WHERE idempotency_key IS NOT NULL`). Integrada en
    `apply-schema.sh` respetando PLAN/APPLY: dry-run la valida en
    `BEGIN … ROLLBACK`, `--apply` la persiste en `BEGIN … COMMIT`
    (schema primero, luego SQL). Ejecuta vía `psql` en `aegora-postgres`
    leyendo credenciales del contenedor Directus.
  - `base.yaml` es un snapshot completo regenerado desde `demo` (incluye
    `relations:` — su ausencia hacía cascar `schema apply --dry-run` en
    `get-snapshot-diff.js`). Displays custom (`aegora-phone-display`,
    `field-actions`) se dejan a null en `base.yaml`: los gestiona
    `configure-directus-ui.sh`, por lo que el dry-run muestra ese diff
    de forma esperada. Flujo de cambio de esquema: crear/ajustar campos en
    `demo` vía API → `schema snapshot` → reemplazar `base.yaml` → re-quitar
    los 2 displays custom → commit → `apply-schema.sh` en los tenants.
  - P3 (Booking API): contrato V1 **congelado** en
    `aegora-booking/docs/api-contract.md` (repo separado; en `aegora-platform`
    solo va el pegamento de despliegue). 7 decisiones cerradas: políticas en
    `services` (`minimum_notice_minutes`, `maximum_booking_days`,
    `requires_confirmation`), `appointments.idempotency_key`, concurrencia por
    advisory lock + recheck en TX (sin cambios en `appointment_resources`),
    `book` siempre crea `scheduled` (bloquean `scheduled` y `confirmed`),
    `BOOKING_API_TOKEN` por tenant, BD única `directus_<tenant>`, y el modelo
    `primary`/`participant`. Delta de esquema ya aplicado en `demo` y en `base.yaml`.
  - `aegora-booking/lib/booking/` reescrito contra el modelo nuevo y validado
    en `demo` (availability, book, idempotencia, reschedule, cancel, auth).
    Buffers simétricos (slot y citas se amplían por `buffer_before/after`).
  - Despliegue por tenant (opción A, build local en el VPS):
    `provisioning/tenant/provision-booking-access.sh` (token en
    `secrets/booking.env`) + `provisioning/tenant/deploy-booking.sh` (checkout
    en `/opt/aegora/src/aegora-booking` vía deploy key SSH `github-aegora-booking`
    en `/root/.ssh/`, build `aegora-booking:<sha>`, render de
    `templates/tenant-stack/booking/`, deploy, espera `/api/health`).
    Integrado como etapas en `onboard-tenant.sh`; ruta Caddy `${BOOKING_HOST}`
    en `publish-tenant.sh` (condicional a que el contenedor exista).
    `demo-booking` desplegado y healthy.
  - `availability_exceptions.start_at/end_at` pasados a `timestamptz`
    (antes `timestamp` sin zona; ahora consistente con `appointments`).
    Cambio de tipo Directus no se puede por PATCH `/fields` en 12.2: se hizo
    con `ALTER … USING <col> AT TIME ZONE 'Europe/Madrid'` en `demo` + snapshot.
  - `create-tenant.sh` + manifests: sin `booking_<tenant>` (DB/rol/data dir).
    Booking V1 usa `directus_<tenant>`. Se conservan `BOOKING_CONTAINER` y
    `BOOKING_HOST` en `tenant.env` (los leen `deploy-booking.sh` /
    `publish-tenant.sh`). Los tenants ya creados (`demo`, `aegora-internal`)
    conservan su `booking_<tenant>` vacío + refs en `config/tenant.env` y
    `config/backup.manifest.json` hasta limpieza manual.
  - n8n: 26 workflows de dominio de `demo` versionados en `n8n/workflows/`
    (`NN-CATEGORIA-Nombre.json`, export normalizado). Credenciales por tenant
    (`Directus · demo`, `Booking API`) NO en Git. n8n 2.31 bloquea `$env` en
    nodos → la URL base va en un nodo `Config`.
  - P4: `APPOINTMENT_Availability.json` — sub-workflow que llama
    `GET /api/availability` y devuelve slots compactos. Probado en `demo`.
  - P5: las 3 mutaciones pasan por el Booking API — `03 · Create` →
    `POST /api/book` (contrato nuevo: `service_id`+`start_at`+`contact_id`,
    sin `title`/`end_at`/`status`); `11 · Reschedule` → `POST /api/reschedule`;
    `05 · Update Status` rama `cancelled` → `POST /api/cancel` (resto de
    estados sigue en Directus). `22 · TOOL · Appointment Create` actualizado al
    nuevo contrato. **Probado end-to-end en `demo`**: create + idempotencia +
    slot_conflict, reschedule, cancel.
  - Cerebro de Lucía reconstruido (Dirección A: LLM interpreta → router
    determinista → `Execute Workflow` a los tools versionados):
    `n8n/workflows/AGENT-Lucia-Core.json` (33 nodos) + `n8n/prompts/lucia-core.md`
    + `26 · TOOL · Resolve Service` (`service_query` → `service_id` contra
    Directus, single/multiple/not_found). El LLM nunca inventa UUIDs.
    v1 cubre knowledge/list_availability/create_appointment/create_task;
    reschedule/cancel stub (falta resolver `appointment_id` vía `23`).
    **Probado en `demo`**: `null` (saludo), `list_availability` y
    `create_appointment` end-to-end (Core NLU → `26` → `Construir start_at` →
    `22` → `/api/book` → cita, contacto resuelto por WF17, recurso asignado).
    `reschedule`/`cancel` también validados end-to-end (Core → `23` →
    `Emparejar cita` por `appointment_date`/`appointment_time` → `24`/`25` →
    `/api/reschedule|cancel`), + caminos de ambigüedad y sin-contacto.
    `create_task` validado (Core → `19` → tarea en `tasks`, `priority` enum
    `low|normal|high|urgent`, prefijo de tipo en el título).
    **Contrato del Core congelado** (`n8n/CONTRACT-lucia-core.md`): entrada
    Entry→Core y salida Core→Entry. Todas las ramas terminan en
    `Salida · normalizar` (regla única de `flujo_activo`, `contact_id`
    best-effort, `result` opcional). Es la base sobre la que se construye
    `AGENT-Lucia-Entry` (capa omnicanal — webchat primero, ver "Omnicanal").
    `knowledge` (**KB V1, sin RAG**): fuera pgvector/embeddings. Colección
    Directus `knowledge` (`title`, `body` markdown, `active`, `sort`) — creada
    en `demo` y en `base.yaml` (commit 19af460). La rama la lee entera vía
    `HTTP · Directus knowledge` (filtro `active`, sort `sort`) → `Code · Preparar
    KB` (concat `## title\nbody`) → `AI Agent - Conocimiento` (KB en el system
    message, context-stuffing). Permiso `read` para la policy n8n `c42ccf84`
    añadido por SQL (`directus_permissions` id 20, `permissions` NULL). RAG solo
    si una KB crece de verdad (~>30k tokens). **Probado en `demo`** end-to-end
    (Core → `knowledge` → colección `knowledge` → respuesta del dato correcto).
### Omnicanal (capa de entrada del cerebro) — V1 funcionando en `demo`
- Cadena: `WEBCHAT · Adapter` → `AGENT · Lucía · Entry` → `AGENT · Lucía · Core`
  → tools versionados → Booking API. Validada end-to-end por webchat.
- **V1 = solo webchat.** WhatsApp irá con WABA Cloud API + Embedded Signup
  (NO Evolution para tenants de pago: viola ToS y arriesga el número del
  cliente). Otro adapter, sin tocar Entry ni Core.
- `conversation_sessions` (Directus) guarda SOLO estado operativo; la
  conversación vive en `Postgres Chat Memory` del Core (`n8n_<tenant>`).
  Entry es dueño de `canal` + `session_key`; `sessionID` del Core === `session_key`.
- Rate-limit por `session_key` en Entry (`state.rl`); allowlist de `Origin` en el adapter.
- Widget en `n8n/webchat/` (`widget.js` sin dependencias + `demo.html`).

#### Patrón clave: lo que el LLM no puede saber, va en `conversation_sessions.state`
Repetidamente ha aparecido el mismo fallo: un hecho que **solo conoce la capa
determinista** (resultado del Booking API, qué cita se localizó, qué servicio se
resolvió) nunca llega a la memoria del LLM, porque se genera *después* de que el
Core clasifique el turno. La solución, aplicada ya varias veces, es persistirlo en
`state` y reinyectarlo como input del Core:

| campo en `state` | para qué | vida |
|---|---|---|
| `contact_phone` | identidad del hilo entre intenciones | indefinida |
| `pending_service_id` | servicio ya resuelto de la reserva en curso | mientras `flujo_activo` |
| `pending_appointment_id` + `pending_appointment_service_id` | cita localizada en reschedule/cancel (evita re-listar cada turno) | mientras `flujo_activo` |
| `last_appointment_id` | última cita tocada; resuelve referencias implícitas ("mejor pásala al jueves") | indefinida |
| `awaiting_slots_offer` + `alt_slots_date`/`alt_slots_time` | guard: nunca reintentar el hueco que acaba de fallar | 1 turno |
| `awaiting_bulk_confirm` + `bulk_appointment_ids` | cancelación en bloque pendiente de confirmar | 1 turno |

Contrato completo en `n8n/CONTRACT-lucia-core.md`. **Los UUID nunca pasan por el
LLM**: el Core solo emite significado (`service_query`, `confirmation`, ordinales)
y el router resuelve identificadores.

#### Redactor (paso 7)
Todas las ramas producen un **borrador determinista**; `Código · outcome` →
`¿Necesita Redactor?` → `Redactor` (gpt-4o-mini, solo reescribe tono) →
`Salida · normalizar`. Se **salta** el Redactor cuando la operación ya se ejecutó
(`ok && !needs_user_reply`) o el texto ya viene redactado (`_already_styled`):
paraphrasear "cita confirmada" → "cita pendiente" es inaceptable. También se salta
cuando se cita el horario literal de la KB.

#### UX conversacional — validado en `demo` por webchat (14/sep/2026)
Todo lo de abajo está probado conversando, no solo cableado:
- Franjas con convención española (`tarde` desde las 14:00, no mediodía);
  el Core emite `daypart` y n8n filtra los slots.
- Un conflicto de hueco **lista los huecos libres de inmediato**, sin preguntar
  "¿quieres que te los diga?" (al reservar y al reprogramar). Si la hora pedida
  cae fuera de servicio, cita el horario **literal** de la colección `knowledge`
  (nunca interpretado: `availability_rules` es por recurso y no sirve para
  afirmar el horario del negocio; esos mensajes saltan el Redactor).
- Reprogramar lista disponibilidad del servicio de la cita, excluyéndose a sí
  misma (su hora actual aparece libre si se mueve dentro del mismo día).
- Elegir una hora de una lista reserva/reprograma; no vuelve a listar.
- Reserva sin declarar servicio: si el tenant tiene uno solo, se usa; si tiene
  varios, se listan por nombre ("¿Para cuál de estos servicios? …"). Nunca se
  pregunta por datos ya dados.
- Referencias implícitas: "mejor pásala al jueves" tras reservar se refiere a esa
  cita, sin listar nada (`last_appointment_id`).
- Desambiguación por día, hora, ordinal o número, contra **la lista que se
  mostró** (`shown_appointment_ids`), no contra todas las citas del contacto.
- Cancelación en bloque: plural detectado ("cancela **las** del martes",
  "todas mis citas"), propuesta explícita del conjunto y confirmación;
  un "no" no toca nada. Reprogramar en bloque no se soporta a propósito
  (cada cita necesita su propio hueco).
- Nombrar un día sin citas es un error explícito ("No tienes ninguna cita el
  martes"), nunca un filtro que se ignora — eso llegó a cancelar otra cita.
- Intención `my_appointments` ("¿cuándo es mi próxima cita?").

**Lección de la sesión de depuración** (vale para cualquier rama nueva): casi
todos los bugs fueron de dos tipos, y conviene revisarlos antes de dar algo por
bueno:
1. Un hecho que solo conoce la capa determinista no llega a la memoria del LLM
   → hay que persistirlo en `state` (tabla de arriba).
2. Un filtro "tolerante" (`if (hayResultados) aplica`) que ante 0 coincidencias
   se ignora en silencio y deja actuar sobre lo que no era.

- Pendiente omnicanal / cerebro:
  - **WhatsApp (siguiente)**: número ya dado de alta en Meta → WABA Cloud API.
    Hace falta `WHATSAPP-Adapter.json` (verificación del webhook con
    `hub.challenge`, firma `X-Hub-Signature-256`, normalización del payload de
    Meta al contrato de Entry, `sendText` de vuelta) + credenciales del tenant.
    **Entry y Core no se tocan**: ese es justo el motivo del split.
    Pendiente de decidir: multi-tenant vía Embedded Signup (cada negocio conecta
    su número bajo su Meta Business y su billing) vs. un WABA propio por ahora.
  - **Personalizar con el nombre del contacto** (no prioritario): "Paco, a las
    8:00 no atendemos ese día…". El nombre lo resuelven los tools pero no vuelve
    al texto de las `Salida ·` — mismo patrón: tendría que viajar en el outcome.
  - `SESSION · Cleanup`: conceder `delete` en `conversation_sessions` a la policy
    n8n `c42ccf84` (SQL) y activarlo.
  - Probar el widget en navegador contra el host público del n8n de `demo`.
  - Parametrizar `http://demo-directus:8055` hardcodeado en los workflows `00-25`
    (bloqueante real para un segundo tenant).
  - Aplicar `base.yaml` + `booking-indexes.sql` en `aegora-internal`, y montar
    allí credenciales n8n + workflows.
  - Migrar build A → imagen en GHCR (CI en `aegora-booking`).
  - **Cambios de plataforma no llegan a tenants existentes**: `create-tenant.sh`
    renderiza `compose/*/.env` una sola vez, al crear el tenant. Si cambia una
    plantilla (p.ej. `WEBHOOK_URL` en `n8n/.env.tpl`), los tenants ya creados se
    quedan atrás y no hay forma limpia de actualizarlos. Falta un
    `render-tenant-config.sh` (PLAN con diff + APPLY) que re-renderice las
    plantillas desde `tenant.env`. Para `tenant.env` en sí ya existe
    `set-tenant-config.sh`.

## Estilo de trabajo esperado
- PLAN antes de APPLY siempre. No inventar flags de script sin confirmar
  con `--help`.
- Comandos técnicos con etiqueta explícita de entorno (Local vs VPS).
- No asumir que la documentación heredada es correcta sin verificar.
