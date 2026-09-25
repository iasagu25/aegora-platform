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

### Los scripts entran con el token de provisioning, NUNCA con el admin
`configure-n8n-service.sh` era el único que se autenticaba con
`ADMIN_EMAIL`/`ADMIN_PASSWORD` del contenedor, y falló en `demo` con un 401 justo al
repartir permisos. **Directus usa esas variables SOLO al arrancar por primera vez**: en
cuanto alguien cambia la contraseña del admin (o se vuelve a renderizar el `.env`), el
fichero y el usuario real divergen y **nadie se entera hasta que un script intenta
entrar**. Se realinean con `node /directus/cli.js users passwd --email X --password Y`.

Todos usan ya `secrets/directus-provisioning.env`, cuyo usuario tiene rol Administrator.
Y el script **comprueba que el token ABRE**, no que el fichero exista: uno revocado o de
otro tenant da un 401 al empezar y no a mitad de repartir permisos.

### El `display_template` de una colección NO basta para que se vea un nombre
Un `display_template` en `contacts` solo entra en juego si **el campo que la referencia
tiene un `display` configurado**. Sin él, Directus pinta el valor crudo: un UUID donde
debería ir el nombre de una persona. Hay que decirlo **campo a campo** -- están en
`displaysDeCampo` de `configure-directus-views.sh` (`related-values` con su plantilla),
y la plantilla se define una sola vez en ese fichero porque la usan dos sitios que tienen
que decir lo mismo.

Costó tres intentos creer que el problema era otro: primero pareció que faltaba la
plantilla de la colección, después que faltaban los presets. El síntoma es idéntico en
los tres casos, y lo que lo distingue es mirar la pestaña **Mostrar** del campo.

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
lo trae. 7 tools (`n8n/workflows/LUCIA-TOOL-*.json`) + prompt (`n8n/prompts/lucia-v2.md`).
**El `.md` manda y el JSON es artefacto**: `python3 n8n/build-prompt.py --write` lo mete en
el `systemMessage` del nodo, y sin `--write` solo avisa si divergen. Antes eran dos copias
de 10.000 caracteres que coincidían por disciplina, y separarse no da ningún error --
simplemente el agente se comporta distinto y no hay nada que mirar.

**v1 sigue importable y sin tocar**: `core_version: v1` en el `Config` de Entry lo devuelve
al router determinista. No borrarlo todavía — es la red de seguridad hasta que v2 acumule
rodaje por WhatsApp, no solo por webchat.

#### Ajustes de comportamiento por tenant (`CONTACTO_PEDIR_EMPRESA`, 21/sep/2026)
Lo que una gestoría necesita y una peluquería no: **la empresa del cliente**. En una
gestoría a las personas se las conoce por su empresa y una ficha sin ella no sirve; en
otros negocios preguntarla es ruido. Así que es configuración del tenant, no del código:
`CONTACTO_PEDIR_EMPRESA` en `tenant.env`, que `create-tenant.sh` escribe siempre con su
valor por defecto -- **un ajuste que solo existe cuando alguien lo añade a mano no lo
descubre nadie**.

**No hizo falta tocar el router ni inventar una rama**: el prompt ya dice "pide solo lo
que venga en `falta`", así que basta con que `reservar_cita` meta `empresa` en esa lista.
Es el mecanismo de `falta_identidad` haciendo su trabajo, y es la prueba de que v2 se
extiende por las tools y no por el prompt.

Dos decisiones de trato: se pide **junto al nombre y en el mismo mensaje** (son el mismo
hueco, quién eres; partirlo en dos turnos cansa) y **no bloquea la reserva** -- un
particular que viene a la renta no tiene empresa y su cita vale igual.

**Un ajuste booleano NO puede ser un token normal.** `normalize` sustituye por valor, así
que un token que vale `true` convertiría en token todos los `true` del JSON al exportar.
Va en `AJUSTES_TENANT` de `workflow-tokens.py`, que se resuelve por **nombre de campo** de
un nodo Set -- el mismo mecanismo que los secretos de WhatsApp y por la misma razón. Y a
diferencia de un secreto, siempre se resuelve con un valor por defecto: dejar puesto el
literal `__CONTACTO_PEDIR_EMPRESA__` sería "verdadero" para cualquier comprobación laxa y
un tenant sin configurar acabaría pidiendo la empresa a todo el mundo.

#### Patrón clave: lo que el LLM no puede saber, va en `conversation_sessions.state`
Repetidamente ha aparecido el mismo fallo: un hecho que **solo conoce la capa
determinista** (resultado del Booking API, qué cita se localizó, qué servicio se
resolvió) nunca llega a la memoria del LLM, porque se genera *después* de que el
Core clasifique el turno. La solución, aplicada ya varias veces, es persistirlo en
`state` y reinyectarlo como input del Core:

| campo en `state` | para qué | vida |
|---|---|---|
| `contact_phone` | identidad del hilo entre intenciones | indefinida | **(ver aviso abajo: en v2 solo funciona en WhatsApp)** |
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
**Y NO cuesta latencia** (medido 22/sep/2026, porque parecía que sí): el nodo lleva la
guarda `itemIndex > 0` antes del `sleep`, así que con un solo mensaje no espera. Los datos
lo confirman sin depender del código: adapter menos Entry da ~950 ms en los turnos de un
mensaje y ~1320 en los de dos, y una espera antes del primero pondría TODOS por encima de
1200. Ese ~1 s de base es firma + clasificación + el viaje a `graph.facebook.com`, y no
hay nada que recortar ahí.

**"Escribiendo…" en WhatsApp (25/sep/2026).** `WHATSAPP · Escribiendo` manda a Meta
`status: read` + `typing_indicator` con el `wamid` del mensaje entrante; Meta lo quita solo al
llegar la respuesta o a los 25 s. El adapter lo dispara **sin esperar** y colocado **por
encima de Entry en el lienzo** -- con `executionOrder: v1` las ramas de una misma salida
corren de arriba abajo --, así que sale antes de que Entry empiece y no le suma latencia.
**Solo con la sesión en `auto`**: en `humano` el indicador prometería una respuesta que puede
tardar una hora, y además marcaría como leído algo que ninguna persona ha leído.

**Insertar un nodo en una cadena cambia `$json` para todo lo que va detrás**, y el fallo
sale lejos del cambio. Pasó **cuatro veces el 21/sep/2026**: el gestor de memoria delante
de `Salida relevo humano`, el guardado de mensajes delante de `Salida Entry`, la consulta
de quién atiende delante de `Code · Salida`, y el resolutor de profesional delante de
`Expandir días` -- este último con un comentario en el propio nodo que avisaba de que
`$json` era la salida del nodo anterior. **Un nodo que necesita la salida de OTRO nodo
concreto se la pide por nombre (`$('Nombre').first().json`), no por `$json`.** Es una línea
más y deja de importar quién vaya delante. Se audita rápido: buscar los nodos que usan
`$json` a pelo y mirar quién es su predecesor.

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
    número que no existía todavía en Directus. El nodo `Config` del
    adapter ya **no** se reescribe a mano tras cada import: lo rellena
    `render-workflows.sh` desde `secrets/whatsapp.env`, y el plan avisa si no
    los encuentra en vez de importar un adapter roto en silencio. Sigue
    pendiente decidir Embedded Signup multi-tenant (ver arriba).
    **La firma del webhook se verifica de verdad desde el 18/sep/2026.**
    `X-Hub-Signature-256` se valida con el nodo `Crypto` de n8n y
    `require_signature` está en `true`, así que una petición sin firma válida se
    descarta. Antes no se comprobaba: el webhook es público y cualquiera podía
    falsificar un evento de Meta y hacer que Lucía actuara como cualquier número
    -- reservar o cancelar citas de terceros.
    Estaban apiladas **cuatro** causas independientes, y ninguna se veía porque
    el veredicto de la firma no salía ni en los logs ni en la ejecución: faltaba
    `WHATSAPP_APP_SECRET` (y el campo tenía un token `EAA…` en su lugar), el
    cuerpo crudo se perdía en el nodo Set intermedio, `require('crypto')` está
    prohibido en el sandbox, y tampoco hay Web Crypto. **Lección: una comprobación
    de seguridad que no se puede observar no está funcionando, se está
    acumulando.** Al hacerla visible, las cuatro cayeron en dos horas.
  - **Personalizar con el nombre del contacto** (no prioritario): "Paco, a las
    8:00 no atendemos ese día…". El nombre lo resuelven los tools pero no vuelve
    al texto de las `Salida ·` — mismo patrón: tendría que viajar en el outcome.
  - `SESSION · Cleanup`: el permiso `delete` ya lo declara
    `configure-n8n-service.sh`; queda probarlo y activarlo.
  - Probar el widget en navegador contra el host público del n8n de `demo`.
  - Verificar tras el primer `render-workflows.sh --apply` que los dos adapters
    siguen respondiendo en su webhook de producción.
  - Aplicar `base.yaml` + `booking-indexes.sql` en `aegora-internal`, y montar
    allí credenciales n8n + workflows.
  - Migrar build A → imagen en GHCR (CI en `aegora-booking`).
  - **Límites de recursos en las plantillas** (`mem_limit`, `cpus` en los tres
    `compose.yml.tpl`). Hoy no hay ninguno y no hay swap: un tenant que se
    dispare hace que el OOM killer mate a otro, y elige él la víctima. Con el
    modelo medido los números ya se saben: ~1,5 GiB para n8n y ~512 MiB para
    Directus dejan margen sobre lo observado. Es lo que convierte "caben 11" en
    una garantía en vez de un promedio.
  - **Medir la latencia del agente con `--concurrency 1`**
    (`scripts/loadtest/webchat-load.sh --tenant demo --concurrency 1 --rounds 5`).
    Con 5 conversaciones simultáneas el p50 ya es de 7 s, y hace falta saber
    cuánto de eso es la cadena LLM -> tool -> LLM y cuánto encolamiento. Si es
    lo primero, es un asunto de producto: son 7 segundos que el cliente espera.
  - ~~Ejecutar `render-tenant-config.sh --apply` en `demo` y `dev`~~ — **hecho (21/sep/2026)**.
    Los dos tienen ya el manifiesto con `secrets/restic.env` y la `WEBHOOK_URL` buena;
    verificado en el entorno del contenedor y con un WhatsApp real en `demo`.

