# AEGORA — Handover técnico

**Arquitectura, Git, despliegue multi-tenant, idempotencia, backups y roadmap**

Estado del proyecto tras la reorganización operativa iniciada a raíz de la incidencia de Luma Dock.
Fecha de corte: 4 de septiembre de 2026.

> Convertido de `AEGORA_handover_tecnico_post_Lumadock.docx`. El `.docx` sigue siendo la copia de referencia; este `.md` es para lectura/diff en el repo.

Objetivo: permitir que un nuevo equipo continúe la implementación sin depender del contexto histórico de las conversaciones.

## 0. Cómo leer este documento

Este documento consolida las decisiones de arquitectura y operación ya tomadas para Aegora, el estado funcional validado y los puntos todavía pendientes. No pretende describir detalles del incidente de Luma Dock que no hayan quedado documentados; se centra en las medidas y prácticas adoptadas después: repositorio Git como fuente canónica, despliegues reproducibles, separación por tenant, backups externos, restauraciones de prueba, credenciales técnicas y diseño de la capa de booking.

Los comandos marcados como «validados» corresponden a operaciones efectivamente utilizadas durante el proyecto. Cuando la sintaxis exacta de un script de provisioning depende de sus opciones actuales, se indica expresamente que debe confirmarse con --help antes de ejecutar; no se inventan flags no verificados.

## 1. Resumen ejecutivo

Aegora está evolucionando hacia una plataforma multi-tenant para pequeños negocios. Directus actúa como CRM y capa visible de configuración de negocio; n8n como capa de orquestación y cerebro de IA; y el Booking API será el componente autoritativo para disponibilidad y mutaciones de reservas. Cada tenant dispone de su propio Directus, n8n, base de datos lógica/configuración y secretos, mientras comparte PostgreSQL y Caddy a nivel de plataforma.

| Área | Decisión actual | Estado |
| --- | --- | --- |
| Control de versiones | Git remoto es la fuente canónica. El VPS no hace push. | Validado |
| Multi-tenant | Stack Directus+n8n por tenant; PostgreSQL y Caddy compartidos. | Validado |
| Provisioning | Scripts PLAN por defecto; --apply para mutar; onboarding idempotente. | Validado funcionalmente |
| Backups | restic + Hetzner Object Storage por tenant; prune, health y restore-test. | Validado en demo |
| Notificaciones | ntfy con metadatos mínimos. | Validado |
| Directus auth técnica | Usuario técnico con static token por tenant. | Validado |
| Booking/availability | Directus configura; Booking API calcula y escribe de forma autoritativa. | Diseño en curso |
| Modelo booking Directus | locations, calendars, services, resources y service_resources iniciados. | En implementación |

## 2. Arquitectura de referencia

```
Internet / DNS
      |
   Caddy compartido
      |
      +---------------------+----------------------+
      |                                            |
Tenant demo                                  Tenant aegora-internal
  Directus                                      Directus
  n8n                                           n8n
  datos/secrets/config                          datos/secrets/config
      |                                            |
      +---------------- PostgreSQL compartido -----+
                           |
                    Backups restic
                           |
                 Hetzner Object Storage
```

Rutas y nombres operativos relevantes: repositorio VPS /opt/aegora/platform; tenants en /opt/aegora/tenants/<tenant>; red proxy compartida aegora_proxy; contenedores <tenant>-directus y <tenant>-n8n. Los tenants activos conocidos son demo y aegora-internal. El identificador aegora está protegido por coexistencia con servicios legacy y no debe utilizarse para un nuevo tenant.

| Componente | Responsabilidad |
| --- | --- |
| Directus | CRM, datos de negocio y configuración visible/canónica: contactos, tareas, citas, empleados, servicios, recursos, horarios, etc. |
| n8n | Orquestación, herramientas del agente, integración con canales y ejecución de workflows. |
| Booking API | Futuro componente autoritativo: disponibilidad, create/reschedule/cancel, sincronización de contacto de booking y control de concurrencia. |
| PostgreSQL | Persistencia compartida a nivel de infraestructura, con separación lógica por tenant. |
| Caddy | Reverse proxy/TLS y publicación de dominios por tenant. |
| restic + Object Storage | Backups externos, retención, health checks y restauraciones de prueba. |

