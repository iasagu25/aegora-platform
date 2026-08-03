# Caddy

Reverse proxy público de Aegora.

## Imagen

- `caddy:2.11.4-alpine`

## Puertos públicos

- TCP 80
- TCP 443
- UDP 443

## Persistencia

- `/opt/aegora/data/caddy/data`
- `/opt/aegora/data/caddy/config`

## Red

- `aegora_proxy`

## Rutas

- `panel.aegora.es` → `aegora-directus:8055`
- `n8n.aegora.es` → `aegora-n8n:5678`

## Operación

```bash
make caddy-config
make caddy-validate
make caddy-up
make caddy-reload
make caddy-logs

