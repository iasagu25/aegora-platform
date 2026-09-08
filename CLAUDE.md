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
- Pendiente P3:
  - Quitar `booking_<tenant>` (DB + rol) de `create-tenant.sh` + `backup.manifest.json`
    (customers + template). El `booking_<tenant>` vacío actual es peso muerto inofensivo.
  - Aplicar `base.yaml` (68cd6f7) + `booking-indexes.sql` en `aegora-internal`.
  - Migrar build A → imagen en GHCR (CI en `aegora-booking`).
  - Herramienta n8n *Appointment Availability* que consume el Booking API (P4).

## Estilo de trabajo esperado
- PLAN antes de APPLY siempre. No inventar flags de script sin confirmar
  con `--help`.
- Comandos técnicos con etiqueta explícita de entorno (Local vs VPS).
- No asumir que la documentación heredada es correcta sin verificar.