## 3. Gestión de versiones con Git

### 3.1 Principio operativo

El repositorio remoto es la fuente canónica. Los cambios de código se preparan, revisan, commitean y publican desde el entorno local. La clave Git instalada en el VPS es deliberadamente de solo lectura. Por tanto, no se debe hacer push desde el servidor.

- Local: editar → probar → git add/commit → git push.
- Remoto: fuente canónica de la rama.
- VPS: git fetch → inspección → actualización desde origin.
- Rama de trabajo documentada: feature/backup.

### 3.2 Flujo recomendado local

```
cd ~/proyectos/aegora-platform
git status
git diff
git add <archivos>
git commit -m "tipo(area): descripción"
git push origin feature/backup
```

Antes de hacer push, revisar siempre git diff y evitar incluir secretos, artefactos runtime o archivos accidentales.

### 3.3 Sincronización segura del VPS

Secuencia validada para comprobar divergencias antes de tocar el árbol de trabajo:

```
cd /opt/aegora/platform
git fetch
git status
git log --oneline --decorate --graph -6 --all
git diff --stat HEAD origin/feature/backup
```

Si el VPS está limpio y se ha confirmado que el remoto contiene el estado canónico que debe ejecutarse, puede alinearse con:

```
git reset --hard origin/feature/backup
git status
git log --oneline --decorate -5
```

Advertencia: no ejecutar reset --hard si hay cambios no inspeccionados. En el pasado aparecieron archivos accidentales creados por comandos shell; deben revisarse antes de eliminarlos.

### 3.4 Lección de divergencias previas

Durante la evolución del proyecto existieron commits equivalentes pero con hashes distintos en VPS y local/remoto. La resolución adoptada fue considerar remoto como canónico y realinear el VPS una vez comprobado que no había cambios únicos que conservar. Este criterio debe mantenerse para evitar que producción se convierta en un segundo repositorio de desarrollo.

## 4. Estrategia de despliegue de tenants

### 4.1 Filosofía

El provisioning está diseñado para ser reproducible, declarativo en lo posible e idempotente. Los scripts trabajan en modo PLAN por defecto y solo mutan con --apply. La publicación DNS/Caddy se mantiene separada de la preparación interna para que un tenant pueda quedar completamente preparado antes de exponerse.

### 4.2 Scripts principales

| Script | Función |
| --- | --- |
| provisioning/tenant/create-tenant.sh | Crea estructura/configuración base del tenant. |
| deploy-tenant.sh | Despliega/arranca servicios del tenant. |
| publish-tenant.sh | Publicación y configuración relacionada con dominio/Caddy. |
| configure-tenant-backup.sh | Configura backup restic por tenant. |
| activate-tenant-operations.sh | Activa timers/operaciones del tenant. |
| onboard-tenant.sh | Orquestador de onboarding por etapas. |
| render-template.py | Renderiza plantillas de configuración. |
| directus/apply-schema.sh | Aplica schema Directus. |
| directus/provision-directus-access.sh | Crea/reconcilia acceso técnico Directus. |
| directus/configure-directus-ui.sh | Aplica metadata/UI gestionada. |
| directus/configure-spanish-ui.sh | Aplica traducciones y locale. |

### 4.3 Secuencia de preparación de un tenant

La secuencia objetivo del onboarding es:

