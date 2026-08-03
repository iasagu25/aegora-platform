# Caddy

Reverse proxy público de Aegora.

## Imagen

- `caddy:2.11.4-alpine`

## Puertos públicos

- TCP 80
- TCP 443
- UDP 443 para HTTP/3

## Persistencia

- `/opt/aegora/data/caddy/data`
- `/opt/aegora/data/caddy/config`

El directorio `data` contiene certificados y claves TLS y debe incluirse en los backups.

## Red

Caddy se conecta exclusivamente a:

- `aegora_proxy`

Los servicios publicados deben compartir esa red.

## Rutas actuales

- `panel.aegora.es` → `aegora-directus:8055`

## Operación

```bash
make caddy-config
make caddy-up
make caddy-status
make caddy-logs
make caddy-reload
