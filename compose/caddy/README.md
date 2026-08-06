# Caddy — infraestructura compartida

Reverse proxy público y terminación TLS de la plataforma Aegora.

Caddy es infraestructura compartida. No pertenece exclusivamente al tenant
`aegora`: en el futuro publicará también los servicios de otros tenants.

## Imagen

- `caddy:2.11.4-alpine`

La versión está fijada para evitar actualizaciones automáticas no controladas.

## Contenedor

- Nombre: `aegora-caddy`
- Puertos públicos:
  - TCP 80
  - TCP 443
  - UDP 443 para HTTP/3

Es el único servicio de la plataforma que publica directamente puertos HTTP y
HTTPS en el host.

## Configuración

El fichero efectivo es:

```text
compose/caddy/Caddyfile
```

Se monta dentro del contenedor como:

```text
/etc/caddy/Caddyfile
```

El fichero se monta en modo de solo lectura.

Las variables no sensibles de ejemplo están en:

```text
compose/caddy/.env.example
```

La configuración real está en:

```text
compose/caddy/.env
```

El `.env` real no debe versionarse.

## Persistencia

Caddy utiliza:

```text
/opt/aegora/data/caddy/data
/opt/aegora/data/caddy/config
```

Montajes:

```text
/opt/aegora/data/caddy/data   → /data
/opt/aegora/data/caddy/config → /config
```

El directorio `/data` contiene certificados, claves privadas TLS y estado ACME.
Debe incluirse en los backups.

## Red

Caddy se conecta a:

```text
aegora_proxy
```

Todos los servicios publicados mediante Caddy deben compartir esta red.

Caddy debe dirigirse a los nombres internos de los contenedores, nunca a
`localhost`.

## Rutas actuales

Actualmente publica:

```text
panel.aegora.es → aegora-directus:8055
n8n.aegora.es   → aegora-n8n:5678
```

Las rutas exactas y futuras se definen en el `Caddyfile`.

## TLS

Caddy obtiene y renueva automáticamente los certificados TLS.

Para que funcione correctamente:

- los dominios deben resolver a la IP pública del VPS;
- los puertos TCP 80 y 443 deben ser accesibles;
- el directorio `/opt/aegora/data/caddy/data` debe ser persistente;
- `ACME_EMAIL` debe estar definido en `.env`.

## Healthcheck

El healthcheck consulta la API administrativa local:

```text
http://127.0.0.1:2019/config/
```

La API administrativa no se publica en el host.

## Operación

Desde la raíz del repositorio:

```bash
make caddy-config
make caddy-validate
make caddy-pull
make caddy-up
make caddy-status
make caddy-logs
make caddy-reload
make caddy-down
```

Antes de recargar:

```bash
make caddy-validate
```

Para aplicar cambios del `Caddyfile` sin recrear el contenedor:

```bash
make caddy-reload
```

Para aplicar cambios del Compose, montajes o variables de entorno, hay que
recrear el contenedor:

```bash
docker compose \
  --env-file compose/caddy/.env \
  -f compose/caddy/compose.yml \
  up -d --force-recreate
```

## Backup

El backup incluye:

- `compose/caddy/compose.yml`;
- `compose/caddy/.env`;
- `compose/caddy/Caddyfile`;
- `/opt/aegora/data/caddy/data`;
- `/opt/aegora/data/caddy/config`.

Los certificados pueden volver a emitirse, pero conservar `/data` evita
renovaciones innecesarias y preserva el estado ACME.

## Restauración

Orden recomendado:

1. Restaurar `compose.yml`, `.env` y `Caddyfile`.
2. Restaurar `/opt/aegora/data/caddy`.
3. Crear la red externa `aegora_proxy`.
4. Validar el `Caddyfile`.
5. Recrear el contenedor.
6. Verificar los dominios y certificados.

## Arquitectura futura

La ubicación actual es heredada:

```text
compose/caddy
```

La ubicación objetivo será:

```text
compose/infrastructure/caddy
```

No se moverá hasta haber completado y validado una restauración integral.
