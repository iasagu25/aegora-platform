# Booking API

Componente autoritativo de disponibilidad y mutación de reservas
(`availability` / `book` / `reschedule` / `cancel`). Código en el repo
`aegora-booking`; contrato congelado en `aegora-booking/docs/api-contract.md`.

## Imagen

- **Build local en el VPS (opción A).** Sin registro externo en V1.
- `provisioning/tenant/deploy-booking.sh` mantiene un checkout en
  `/opt/aegora/src/aegora-booking` y construye `aegora-booking:<git-sha>`.
- Migración futura a `ghcr.io/iasagu25/aegora-booking:<version>` prevista.

## Base de datos

- **No tiene BD propia.** Opera sobre `directus_<tenant>` con las
  credenciales del usuario de Directus del tenant.
- Estado de negocio = colecciones Directus (`appointments`,
  `appointment_resources`, …). Idempotencia vía `appointments.idempotency_key`.

## Auth

- `Authorization: Bearer <BOOKING_API_TOKEN>` en todos los endpoints.
- Secreto por tenant en `/opt/aegora/tenants/<tenant>/secrets/booking.env`
  (root, mode 600), generado por `provisioning/tenant/provision-booking-access.sh`.
- Independiente de `DIRECTUS_PROVISIONING_TOKEN`.

## Red y salud

- Redes: `aegora_backend` (Postgres) + `aegora_proxy` (Caddy).
- Puerto interno: `3000`. Health check: `GET /api/health`.
- Host público por tenant: `${BOOKING_HOST}` (por defecto `reservas.<base-domain>`).

## Runbook

```bash
# generar/rotar el token del tenant
provisioning/tenant/provision-booking-access.sh --tenant TENANT [--apply]

# construir imagen + desplegar el contenedor del tenant
provisioning/tenant/deploy-booking.sh --tenant TENANT [--ref GIT_REF] [--apply]
```
