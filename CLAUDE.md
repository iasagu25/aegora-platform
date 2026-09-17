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
- Snapshot del esquema: **`directus/snapshot-schema.sh --tenant TENANT`**, nunca el CLI a
  mano. Hace las dos cosas que se olvidaban: escribe a fichero en vez de canalizar (una
  tubería **trunca en 64 KiB exactos** — Node no vacía stdout asíncrono antes de salir, y el
  YAML resultante parsea pero llega a la mitad: 54 campos de 160 y sin `relations`), y deja
  a `null` los displays que aportan nuestras extensiones, cuya lista deduce de
  `directus/extensions/`. Luego `scp` al repo local y **revisar el diff**: un snapshot
  arrastra todo lo que haya cambiado en el tenant, no solo lo que creías capturar.
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
- **Permisos por campo NO están disponibles** (verificado 16/sep/2026 en `demo`):
  crear un permiso con `fields` distinto de `['*']` devuelve
  `403 custom_permission_rules_enabled is a restricted resource`. Afecta también,
  previsiblemente, a filtros (`permissions`), validaciones y presets propios en un permiso:
  son todos "custom permission rules" y están capados en esta edición. Consecuencia
  práctica: un rol tiene sobre cada colección **todo o nada** por acción. Lo que se quería
  restringir a un campo (p.ej. que el gestor solo tocara `appointments.status`) hay que
  resolverlo en la interfaz (campos `readonly`) o con un Flow, sabiendo que eso es un
  guardarraíl y no una barrera: por API se puede cambiar igual.
- Permisos (12.2): modelo Role → Policies → Permissions. Un permiso `read` con
  `permissions: {}` (filtro vacío, lo que escribe la UI si no tocas el filtro)
  se evalúa como "no matchea nada" → 403 "no tienes permiso o no existe". Usar
  `permissions: null`. Editar `directus_permissions` por API puede dar 403
  incluso con token admin; se arregla por SQL (`UPDATE ... SET permissions =
  NULL`) + reiniciar el contenedor (caché de permisos). El rol n8n
  (`Aegora · n8n Service`, policy `c42ccf84-…` en demo) tiene `read` sobre
  `services/resources/service_resources/availability_rules/availability_exceptions/calendars/locations`
  + `knowledge` + `employees`, y CRUD sobre `conversation_sessions`.
  **`configure-n8n-service.sh` (`permissionModel`) es la fuente de verdad**: si falta un
  permiso se añade ahí y se re-ejecuta el script (`--apply`, idempotente, crea con
  `permissions: null`), nunca por SQL a mano. Cuidado al declarar una colección: el bloque
  de saneo borra las acciones NO listadas de las colecciones que sí están declaradas, así
  que hay que listar todas las que necesite. Tras aplicar, reiniciar el contenedor Directus
  (caché de permisos).

### Layout `Aegora Tasks` (extensión) — orden fijo, decidido
`directus/extensions/directus-extension-aegora-tasks-layout` no expone panel de opciones
(los tres slots devuelven `null`), así que **no hay selector de orden y es a propósito**:
el orden está fijo en `src/index.js` → `['due_at', '-created_at']`.

Limitación conocida y **aceptada**: la prioridad no entra en el orden, y `due_at` ascendente
manda al final las tareas sin fecha (nulos al final en Postgres), así que una tarea
`urgent` sin plazo queda por debajo de una `low` que vence dentro de semanas. La tarjeta sí
muestra prioridad (chip de color) y marca las vencidas, así que la información está.

**No "arreglarlo" ordenando en el cliente**: solo ordenaría la página cargada (limit 50) y
la lista cambiaría de orden según cuánto hayas bajado — peor que no ordenar. Tampoco sirve
meter `priority` en el sort del servidor: es un enum de texto y alfabéticamente sale
`high, low, normal, urgent`. Si algún día molesta de verdad, la solución correcta es un
campo numérico `priority_order` en `tasks` que el servidor pueda ordenar.

Ojo también: el layout tiene que exponer `refresh` desde `setup()` o el auto-refresco de
Directus (`directus_presets.refresh_interval`) no hace nada — el temporizador corre sin
nadie a quien llamar. Y `dist/` es lo que carga Directus: tras tocar `src/` hay que
`npm run build` y copiar el `dist` al contenedor.