1. CREATE TENANT
1. DEPLOY TENANT
1. APPLY DIRECTUS SCHEMA
1. RESTART DIRECTUS + esperar health
1. PROVISION DIRECTUS TECHNICAL ACCESS
1. CONFIGURE DIRECTUS UI
1. CONFIGURE DIRECTUS SPANISH UI
1. CONFIGURE BACKUP
1. ACTIVATE OPERATIONS
El restart tras aplicar schema es obligatorio con Directus 12.2.0: se comprobó que nuevos campos/colecciones podían existir en DB y metadata pero devolver 403 hasta reiniciar Directus. No eliminar esta pausa de salud del onboarding.

### 4.4 Comandos de despliegue

Los nombres de scripts y el uso de --apply están confirmados. La lista exacta de argumentos posicionales/flags del tenant puede haber evolucionado; el equipo debe consultar --help en la versión del repositorio antes de ejecutar un alta real.

```
cd /opt/aegora/platform

# 1) Verificar sintaxis vigente
./provisioning/tenant/onboard-tenant.sh --help
./provisioning/tenant/create-tenant.sh --help
./provisioning/tenant/deploy-tenant.sh --help
./provisioning/tenant/publish-tenant.sh --help

# 2) Ejecutar primero en PLAN (sin --apply)
# Usar los argumentos que muestre --help para <tenant>, dominio, display name, etc.

# 3) Revisar el plan.

# 4) Repetir con --apply para mutar.

# 5) Publicar solo después de que DNS esté preparado:
# onboard-tenant.sh ... --stage publish --apply
# o stage all cuando proceda, según --help de la versión actual.
```

No se documenta aquí una línea de alta con flags no verificados. Esta precaución es intencionada: el handover debe ser ejecutable, no una receta basada en una sintaxis posiblemente obsoleta.

### 4.5 DNS y Caddy

Los dominios siguen el patrón <tenant>.aegora.es y, para servicios internos, panel.<tenant>.aegora.es / n8n.<tenant>.aegora.es. Caddy carga fragmentos runtime desde /opt/aegora/data/caddy/sites/<tenant>.caddy. La publicación debe validar DNS y recargar Caddy.

- IP pública documentada del VPS: 185.200.244.81.
- Caddy compartido: aegora-caddy, versión 2.11.4 en el último estado conocido.
- No publicar antes de que el tenant esté sano internamente.

## 5. Idempotencia

### 5.1 Concepto aplicado

Un proceso idempotente puede ejecutarse repetidamente y converger al mismo estado deseado sin duplicar recursos, corromper configuración ni depender de que la ejecución anterior terminara exactamente en un punto concreto. En Aegora esto es esencial porque onboarding, configuración de Directus, backups y activación de timers deben poder reintentarse después de un fallo parcial.

### 5.2 Cómo se ha implementado

- PLAN por defecto; --apply explícito para cambios.
- Scripts de configuración reconcilian estado en lugar de asumir una máquina vacía.
- Usuario técnico Directus: se crea si no existe y se reutiliza/reconcilia si ya existe.
- Backups y timers se configuran por tenant sin duplicar unidades.
- SQL futuro para índices/constraints debe usar CREATE INDEX IF NOT EXISTS / equivalentes idempotentes.
- Onboarding por etapas permite repetir una fase concreta.

### 5.3 Cómo se ha testado

El onboarding integrado fue ejecutado y validado funcionalmente. Durante las pruebas apareció un bug real en el bucle de espera de health:

```
# Incorrecto
elapsed=$(
  elapsed +
  DIRECTUS_HEALTH_INTERVAL_SECONDS
)

# Corregido
elapsed=$((elapsed + DIRECTUS_HEALTH_INTERVAL_SECONDS))
```

Tras la corrección, el flujo integrado quedó operativo. También se validó que la provisión del usuario técnico puede repetirse y que las capas UI/Spanish UI funcionan usando el token técnico en lugar de la contraseña del administrador humano.

### 5.4 Pruebas que debe mantener el nuevo equipo