## El snapshot va SIEMPRE al final de la cadena (21/sep/2026)
`base.yaml` lleva la forma **cruda** del esquema; la capa de interfaz la ponen
`configure-directus-views.sh` (visibilidad en el menú, orden y ancho de campos,
`display_template`) y `configure-directus-ui.sh` (displays propios). Las dos fuentes
discrepan por diseño, así que **el orden importa y no es opcional**:

    apply-schema --apply  ->  configure-directus-views  ->  configure-directus-ui
                          ->  configure-spanish-ui      ->  snapshot-schema

Capturar el snapshot ANTES de los `configure-*` mete el estado crudo en Git, y el
siguiente `apply-schema` de cualquiera vuelve a esconder del menú lo que el script de
vistas había puesto. Pasó dos veces el mismo día: con `service_resources` (venía de un
commit de septiembre) y con `conversation_sessions` (capturado a las 05:04, con las
vistas configuradas a las 07:2x). El síntoma es siempre el mismo: un dry-run que
propone `Set hidden to true` sobre algo que quieres ver.

**`apply-schema.sh` NO ejecuta los `configure-*`** aunque su ayuda lo afirmara hasta
hoy. Ahora los nombra al terminar, pero sigue sin ejecutarlos: aplicar el esquema y
parar ahí deja el tenant sin la capa de interfaz.

**Y con una COLECCIÓN nueva, el reinicio va también EN MEDIO** (23/sep/2026, promocionando
`call_notes` a `demo`). Los `configure-*` hablan por la API, y la API valida contra el
esquema que Directus tiene **en memoria**: con un único reinicio al final, todo lo que
corre antes se encuentra un Directus que aún no conoce la colección. El síntoma llegó
tarde y disfrazado -- n8n devolviendo `403 "no tienes permiso o no existe"` sobre
`call_notes` en una llamada real, no un error durante el despliegue.

    apply-schema --apply  ->  reinicio  ->  configure-*  ->  reinicio

Son dos cachés distintas: la primera es el esquema, la segunda los permisos.

**Y esperar es esperar, no dormir.** Un `sleep 20` entre el reinicio y el script siguiente
falla con `ECONNREFUSED 127.0.0.1:8055` en cuanto Directus tarda 21. Los scripts ya traían
`esperar_api()` (sondea `/server/ping`, que en 12.2.0 es el bueno), pero **tres de ellos la
definían sin llamarla al empezar**: `configure-tenant-role.sh` solo la usaba al final, para
proteger al SIGUIENTE de la cadena, nunca a sí mismo. Dead code con aspecto de salvaguarda,
que es la peor clase: leer el fichero te convence de que está cubierto. Corregido en los
cuatro que faltaban; `configure-directus-ui.sh` además exigía `healthy` y abortaba, ahora
espera.

Y una trampa al corregirlo, que costó otra pasada: la función se insertó **dentro del
cuerpo de `fail()`**, porque el ancla era la línea `fail() {` y en esos ficheros abre un
bloque multilínea. Resultado: `esperar_api` solo existía si se llamaba a `fail`, y el
script murió con `command not found` **teniendo la definición a columna 0 y pasando
`bash -n`**. Dos lecciones: `bash -n` valida sintaxis, NO ámbito -- una función dentro de
otra es sintácticamente correcta --, y comprobar la definición con `grep '^nombre()'`
tampoco sirve, porque la indentación no dice nada del anidamiento. Lo que sí sirve es
contar llaves hasta ese punto, o mirar si cae dentro del cuerpo de otra función.

**Y desde el 25/sep/2026 la espera es UNA sola: `scripts/lib/esperar-contenedor.sh`**
(`esperar_healthy` / `reiniciar_y_esperar`). Cada script traía la suya y medían cosas
distintas: unos sondeaban `/server/ping`, otros exigían `healthy` de Docker sin esperar.
Son **dos relojes**: la API contesta a los ~24 s de un reinicio, pero el healthcheck de
Docker solo pasa a `healthy` en su siguiente sondeo (cada 15 s). `configure-tenant-role.sh`
esperó al ping, `configure-n8n-service.sh` exigió `healthy` y la cadena murió con
`Directus no está healthy: starting` con un Directus que ya respondía. Ahora todos esperan a
lo más estricto de los dos, en el mismo sitio; `starting`/`unhealthy` son de paso y solo
`exited`/`dead`/inexistente abortan. La usan todos los scripts de `directus/`, los de
`n8n/` que hablan con el contenedor, `publish-tenant.sh` y `restore-tenant.sh` (que tenía un
`sleep 20` y daba por bueno `starting`). `deploy-tenant.sh`, `deploy-booking.sh` y
`onboard-tenant.sh` ya esperaban `healthy` con su propia función y se dejaron.
**Un script nuevo que hable con un contenedor la usa al empezar; uno que reinicie usa
`reiniciar_y_esperar`.** Nada de `docker restart` suelto ni de `sleep`.

Detalle menor que hace dudar de un apply correcto: **el resumen del dry-run no imprime
las altas dentro de un array**, solo las modificaciones. Al añadir un valor a un
`choices` se ven los índices que se desplazan pero no el nuevo, y parece que se pierde
el último. Se comprueba en la BD (`SELECT options FROM directus_fields WHERE ...`).

## Las conversaciones se leen y se contestan desde Directus (21/sep/2026)
La objeción que sale en cada venta: al pasar a WABA el negocio **pierde la app de
WhatsApp** y pregunta enseguida dónde va a ver y contestar sus conversaciones. Hasta
hoy la respuesta no existía -- la conversación vivía en el `Postgres Chat Memory` del
Core, dentro de `n8n_<tenant>`, en formato interno y en otra base de datos.

`conversation_messages` (una fila por mensaje, cualquier canal) + dos campos en
`conversation_sessions` (`modo`, `ventana_hasta`). Decisiones que importan:
- **`direccion` y `autor` son ejes distintos.** Un saliente puede ser de Lucía o de una
  persona, y eso es lo que hace legible un relevo.
- **Se guarda lo que el canal ENTREGA**, no el `reply_to_user` combinado de v1, que no
  lo recibe nadie tal cual: el aviso de privacidad va como mensaje propio (CTA-url en
  WhatsApp, pintado por el widget en webchat) y `core_reply` es la respuesta. Guardar
  el combinado le enseñaba al gestor un mensaje que el cliente nunca vio así.
- **El `contact_id` de la sesión se rellena solo**, y lo hace **Entry llamando a
  `17 · CORE · Resolve Context`** -- el mismo resolutor que usan las tools, así que no
  pueden discrepar sobre quién es el contacto.
  **Y aquí hay una lección que vale para todo el Core v2: dentro de un agente,
  `$(tool).first().json` NO devuelve el JSON del sub-workflow.** El primer intento fue
  hacer que las tools devolvieran `contact_id` y que `Code · Salida v2` lo recogiera como
  recoge `telefono_usado` -- y se comprobó en la ejecución que llegan **los dos a `null`**.
  Consecuencia que conviene saber: **`state.contact_phone` solo funciona en WhatsApp**,
  donde el teléfono lo da el canal (`_known_phone`). En webchat el número lo teclea el
  cliente, solo lo ve la tool, y por esa vía no vuelve: Lucía lo volverá a pedir en cada
  intención nueva. El arreglo, cuando toque, no es tocar `Code · Salida v2` sino que **la
  propia tool escriba en `conversation_sessions`** -- tiene el `session_key`, así que no
  necesita el canal de vuelta.
  El Core v2 devolvía además `contact_id: null` fijo, así que la sesión se quedaba sin
  contacto **siempre** -- no solo cuando se creaba
  durante la conversación, también con un cliente que ya existía. Tres consecuencias que
  parecían independientes y eran la misma: columna Contacto vacía en la bandeja,
  `conversation_messages.contact_id` siempre nulo, y **el panel de "citas de este contacto"
  de la interfaz sin activarse nunca** -- justo lo que existe para que el gestor no prometa
  una cita que no ha creado. Ahora `22` devuelve el contacto que resolvió o creó, la tool
  lo pasa y `Code · Salida v2` lo recoge igual que `telefono_usado`. No lo ve el modelo.
- **Entry solo LEE `modo`.** Si lo escribiera, cada turno devolvería la sesión a `auto`
  y un relevo duraría un mensaje.
- **El relevo es de WhatsApp.** En webchat no hay forma de empujarle nada a un
  navegador cerrado: callar a Lucía ahí deja al cliente en un chat muerto.
- **`ventana_hasta` se enseña porque la ventana de 24h aplica también al humano.** Un
  gestor que no la ve escribe, falla, y no vuelve.
- El gestor tiene `create` sobre los mensajes y **nunca `update` ni `delete`**: un
  historial que se puede editar deja de ser un registro de lo que pasó.

`HUMANO · Enviar pendientes` recoge los `pendiente` cada 10 s. **Se reserva las filas
poniéndolas en `enviando` con un update-by-query antes de enviar**: sin esa reserva,
dos pasadas solapadas del temporizador mandan el mismo mensaje dos veces a una persona
real. Un envío fallido **no se reintenta solo** -- reintentar a ciegas contra WhatsApp
es como se manda cuatro veces lo mismo. Y va con `saveDataSuccessExecution: none`, que es
lo que permite sondear rápido: una pasada que no encuentra nada no deja rastro, así que el
límite de 10.000 del pruning deja de ser la restricción y el intervalo lo decide la
latencia que quieres, no la contabilidad. (A 30 s lo elegía la contabilidad: 2.880
ejecuciones diarias se habrían comido ese límite en tres días, desalojando las de
conversaciones, que son las que sirven para depurar.)