### Cuando el Booking API no devuelve huecos, mirar el dato antes que el código
`/api/availability` no dice POR QUÉ un día sale vacío, así que una regla mal configurada es
indistinguible de un día lleno. Comprobado en `aegora-booking/lib/booking/availability.ts`:
los slots avanzan **por duración desde el inicio de la ventana** (`cursor = slotEnd`), sin
rejilla de ningún tipo — una clase a las 09:15 es perfectamente expresable, basta con que la
regla empiece a las 09:15. Los buffers NO entran en la condición de que el slot quepa en la
ventana; solo se usan para detectar choques con citas existentes (y se aplican a los dos
lados, así que una cita de 09:00-09:50 con `buffer_after` 10 bloquea hasta las 10:00).

Orden de sospechas cuando no hay huecos y "debería haberlos" (16/sep/2026: fue la tercera):
1. **`valid_from` / `valid_until` de la regla.** Una validez caducada no da error: la regla
   simplemente deja de existir para esa fecha.
2. `active` en regla, recurso o servicio.
3. Falta la fila en `service_resources` que une servicio y recurso.
4. `day_of_week`: 1 = lunes … 7 = domingo.
5. Una cita existente que bloquea por buffers.
6. `minimum_notice_minutes` / `maximum_booking_days` del servicio.

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
    (`Directus`, `Booking API`) NO en Git — con nombres SIN el tenant, porque
    cada tenant tiene su propia instancia de n8n y n8n re-mapea por nombre al
    importar. Lo que ata un workflow a un tenant va en **tokens** que se
    resuelven al desplegar (ver más abajo).
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
- Cadena: `WEBCHAT · Adapter` / `WHATSAPP · Adapter` → `AGENT · Lucía · Entry`
  → `AGENT · Lucía · Core` → tools versionados → Booking API. Validada
  end-to-end por webchat y por WhatsApp real (número de prueba, WABA Cloud
  API — NO Evolution para tenants de pago: viola ToS y arriesga el número
  del cliente). Cada canal es un adapter fino; **Entry y Core no se tocan**
  por canal (`n8n/WHATSAPP.md` documenta el setup de Meta).
  Pendiente de decidir: multi-tenant vía Embedded Signup (cada negocio
  conecta su número bajo su Meta Business y su billing) vs. un WABA propio
  por ahora — de momento un único WABA para `demo`.
- `conversation_sessions` (Directus) guarda SOLO estado operativo; la
  conversación vive en `Postgres Chat Memory` del Core (`n8n_<tenant>`).
  Entry es dueño de `canal` + `session_key`; `sessionID` del Core === `session_key`.
- Rate-limit por `session_key` en Entry (`state.rl`); allowlist de `Origin` en el adapter.
- Widget en `n8n/webchat/` (`widget.js` sin dependencias + `demo.html`).

#### Lucía v2 — reescritura del Core en curso (decidida el 15/sep/2026)
El Core v1 (`AGENT-Lucia-Core.json`) llegó a **75 nodos: 4 LLMs, 21 puertas de
routing, 19 ramas de salida, 29 nodos de código** y lleva días con el mismo ciclo:
se arregla un camino y se rompe otro. El diagnóstico NO es "bugs sueltos", son tres
fallos estructurales:
1. El estado de la conversación vive en tres sitios que pueden contradecirse (memoria
   del LLM, `state`, JSON del turno). El prompt pinta `state` como hecho, así que
   cuando `state` no llega el prompt **contradice** a la memoria y el modelo se cree
   el prompt. Todos los bucles han sido esto.
2. El control de flujo depende de juicios del LLM (`ready_to_execute`, `intent` de
   etiqueta única). Cuando el juicio falla, el router hace lo incorrecto y se le
   añade un guard — parche sobre la misma causa.
3. "Qué falta y qué preguntar" está implementado en 4 sitios que derivan entre sí.

Y el coste de mantenimiento: añadir un campo de slot = **6 ediciones coordinadas en 4
ficheros**, con fallo silencioso si te dejas una (pasó: commit 3a525f2).

**v2 = un solo agente con tools.** El LLM entiende, decide qué preguntar y redacta;
las tools tienen todos los hechos y todas las escrituras. Una llamada a tool es la
única forma de que un dato entre en la conversación. Reglas que conservan lo aprendido:
ningún UUID en el contexto del agente, hechos solo de tools, identidad inyectada
server-side (nunca se pregunta el teléfono que da el canal), y las tools responden
qué falta de forma estructurada (`{ok:false, motivo:'varios_servicios', opciones:[…]}`).