- Ejecutar onboarding en PLAN y comprobar que no muta.
- Ejecutar onboarding --apply sobre tenant nuevo.
- Repetir exactamente el mismo onboarding --apply y comprobar ausencia de duplicados/cambios destructivos.
- Interrumpir una ejecución en una fase controlada y reanudar.
- Repetir configure-directus-ui.sh y configure-spanish-ui.sh.
- Repetir configure-tenant-backup.sh y activación de timers.
- Comprobar health y API tras schema apply + restart.

## 6. Estrategia de backups y recuperación

### 6.1 Objetivo

El backup no se considera completo por el mero hecho de crear snapshots. La estrategia incluye copia externa, retención, comprobación de salud, restauraciones de prueba y notificaciones.

### 6.2 Componentes

| Elemento | Ubicación / función |
| --- | --- |
| backup-tenant.sh | Generación de backup por tenant. |
| prune-tenant.sh | Aplicación de política de retención. |
| backup-health-tenant.sh | Comprueba salud/estado de backups. |
| check-tenant.sh | Comprobaciones del tenant. |
| restore-tenant.sh | Restauración operativa. |
| restore-test-tenant.sh | Restauración periódica de prueba. |
| tenant-context.sh | Resolver contexto/configuración del tenant. |
| restic | Repositorio de backup deduplicado/cifrado. |
| Hetzner Object Storage | Destino externo por tenant. |
| ntfy | Notificaciones operativas con metadatos mínimos. |

### 6.3 Configuración por tenant

```
/opt/aegora/tenants/<tenant>/config/tenant.env
/opt/aegora/tenants/<tenant>/config/backup.manifest.json
/opt/aegora/tenants/<tenant>/secrets/restic.env
```

Los secretos deben permanecer fuera de Git, con permisos restrictivos. El bucket/repositorio debe ser específico por tenant. Para aegora-internal se contempló el bucket aegora-aegora-internal-backups.

### 6.4 Automatización systemd

```
aegora-backup@.service
aegora-backup@.timer

aegora-backup-prune@.service
aegora-backup-prune@.timer

aegora-restore-test@.service
aegora-restore-test@.timer

aegora-backup-health@.service
aegora-backup-health@.timer
```

Se añadieron locks por tenant para evitar ejecuciones concurrentes incompatibles.

### 6.5 Comandos operativos útiles

```
# Ver timers relacionados con Aegora
systemctl list-timers --all | grep aegora

# Estado de una unidad concreta (ejemplo)
systemctl status aegora-backup@demo.service
systemctl status aegora-backup@demo.timer

# Logs
journalctl -u aegora-backup@demo.service
journalctl -u aegora-backup-health@demo.service
journalctl -u aegora-restore-test@demo.service
```

Las pruebas de backup y notificación se realizaron en demo. El principio de aceptación es: no basta con que el backup termine OK; debe existir evidencia de que puede restaurarse.

### 6.6 Notificaciones

Se utiliza ntfy. La notificación debe contener información operativa suficiente para actuar, pero evitar secretos y datos personales. El equipo debe conservar esta disciplina: tenant, tipo de operación, resultado y contexto mínimo; nunca tokens, contraseñas o contenido de clientes.

## 7. Directus: decisiones operativas relevantes

### 7.1 Versión y health

- Directus fijado en 12.2.0.
- La actualización a 12.3.0 se decidió posponer hasta estabilizar el provisioning.
- Health endpoint utilizado: /server/ping. /server/health devolvía 403 en 12.2.0.

### 7.2 Credencial técnica de provisioning

El provisioning no debe depender de la contraseña del administrador humano. Se creó un usuario de servicio por tenant con rol Administrator y static token.

```
Usuario técnico:
directus-provisioning@aegora.es

Secret por tenant:
/opt/aegora/tenants/<tenant>/secrets/directus-provisioning.env

Permisos del fichero:
root-owned, mode 600
```

configure-directus-ui.sh y configure-spanish-ui.sh usan Bearer token. La contraseña del administrador humano puede cambiar sin romper automatizaciones. El script provision-directus-access.sh usa credenciales bootstrap solo en la creación inicial y después trabaja con el token técnico.

### 7.3 Separación entre schema y UI