**Por eso el chat NO necesita Flows de Directus.** Se recurrió a ellos dos veces y las dos
hubo algo mejor: cancelar las citas al borrar un contacto es un trigger (cubre más, es
atómico y viaja en el dump), y el empujón para que el gestor no espere se resolvió bajando
el sondeo. Los flows no entran en `schema snapshot` y necesitarían provisioning propio; si
algún día hacen falta, que sea por un caso que de verdad no se pueda resolver de otra
forma.

**Los turnos del relevo entran en la memoria del Core** (`Chat Memory Manager`, misma
tabla y misma clave de sesión que el Core, o se escribiría en un historial que el agente
no lee). Entry anota el mensaje del cliente al entrar en la rama de relevo y el enviador
anota la respuesta del gestor cuando el envío sale de verdad: en tiempo real, así el
orden cronológico sale solo y no hay que detectar la transición ni ponerse al día.

La respuesta del gestor se guarda como mensaje `ai` **con el texto tal cual y sin marca
dentro**. La memoria tiene que contener lo que el cliente recibió; meter una anotación
nuestra ahí es el mismo error que guardar el texto combinado de v1, y el modelo se lo
repetiría al cliente.

**Para qué sirve esa memoria y para qué NO.** Sirve para la continuidad -- quién es, de
qué se está hablando, qué ya ha dicho. **No** para hechos: citas, huecos y precios salen
siempre de una herramienta (regla 2 de `lucia-v2.md`). Probado en `dev`: tras un relevo,
Lucía no vuelve a pedir el nombre ni el día y llama a `consultar_disponibilidad` para lo
demás. Si contestara una hora de memoria sería un FALLO, no un acierto: estaría
confirmando una cita que puede no existir.

**Agujero abierto que la memoria no tapa: el gestor puede decir "ya está apuntada" sin
apuntarla.** Es texto libre de una persona y el sistema no se entera. No es problema del
agente sino de la interfaz: **la bandeja tiene que enseñar las citas del contacto al lado
del hilo** (la sesión ya tiene `contact_id`), para que el gestor vea si existe o la cree
mientras contesta. Va con la extensión de Directus.

Queda avisar a Lucía de que ahí habló otra persona, y el aviso correcto **no** es "lo que
se dijera vale" sino *"no está necesariamente reflejado en el sistema: comprueba con tus
herramientas antes de confirmar nada"*.

**Dos trampas que costaron la tarde y volverán:**
- **Una lista explícita de `fields` convierte una columna nueva en un valor por defecto,
  sin error.** `HTTP · Cargar sesión` no pedía `modo`, así que llegaba `undefined`,
  caía a `auto` y el relevo no se activaba nunca sin nada anómalo que mirar.
- **La vista por defecto de una colección nueva no enseña lo importante.** Directus
  elige las primeras columnas y el texto del mensaje se quedaba fuera: una lista de
  mensajes sin mensajes. Las columnas se fijan en `configure-directus-presets.sh`.

## Latencia: cada salto de sub-workflow cuesta ~100 ms (medido 22/sep/2026)
Medido en `demo` con una reserva real, leyendo `execution_entity` (los tiempos **anidan**:
un sub-workflow cuenta dentro de su padre, así que se restan, no se suman):

| tramo | ms |
|---|---|
| Entry (turno entero) | 7573 |
| └ Core v2 | 6466 |
| &nbsp;&nbsp;└ **el LLM** (Core menos la tool) | **~4100** |
| &nbsp;&nbsp;└ `LUCÍA · TOOL · Reservar` | 2325 |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `22` | 1521 |
| &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;└ `17` | 988 (de los cuales `16` son 623) |
| └ fontanería de Entry | ~1100 |

**El dato que lo explica todo: `06`, `08` y `09` tardan 108-132 ms cada uno y solo hacen
UNA consulta a Directus.** O sea que el peaje de un salto de sub-workflow es ~100 ms haga
lo que haga. Con `EXECUTIONS_MODE=regular` cada uno es una ejecución completa en el proceso
principal que además escribe en Postgres. **La palanca son los saltos, no las consultas**
-- todas las columnas calientes ya están indexadas (Directus las crea desde `is_indexed`
del esquema; `booking-indexes.sql` no las lista y eso engaña).

Lo quitado, todo trabajo **demostrado** muerto y nada de lógica compartida tocada:
- Entry resolvía el contacto con `17` en CADA turno: seis ejecuciones para saber algo que
  la fila de sesión ya tenía. Ahora solo si falta.
- Las dos tools llamaban a `27` aunque nadie nombrara un profesional, y el código de `27`
  devuelve pronto en ese caso -- una ejecución y dos consultas tiradas por reserva.
- **`17` tiene ahora `sin_contexto`**, que salta `16` (y con él `06`+`08`+`09`): ~600 ms de
  una tool de 2,3 s. `16` trae las tareas y las citas del contacto, y el camino de reserva
  **no las lee**. Es aditivo: quien no pase la bandera se comporta igual que siempre, y
  solo se apuntaron `22` y Entry tras comprobar que ninguno usa `context`. `18`, `19`,
  `20`, `23`, `24` y `25` siguen con contexto hasta que alguien los verifique uno a uno.

  **Y traía un fallo que tardó un día en verse** (23/sep/2026): en la rama en que hay que
  BUSCAR el contacto, `07 · CONTACT · Search` devuelve cada resultado envuelto --
  `{ contact: {...}, primary_phone, phones }` -- y `Code · Solo id` leía `results[0].id`
  en vez de `results[0].contact.id`. Devolvía `not_found` con el contacto delante:
  `status: 'single'`, `count: 1`, y a la basura. Afecta a TODO el que pida `sin_contexto`,
  Entry incluido, no solo a la voz.

  Lo que lo hizo invisible: **una optimización que devuelve una respuesta bien formada y
  equivocada pasa cualquier medición de latencia con nota.** Se comprobó que tardaba menos;
  no que siguiera acertando. Y el síntoma aguas abajo --"el contacto no se enlaza"-- se
  parece demasiado a un permiso, a un teléfono sin prefijo o a un tenant desactualizado:
  fueron los tres diagnósticos que gasté antes de mirar la ENTRADA REAL del nodo, que es
  donde estaba la respuesta desde el principio.

Resultado medido después de los tres cambios, misma reserva por WhatsApp:

| | antes | después |
|---|---|---|
| `LUCÍA · TOOL · Reservar` | 2325 | **1286** |
| `22` | 1521 | **762** |
| `17` | 988 | **270** |
| `16` + `06`+`08`+`09` | ~980 | **0 ejecuciones** |
| Entry (turno entero) | 7573 | **5554** |

**Solo ~1 s de ese −27% es atribuible.** El LLM pasó de ~4141 a ~3288 ms entre las dos
medidas y eso es varianza entre llamadas, no mérito del cambio. Lo ganado de verdad es
**un segundo de tool**. Al leer estas medidas conviene recordarlo: el tramo del LLM se
mueve solo, y comparar totales sin restarlo invita a atribuirse lo que no es tuyo.

**Y lo que esto significa para voz**: en una llamada, los ~3-4 s del LLM casi desaparecen
--la plataforma empieza a hablar en cuanto llegan los primeros tokens-- pero **los segundos
de la tool son silencio**. Así que optimizar tools no era preparar la voz: es lo ÚNICO de
la latencia que la voz no perdona.

**Dónde está el suelo ahora**: la reserva son ~5 saltos y ~1,3 s. Bajar más significa
aplanar workflows compartidos (`22 -> 03` son 93 ms, `26` son 91) -- no compensa el riesgo
por 90 ms. El siguiente tramo gordo es el LLM, y ahí n8n no pinta nada.

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
- `n8n/render-workflows.sh --tenant X [--only TEXTO] [--apply]` — Git → tenant,
  importa por CLI y **publica** (sustituye a importar 41 JSON a mano por la UI).
  `--only` acota por subcadena del nombre de fichero (`--only Entry,WHATSAPP`),
  que es lo normal al iterar sobre un workflow: importar y republicar los 41 más
  el reinicio son minutos por un cambio de un fichero. Renderiza igualmente el
  conjunto entero —los controles de secretos y de residuo del tenant valen
  porque miran todos— y solo importa y publica lo elegido. Da por hecho que los
  sub-workflows de los que dependa ya están publicados en ese tenant, así que la
  primera pasada de un tenant nuevo va sin `--only`. El reinicio del contenedor
  sigue siendo obligatorio, también para uno solo.
- `n8n/export-workflows.sh --tenant X` — tenant → forma de Git. **No escribe en
  el checkout del VPS** (que se resetea duro): deja el resultado aparte para
  traérselo por `scp`, como `snapshot-schema.sh`.

Los `webhookId` no llevan token, simplemente dejan de nombrar al tenant. Los
**nombres** de credencial tampoco (`Directus`, `WhatsApp`), pero sus **`id`** sí:
n8n resuelve una credencial por `id` y **NO por nombre**, al contrario de lo que
afirmaba el README heredado — se vio con `Credential with ID
"REPLACE_WHATSAPP_CRED" does not exist` teniendo la credencial `WhatsApp`
delante. Los otros 29 nodos funcionaban solo porque llevaban dentro el id de
`demo`; en otro tenant habrían fallado igual. Así que el id va en
`__CRED_<NOMBRE>__` y `render-workflows.sh` lo resuelve leyendo
`n8n export:credentials` del tenant (de ahí solo salen id y nombre; el blob
cifrado no sale del contenedor).

**Publicar es un paso aparte, y obligatorio.** En n8n 2.x `import:workflow` no
publica, y un workflow sin publicar ni se ejecuta ni registra su webhook
(`Workflow is not active and cannot be executed`) — así que sin publicar, Lucía
se queda sin herramientas y WhatsApp deja de entrar. Tres cosas, y las tres
hacen falta (`render-workflows.sh --apply` las hace):
1. `publish:workflow --all` está deprecado ("no longer supported"): uno a uno
   por `--id`. `update:workflow --active=true` es ya solo un alias de publish.
