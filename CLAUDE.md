# Aegora — Contexto para Claude Code

## Qué es esto
Plataforma multi-tenant (pequeños negocios): Directus (CRM/config visible),
n8n (orquestación + agente conversacional "Lucía"), Booking API (futuro
componente autoritativo de disponibilidad). PostgreSQL y Caddy compartidos
a nivel de plataforma; cada tenant tiene su propio Directus + n8n.

Handover técnico completo (arquitectura, backups, runbooks): ver
`AEGORA_handover_tecnico_post_Lumadock.docx` — si no está en este repo,
pídele al usuario que lo copie a `docs/` para que puedas leerlo directo.

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
  (`directus-provisioning@aegora.es`, documentado en el handover) **no
  existe en demo** — pendiente crearlo. Sí existe en `aegora-internal`.
- Directus fijado en 12.2.0 a propósito (no actualizar a 12.3.x todavía,
  hasta estabilizar provisioning).
- Health check: usar `/server/ping`, NO `/server/health` (devuelve 403 en 12.2.0).

## Modelo de booking en Directus — decisiones ya tomadas
- Semántica V1 simple: `service_resources` = pool OR de recursos alternativos
  por servicio. `appointment_resources` = AND, recursos comprometidos por una
  cita concreta (junction plana, sin interfaz M2M — Directus 12.2 tiene un bug
  conocido con M2M inverso sobre la misma junction: "Interfaz list-m2m no
  encontrada"). Sin categorías/grupos de recursos en V1.
- `availability_rules` funciona como allow-list: ausencia de regla para un
  día = no disponible ese día (no usar `availability_exceptions` para
  patrones recurrentes como fin de semana, solo para desviaciones puntuales).
- La junction pool-OR se llama `service_resources` (singular). El nombre
  `services_resources` fue un typo; corregido en Directus y en `base.yaml`.
- Estado: Prioridades 1 y 2 CERRADAS.
  - P1 (modelo Directus): 18 relaciones M2O creadas y validadas.
  - P2 (índices/constraints SQL): `directus/sql/booking-indexes.sql` —
    capa idempotente (`CREATE [UNIQUE] INDEX IF NOT EXISTS`) con los 20
    índices de la sección 12.2 del handover. Integrada en
    `apply-schema.sh` respetando PLAN/APPLY: dry-run la valida en
    `BEGIN … ROLLBACK`, `--apply` la persiste en `BEGIN … COMMIT`
    (schema primero, luego SQL). Ejecuta vía `psql` en `aegora-postgres`
    leyendo credenciales del contenedor Directus.
  - `base.yaml` regenerado como snapshot completo desde `demo` (incluye
    `relations:` — su ausencia hacía cascar `schema apply --dry-run` en
    `get-snapshot-diff.js`). Displays custom (`aegora-phone-display`,
    `field-actions`) se dejan a null en `base.yaml`: los gestiona
    `configure-directus-ui.sh`, por lo que el dry-run muestra ese diff
    de forma esperada.
- Siguiente hito: Prioridad 3 — Availability/Booking Engine (Booking API).

## Estilo de trabajo esperado
- PLAN antes de APPLY siempre. No inventar flags de script sin confirmar
  con `--help`.
- Comandos técnicos con etiqueta explícita de entorno (Local vs VPS).
- No asumir que la documentación heredada es correcta sin verificar.
