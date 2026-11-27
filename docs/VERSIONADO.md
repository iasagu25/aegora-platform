# Versiones y despliegue a tenants — estrategia

Propuesta del 26/nov/2026. **Fase 1 hecha el mismo día** (primer release: `v2026.11.26`) y **fase 2 el 27/nov**
(`provisioning/tenant/actualizar-tenant.sh`). Cómo se corta y se despliega un release:
`releases/README.md`. Con cuatro tenants se sabe de memoria qué tiene cada uno. Con
diez ya no: el síntoma conocido es "en `dev` funciona y en `demo` no", y la causa es una
pieza de otra semana.

## El problema, en concreto

**Un tenant no tiene "una versión": tiene unas diez capas, y cada una la pone un script
distinto, en un momento distinto.**

| capa | la aplica |
|---|---|
| esquema + SQL (`base.yaml`, `directus/sql/`) | `apply-schema.sh` |
| interfaz de Directus (vistas, displays, español, presets, Insights) | `configure-directus-{views,ui,presets,insights}.sh`, `configure-spanish-ui.sh` |
| permisos (rol gestor, rol n8n) | `configure-tenant-role.sh`, `configure-n8n-service.sh` |
| extensiones de Directus | `configure-directus-extensions.sh` |
| workflows de n8n | `render-workflows.sh` (con o sin `--only`) |
| Booking API (otro repo) | `deploy-booking.sh` (imagen `aegora-booking:<sha>`) |
| `compose.yml` / `.env` / manifiesto de backup | `render-tenant-config.sh` + recrear |
| plantillas de WhatsApp | `whatsapp-templates.sh` |
| plataforma compartida (Caddy, webchat, timers de backup) | el propio checkout, en cuanto se hace `git reset` |

A eso se suman tres agravantes:

- **Un único checkout para todos** (`/opt/aegora/platform`). Un `git reset` cambia el disco
  de todos los tenants y no cambia ninguno hasta que alguien ejecuta un script contra él.
  Por eso la versión del checkout no dice nada sobre la de un tenant.
- **Nada registra lo que se aplicó.** Lo que hay en cada tenant solo se sabe por la memoria
  de quien lo hizo y por este historial de chat.
- **Los despliegues parciales y los pasos olvidados no dejan rastro.** Dos casos reales:
  - `17` llegó a `demo` por `--only` con una semana de desfase.
  - `configure-directus-ui` se olvidó en `dev` y en `ops`, y los teléfonos volvieron a
    salir como UUID.

Y `main` va 449 commits por detrás de `feature/backup`: hoy la rama no significa nada.

## Principios

1. **La unidad de versión es un _release_ de plataforma, que es un tag de Git.** Un tenant
   de cliente está siempre en un release, nunca "en un commit".
2. **`dev` va por la rama. Los demás tenants, solo por tags.**
3. **Un solo tren.** Todos los tenants de cliente van al mismo release. Mantener N versiones
   vivas a la vez es exactamente cómo se pierde la cuenta. Si un cliente tiene que quedarse
   atrás, es una excepción y se anota.
4. **Lo aplicado lo registra el propio script que lo aplica,** en el tenant y no a mano.
5. **Un solo comando actualiza un tenant a un release.** Los scripts actuales son sus pasos
   y no se reescriben.
6. **Lo que no se puede automatizar se escribe en la nota del release.** Son los paneles de
   Meta y Retell, las credenciales de n8n y la aprobación de plantillas. El comando comprueba
   lo que pueda comprobar.

## 1. Releases

**Nombre: CalVer, `vAAAA.MM.DD`** (`v2026.11.26`, y `v2026.11.26.2` si sale otro ese día).
SemVer sirve para avisar a terceros que consumen una API, y aquí no los hay. Lo útil es
saber **cuánto de viejo** es lo que corre en un tenant, y eso lo dice la fecha.

**Ramas:**
- `main` se pone al día con `feature/backup` (fast-forward, no hay divergencia) y pasa a ser
  la rama de trabajo.
- Las ramas de funcionalidad son cortas y se fusionan en `main`.
- Los tags se crean siempre sobre `main`.

**Cada release lleva `releases/vAAAA.MM.DD.md`**, escrito al cortar el tag:

```markdown
# v2026.11.26
Probado en dev: 2026-11-25 (release candidato = commit 2c00247)
Booking API: <sha o tag de aegora-booking>

## Qué cambia
- ...

## Antes de desplegar (manual)
- [ ] Credencial `Gmail` creada en todos los tenants (el render la exige)

## Después de desplegar (manual)
- [ ] Suscribir `smb_message_echoes` en la app de Meta del tenant

## Riesgos
- Esquema: solo altas / BORRA columnas (ver "Volver atrás")
- Recrear contenedores: sí/no
```