2. **En orden de dependencias**: n8n no publica un workflow cuyos sub-workflows
   no lo estén. Alfabético sale mal (`AGENT-Lucia-Core-v2` antes que las siete
   `LUCIA-TOOL-*` de las que depende), así que lo calcula `workflow-order.py`
   del grafo de nodos `executeWorkflow`/`toolWorkflow`.
3. **Reiniciar el contenedor**: el CLI escribe en la BD y el proceso en marcha
   no se entera — lo avisa él mismo. Sin reinicio el import parece correcto y
   el webhook devuelve 404.
Excluye `SESSION · Cleanup`, cuyo schedule borra sesiones y nunca se ha probado.

Por eso **`active` no se versiona** (lo metí primero por no perder información;
fue un error): un `active: false` viajando en Git despublicaría herramientas que
funcionan. Quién está publicado es estado del instance, no de la definición.

**Un export trae los secretos del tenant en claro.** Los campos de un nodo
`Config` los guarda n8n tal cual (no son credenciales cifradas), así que
`WHATSAPP · Adapter` viene con el `phone_number_id`, el `verify_token` y el
token de Meta reales, donde el repo tiene `REPLACE_*` a propósito. Se detectó
mirando el primer export de verdad, a un `git commit` de publicarlos.
`normalize` los devuelve a su placeholder (`SECRET_FIELDS`) y, por debajo,
detiene el proceso sin escribir nada si ve algo con forma de secreto que no
conoce (`EAA…`, `sk-…`, `ghp_…`, JWT). Ese segundo control no tiene escape:
un secreto en Git no se arregla revirtiendo el commit.

**Lo que hace que esto no se pudra es la dirección de vuelta**, y en concreto
que `export-workflows.sh` FALLE si tras normalizar sigue apareciendo el id del
tenant. Sin esa comprobación, la próxima captura devuelve el hardcode a Git y no
se nota hasta que falla un tenant nuevo. Si se añade un valor propio del tenant,
su regla va en `workflow-tokens.py` — nunca se arregla a mano en el JSON.

Los flags del CLI de n8n se comprueban contra `--help` del binario antes de
usarlos, no contra la documentación.

## Voz: la plataforma trae su LLM, nosotros ponemos las tools (22/sep/2026)
**Un agente de voz NO puede llamar a Entry.** El turno del Core v2 son ~5,5 s medidos: en
un chat se tolera, por teléfono el que llama cuelga. Así que en voz **la plataforma
(Retell, ElevenLabs Agents…) trae su propio bucle LLM** con streaming y nuestras siete
tools son sus *custom functions*. No es un apaño: es la arquitectura de v2 servida por
HTTP en vez de por `Execute Workflow`.

`n8n/workflows/TOOLS-Dispatcher.json` -> `POST /webhook/tool`. Contrato completo en
`n8n/TOOLS-DISPATCHER.md`. Lo que importa recordar:

- **`identidad.telefono` lo rellena la PLATAFORMA desde los metadatos de la llamada, nunca
  el modelo.** Misma regla que WhatsApp. Si se cablea como un parámetro que el LLM pueda
  escribir, cualquiera que llame opera sobre las citas de otro -- el mismo agujero que se
  cerró validando la firma del webhook de WhatsApp.
- Una credencial **Header Auth `Tool Dispatcher`** por tenant, a mano en la UI (token
  `__CRED_TOOL_DISPATCHER__`). El webhook es público.
- La respuesta de la tool se devuelve **tal cual**: sus contratos ya están hechos para que
  un LLM decida qué decir.
- `session_key` es `voz:<telefono>`: una llamada y un WhatsApp del mismo cliente son hilos
  distintos pero **el mismo contacto**.

### El resumen de la llamada acaba en Directus (23/sep/2026)
**Retell no puede transcribir sin grabar.** Sus opciones de almacenamiento son `Everything`,
`Everything except PII` y solo metadatos: no hay "transcripción sin audio". Y venía en
`Everything` + `Keep forever`, o sea grabando y guardando indefinidamente sin que el saludo
lo dijera. De ahí el diseño: **retención corta donde está el dato crudo, retención larga
donde solo queda un resumen.**

    Retell (audio + transcripción, retención corta)
      -> webhook `call_analyzed`
      -> `VOZ · Nota de llamada`  -> Directus `call_notes` (solo el resumen, ~1 año)

Lo que hay que saber si se toca:
- **`call_notes.contact_id` es ON DELETE CASCADE**, la única relación hacia `contacts` que
  no es `SET NULL`. Un resumen sin dueño es un dato personal huérfano, no un registro de
  negocio. El precio, asumido: borrar el contacto borra también la prueba de que hubo
  llamada.
- **`call_id` es UNIQUE** porque el webhook se reintenta. El workflow además consulta antes,
  pero lo que de verdad impide el duplicado es la restricción, no la consulta: dos
  reintentos simultáneos pasan los dos por la comprobación.
- **La respuesta al webhook dice la verdad**, y eso no es cosmético: Retell reintenta ante un
  error, y con retención corta ese reintento es la única red si Directus estaba caído.
  Contestar 200 a un fallo convierte algo recuperable en un resumen perdido para siempre.
- El contacto lo resuelve **`17 · CORE · Resolve Context` con `sin_contexto`** -- el mismo
  resolutor que las tools, para que la nota y la conversación no discrepen sobre quién llamó.
- **Un teléfono español entra sin el 34 la mitad de las veces**, y eso rompe la identidad
  sin dar un solo error. En `demo` la variable de prueba traía `683187144`: la clave del
  hilo salió `voz:683187144` en vez de `voz:34683187144`, el contacto está guardado como
  `+34683187144`, y nadie quedó enlazado. Ni excepción ni log: una conversación correcta
  colgando de nadie. Ahora los dos sitios que resuelven identidad (`Code · Validar` del
  despachador y `Code · Normalizar` de la nota) normalizan a E.164 con una regla
  deliberadamente estrecha -- 9 dígitos que empiezan por 6/7/8/9 son españoles, el resto se
  deja como viene. En una llamada real `from_number` ya llega en E.164; el problema es todo
  lo demás: variables, formularios, webchat.
- **El contacto de la sesión se enlaza también cuando la sesión YA existía.** Ponerlo solo
  al crearla deja huérfano para siempre un hilo nacido en mal momento -- el contacto aún no
  existía, o el flujo se rompió a medias. Entry no lo sufre porque hace `PATCH` en cada
  turno; en voz solo hay una pasada por llamada, así que hay que decirlo explícitamente.
- **De dónde sale el teléfono hay que copiarlo del despachador, no reinventarlo.** La
  primera versión de la nota miraba solo `call.from_number` y en las pruebas por webcall
  salía siempre sin contacto, mientras la tarea creada en esa MISMA llamada sí lo
  encontraba: una webcall no tiene número y el teléfono llega en
  `retell_llm_dynamic_variables.telefono`. La regla ya estaba resuelta en
  `Code · Validar` del despachador y no se trasladó. Y de paso apareció un segundo
  fallo que en pruebas entrantes no se ve nunca: **en una llamada SALIENTE el cliente es
  `to_number`**, así que usar `from_number` habría guardado nuestro propio número en su
  ficha.

**Una llamada también se lee como conversación.** El payload de Retell trae SIEMPRE el
`transcript_object`, así que los turnos se escriben en `conversation_messages` con
`canal: voz`, bajo el mismo `session_key` (`voz:<telefono>`) que usan las tools. No es un
concepto nuevo: es la bandeja de siempre con un canal más, y evita la asimetría de guardar
cada palabra de un WhatsApp y solo un resumen de una llamada.

Dos detalles que parecen menores y no lo son:
- **Los turnos se insertan de uno en uno, no en un POST con el array.** `created_at` lo pone
  Directus (`date-created`, y sobrescribe lo que le mandes), así que un único POST deja todas
  las filas en el mismo instante y el hilo se lee desordenado. Una fila por item hace que el
  nodo HTTP las inserte en orden.
- **`canal_message_id` es `<call_id>#<índice>`**, y eso es lo que permite reconocer por
  prefijo que los turnos de esa llamada ya estaban escritos. Hace falta porque la nota se
  escribe DESPUÉS: si fallara justo ahí, el reintento de Retell volvería a pasar por aquí.

**La firma de Retell: `HMAC-SHA256(cuerpo + marca_de_tiempo, api_key)`, en ESE orden.** La
cabecera es `x-retell-signature: v=<ms>,d=<hex>`. Se tardó en dar con ello porque el `v=`
delante invita a suponer que la marca va primero -- se probaron tres variantes con la marca
delante y ninguna cuadraba. **Dos trampas más, que están en la documentación y no en el
payload**: solo vale **la API key que lleva el distintivo de webhook** en el panel (si hay
varias claves, las otras no verifican nada), y hay que **rechazar marcas de más de 5
minutos**, o una petición legítima capturada una vez se puede reenviar para siempre.

Lo que hizo que esto se resolviera en dos intentos y no en diez: el veredicto sale en cada
ejecución con `firma_detalle` -- qué forma tenía el cuerpo, cuánto medía, la cabecera cruda
y los primeros 12 caracteres de cada digest candidato. Con eso, "el cuerpo llega mal" y
"firmamos otra cosa" dejan de confundirse. **Y cuando fallaron las CUATRO candidatas a la
vez, eso dejó de ser una pista sobre la concatenación y pasó a serlo sobre el secreto**: es
la señal de que tocaba ir a la documentación en vez de seguir probando.

**La firma se exige** (`require_signature: true`, confirmado en `dev` el 23/sep/2026 con
`firma_variante: cuerpo+ts`). Consecuencia que hay que tener presente al montar un tenant:
**sin `RETELL_API_KEY` en `secrets/retell.env` las llamadas dejan de dejar nota**, porque la
firma no valida y el evento se descarta -- igual que el App Secret de WhatsApp, y por eso
`render-workflows.sh` lo avisa en el plan con esas palabras.

