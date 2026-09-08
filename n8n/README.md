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

## Deuda conocida

- **Host de Directus hardcodeado** (`http://demo-directus:8055/...`) en casi
  todos los workflows. Para multi-tenant hay que parametrizarlo (patrón nodo
  `Config` como en `APPOINTMENT_Availability.json`). Pendiente.
- `03 / 05 / 11` y sus wrappers `22 / 24 / 25` escriben directo en Directus
  (`/items/appointments`). El plan (handover §12.3) es que llamen al
  **Booking API** (`/api/book|reschedule|cancel`) para tener revalidación
  autoritativa y control de concurrencia. **En curso.**

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