**Versión de Booking API fijada en el release:** un fichero `release.env` en la raíz con
`BOOKING_REF=<sha>`. `deploy-booking.sh` lo lee si no se le pasa otra. Así el tag de
plataforma fija también la versión del otro repo.

## 2. Registro de lo desplegado en cada tenant

Va en `/opt/aegora/tenants/<t>/state/despliegues.jsonl`, una línea por cada `--apply` que
termina, y solo se añade, nunca se reescribe:

```json
{"fecha": "2026-11-26T10:12:03+01:00", "componente": "workflows", "release": "v2026.11.26",
 "commit": "f67591d0a1b2", "sucio": false, "parcial": null, "detalle": null, "usuario": "aegora"}
```

**Solo se anotan las pasadas que terminan bien.** Un fallo a mitad no deja versión, así que
la capa sigue mostrando la que tenía, que es lo que de verdad hay (o algo a medias, y por eso
conviene repetir la pasada).

- Una función común, `scripts/lib/registrar-despliegue.sh`, a la que llama cada script al
  final de su `--apply`. Es el mismo patrón que `esperar-contenedor.sh`. Componentes:
  `esquema`, `extensiones`, `vistas`, `ui`, `espanol`, `presets`, `insights`,
  `rol-gestor`, `rol-n8n`, `workflows`, `booking`, `config` y `plantillas-whatsapp`. Un
  script nuevo que modifique un tenant registra el suyo, y se añade a `GRUPOS` en
  `aegora-estado.sh`.
- `release` sale de `git describe --tags --exact-match`. Si el checkout no está en un tag, va
  `null`, y si tiene cambios sin commitear, `commit` lleva `-sucio`.
- `parcial` guarda el `--only` usado. **Un parcial no cuenta como versión de la capa**: el
  estado lo enseña como `v2026.11.20 + VOZ- @2c00247`.

**`scripts/aegora-estado.sh`** lo lee y pinta la matriz. Es solo lectura y no toca
secretos, pero en el VPS va con `sudo`: los directorios de los tenants son de root. Sin
permiso, cada tenant sale como `(sin permiso: sudo)`, nunca escondido:

```
tenant  release       esquema       interfaz      workflows                   booking   hace
dev     (rama)        2c00247       2c00247       2c00247 + parcial(Entry)    9f1e2a0   hoy
ops     v2026.11.26   v2026.11.26   v2026.11.26   v2026.11.26                 9f1e2a0   hoy
jca     v2026.11.20   v2026.11.20   v2026.11.20   v2026.11.20 + VOZ- @2c00247 9f1e2a0   6 d
demo    v2026.11.20   v2026.11.20   ⚠ v2026.11.12 v2026.11.20                 7c3b111   6 d
```

Marca en amarillo:
- una capa que no coincide con el release del tenant;
- un parcial;
- un tenant que va por detrás del último tag.

**Un commit aplicado antes de etiquetarlo cuenta como ese release.** El estado traduce
commit -> tag, así que lo normal funciona: se prueba en `dev` el commit que va a salir y
luego se etiqueta, sin repetir la pasada. Con cambios sin commitear (`*`) no cuenta nunca.

**Esto solo ya responde a "en qué versión está cada tenant"**, y es lo primero que conviene
hacer. Los tenants actuales arrancan sin historial: al primer `--apply` de cada capa quedan
registrados, y hasta entonces aparecen como `desconocido`, que es la verdad.

## 3. El comando único: `actualizar-tenant.sh`

**Sí es viable, y no hace falta reescribir nada.** Cada paso ya existe, es idempotente, tiene
PLAN/APPLY y espera a los contenedores con la librería común. Hoy el orden se encadena a mano
leyendo el CLAUDE.md. El comando sería ese orden escrito una vez:

```
provisioning/tenant/actualizar-tenant.sh --tenant X [--apply] [--permitir-borrados] [--recrear]
```

| # | paso | detalle |
|---|---|---|
| 0 | comprobaciones previas | ver la lista de abajo |
| 1 | backup | `backup-tenant.sh`: es el punto de vuelta |
| 2 | `render-tenant-config.sh` | si hay diff, solo con `--recrear` (corta el servicio) |
| 3 | extensiones | + reinicio |
| 4 | `apply-schema --apply` | **reiniciar y esperar** (caché de esquema) |
| 5 | `configure-*` | views, ui, spanish-ui, presets, tenant-role, n8n-service, insights; luego **reiniciar y esperar** (caché de permisos) |
| 6 | `deploy-booking.sh` | con `BOOKING_REF` del release |
| 7 | `render-workflows.sh` completo | **nunca `--only`** |
| 8 | `whatsapp-templates.sh` | solo crea las que falten; dice cuáles quedan PENDING |
| 9 | pruebas de humo | `/server/ping`, `/api/health` de booking, número de workflows publicados, GET de verificación del webhook de WhatsApp |
| 10 | registro | `state/version` = el release, solo si TODO salió bien |

