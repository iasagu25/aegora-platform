# n8n — workflows versionados

Área nueva. Los workflows de dominio históricos viven en la BD `n8n_<tenant>`
y no están todos aquí; este directorio versiona los que la plataforma
mantiene de forma reproducible. Importación manual por ahora.

## `workflows/APPOINTMENT_Availability.json`

Herramienta del agente (handover §12.4). Consulta `GET /api/availability`
del Booking API y devuelve una salida compacta para que el agente proponga
huecos. **No decide** disponibilidad: solo lee. Las mutaciones
(`book`/`reschedule`/`cancel`) tienen su propia revalidación autoritativa
en el Booking API.

### Contrato

Sub-workflow con trigger *Executed by Another Workflow* (para engancharlo
al agente principal como *Tool Workflow*). Entradas:

| campo | req | |
|---|---|---|
| `service_id` | ✔ | uuid del servicio |
| `date` | ✔ | `YYYY-MM-DD` en la timezone de salida |
| `location_id` | | filtra recursos por sede |
| `resource_id` | | fija un recurso del pool |
| `timezone` | | IANA; por defecto la resuelve el Booking API |
| `exclude_appointment_id` | | excluye el bloque de esa cita (reschedule) |

Salida:

```json
{ "available": true, "count": 6, "service_id": "…", "date": "2026-09-09",
  "timezone": "Europe/Madrid", "duration_minutes": 30,
  "slots": [ { "start_at": "…+02:00", "end_at": "…+02:00" }, … ] }
```

o, en error / parámetros insuficientes:

```json
{ "available": false, "error": "missing_required_fields", "message": "…" }
```

### Requisitos en el tenant

1. **Env de n8n**: `BOOKING_API_BASE_URL` (p.ej. `http://demo-booking:3000`).
   Ya lo añade `templates/tenant-stack/n8n/.env.tpl` (`http://${BOOKING_CONTAINER}:3000`).
   Para tenants ya creados, añadirlo a mano a `config/compose/n8n/.env` y reiniciar n8n.
2. **Credencial n8n** tipo *Header Auth*, nombre `Booking API`:
   - Name: `Authorization`
   - Value: `Bearer <BOOKING_API_TOKEN>` — el token está en
     `/opt/aegora/tenants/<tenant>/secrets/booking.env`.
3. `<tenant>-n8n` debe alcanzar `<tenant>-booking:3000` por la red
   `tenant_<tenant>_backend` (ambos están en ella).

### Importar

En la UI de n8n del tenant: *Workflows → Import from File →*
`APPOINTMENT_Availability.json`. Tras importar, abrir el nodo
`GET /api/availability` y **re-seleccionar** la credencial `Booking API`
(el `id` del JSON es un placeholder).

O por CLI dentro del contenedor:

```bash
docker cp n8n/workflows/APPOINTMENT_Availability.json <tenant>-n8n:/tmp/wf.json
docker exec <tenant>-n8n n8n import:workflow --input=/tmp/wf.json
```

(La credencial hay que asignarla igualmente desde la UI.)

### Probar

En n8n, *Execute Workflow* con input de prueba:
`{ "service_id": "<uuid>", "date": "2026-09-09" }` → debe devolver los
slots. Compararlo con la llamada directa:
`docker exec <tenant>-booking sh -c 'wget -qO- --header="Authorization: Bearer $BOOKING_API_TOKEN" "http://127.0.0.1:3000/api/availability?service_id=<uuid>&date=2026-09-09"'`

### Pendiente

- Enganchar al agente principal como *Tool Workflow* (solo cuando estén
  también las mutaciones con revalidación autoritativa — handover §12.4).
- Automatizar la importación en el provisioning (hoy es manual).