**Markdown por canal — hecho.** El agente redacta con markdown y cada canal lo adapta,
en el adapter y nunca en el Core ni en el prompt (el Core produce UN texto):
- WhatsApp (`Code · Preparar envío`): a su dialecto — `**x**` → `*x*`, `__x__` → `_x_`,
  `## t` → `*t*`, `[t](url)` → `t: url`, backticks fuera, viñetas `*`/`+` → `-`.
- Webchat (`widget.js`): se renderiza de verdad (negrita, cursiva, listas, enlaces,
  `code`). Se escapa SIEMPRE antes de inyectar, y los `href` salen de un patrón que solo
  acepta http(s) — el texto del modelo no puede colar etiquetas.
- Voz (futuro): ahí no habrá markdown ni listas; tocará decir dos o tres huecos y ofrecer
  más, como haría una persona por teléfono.
La regla de redacción (huecos en lista, uno por línea) vive en `n8n/prompts/lucia-v2.md`.

Estado: **v2 es el Core por defecto** (`core_version: v2` en el `Config` de Entry) tras
validarlo por webchat en toda la superficie de v1: reservar, conflicto de hueco con
alternativas, listar citas, cancelar con confirmación (y un "no" que no toca nada),
reprogramar, horario y dirección desde la KB, e identidad por teléfono en un canal que no
lo trae. 7 tools (`n8n/workflows/LUCIA-TOOL-*.json`) + prompt (`n8n/prompts/lucia-v2.md`,
del que el nodo lee el `systemMessage` al construir el JSON, para que no puedan divergir).

**v1 sigue importable y sin tocar**: `core_version: v1` en el `Config` de Entry lo devuelve
al router determinista. No borrarlo todavía — es la red de seguridad hasta que v2 acumule
rodaje por WhatsApp, no solo por webchat.

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
| `slot_service_query` + `slot_date` + `slot_time` + `slot_daypart` | los datos que el usuario ya ha ido dando (servicio/día/hora/franja) | mientras `flujo_activo` |
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
- Aviso de privacidad (Art. 13 RGPD) en el primer mensaje de cada sesión:
  intro + enlace a la política. En canales de solo texto (webchat) va
  concatenado al inicio de la respuesta; en WhatsApp va como mensaje
  **interactivo `cta_url`** aparte (texto de enlace personalizado no existe
  en un mensaje de texto normal de WhatsApp; botón limitado a 20 caracteres
  — `Ver política` por defecto, editable en `Config` de Entry). No repite el
  saludo genérico detrás si el primer mensaje ya era solo un saludo.
- Alta automática de contacto al reservar si no existe en Directus (Art.
  6.1.b RGPD: medida precontractual a petición del propio interesado, no
  hace falta opt-in para esto — un opt-in aparte haría falta solo para
  marketing, que no está construido). `22 · TOOL · Appointment Create`
  intenta `01 · CONTACT · Upsert` con el teléfono conocido del canal cuando
  `17 · CORE · Resolve + Context` no encuentra a nadie; si falta el
  teléfono, el nombre, o ambos, Lucía los pide explícitamente en vez de
  fallar en seco o de inventar el nombre. **El nombre nunca sale del
  nombre de perfil del canal** (el push name de WhatsApp no es una
  identidad fiable ni deseada por la persona para su ficha): solo cuenta
  el que el usuario ha dicho explícitamente en la conversación
  (`Construir start_at` en el Core ya no cae al nombre de canal).
- Cancelación en bloque: plural detectado ("cancela **las** del martes",
  "todas mis citas"), propuesta explícita del conjunto y confirmación;
  un "no" no toca nada. Reprogramar en bloque no se soporta a propósito
  (cada cita necesita su propio hueco).