**Orden de despliegue, y no es intercambiable**: montar el pipeline en `dev` -> ver la nota
escrita en Directus -> **entonces** bajar la retención de Retell. Al revés se tiran datos sin
red, y el propio panel avisa de que el borrado no es reversible.

**Tres capas, y solo una es cara de cambiar**: operador (bajo -- es un trunk SIP),
plataforma de agente (**alto** -- prompt, tools y comportamiento), lógica de negocio (cero,
ya está). De ahí el orden: **no empezar por el número**.

Y **`<Say>` de Twilio con voces de ElevenLabs NO es una alternativa** a una plataforma de
agente: `<Say>`+`<Gather>` es petición/respuesta, 1,5-3 s por turno y **sin barge-in**. Un
agente de verdad usa media streams bidireccionales. Esa integración sirve para locuciones
sueltas ("le paso con un compañero"), no para conversar.

**El prompt de voz es otro fichero**, `n8n/prompts/lucia-voz.md`, y **no lo carga n8n**: se
pega en la configuración del agente de la plataforma. No es `lucia-v2.md` reformateado --
el canal cambia cosas de fondo: una lista de quince huecos no se lee por teléfono (se dicen
dos o tres y se ofrece mirar más), no se puede releer nada (hay que **confirmar en voz alta
antes de actuar**), interrumpir a alguien cuesta (frases cortas), deletrear en español es
una tortura (**nada de correos por voz**: el resguardo va por WhatsApp al mismo número), y
**hay que decir que es una máquina** al empezar.

Lo que NO cambia: los contratos de las tools y los motivos de error son los mismos. Si se
añade un motivo en `lucia-v2.md`, va también en el de voz.

**El prompt y las funciones de la plataforma se despliegan JUNTOS.** Probado el
22/sep/2026 y es el peor fallo posible: en Retell estaban creadas solo las tres tools de
lectura, el prompt nombra las siete, y el modelo **anunció la reserva, dijo la frase de
espera y no llamó a nada**. No hay error, ni log, ni 4xx -- solo un cliente que cuelga
convencido de tener cita. Por WhatsApp esto no puede pasar (la tool está cableada en el
mismo sitio que el prompt); en voz el cableado vive en otra plataforma y puede discrepar.
Antes de dar por buena una configuración, **una llamada de prueba por cada tool que el
prompt nombre**. Detalle que volverá: cuando un turno no avanza el cliente repite, y en la
repetición el ASR se equivoca más -- aquí "sí, resérvala" se transcribió *"Cierreserva"* y
el modelo lo leyó como cancelar.

**Transferencia a una persona: resuelta (24/sep/2026).** `Transfer Call` de Retell no
funciona en llamadas web -- solo con un número de teléfono real detrás -- así que hasta
tener el número de Zadarma asociado no era probable ni siquiera testearlo. Con el número
asociado, el `Displayed Caller ID` en "Retell Agent's Number" seguía enseñando un `+44`:
no es un fallback de Retell, es el **CallerID por defecto de la cuenta de Zadarma**, que
Zadarma usa cada vez que la cabecera `From` no le llega en E.164 exacto o no coincide con
`P-Asserted-Identity`. Se arregla en el panel de Zadarma (ajustes de la SIP trunk ->
CallerID por defecto -> el número real), no en Retell. Si algún día vuelve a salir un
número que no es el nuestro, mirar ahí primero.

**Confirmación por WhatsApp de lo hecho por teléfono (24/sep/2026).** Reservar, mover o
anular una cita por voz manda una plantilla al mismo número: `aegora_cita_confirmada`
(reserva y cambio) o `aegora_cita_anulada`. Tres decisiones:
- **Se dispara en el despachador DESPUÉS de `Responder`, y sin esperar**
  (`waitForSubWorkflow: false`). Retell ya tiene su respuesta: la voz no paga ni un
  milisegundo por el envío.
- **Solo con `canal: voz` y `ok: true`** en `reservada` / `reprogramada` / `cancelada`. Por
  WhatsApp Lucía acaba de confirmarlo en el mismo hilo, y un `ya_estaba_reservada` ya tuvo
  su confirmación la primera vez.
- **Las plantillas no llevan el nombre del cliente**: un parámetro de Meta no puede ir
  vacío y por voz el nombre no siempre se sabe. Si falta cualquier dato de la cita, no se
  manda nada (`faltan_datos_de_la_cita`, a la vista en la ejecución): mejor sin mensaje que
  con un hueco.

El envío lo hace **`WHATSAPP · Enviar plantilla`**, genérico a propósito: es el mismo
camino que necesitarán el recordatorio y el botón de "cambiar cita". Anota el mensaje en
`conversation_messages` bajo el hilo `whatsapp:<tel>` (creándolo si no existe) **y en la
memoria del Core** de ese hilo: si el cliente contesta "vale, gracias", el gestor y Lucía
ven a qué contesta. Un envío fallido queda `fallido` con el error de Meta y **no se
reintenta solo**, igual que en `HUMANO · Enviar pendientes`. Un tenant sin
`secrets/whatsapp.env` no intenta nada (`tenant_sin_whatsapp`).

**Mientras Meta no apruebe las dos plantillas, todos los envíos saldrán `fallido`.** No
rompe nada, pero el prompt de voz NO debe prometer la confirmación hasta que estén
aprobadas: es el mismo fallo que las tools que no existían.

### VIP y números bloqueados: se decide ANTES de descolgar (25/sep/2026)
`VOZ · Llamada entrante` (`POST /webhook/retell-inbound`) es el *inbound webhook* de Retell.
Bloqueado (`numeros_bloqueados`) -> se rechaza. `contacts.trato = vip` con `gestor_id`
activo y con teléfono -> agente pasarela (`RETELL_AGENTE_PASARELA` en `secrets/retell.env`):
un Conversation Flow cuyo nodo inicial es un Transfer Call a `{{destino_transferencia}}`, que
**no habla** -- el VIP no oye a ninguna IA. Retell no puede transferir sin agente: el webhook
solo rechaza o elige agente, así que "transferir y ya está" es ESTE agente mudo. El resto -> Lucía con nombre, empresa y
servicios como variables dinámicas. Detalle y montaje en Retell: `n8n/prompts/lucia-voz.md`.

La regla que lo gobierna todo: **falla hacia Lucía**. Un error nuestro nunca rechaza ni
desvía una llamada; como mucho la deja sin contexto. Y por eso **el número conserva a Lucía
como agente inbound**: es lo que Retell conecta si el webhook no contesta. La pasarela no es
obligatoria -- sin ella los VIP los atiende Lucía sabiendo que lo son.

`numeros_bloqueados` es una colección aparte y no un campo de `contacts` a propósito: el
spam casi nunca es un contacto, y crear una ficha para bloquear un número es meter datos
personales de alguien a quien precisamente no se quiere tratar.

### Resumen diario al equipo por WhatsApp (24/sep/2026)
`RESUMEN · Diario al equipo` manda cada día a las 8:00 (hora de Madrid, `settings.timezone`
del workflow) la plantilla `aegora_resumen_diario` a cada empleado con
`whatsapp_notifications` activado y teléfono relleno. El campo ya existía en `employees` y
no lo usaba nada; ahora tiene una nota que explica qué hace.

Decisiones:
- **Un resumen por empleado**, con SUS citas (recurso `primary`; un `participant` acompaña,
  no atiende) y SUS tareas. Para ir de una cita a quien la atiende hace falta leer
  `appointment_resources`, así que n8n tiene ahora `read` sobre esa colección.
- **Solo los días con algo**: citas hoy, tareas que vencen hoy o tareas vencidas. Una tarea
  pendiente sin plazo no dispara el resumen por sí sola, porque estaría ahí todos los días.
- **Los datos van en líneas fijas del cuerpo de la plantilla, no en un parámetro.** Meta NO
  admite saltos de línea, tabuladores ni más de cuatro espacios seguidos dentro de una
  variable, así que "la lista de citas en `{{1}}`" no se puede hacer. Por eso es un
  recuento (citas, primera hora, pendientes, vencidas) y el detalle está en el panel.
- **Si una consulta a Directus falla, el workflow falla a la vista.** Un resumen montado
  sobre una lista vacía por un 403 le diría "no tienes nada hoy" a quien tiene seis citas.
- El `Execute Workflow` va con **`mode: each`**. Por defecto manda todos los items a UNA
  ejecución del sub-workflow, que lee uno solo: con tres empleados le llegaría al primero.

**Hueco conocido, a propósito:** si el empleado CONTESTA a la plantilla, su mensaje entra
por el adapter de WhatsApp como si fuera un cliente y le responde Lucía. No rompe nada, pero
es feo. La siguiente fase es reconocer los teléfonos de los empleados en el adapter y
desviarlos a un flujo determinista que mande el detalle del día como texto libre (su
respuesta ya ha abierto la ventana de 24 h). Ese detalle tiene que salir de consultas, no
redactado por un modelo.

Sigue pendiente **enviar la política de privacidad por WhatsApp** cuando preguntan por sus
datos: necesita su propia plantilla (con la URL) y una tool que la dispare, porque no nace
de ninguna acción sobre una cita.

Pendiente antes de elegir plataforma: **webcall primero, sin teléfono** (los dos tienen SDK
web y ya existe la web del webchat), que quita de en medio toda la capa regulatoria; y un
bake-off Retell vs ElevenLabs con el mismo prompt y las tres tools de solo lectura, juzgado
por calidad de voz en español y latencia desde España. Lo demás que hay que resolver sí o
sí: aviso de que es una máquina (obligación de transparencia del Reglamento de IA, en vigor
desde agosto -- verificar con fuente legal), transferencia a una persona desde el día uno,
no pedir correos por voz (**confirmar por WhatsApp al mismo número**, que ya está montado),
y el número: **una gestoría no cambia el teléfono impreso en su puerta**, así que desvío
desde el suyo, no portabilidad.

