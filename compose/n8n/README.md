# n8n — tenant Aegora

Orquestador de automatizaciones del tenant interno `aegora`.

Esta instancia no debe compartirse con futuros clientes. Cada nuevo tenant tendrá su propia instancia de n8n, credenciales, base de datos y almacenamiento persistente.

## Imagen

- `n8nio/n8n:2.31.7`

La versión está fijada para impedir actualizaciones automáticas no controladas.

## Contenedor

- Nombre: `aegora-n8n`
- Puerto interno: `5678`
- URL pública: `https://n8n.aegora.es`

No se publica ningún puerto directamente en el host. Caddy accede al servicio mediante la red `aegora_proxy`.

## Base de datos

- Motor: PostgreSQL
- Host: `aegora-postgres`
- Base: `n8n`
- Usuario: definido en `.env`
- Red: `aegora_backend`

## Persistencia

- `/opt/aegora/data/n8n/storage` → `/home/node/.n8n`
- `/opt/aegora/data/n8n/files` → `/files`

La base principal está en PostgreSQL, pero `/home/node/.n8n` también debe respaldarse porque contiene estado local y configuración operativa.

## Redes

- `aegora_backend`: acceso a PostgreSQL.
- `aegora_proxy`: acceso desde Caddy.

## Variables de entorno

La configuración real está en:

```text
compose/n8n/.env
```

Este archivo contiene secretos y está excluido de Git.

La plantilla versionable está en:

```text
compose/n8n/.env.example
```

La variable `N8N_ENCRYPTION_KEY` es crítica. No debe perderse ni cambiarse después de crear credenciales.

## Operación

Desde la raíz del repositorio:

```bash
make n8n-config
make n8n-pull
make n8n-up
make n8n-status
make n8n-logs
make n8n-down
```

## Backup

El backup del tenant incluye:

- dump consistente de la base PostgreSQL `n8n`;
- `/opt/aegora/data/n8n/storage`;
- `/opt/aegora/data/n8n/files`;
- `compose/n8n/compose.yml`;
- `compose/n8n/.env`;
- manifiesto y hashes de verificación.

No se copia el directorio físico de PostgreSQL en caliente.

## Restauración

La restauración debe realizarse en este orden:

1. Recuperar secretos y configuración.
2. Crear la base PostgreSQL vacía.
3. Restaurar el dump con `pg_restore`.
4. Restaurar los directorios persistentes.
5. Recrear el contenedor.
6. Verificar credenciales, workflows y webhooks.

## Arquitectura futura

La ubicación actual es heredada:

```text
compose/n8n
```

La ubicación objetivo será:

```text
compose/tenants/aegora/n8n
```

No se moverá hasta haber validado completamente el backup y una restauración real.
