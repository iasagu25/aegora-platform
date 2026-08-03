# Directus

Backoffice, API y administración de datos operativos de Aegora.

## Imagen

- `directus/directus:11.17.4`

La versión está fijada para evitar actualizaciones automáticas no controladas.

## Base de datos

- Host: `aegora-postgres`
- Base de datos: `directus`
- Usuario: `directus_app`
- Red: `aegora_backend`

Directus administra en esta base tanto sus tablas internas como las colecciones operativas.

## Persistencia

- `/opt/aegora/data/directus/uploads`
- `/opt/aegora/data/directus/extensions`
- `/opt/aegora/data/directus/snapshots`

## Redes

- `aegora_backend`: conexión con PostgreSQL
- `aegora_proxy`: conexión futura con Caddy

## Exposición

Directus no publica ningún puerto directamente en el host.

El acceso público se realizará posteriormente mediante:

- `https://panel.aegora.es`

## Operación

Los comandos se ejecutarán mediante el Makefile de la raíz del repositorio.