## Tres tenants con alcances separados — decidido 18/sep/2026
`demo` era a la vez escaparate y banco de pruebas, y eso significa que una demo a un
cliente se puede romper porque estábamos tocando. Se separan:

| tenant | para qué |
|---|---|
| `demo` | demos a clientes. **No se toca para desarrollar.** |
| `dev` | desarrollo. Todo se hace aquí primero. |
| `ops` | la operación del propio negocio Aegora (lo que iba a ser `aegora-internal`). |

Eliminados (20/sep/2026): `aegora-internal` con `delete-tenant.sh`, y el stack `aegora`,
que no era un tenant sino la instalación original anterior al incidente — definida en
`compose/directus` y `compose/n8n`, con bases sin sufijo y roles `directus_app`/`n8n_app`.
`delete-tenant.sh` **se niega** a borrar el id `aegora` (protegido), y hace bien:
`aegora-postgres` y `aegora-caddy` comparten ese prefijo y son plataforma viva. Su
desmontaje fue manual; de `compose/` solo quedan `caddy` y `postgres`, que sí están en uso.

Dos cosas del legacy que NO se tocan: la red `aegora_backend` (dentro está
`aegora-postgres`) y **`/opt/aegora/secrets/restic.env`**, que era su configuración restic y
es a la vez el fichero de credenciales S3 compartido (`GLOBAL_BOOTSTRAP_CONFIG`) del que
dependen `demo` y `dev`.

**El camino de promoción es `dev -> git -> demo/ops`**, y ya existe:
`export-workflows.sh` + `snapshot-schema.sh` para capturar, `render-workflows.sh` +
`apply-schema.sh` para aplicar. Nada se edita a mano en `demo` ni en `ops`.

### La regla, en concreto: qué puede tocar `demo` y qué no

La regla general se olvida en cuanto `demo` se vuelve el tenant interesante. Pasó el
22/sep/2026: con la gestoría cargada y WhatsApp real, el despachador HTTP -- **código
nuevo sin probar** -- se desplegó ahí primero, igual que las optimizaciones de latencia.
Nadie lo decidió; simplemente era donde estaba la atención.

Así que la distinción práctica no es "no toques demo", que es demasiado vago:

| en `demo` | |
|---|---|
| **Leer**: medir ejecuciones, consultar la BD, mirar el panel, `--help`, cualquier dry-run | **sí, siempre** |
| **Aplicar algo ya probado en `dev`** (esquema, workflows, permisos, seeds) | **sí, es el camino** |
| **Estrenar** un workflow, un script o un cambio de esquema | **NO. A `dev` primero, aunque parezca trivial** |
| Editar a mano cualquier cosa | **nunca** |

La prueba para saber en cuál estás: **¿esto ya ha corrido en `dev`?** Si la respuesta es
no, no va a `demo` todavía -- por pequeño que parezca y aunque `dev` esté sucio de
pruebas. Para eso existe `reset-tenant-data.sh`.

Y un aviso para quien escriba los comandos (yo incluido): **si en una sesión te descubres
escribiendo `--tenant demo` para algo que acabas de crear, párate.** Ese es el síntoma.

### `--only` es para iterar en `dev`; a `demo` y `ops` se promociona ENTERO
`render-workflows.sh --only` existe para no reimportar 45 workflows por cada cambio de un
fichero mientras se itera. Usarlo para **promocionar** convierte el tenant destino en una
mezcla de versiones de días distintos, y no hay nada que lo avise: cada workflow importado
funciona, lo que falla es la combinación con los que se quedaron atrás.

Pasó el 23/sep/2026: `17 · CORE · Resolve Context` cambió el 22/sep y a `demo` solo le
habían llegado tres workflows por `--only` desde entonces. El síntoma --"el contacto no se
enlaza en demo y en dev sí"-- se leyó sucesivamente como permiso, como teléfono sin prefijo
y como esquema, antes de ver que `demo` corría sub-workflows de otra semana.

La regla:

| destino | cómo |
|---|---|
| `dev` | `--only` libremente, es para eso |
| `demo` / `ops` | `render-workflows.sh --tenant X` **sin `--only`**: PLAN, revisar la línea de secretos de WhatsApp y Retell, y `--apply` |

Un render completo publica los 45 (menos `SESSION · Cleanup`) y reinicia n8n: se hace en un
momento en que no haya una demo en curso. Si algo en `demo` está despublicado a propósito,
va a volver a activarse, y eso tiene que estar escrito aquí para que no sorprenda.

**`onboard-tenant.sh` va por detrás de los scripts que existen.** Encadena create, deploy,
esquema, acceso técnico, UI, español, booking, publicación, backup y operaciones — pero NO
llama a `configure-n8n-service.sh` (sin él Lucía no puede leer nada), `configure-tenant-role.sh`,
`configure-directus-views.sh`, `configure-directus-presets.sh` ni `render-workflows.sh`. Un
tenant creado solo con él sale sin permisos para el agente y sin workflows. Levantar `dev` y
`ops` a mano es la oportunidad de fijar el orden real antes de encerrarlo en el orquestador.

**Crear un tenant limpio destapa lo que `demo` tapaba.** Cuatro en el primer intento con
`dev`, ninguno visible desde `demo`: el rol booking obligatorio en los backups, los scripts
de configuración encadenados sin esperar a que Directus vuelva de un reinicio, la receta de
snapshot con tubería en el mensaje final de `configure-directus-views.sh`, y la publicación
sin comprobar DNS. Conviene esperar más, y son justamente el motivo de hacerlo a mano.

**El DNS de un tenant son CUATRO subdominios, no el dominio a secas**: `panel.`, `n8n.`,
`lucia.` y `reservas.` bajo `${BASE_DOMAIN}`. Un comodín `*.<dominio>` los cubre. Si faltan,
todo se despliega y publica correctamente y el tenant es inalcanzable: Caddy no puede pedir
certificado porque nadie llega hasta él, así que su log ni siquiera tiene errores.
`publish-tenant.sh` ahora lo comprueba y lo dice al final.

Primer ejemplo, en el primer
intento: `backup-tenant.sh` exigía `POSTGRES_BOOKING_USER`, que `create-tenant.sh` dejó de
escribir cuando Booking V1 pasó a usar `directus_<tenant>`. `demo` y `aegora-internal` son
anteriores al cambio y lo tienen, así que sus backups funcionaban; el backup de cualquier
tenant creado después habría muerto en la primera ejecución. Corregido: el rol booking es
opcional. Conviene esperar más de estos, y son justamente el motivo de hacerlo a mano.

**Borrar un tenant deja residuos que hay que conocer**: `delete-tenant.sh` ya para sus
timers de systemd (antes no, y `aegora-internal` siguió fallando backups cada noche tras
borrarlo), pero NO borra su bucket remoto (a propósito) ni sus certificados de Caddy (que
caducan solos en 90 días).

**Ojo con `booking_<tenant>`**: los tenants creados antes del cambio a Booking V1 conservan
esa base Y las referencias en `tenant.env` y en su `backup.manifest.json` -- que incluye la
base **y un `persistent_path`**. Borrar la base sin quitar las dos referencias deja el
backup del tenant fallando. Pasó con `demo` el 18/sep, por recomendar el `dropdb` leyendo
solo media frase de este documento.

Backups por tenant: `demo` está en lista blanca para las credenciales S3 compartidas;
cualquier otro exige `--allow-shared-s3-credentials` o `--s3-credentials-file`. `dev` va con
compartidas (no tiene datos de valor por diseño); **`ops` debe llevar credencial dedicada**,
porque es el único tenant cuyos datos son de Aegora y valiosos. Crear esa llave en Hetzner
ANTES de lanzar el onboarding, o para en la etapa 7/8.

## Datos de demostración por vertical — pedido, sin construir (21/sep/2026)
Dos conjuntos para enseñar la plataforma a un cliente sin que parezca un tenant vacío:

- **Gestoría**: 3 empleados (Arturo, Juan, Carlos), servicios típicos del ramo,
  disponibilidad y una KB de gestoría.
- **Gimnasio**: **clases en bloque con N plazas** — varias personas se apuntan al mismo
  hueco.

**El de gimnasio NO se puede montar con datos: le falta motor.** El modelo V1 es
`service_resources` como pool OR y una cita ocupa un recurso; una clase de 19:00 con 12
plazas es otra cosa -- la capacidad vive en el hueco, no en el recurso. `availability` hoy
devuelve libre/ocupado, no plazas restantes, y `book` bloquea el hueco con la primera
reserva. `appointment_resources.role = participant` **no sirve** para esto: es un recurso
que acompaña a la cita, no una persona que ocupa una plaza. Es trabajo de
`aegora-booking`, y está en la lista de pendientes como "soporte de clases en grupo".
Conviene decidir dónde vive la capacidad (¿en `services`? ¿en `availability_rules`?) antes
de tocar nada.

**Un tenant solo puede enseñar una vertical a la vez**: servicios, empleados y KB son de
todo el tenant. Así que o son dos tenants de demo (~1 GiB cada uno según el modelo de
capacidad medido) o un script que carga y reinicia el conjunto. Se hizo lo segundo:

- `directus/seed/<conjunto>.json` — los datos. Las referencias entre colecciones van por
  `_ref`/`@ref` y **no por UUID**: los ids los genera Directus al insertar, así que un
  seed con UUIDs dentro solo se podría cargar una vez y en un tenant.
- `directus/seed/load-seed.sh --tenant X --set gestoria [--apply]` — idempotente por clave
  natural. Lo que ya existe se reutiliza y **no se modifica**: si alguien ajustó un horario
  durante una demo, recargar no se lo pisa. No borra nada.
- `directus/seed/reset-tenant-data.sh --tenant X [--apply --yes-destroy-data]` — vaciar.
  Es otra orden y no una bandera de la anterior, porque tiene otros riesgos. Exige la
  segunda bandera aparte **porque `--apply` se escribe cincuenta veces al día y esto no se
  deshace**, y **se niega en seco con `ops`**, el único tenant cuyos datos son de Aegora.
  Borra en una transacción y en orden de claves ajenas: a medias dejaría servicios sin
  recursos, que es peor que no empezar.