Se adoptó una separación explícita de fuentes de verdad porque aplicar el schema podía resetear metadata de interfaces personalizadas:

- directus/schema/base.yaml: estructura/modelo Directus.
- configure-directus-ui.sh: metadata e interfaces personalizadas.
- configure-spanish-ui.sh: traducciones y locale es-ES.
- configure-directus-extensions.sh: extensiones gestionadas.

### 7.4 Extensiones gestionadas

| Extensión | Uso |
| --- | --- |
| aegora-phone-display | Display O2M para teléfonos de contactos. |
| aegora-tasks-layout | Layout de tarjetas de tareas. |
| aegora-phone-normalizer | Normalización de teléfonos en contacts/employees. |
| field-actions 2.2.0 | Acciones sobre teléfono escalar de employees; vendorizada/pinneada. |

## 8. Modelo funcional actual de Directus

Colecciones base ya existentes y estabilizadas:

```
contacts
contact_phones
tasks
appointments
employees
languages (hidden)
```

Tasks dispone de assignee_id → employees y assigned_at. Employees se relaciona opcionalmente con directus_users. Appointments sigue siendo el calendario maestro actual y conserva contact_id, title, start_at, end_at, status, notes, source y campos de proveedor externo.

### 8.1 Inconsistencia conocida en employees

Existe una inconsistencia a corregir: las choices UI de employees.status usan Active/Inactive mientras el default de DB es active. Debe normalizarse a valores lowercase active/inactive con etiquetas españolas Activo/Inactivo.

## 9. Capa n8n y herramientas del agente

La capa n8n ya dispone de un conjunto amplio de workflows de dominio y herramientas. La numeración conocida incluye workflows CORE, CONTACT, TASK y APPOINTMENT. No debe inventarse el workflow 15: su propósito exacto no está documentado.

| Workflow | Estado / función |
| --- | --- |
| 06 CONTACT Get | Corregido para consultar colección con filter+limit 1; UUID inexistente devuelve not_found estable. |
| 08 TASK List Pending | Base de listado de tareas. |
| 09 APPOINTMENT List Upcoming | Lista próximas citas scheduled/confirmed. |
| 11 APPOINTMENT Reschedule | PATCH de fechas; WF24 valida previamente propiedad/estado. |
| 16 CORE Contact Context | No llama tareas/citas si el contacto no existe. |
| 17 CORE Resolve + Context | Resuelve single/multiple/not_found de forma estable. |
| 20 TOOL Task List | Herramienta de listado de tareas. |
| 23 TOOL Appointment List | Terminado y probado. |
| 24 TOOL Appointment Reschedule | Terminado; valida pertenencia y cita futura activa. |
| 25 TOOL Appointment Cancel | Terminado; usa WF05 con status cancelled. |
| 26 TOOL Contact Update | Opcional/redundante; deliberadamente diferido. |

## 10. Booking y disponibilidad: arquitectura acordada

La decisión fundamental es que el LLM/agente NO decide autoritativamente si un hueco está libre. Puede pedir disponibilidad y proponer alternativas, pero la lógica determinista debe comprobar el slot y volver a comprobarlo inmediatamente antes de escribir.

```
Agente / canal
     |
     v
n8n Tool
     |
     v
Booking API  <-- autoridad de disponibilidad y mutación
     |
     +--> Directus: configuración de negocio
     +--> PostgreSQL: estado / transacción
     +--> adaptadores Google/Outlook
```

Regla de solapamiento base:

```
existing.start_at < requested.end_at
AND existing.end_at > requested.start_at
```

Solo deben bloquear por cita activa los estados scheduled y confirmed. En un reschedule se excluye la propia cita. La disponibilidad real también debe considerar horarios, excepciones, buffers, ausencias, recursos y eventos externos.

La comprobación read-then-write puramente en n8n puede sufrir carreras. El Booking API debe hacer check+write de forma atómica o aplicar locking/constraint transaccional equivalente.