- Nombrar un día sin citas es un error explícito ("No tienes ninguna cita el
  martes"), nunca un filtro que se ignora — eso llegó a cancelar otra cita.
- Intención `my_appointments` ("¿cuándo es mi próxima cita?").

**Dos bugs encontrados probando por WhatsApp (15/sep/2026), ya corregidos**:
- `Salida · huecos tras conflicto` decidía "no atiendo ese día" comparando la hora
  pedida contra el rango de **huecos libres que quedan** ese día (`primera`/`ultima`
  de los slots), no contra el horario real. Si el día ya estaba parcialmente
  ocupado, el primer hueco libre caía más tarde que la hora pedida aunque esa hora
  sí estuviera dentro de horario → decía "no atiendo a las 10:00" y en la misma
  frase citaba un horario que SÍ incluye las 10:00. Corregido: un único mensaje
  neutro ("no me queda hueco ese día"), verdadero se deba a cierre real o a que
  ya esté todo cogido — no se intenta distinguir ambos casos por huecos libres.
- "horario" es ambiguo en español (horario de atención del negocio vs. huecos
  para reservar) y el propio prompt lo usaba en el título de la regla de
  `list_availability` ("Listar horarios"), sesgando la clasificación: "¿cuál es
  vuestro horario?" se clasificó como `list_availability` en vez de `knowledge`.
  Añadida una regla explícita de desambiguación en ambos prompts
  (`n8n/prompts/lucia-core.md` y el `systemMessage` inline del nodo `AI Agent -
  Core`) — mantenerlos en paralelo si se vuelve a tocar.

Pendiente de confirmar: un aviso de privacidad (botón CTA-url) y la respuesta
real llegaron en orden invertido en WhatsApp en una prueba — probablemente
Meta no garantiza el orden de entrega entre dos envíos consecutivos de tipos
distintos aunque n8n los mande en orden. Mitigación aplicada (no confirmada
en real): `batching` (`batchSize: 1`, `batchInterval: 1200`ms) en
`HTTP · WhatsApp sendText` de `WHATSAPP-Adapter.json`, para dar margen al
primer mensaje antes de mandar el segundo.

**Lección de la sesión de depuración** (vale para cualquier rama nueva): casi
todos los bugs fueron de estos tipos, y conviene revisarlos antes de dar algo por
bueno:
1. Un hecho que solo conoce la capa determinista no llega a la memoria del LLM
   → hay que persistirlo en `state` (tabla de arriba).
2. Un filtro "tolerante" (`if (hayResultados) aplica`) que ante 0 coincidencias
   se ignora en silencio y deja actuar sobre lo que no era.
3. **Un bloque de contexto que miente es peor que no tenerlo.** El prompt
   enseñaba `fecha: null · servicio: null` en cada turno porque Entry no enviaba
   esos campos; el LLM se creyó el contexto antes que su propia memoria y la
   conversación entró en bucle (servicio → día → servicio…). Si un campo aparece
   en el bloque CONTEXTO, Entry TIENE que enviarlo de verdad.
4. **El router no debe repetir al usuario una pregunta cuya respuesta ya tiene.**
   `Salida · respuesta directa` relevaba tal cual el `reply_to_user` del LLM,
   incluida una pregunta por el servicio que el router ya tenía resuelto, o por
   el teléfono que WhatsApp manda en cada mensaje. Ahora descarta esas preguntas
   y pide lo que falta de verdad.
5. **Una decisión que el router puede tomar con datos no se delega al LLM.**
   `ready_to_execute` (juicio del modelo) era la única puerta de entrada a
   reservar, y fallaba pidiendo datos ya conocidos. Ahora `¿Reserva lista?`
   entra también si hay día + hora + (teléfono o nombre), y `¿Lista lista?` con
   solo tener el día. Entrar "de más" es seguro: `Construir start_at` revalida y
   `Salida · pedir datos reserva` pide exactamente lo que falte.

- Pendiente omnicanal / cerebro:
  - **WhatsApp**: `WHATSAPP-Adapter.json` en producción en `demo` (verificación
    de webhook, firma `X-Hub-Signature-256`, dedup por `wamid`, aviso de
    privacidad como CTA-url, alta automática de contacto) — validado con
    conversación real de principio a fin, incluida una reserva desde un
    número que no existía todavía en Directus. Sigue pendiente: decidir
    Embedded Signup multi-tenant (ver arriba) y sincronizar el nodo `Config`
    del adapter con `secrets/whatsapp.env` sin copiar a mano (el usuario
    preguntó si hay forma de automatizarlo; de momento se edita en la UI de
    n8n tras cada import).
  - **Personalizar con el nombre del contacto** (no prioritario): "Paco, a las
    8:00 no atendemos ese día…". El nombre lo resuelven los tools pero no vuelve
    al texto de las `Salida ·` — mismo patrón: tendría que viajar en el outcome.
  - `SESSION · Cleanup`: el permiso `delete` ya lo declara
    `configure-n8n-service.sh`; queda probarlo y activarlo.
  - Probar el widget en navegador contra el host público del n8n de `demo`.
  - Verificar en el primer `render-workflows.sh --apply` si `import:workflow`
    respeta `active` y si hay que reactivar los adapters con webhook a mano.
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

## Los workflows de n8n no llevan el tenant dentro — resuelto (17/sep/2026)

`$env` **no sirve**: n8n 2.31 lo bloquea en nodos **por defecto** (`access to
env vars denied`). Ojo con cómo se comprueba: `N8N_BLOCK_ENV_ACCESS_IN_NODE`
sale vacía —lo que invita a concluir que no hay bloqueo— y en el editor un
`{{ $env.PATH }}` muestra `[not accessible via UI, please run node]`, que es el
mensaje genérico de "ejecuta el nodo", no un error de permisos. Solo ejecutando
se ve la verdad.

Lo que ataba los 41 workflows a `demo` eran **72 valores**, y la URL de Directus
era solo un tercio: 30 eran **nombres de credencial**, que ninguna expresión de
n8n puede tocar. Por eso se descartó el patrón "un nodo `Config` por workflow"
que proponía el README: un `Config` vive DENTRO de un workflow, así que para que
el valor llegue a una hoja como `06 · CONTACT · Get` hay que añadirle el nodo Y
que cada `Execute Workflow` que la invoca se lo pase Y que ese llamante lo tenga
a su vez — el cambio de contrato en cascada del que huimos al reescribir el Core
(commit 3a525f2) — y aun así deja fuera las credenciales.

**El JSON de un workflow es un artefacto de despliegue, no algo configurable en
caliente.** La URL base es tan constante durante la vida de un tenant como el
nombre de su contenedor, así que se renderiza al desplegar, igual que
`compose.yml.tpl` y `.env.tpl`:

- `n8n/workflow-tokens.py` — las reglas, **una sola vez**, en las dos
  direcciones (`render` / `normalize`). Cuatro tokens: `__TENANT_ID__`,
  `__DIRECTUS_BASE_URL__`, `__BOOKING_BASE_URL__`, `__PRIVACY_POLICY_URL__`.
  Sintaxis `__X__` a propósito: no choca con los ~65 `${...}` de los template
  literals de los Code nodes ni con las expresiones `{{ }}` de n8n.
- `n8n/render-workflows.sh --tenant X [--apply]` — Git → tenant, e importa por
  CLI (sustituye a importar 41 JSON a mano por la UI).
- `n8n/export-workflows.sh --tenant X` — tenant → forma de Git. **No escribe en
  el checkout del VPS** (que se resetea duro): deja el resultado aparte para
  traérselo por `scp`, como `snapshot-schema.sh`.

Dos valores NO llevan token, simplemente dejan de nombrar al tenant: los nombres
de credencial (`Directus`, `WhatsApp`) y los `webhookId`.

**Lo que hace que esto no se pudra es la dirección de vuelta**, y en concreto
que `export-workflows.sh` FALLE si tras normalizar sigue apareciendo el id del
tenant. Sin esa comprobación, la próxima captura devuelve el hardcode a Git y no
se nota hasta que falla un tenant nuevo. Si se añade un valor propio del tenant,
su regla va en `workflow-tokens.py` — nunca se arregla a mano en el JSON.

Los flags del CLI de n8n se comprueban contra `--help` del binario antes de
usarlos, no contra la documentación.

## Sincronización con el calendario del cliente (Google / Outlook) — decidido, sin construir
El layout Calendario de Directus **no admite color por evento** (sus únicas opciones son
plantilla, campo inicio, campo fin y primer día) y además **renderiza la plantilla como
texto plano**: un `display` de etiquetas se ve con chips en Tarjetas, pero pelado en el
calendario. Conclusión tomada el 16/sep/2026: **no se construye un layout de calendario
propio**. Es de los componentes de UI más caros de mantener, cada versión de Directus lo
pone en riesgo, y compite con una superficie que el cliente ya prefiere: su móvil.

La inversión va a la sincronización, que además **ya está prevista en el modelo**:
`appointments.external_provider`, `appointments.external_event_id`, `appointments.calendar_id`
y la colección `calendars`. El handover dice que la plataforma ya hizo sync bidireccional
Directus↔Google y Directus↔Outlook antes del incidente, con una regla de diseño que sigue
vigente: *los IDs de proveedor no entran en el núcleo del dominio, Google/Outlook son
adaptadores*.

Decisiones cerradas:
- **Un calendario por empleado**, no uno del negocio (el modelo ya apunta ahí con
  `calendars.resources`).
- **Directus manda** cuando los dos lados cambian la misma cita.

Fases, por orden de valor:
1. **Salida** (Aegora → su calendario): las citas le llegan al móvil. `external_event_id`
   ya existe para no duplicar al reenviar.
2. **Entrada como bloqueos** (sus eventos → disponibilidad): si el dueño se pone el dentista
   el jueves a las 11, Lucía deja de ofrecer esa hora. **Es lo que de verdad diferencia el
   producto**, y toca el Booking API, no solo n8n (handover §505).
3. **Bidireccional real**: mover en Outlook actualiza Aegora. Conflictos, webhooks,
   renovación de tokens. No antes de que un cliente la pida.

**Forma del OAuth — decidido en dos tiempos.** El problema no es el protocolo (sería
OAuth 2.1, o sea 2.0 con PKCE obligatorio y sin flujo implícito ni password grant: eso es
*cómo* se implementa, no *quién registra la app*), sino **quién es dueño del registro**:

1. **Ahora — app en el directorio del propio cliente, registrada por Aegora** durante el
   onboarding (no la registra el cliente: se le ayuda). Al ser una app interna de su
   organización **no pasa por la verificación de Google**, que es lo que bloquearía el
   producto semanas. Además el radio de explosión es menor: unas credenciales filtradas
   afectan a un cliente, no a toda la cartera.
   Cuesta: tiempo de Aegora por cliente, y **los client secrets caducan** (Azure, máx. ~24
   meses) con **fallo silencioso** — si se va por aquí, la caducidad va en el modelo y avisa
   sola. Solo es limpio con Microsoft 365 / Google Workspace propios: con un Gmail suelto la
   app es "externa", vuelve la verificación, y en modo *testing* los refresh tokens caducan
   a los pocos días.
2. **Después — app propia de Aegora, multi-tenant** (el cliente solo pulsa "conectar"),
   cuando el montaje manual y la rotación de secretos sean el cuello de botella.

**Lo que hace que esto no sea arriesgado**: las dos se implementan igual si el almacén
guarda `client_id`/`client_secret` **por tenant** desde el día uno y refresh tokens por
empleado. La opción 2 es el caso en que ese `client_id` resulta ser el mismo para todos, y
cambiar de modelo es configuración, no reescritura.

Los tokens NO caben en `secrets/` del tenant (son por empleado, dinámicos y se renuevan):
van en una colección de Directus ligada a `calendars`, cifrados y **sin lectura para el rol
de gestor**.

**Qué pide la verificación de Google** (para cuando toque; estas políticas cambian a
menudo, verificar antes de planificar): depende de si el scope de calendario es *sensible*
(verificación) o *restringido* (verificación **+ auditoría de seguridad anual de un
tercero**, cara) — creo que es lo primero, y **ese dato es el que decide semanas vs. meses**.
Asumiendo sensible: dominio verificado, política de privacidad publicada con la cláusula de
*Limited Use*, términos, home que explique la app, **un vídeo enseñando el flujo de
consentimiento y el uso de cada permiso** (la que pilla por sorpresa), justificación permiso
a permiso y usar el scope más estrecho que sirva. Históricamente de 2 a 6 semanas.
En Microsoft no hay revisión equivalente: es *publisher verification* (alta en el programa de
partners + verificar dominio), que solo quita el aviso de "app no verificada".
Casi todo eso —dominio, home, términos, política de privacidad real— **hace falta igualmente**
como empresa. El aviso de privacidad de Lucía ya apunta a la política real
(`https://aegora.es/politica-privacidad`), la misma para todos los tenants; sigue
siendo el token `__PRIVACY_POLICY_URL__` por si algún negocio acaba teniendo la
suya, y entonces se pone `PRIVACY_POLICY_URL` en su `tenant.env`.

## Cómo mueve el gestor una cita — decidido, sin construir (16/sep/2026)
**No se le da un selector de huecos. Se le da un botón que arranca la conversación.**

El problema real del gestor no es "quiero elegir otra hora", es "no puedo atender esta cita
y hay que renegociarla con el cliente". Cualquier interfaz que le deje elegir el hueco nuevo
le está pidiendo que **adivine cuándo le viene bien a otra persona**, y sale una cita puesta
a ojo que probablemente haya que volver a mover. Así que el botón manda al cliente una
plantilla de WhatsApp ("necesitamos cambiar tu cita del {{fecha}} a las {{hora}}, ¿cuándo te
viene bien?") y **la conversación la lleva Lucía**, que ya sabe y está probada.

Encaja con la regla que ha ido saliendo toda la sesión: la acción del gestor es un botón
determinista, y el LLM se usa donde aporta — negociar con un humano — no como interfaz de
administración.

Descartado, y por qué:
- **UI de reservas para el gestor** (formulario en un Flow, extensión de Directus, o app
  aparte): resuelve el problema equivocado, y las dos últimas son superficie que mantener.
- **Hacerlo hablando con Lucía**: es no determinista y conversacional para una tarea que es
  un formulario. El coste en tokens es el menor de los dos argumentos.

**Restricción real de WhatsApp**: fuera de la ventana de 24h desde el último mensaje del
cliente solo se pueden enviar **plantillas aprobadas por Meta**, no texto libre. Hay que
registrar la plantilla (categoría "utilidad", que suele aprobarse rápido — confirmar). En
cuanto el cliente responde se abre la ventana y Lucía conversa con normalidad: la plantilla
es solo el pistoletazo de salida.

Preguntas abiertas para cuando se construya:
- En qué estado queda la cita mientras espera respuesta (si no se marca, el hueco sigue
  ocupado y en el calendario parece normal).
- Qué pasa si el cliente no contesta: alguien tiene que llamarle, y eso es una tarea — ya
  existe `anotar_tarea`.

**No hace falta equivalente en webchat**: el ~99% de la conversación por texto va a ser
WhatsApp. Webchat es secundario y esa proporción vale también para priorizar cualquier otra
cosa entre los dos canales.

Relacionado: `appointments.start_at/end_at/service_id/contact_id` se dejan **readonly para
todos, incluido el admin**, a propósito — la hora de una cita la decide el Booking API, y
editarla a mano en Directus siempre está mal. No es un apaño por no tener permisos por
campo (ver el quirk de Directus arriba), es dónde está la verdad.

## Pendientes de la UI de Directus
- **Traducciones — completadas** en `configure-spanish-ui.sh` (16/sep/2026): las 16
  colecciones con nombre singular/plural y todos sus campos. Antes solo cubría cinco, y el
  menú mezclaba "Citas" con "Appointment Resources". **Si se añade una colección o un campo,
  su traducción va en ese script**, nunca clicada en la UI: lo que se clica se pierde en el
  próximo tenant.
- **KB en secciones — decidido (16/sep/2026), se mantienen.** Para el agente da igual:
  `LUCÍA · TOOL · Info` concatena las filas como `## título\nbody`, así que ya recibe un
  único documento. La diferencia es para quien la mantiene, y ahí ganan las secciones:
  editar un markdown gigante en un campo de Directus es incómodo, `active` por sección deja
  apagar un trozo (una promoción caducada) sin borrarlo, y los títulos concatenados le dan
  estructura al modelo para localizar el dato.

## Deuda de esquema conocida (no urgente)
- `calendars`, `locations`, `resources` y `services` llevan **dos pares de timestamps**:
  `created_at`/`updated_at` (convención del negocio) y `date_created`/`date_updated`
  (los de Directus). Limpiarlo implica borrar columnas, así que no se toca sin decidirlo
  a propósito. El resto de colecciones usa uno u otro par, no los dos.

## Estilo de trabajo esperado
- PLAN antes de APPLY siempre. No inventar flags de script sin confirmar
  con `--help`.
- Comandos técnicos con etiqueta explícita de entorno (Local vs VPS).
- No asumir que la documentación heredada es correcta sin verificar.
