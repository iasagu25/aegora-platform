# n8n

Orquestador de automatizaciones de Aegora.

## Imagen

- `n8nio/n8n:2.31.7`

La versión está fijada para evitar actualizaciones automáticas.

## Base de datos

- Host: `aegora-postgres`
- Base: `n8n`
- Usuario: `n8n_app`
- Red: `aegora_backend`

## Persistencia

- `/opt/aegora/data/n8n/storage`
- `/opt/aegora/data/n8n/files`

`storage` contiene el estado local de n8n y debe respaldarse aunque PostgreSQL sea la base principal.

## Redes

- `aegora_backend`: PostgreSQL
- `aegora_proxy`: Caddy

## URL pública

- `https://n8n.aegora.es`

## Operación

```bash
make n8n-config
make n8n-pull
make n8n-up
make n8n-status
make n8n-logs