## 11. Modelo booking Directus: estado exacto

Se inició la construcción manual en demo para validar primero la UX y la metadata real que genera Directus 12.2.0. Después se hará snapshot y se limpiará el diff. Este enfoque evita escribir a mano una gran cantidad de YAML M2M sensible a versión.

| Colección | Estado | Contenido |
| --- | --- | --- |
| locations | Creada | name, code, timezone, address, phone, email, active, timestamps. Registro Oficina principal. |
| calendars | Creada | Agenda lógica; M2O opcional a location; timezone; active. Agenda principal. |
| services | Creada | duration, buffers, booking_mode=fixed_duration, active. Consulta general. |
| resources | Creada | resource_type, employee/location/calendar opcionales, capacity, active. Recurso humano de prueba. |
| service_resources | En ajuste/validación | Junction services↔resources. M2M funcional desde services.resources; inversa en resources se descartó por problema list-m2m. |
| availability_rules | Pendiente | Horario recurrente por recurso. |
| availability_exceptions | Pendiente | Disponibilidad/no disponibilidad excepcional. |
| appointment_resources | Pendiente | Junction appointment↔resource. |
| appointments | Pendiente ampliar | Añadir service_id, calendar_id, location_id y recursos. |

### 11.1 Hallazgo Directus M2M

Al intentar crear una interfaz inversa M2M adicional en resources sobre la misma junction service_resources, Directus 12.2 rompió la interfaz con «Interfaz list-m2m no encontrada». Decisión actual: mantener un único M2M editable desde services.resources y no forzar resources.services. La relación física sigue siendo bidireccional para API/SQL.

### 11.2 Modelo objetivo restante

```
locations
  ├── calendars
  └── resources

services
  └── resources (M2M vía service_resources)

resources
  ├── availability_rules
  ├── availability_exceptions
  └── appointments (vía appointment_resources)

appointments
  ├── contact_id
  ├── service_id
  ├── calendar_id
  ├── location_id
  ├── start_at / end_at
  └── resources
```

## 12. Puntos pendientes y plan de implementación

### 12.1 Prioridad 1 — Terminar modelo Directus booking

1. Crear availability_rules por resource: day_of_week ISO 1–7, start_time, end_time, valid_from/valid_until, active.
1. Crear availability_exceptions por resource: exception_type available/unavailable, start_at, end_at, reason, active.
1. Crear appointment_resources con appointment_id y resource_id.
1. Ampliar appointments con service_id, calendar_id y location_id nullable por compatibilidad; añadir alias de resources si Directus lo permite de forma estable.
1. Validar con datos reales de prueba y revisar UX.
1. Generar schema snapshot desde Directus 12.2.0.
1. Comparar snapshot con directus/schema/base.yaml y eliminar metadata accidental.

### 12.2 Prioridad 2 — Índices y constraints

No confiar en base.yaml como sistema completo de migraciones PostgreSQL para índices compuestos y constraints. Añadir una capa SQL idempotente, por ejemplo directus/sql/booking-indexes.sql, e integrarla en apply-schema.sh respetando PLAN/APPLY.

```
Índices simples esperados:
appointments.service_id
appointments.calendar_id
appointments.location_id
appointments.start_at
appointments.end_at
appointments.status
resources.employee_id
resources.location_id
resources.calendar_id
service_resources.service_id
service_resources.resource_id
appointment_resources.appointment_id
appointment_resources.resource_id
availability_rules.resource_id
availability_exceptions.resource_id

Índices/unique compuestos deseados:
appointments(status, start_at, end_at)
availability_rules(resource_id, day_of_week)
availability_exceptions(resource_id, start_at, end_at)
UNIQUE service_resources(service_id, resource_id)
UNIQUE appointment_resources(appointment_id, resource_id)
```

Antes de integrar SQL, inspeccionar la versión vigente de directus/apply-schema.sh para conservar su comportamiento PLAN/APPLY y su forma de acceder a la base de datos del tenant.

