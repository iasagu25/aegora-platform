# Aegora Platform

Infraestructura reproducible de la plataforma operativa de Aegora.

## Servicios previstos

- Reverse proxy
- PostgreSQL
- Directus
- n8n
- Booking API
- Monitorización
- Backups externos

## Principios

- Git es la fuente de verdad de la infraestructura.
- El VPS es reemplazable.
- Los datos persistentes se respaldan fuera del VPS.
- Ningún secreto se almacena en Git.
- Los servicios internos no exponen puertos directamente a Internet.

## Estado

Fase inicial: preparación y securización del VPS.