Del conjunto de gestoría, lo que lo hace útil: **los tres empleados tienen horarios
distintos a propósito**. Uno donde todos atienden a la vez no enseña nada -- la gracia es
que Lucía ofrezca huecos diferentes según el servicio, porque cada servicio lo dan
personas distintas.

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

## En los Code node de n8n NO hay criptografía (n8n 2.31, task runner)
Dos puertas cerradas, comprobadas ejecutando (en el editor no se ve ninguna):
- `require('crypto')` -> **`Module 'crypto' is disallowed`**.
- **`globalThis.crypto` es `undefined`**, así que tampoco hay Web Crypto.

Lo que sí hay: `TextEncoder`, `Buffer`, `atob` (`typeof` = `function`).

**La salida es el nodo `Crypto` de n8n**, que corre en el proceso principal y no pasa por
el sandbox. `WHATSAPP · Adapter` valida `X-Hub-Signature-256` en tres pasos:
`Code · Clasificar y normalizar` (saca el cuerpo crudo y prepara `_raw`/`_sig`/
`_app_secret`) -> `Crypto · HMAC del cuerpo` (HMAC-SHA256, hex, en `_hmac`) ->
`Code · Verificar firma` (compara en tiempo constante, aplica `require_signature` y
**borra los campos temporales** para que el App Secret no siga viajando).

Detalles que importan si se toca:
- El **GET de verificación** de Meta no viene firmado: lleva `firma: 'no_aplica'` y la
  puerta de `require_signature` lo excluye explícitamente. Exigir firma ahí rompería el
  alta del webhook.
- El nodo Crypto va con `onError: continueRegularOutput`. Si falla, el item sigue sin
  `_hmac` y `Verificar firma` lo dice ("el nodo Crypto no devolvió _hmac") en vez de
  tumbar el webhook.

Hubo una versión con **HMAC-SHA256 en JS puro** incrustado en el Code node (commit
8808fff). Funciona y está verificada contra los vectores del RFC 4231, pero es la última
bala, no la primera: se llegó a ella por preferir la opción demostrable en local antes que
la ortodoxa. Si algún día el nodo Crypto no sirve, está en el historial.

Tercera opción, no usada: `NODE_FUNCTION_ALLOW_BUILTIN=crypto` en el `.env` del
contenedor. Es perfectamente viable en un tenant existente (editar el `.env` renderizado y
reiniciar); se descartó solo porque relaja el sandbox de todos los Code node para arreglar
uno. **No es cierto que no se pueda cambiar la configuración de un tenant ya creado** --
lo que falta es la automatización (`render-tenant-config.sh`), no la posibilidad.

**Antes de apoyarse en cualquier builtin o global dentro de un Code node, probarlo
ejecutando.** Han fallado, por este orden: `$env`, `require('crypto')`, `globalThis.crypto`.

## Cuántos tenants caben en la VPS — medido bajo carga (18/sep/2026)
VPS: **15 GiB, 8 núcleos, SIN swap**. Medido con `scripts/loadtest/webchat-load.sh` contra
`demo`, tres pasadas de 3 turnos por conversación:

| simultáneas | reposo antes | pico n8n | p50 | p95 | errores |
|---|---|---|---|---|---|
| 5  | 502 MiB | 598 MiB | 7,0 s | 12,0 s | 0 |
| 20 | 602 MiB | 786 MiB | 8,0 s | 14,3 s | 0 |
| 40 | 428 MiB | 942 MiB | 12,5 s | 19,0 s | 0 |

**La memoria se devuelve, pero tarda minutos, no segundos.** La tercera pasada arrancó en
428 MiB cuando la segunda "acabó" en 645: n8n soltó 217 MiB en el intervalo. La primera
versión del script miraba una sola vez a los 60 s y habría diagnosticado una fuga
inexistente; ahora muestrea a 30/60/120/180 s. **Al interpretarlo, mirar la curva, no un
punto.**

Modelo utilizable: **n8n ≈ 430 MiB en reposo + ~12 MiB por conversación simultánea**
(marginal decreciente: 12,5 MiB entre 5 y 20, 7,8 entre 20 y 40). Directus se mueve poco
(230->265) y booking nada.

Un tenant con varias conversaciones a la vez cabe en **~1 GiB**, de donde salen
**~11 tenants** ((11,7 GiB de techo al 78 % − 0,75 de SO/postgres/caddy) / 1 GiB). El 78 %
es por no haber swap: sin él no hay aviso previo, se pasa de ir bien a que el OOM killer
mate un contenedor que elige él.

Dos miedos míos que la medición descartó:
- **Las conexiones a Postgres no son el cuello.** 40 conversaciones simultáneas, 120 turnos,
  cero errores, y la memoria de `aegora-postgres` apenas se movió (231->248). La teoría de
  los pools elásticos reventando a los 4 tenants era infundada.
- **La CPU tampoco.** Ni se acercó.

Lo que sí sale mal parado es la **latencia**: 7 s de p50 con solo 5 conversaciones a la vez.
Eso no es carga, es lo que cuesta un turno del agente v2 (LLM + tools encadenados).

`EXECUTIONS_MODE=regular`: todo corre en el proceso principal de n8n, por eso la memoria
escala con la concurrencia dentro de un contenedor. El modo cola (workers + Redis) cambiaría
ese perfil, pero no hace falta a esta escala.

**Pruning de ejecuciones: comprobado y correcto.** `demo` tiene las tres variables
(`EXECUTIONS_DATA_PRUNE=true`, 336 h, 10.000) y la tabla está en 4.042 filas / 1,9 MB con la
más vieja a 10 días. No es un problema. Ojo al orden de magnitud: cada turno son ~10
ejecuciones (adapter + Entry + Core + tools), así que 10.000 son ~1.000 turnos y quien manda
de verdad es el límite de 14 días.

Los dos pendientes que salen de aquí están en la lista de pendientes de más arriba.

## Restaurar un tenant — `restore-tenant.sh` arreglado (20/sep/2026)
Estaba escrito **solo para el layout antiguo**: leía `customers/<tenant>/tenant.env` y
restauraba en `${PLATFORM_ROOT}/compose/<servicio>/`. No podía restaurar `demo` ni `dev`,
cuya configuración vive en `/opt/aegora/tenants/<tenant>/`. Con el tenant legacy eliminado
se quedó además sin ningún destino válido: código muerto con aspecto de vivo, y es el script
al que se recurre con el sistema caído.

Ahora resuelve el layout con `tenant-context.sh`, la misma librería que ya usaban
`backup-tenant.sh` y `restore-test-tenant.sh`. Cambios que importan:
- **`--tenant` es obligatorio.** Antes caía por defecto a `aegora`. Un script que para
  servicios y sobrescribe bases de producción no debe suponer sobre cuál trabaja.
- Llama a `validate_loaded_tenant_context` **antes de tocar nada**: comprueba que el
  `TENANT_ID` del fichero es el pedido y que el repositorio Restic apunta al bucket de ese
  tenant. Es lo que impide restaurar el backup de un cliente encima de otro.
- La base y el directorio de **booking son opcionales** (mismo arreglo que en
  `backup-tenant.sh`). Ojo al detalle: `"${RESTORE_DIR}${BOOKING_DATA_DIR}"` con la variable
  vacía se queda en `${RESTORE_DIR}`, que SÍ existe, y activaba booking en tenants que no
  lo tienen.
- En layout gestionado **no restaura la configuración de Postgres ni de Caddy**: son de
  plataforma y no están en el backup de ningún tenant. Restaurarlas desde aquí sería que un
  tenant pisara la configuración de todos.
- La rama legacy se conserva para poder recuperar un snapshot viejo, y **avisa** de que
  `/opt/aegora/secrets/restic.env` es el fichero de credenciales S3 compartido.

Lo que ya funcionaba y conviene no confundir: `restore-test-tenant.sh` sí era consciente del
layout, hace su propia restauración (hashes SHA-256, `pg_restore` a una base temporal,
recuento de esquemas y tablas) y corre cada semana. La restaurabilidad del dato estaba
probada; lo que faltaba era el procedimiento para devolverlo a su sitio.

**Ensayado de verdad el 20/sep/2026**, y encontró un fallo que ninguna verificación habría
visto. El método: backup fresco, marcador insertado DESPUÉS del backup, un workflow
renombrado, restauración completa, y comprobar las dos direcciones. Las dos salieron bien
(el marcador desapareció, el nombre volvió), pero **Directus y n8n se quedaron en `starting`
con `permission denied for schema public`**.

Causa: `createdb` crea la base a nombre del administrador y `pg_restore --no-owner
--no-privileges` quita propiedad y permisos de todo lo de dentro. La base queda
perfectamente restaurada y su propia aplicación no puede entrar. **Un `--verify-only` jamás
lo habría detectado**: valida hashes y dumps, no que el servicio arranque después.

Arreglado con `apply_database_owner`, que devuelve la propiedad de la base, del esquema
`public` y de cada tabla, secuencia y vista al rol de la aplicación. Los roles se leen de
`secrets/postgres.env` (vía `TENANT_POSTGRES_SECRETS`), que este script no miraba; si no
estuviera, cae a la convención de que el rol se llama como su base. Los flags `--no-owner
--no-privileges` se conservan a propósito: hacen que la restauración no dependa de que los
roles del dump existan, que es lo que uno quiere con el sistema caído.

**Segundo ensayo, con el arreglo: superado entero** (20/sep/2026). 41 workflows de vuelta,
marcador desaparecido, nombre restaurado, **cero objetos con dueño equivocado** en las dos
bases, los tres contenedores sanos solos y el panel respondiendo. Ya no es una suposición:
sabemos recuperar un tenant.

Dos reglas que salieron de ahí:
- **Un ensayo de recuperación no termina cuando el script dice que ha terminado, sino
  cuando el servicio atiende peticiones.** El primer intento devolvió el dato perfecto y
  dejó el tenant muerto; si se hubiera dado por bueno ahí, el fallo habría aparecido con un
  cliente caído.