### 12.3 Prioridad 3 — Booking API

1. Definir contrato de disponibilidad: servicio, fecha/rango, ubicación opcional, recurso opcional y timezone.
1. Resolver recursos activos compatibles con el servicio.
1. Aplicar availability_rules.
1. Aplicar availability_exceptions.
1. Aplicar duración y buffers del servicio.
1. Restar citas activas scheduled/confirmed asociadas por appointment_resources.
1. Incorporar eventos externos Google/Outlook como bloques.
1. Generar slots deterministas.
1. En create/reschedule: repetir comprobación inmediatamente antes de escribir.
1. Implementar check+write transaccional/atómico para evitar doble reserva.
1. Hacer que Booking API sea propietario de create/reschedule/cancel, desplazando gradualmente las escrituras directas desde n8n.

### 12.4 Prioridad 4 — Tool de disponibilidad para el agente

Crear una herramienta n8n de Appointment Availability que consulte Booking API. No conectar todavía el conjunto final de herramientas al agente principal hasta disponer de esta pieza y de la revalidación autoritativa en las mutaciones.

### 12.5 Prioridad 5 — Integraciones de calendario

Directus debe conservar el modelo de negocio agnóstico al proveedor. Google/Outlook son adaptadores. La plataforma ya ha trabajado con sincronización bidireccional Directus↔Google y Directus↔Outlook, pero el modelo futuro debe evitar convertir IDs de proveedor en el núcleo del dominio.

## 13. Decisiones todavía abiertas

| Tema | Estado / riesgo | Recomendación |
| --- | --- | --- |
| Recursos compuestos | service_resources representa A O B, no profesional Y sala. | Decidir antes de congelar Booking V1 si casos como terapeuta+cabina son core. |
| resources.calendar_id | V1 permite 0..1 agenda principal por recurso. | Validar si un recurso debe pertenecer a múltiples agendas. |
| Horarios comunes | availability_rules solo por recurso puede duplicar horario de oficina. | Mantener V1 simple salvo necesidad real; futuro baseline por calendar/location. |
| capacity | Campo existe, pero V1 calcula esencialmente capacidad 1. | No prometer reservas grupales hasta implementar semántica real. |
| service_locations | No existe; se infiere por resource.location_id. | Añadir solo si aparecen servicios restringidos por sede que no se expresen bien por recursos. |
| Snapshot vs SQL | Directus cubre modelo; no todos los constraints compuestos. | Mantener separación base.yaml + SQL idempotente. |
| Campos external_provider/event_id | Compatibilidad legacy. | Mantener de momento; futuro mapping/adaptador separado. |

## 14. Seguridad y secretos

- No almacenar tokens/restic credentials/static tokens en Git.
- Mantener secretos por tenant bajo /opt/aegora/tenants/<tenant>/secrets con permisos mínimos.
- El administrador humano no debe ser dependencia de automatización.
- Las notificaciones no deben incluir PII ni secretos.
- Mantener clave Git del VPS read-only.
- No usar tenant id aegora por coexistencia con infraestructura legacy.

## 15. Checklist operativo para un nuevo equipo

1. Clonar/actualizar el repositorio local y revisar feature/backup.
1. Leer los --help de scripts de provisioning antes de altas reales.
1. Comprobar demo y aegora-internal antes de modificar schema.
1. No actualizar Directus hasta completar pruebas de regresión del provisioning.
1. Finalizar modelo booking en demo.
1. Snapshot + diff + commit local + push.
1. Actualizar VPS solo desde origin; nunca push desde VPS.
1. Aplicar schema y reiniciar Directus antes de overlays UI.
1. Probar onboarding dos veces para idempotencia.
1. Probar backup, prune, health y restore-test del tenant.
1. Implementar SQL idempotente de índices/constraints.
1. Construir Booking API y disponibilidad determinista.
1. Añadir test de concurrencia/doble reserva.
1. Solo después integrar Tool Availability y conectar herramientas al agente principal.

