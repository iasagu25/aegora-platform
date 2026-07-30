# PostgreSQL

Instancia PostgreSQL compartida por los servicios operativos de Aegora.

## Bases de datos

- `directus`
- `n8n`
- `booking`

Cada base de datos tiene un usuario propietario independiente.

## Operación

Desde la raíz del repositorio:

```bash
make postgres-config
make postgres-pull
make postgres-up
make postgres-status
make postgres-logs