**Sin `--apply`** ejecuta el PLAN de cada paso y enseña un resumen: el diff de esquema, los
workflows que cambian, si hay que recrear contenedores, la versión de booking y los pasos
manuales de la nota del release.

**Comprobaciones previas.** Son lo que convierte las reglas del CLAUDE.md en algo que no
depende de acordarse:
- Para un tenant que no es `dev`, el checkout tiene que estar **exactamente en un tag** y
  limpio.
- **Ese release tiene que constar como aplicado en `dev`**: el comando lee el registro de
  `dev`. "dev primero" deja de ser una costumbre y pasa a ser una condición.
- Contenedores del tenant en pie y DNS respondiendo.
- Credenciales de n8n: ya lo comprueba `render-workflows`, pero aquí se adelanta al paso 0
  para no parar a mitad.
- **Si el plan de esquema borra campos o colecciones, se para** salvo con
  `--permitir-borrados`.

**Comportamiento ante un fallo:** se para en el primer paso que falla y lo registra. Volver a
ejecutarlo es seguro porque todos los pasos son idempotentes. `state/version` no se mueve
hasta que todo sale bien, así que un tenant a medias se ve a medias en `aegora-estado.sh`.

**Lo que NO hace:**
- crear credenciales de n8n;
- tocar paneles de Meta o Retell;
- aprobar plantillas;
- configurar DNS.

Esos pasos quedan como checklist en la nota del release, y el resumen del PLAN los repite.

**Varios tenants:** cuando haya más, `--todos` (o una lista) los recorre de uno en uno y se
para en el primer fallo. El orden es:
1. `dev`, que ya se ha probado;
2. **`ops`** como canario, porque es nuestro;
3. `demo`;
4. los clientes.

`onboard-tenant.sh` pasa a llamar a este comando para toda la parte de configuración, y así
se cierra el hueco de los `configure-*` que hoy no lanza.

## 4. Volver atrás

| capa | cómo |
|---|---|
| workflows, interfaz, permisos, extensiones, booking | desplegar el tag anterior con el mismo comando |
| esquema con solo altas | no hace falta: el código viejo ignora campos nuevos |
| esquema que borra | **no se deshace con Git**: restaurar el backup del paso 1 (`restore-tenant.sh`, ensayado) |

De ahí sale una regla de diseño: **los borrados de esquema van en un release aparte y
posterior al que deja de usarlos** (expandir primero, contraer después). Así casi cualquier
release se puede deshacer redesplegando el anterior.

## 5. El checkout compartido

Mientras se itera en `dev`, el checkout está en la rama y no en un tag. Mientras tanto, los
backups nocturnos de todos los tenants, Caddy y las páginas de webchat corren con el código
de la rama. Ya pasa hoy y no ha dado problemas, pero con el comando exigiendo un tag para
desplegar, habría que estar moviendo el checkout entre tag y rama.

La solución limpia son **dos checkouts**:
- `/opt/aegora/platform`, siempre en el último release;
- `/opt/aegora/platform-dev`, en la rama, solo para `dev`.

Requiere que los 28 scripts que fijan `PLATFORM_ROOT="/opt/aegora/platform"` lo deduzcan de
su propia ubicación (`BASH_SOURCE`). Es un cambio mecánico.

## Plan por fases

| fase | qué | resuelve |
|---|---|---|
| **1** ✅ | `main` al día; tags CalVer + `releases/*.md` + `release.env`; registro por tenant + `aegora-estado.sh` | **saber qué tiene cada tenant** |
| **2** ✅ | `actualizar-tenant.sh` con sus comprobaciones previas; `onboard-tenant.sh` lo usa | los pasos olvidados, el `--only` al promocionar y "dev primero" |
| **3** | dos checkouts (`PLATFORM_ROOT` deducido) | tener que mover el checkout entre `dev` y los releases |
| **4** | `--todos`; render incremental por hash; imagen de booking en GHCR | el tiempo de despliegue con muchos tenants |

Render incremental: `render-workflows` guarda en el registro un hash de cada workflow
renderizado e importa solo los que cambian. Decide el contenido, no un `--only` escrito a
mano, así que es rápido sin dejar el tenant mezclado. El reinicio de n8n sigue siendo uno.