## 16. Runbook rápido de diagnóstico

### Git / código desplegado

```
cd /opt/aegora/platform
git fetch
git status
git log --oneline --decorate --graph -6 --all
git diff --stat HEAD origin/feature/backup
```

### Contenedores

```
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker logs <tenant>-directus --tail 200
docker logs <tenant>-n8n --tail 200
```

### Directus health

```
# Desde el entorno/red correspondiente:
curl -fsS http://<tenant>-directus:8055/server/ping
```

No sustituir por /server/health mientras se mantenga Directus 12.2.0.

### Backups / timers

```
systemctl list-timers --all | grep aegora
systemctl status aegora-backup@<tenant>.timer
journalctl -u aegora-backup@<tenant>.service --since today
journalctl -u aegora-backup-health@<tenant>.service --since today
journalctl -u aegora-restore-test@<tenant>.service
```

## 17. Criterios de aceptación antes de considerar estable una entrega

- Git remoto contiene el commit desplegado y VPS está limpio.
- Tenant arranca y Directus /server/ping responde.
- Schema + restart + acceso técnico + UI + español completan sin intervención humana.
- Segunda ejecución de onboarding no crea duplicados ni rompe estado.
- Caddy publica únicamente cuando DNS y servicios están preparados.
- Backup externo existe y health check es correcto.
- Existe restauración de prueba reciente satisfactoria.
- No hay secretos en repositorio ni logs/notificaciones.
- Para booking: ningún create/reschedule puede saltarse la comprobación autoritativa de disponibilidad.
- Existe prueba de carrera/concurrencia antes de producción real de booking.

## 18. Conclusión y siguiente hito recomendado

La parte de infraestructura y operación ha pasado de un modelo más artesanal a uno reproducible: Git remoto canónico, provisioning por tenant, idempotencia, acceso técnico desacoplado del usuario humano, backups externos y restauraciones de prueba. El principal frente abierto ya no es la base operativa, sino cerrar el dominio de booking y trasladar la autoridad de disponibilidad/escritura a un Booking API transaccional.

El siguiente hito recomendado es terminar availability_rules, availability_exceptions, appointment_resources y la ampliación de appointments en demo; generar el snapshot; incorporar índices/constraints SQL idempotentes; y solo entonces comenzar el Availability/Booking Engine.

## Anexo A — Inventario de rutas y nombres

| Elemento | Valor |
| --- | --- |
| Repo local | ~/proyectos/aegora-platform |
| Repo VPS | /opt/aegora/platform |
| Rama | feature/backup |
| Tenant root | /opt/aegora/tenants/<tenant> |
| Caddy runtime sites | /opt/aegora/data/caddy/sites/<tenant>.caddy |
| Proxy network | aegora_proxy |
| Postgres compartido | aegora-postgres |
| Caddy compartido | aegora-caddy |
| Tenants conocidos | demo, aegora-internal |
| Tenant reservado/no usar | aegora |
| Directus | 12.2.0 |
| Provisioning secret | /opt/aegora/tenants/<tenant>/secrets/directus-provisioning.env |
| Restic secret | /opt/aegora/tenants/<tenant>/secrets/restic.env |

## Anexo B — Principios que no deben perderse

- Producción no es un entorno de desarrollo: no hacer push desde VPS.
- Un tenant debe poder reconstruirse/reconciliarse mediante scripts, no memoria humana.
- PLAN antes de APPLY.
- Reintentar debe ser seguro: idempotencia como requisito de diseño.
- Backup sin restore-test no es suficiente.
- Directus es configuración/CRM, no motor de disponibilidad.
- n8n orquesta; no debe ser la autoridad final de concurrencia de booking.
- El agente puede sugerir, pero no decidir disponibilidad.
- Proveedor externo de calendario es un adaptador, no el modelo de negocio.
- Mantener compatibilidad con datos legacy mediante FKs nullable y migraciones graduales.