- En la restauración de configuración, **un fichero que falte en el snapshot no aborta
  nada**: se avisa y se sigue. Quien restaura ya tiene la contraseña del repositorio.

**El manifiesto de backup se genera en `create-tenant.sh`, no se renderiza de ninguna
plantilla.** Había un `templates/tenant-stack/backup.manifest.json` que no usaba nadie y
declaraba ocho ficheros donde el generador declaraba cinco — faltaba `secrets/restic.env`,
así que un tenant restaurado se quedaba sin configuración de backup y dejaba de respaldarse
en silencio. La plantilla se borró. Si hay que añadir algo al backup, se añade en
`create-tenant.sh`.

**Los tenants creados antes de ese arreglo (`demo`, `dev`) tienen el manifiesto corto** y
necesitan la entrada añadida a mano — otra vez lo que resolvería `render-tenant-config.sh`.

## `render-tenant-config.sh` — los cambios de plantilla llegan a tenants existentes
`create-tenant.sh` renderiza la configuración **una sola vez**. Cuando una plantilla mejora,
los tenants ya creados se quedan atrás en silencio y la diferencia se descubre cuando algo
falla. Entre el 18 y el 20/sep/2026 eso fue la causa de seis incidencias distintas (el
pruning de n8n, el App Secret de WhatsApp, el manifiesto sin `secrets/restic.env`...), y
cada una acabó con una edición a mano de un fichero del tenant.

`provisioning/tenant/render-tenant-config.sh --tenant X [--only PIEZA] [--apply]` re-renderiza
`compose/{directus,n8n,booking}/{compose.yml,.env}` y `backup.manifest.json`.

Tres decisiones que lo hacen usable y seguro:
- **De dónde salen los valores, por orden**: `tenant.env` -> `secrets/*.env` -> **el `.env`
  ya renderizado** -> **el contenedor en marcha** (solo `BOOKING_IMAGE`). Los dos últimos
  son los que lo hacen viable: `deploy-booking.sh` calcula `BOOKING_DATABASE_URL` y
  `BOOKING_IMAGE`, que no viven en ningún fichero estático.
  Para heredar del `.env` **se invierte la plantilla** (`invert-template.py`): no se puede
  dar por hecho que la variable y la clave se llamen igual. En `booking/.env.tpl` la línea
  es `DATABASE_URL=${BOOKING_DATABASE_URL}`, así que ese valor vive bajo la clave
  `DATABASE_URL` y buscar `BOOKING_DATABASE_URL=` no encuentra nada, nunca. Las líneas
  compuestas (`URL=https://${HOST}/x`) no se intentan despejar.
  De un `compose.yml` no se hereda: el valor va dentro del YAML.
- **Salvaguarda**: si un valor que hoy NO está vacío quedaría vacío o desaparecería, aborta.
  Un `.env` que pierde `N8N_ENCRYPTION_KEY` deja las credenciales del tenant ilegibles.
  Para perder una clave **muerta** a propósito está `--allow-drop CLAVE[,CLAVE]`, que las
  nombra una a una en vez de desactivar el control: así la decisión queda en el comando y no
  en la memoria de quien lo ejecutó. El primer uso real en `demo` fue exactamente eso —
  `N8N_WEBHOOK_URL` (que n8n ignoraba: su variable es `WEBHOOK_URL`) y `BOOKING_API_BASE_URL`
  (que no aparece en el repo y que `$env` no podría leer de todos modos).
- **No toca contenedores**: dice cuáles hay que recrear y para ahí. Cortar el servicio del
  cliente es una decisión con horario.
  **Y es recrear, no reiniciar** (`docker compose up -d --force-recreate`, no `docker
  restart`). El script decía `restart` y eso lo convertía en un no-op silencioso: Compose
  lee `env_file` **al crear** el contenedor, así que un `restart` reutiliza el entorno
  viejo y el `.env` nuevo se queda en disco sin que nadie lo lea. Se vio en `demo` tras el
  primer `--apply` de verdad: `WEBHOOK_URL` seguía vacía y `N8N_WEBHOOK_URL` seguía puesta,
  exactamente como antes de aplicar. Se comprueba mirando el entorno del contenedor, no el
  fichero:
  `docker exec demo-n8n sh -c 'echo $WEBHOOK_URL'`.
  Los `docker restart` del resto de scripts (Directus tras permisos, n8n tras publicar) sí
  son correctos: ahí lo que se refresca es estado del proceso, no el entorno.

El **manifiesto de backup tiene su propio control**: si el nuevo respaldaría menos que el
actual —una base, una ruta o un fichero que desaparecen— aborta. Es la misma idea que la
salvaguarda de los `.env` y hace más falta todavía, porque perder cobertura de backup no
rompe nada: simplemente deja de copiarse algo y no se descubre hasta que hace falta.
Ahí NO hay `--allow-drop` a propósito: si una entrada sobra, se quita del manifiesto del
tenant a mano, para que sea una decisión y no un efecto colateral de la plantilla.

Los `.env` se muestran en el diff **por clave, nunca con sus valores**.

**El manifiesto de backup pasó a ser una plantilla** (`templates/tenant-stack/backup.manifest.json.tpl`)
que renderizan `create-tenant.sh` y este script. Antes era un heredoc dentro de
`create-tenant.sh` y convivía con una plantilla muerta que decía otra cosa — el origen de
que `secrets/restic.env` no se respaldara. Una sola fuente, y la usan los dos.

## Borrar un contacto cancela sus citas futuras (21/sep/2026)
El derecho de supresión del RGPD obliga al **negocio**, así que el gestor tiene que poder
borrar un contacto sin llamarnos. El primer intento de darle el permiso se revirtió el
mismo día: las claves ajenas ponen `appointments.contact_id` a NULL, y eso es correcto
para una cita pasada -- se va el dato personal, queda el registro -- pero en una cita
FUTURA deja **un hueco reservado para nadie**, en la agenda del gestor, sin saber de quién
era ni a quién avisar. Y en silencio: un borrado, tres citas huérfanas, y nada que lo diga.

Segundo efecto encadenado: la `idempotency_key` de una reserva es
`session_key + start_at`, **sin el contacto**, así que una cita huérfana seguía casando
con la siguiente petición del mismo teléfono y el Booking API la devolvía como idempotente
-- Lucía confirmaba *"tu cita ya está reservada"* de una cita que no era de nadie. **Eso
sigue sin arreglar y es del Booking API**: una cita sin dueño no debería casar con la
petición de nadie. Merece una línea en el contrato cuando se toque ese repo.

El arreglo: **un trigger `BEFORE DELETE` sobre `contacts`**
(`directus/sql/contacts-erasure.sql`) que cancela sus citas futuras -- lo que dicen a la
vez la operativa y la ley: si dejas de tratar sus datos, dejas de guardarle una hora.

**Por qué un trigger y no un Flow de Directus**, que fue la primera idea: es un
**invariante del dato**, no un automatismo de la aplicación. Un Flow solo se dispara si el
borrado pasa por la API -- no desde `psql` ni desde un script de mantenimiento --, hay que
escribirle provisioning propio (los flows NO entran en `schema snapshot`) y es otra
superficie que mantener. El trigger es atómico con el borrado, viaja dentro del `pg_dump`
(un tenant restaurado lo conserva) y **ya había sitio para él**: `apply-schema.sh` aplica
`directus/sql/` de forma idempotente y lo valida en `BEGIN … ROLLBACK` en el dry-run.

De paso, `apply-schema.sh` aplica ahora **todos** los `.sql` del directorio en orden
alfabético, no un fichero nombrado a mano: el segundo habría obligado a tocar el script o,
peor, a meter un trigger dentro de `booking-indexes.sql`.

Lo otro que quedó del primer intento y es bueno: **`conversation_sessions.contact_id` es
ya una M2O de verdad** (antes un uuid suelto sin clave ajena, que además habría enseñado
el UUID en la columna Contacto de la bandeja en cuanto hubiera datos reales).

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
- **Los paneles de terceros (Retell, Meta, etc.) los edita el usuario, no Claude.**
  Automatizar un formulario web cuesta una barbaridad de tokens -- captura, localiza,
  escribe, vuelve a capturar para comprobar -- para algo que una persona hace en un
  minuto, y esos tokens hacen falta para el trabajo que de verdad es difícil. Claude da
  **el texto exacto y dónde va**, en un bloque copiable, y el usuario lo pega.
  Y hay una segunda razón, que apareció el 23/sep/2026: el usuario trabaja en ese panel a
  la vez, así que editarlo desde aquí provoca conflictos de versión ("This draft changed
  while you were editing") en los que alguien pierde trabajo. Si alguna vez hay que tocar
  uno, **el que tiene la versión en Git cede**: `Refresh` y reaplicar, nunca `Override`.
- PLAN antes de APPLY siempre. No inventar flags de script sin confirmar
  con `--help`.
- Comandos técnicos con etiqueta explícita de entorno (Local vs VPS).
- **En el VPS, los scripts que tocan `docker` o `secrets/` van con `sudo`.** Son todos los
  de `directus/` salvo los de lectura pura, y `n8n/render-workflows.sh` y
  `export-workflows.sh`: leen `/opt/aegora/tenants/<tenant>/secrets/*`, que es de root, y
  ejecutan `docker exec` contra los contenedores del tenant. `render-workflows.sh` ya lo
  dice él mismo cuando falla ("Prueba con sudo", "¿sudo?" al no poder leer los secretos de
  WhatsApp), pero **el aviso llega a mitad de ejecución**, así que el comando se escribe
  con `sudo` desde el principio.
  Ojo al escribirlo: `sudo` no hereda el `cd`, pero sí el directorio actual del shell, así
  que `cd /opt/aegora/platform && sudo ./n8n/render-workflows.sh ...` funciona.
- No asumir que la documentación heredada es correcta sin verificar.
