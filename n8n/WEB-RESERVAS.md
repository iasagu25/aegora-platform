# Reservas desde la web — contrato de los webhooks públicos

**Estado: construido el 21/oct/2026, pendiente de probar en `dev`.** Workflows
`WEB-Disponibilidad.json` (`WEB · Disponibilidad`) y `WEB-Reservar.json` (`WEB · Reservar`). Lo
consume la isla de reservas de `aegora-web`. Se prueban en `dev` y se promocionan a `ops` cuando
exista; en la web solo cambia la URL base.

**Dos ajustes de tenant** (`tenant.env`, los resuelve `render-workflows.sh`):
- `WEB_SERVICIO`: nombre exacto del único servicio reservable. Por defecto `Demo de Aegora`.
- `WEB_ORIGENES`: orígenes permitidos, separados por comas. Por defecto
  `https://aegora.es,https://www.aegora.es,https://web.dev.aegora.es`; en `dev` se añade
  `http://localhost:4321`. Van como ajuste y no escritos en el JSON para que un export no
  arrastre al repo nombres que coinciden con el id de un tenant (`dev`, `demo`).

| tenant | URL base |
|---|---|
| `dev` (pruebas, la usa `web.dev.aegora.es`) | `https://lucia.dev.aegora.es/webhook` |
| `ops` (producción, cuando exista) | `https://lucia.<dominio de ops>/webhook` |

## Lo que la web NO hace nunca
- **No conoce el `BOOKING_API_TOKEN`** ni ningún otro secreto. Con ese token se reserva y se
  cancela cualquier cita del tenant; vive dentro de n8n.
- **No elige el servicio.** Los webhooks solo sirven el servicio de demo, fijado en el
  workflow. Un `service_id` en la petición se ignora.
- **No ve identificadores internos** (uuid de servicio, recurso, cita o contacto) ni nada de
  otras citas. Las respuestas solo llevan fechas, horas y plazas.

## Reglas comunes
- JSON en UTF-8. Horas en ISO 8601 **con offset** (`2026-10-27T10:00:00+01:00`); la zona es
  `Europe/Madrid`.
- Éxito: `{ "ok": true, ... }`. Error: `{ "ok": false, "motivo": "<código>", ... }` con el
  código HTTP de la tabla de errores. La web decide qué decir por el `motivo`, nunca por el
  texto.
- **Origen permitido** (cabecera `Origin`): `https://aegora.es`, `https://www.aegora.es`,
  `https://web.dev.aegora.es` y, **solo en `dev`**, `http://localhost:4321` (el servidor de
  desarrollo de Astro). Cualquier otro origen recibe `403 origen_no_permitido`.
- **Límite de peticiones por IP**: disponibilidad 60 cada 10 min; reserva 5 por hora. Al
  pasarse, `429 demasiadas_peticiones`. La web no tiene que reintentar sola.

## 1. `GET /web-disponibilidad`
Huecos libres del servicio de demo.

**Parámetros** (query):

| param | obligatorio | tipo | nota |
|---|---|---|---|
| `desde` | no | `YYYY-MM-DD` | por defecto, hoy. No puede ser anterior a hoy |
| `dias` | no | entero 1–31 | cuántos días desde `desde`; por defecto 14 |

La antelación mínima y el máximo de días vista los pone el servicio (Booking API): un día
dentro de ese margen simplemente no trae huecos.

**200**
```json
{
  "ok": true,
  "servicio": { "nombre": "Demo de Aegora", "duracion_minutos": 45 },
  "zona": "Europe/Madrid",
  "dias": [
    {
      "fecha": "2026-10-27",
      "fecha_label": "martes 27 de octubre",
      "huecos": [
        { "inicio": "2026-10-27T10:00:00+01:00", "hora": "10:00", "plazas": 4 },
        { "inicio": "2026-10-27T16:00:00+01:00", "hora": "16:00", "plazas": 1 }
      ]
    }
  ]
}
```
- `dias` solo trae los días **con** huecos, en orden. Lista vacía si no hay ninguno en el rango.
- `plazas`: las que quedan en ese hueco (la demo es una sesión en grupo). Útil para decir
  "quedan 2 plazas" cuando sean pocas; no hace falta enseñarlo siempre.
- `inicio` es lo que se manda tal cual a la reserva. `hora` y `fecha_label` son para pintar.

## 2. `POST /web-reservar`
Reserva una plaza en un hueco que devolvió la disponibilidad.

**Cuerpo**
```json
{
  "inicio": "2026-10-27T10:00:00+01:00",
  "nombre": "Ana García",
  "email": "ana@ejemplo.es",
  "telefono": "612345678",
  "empresa": "Gestoría García",
  "mensaje": "Contestamos el WhatsApp a mano y se nos escapan clientes.",
  "id_solicitud": "3f0c9a8e-5d2b-4c1e-9f7a-0b6d2e4c8a11",
  "sitio_web": ""
}
```

| campo | obligatorio | regla |
|---|---|---|
| `inicio` | sí | ISO con offset, uno de los `inicio` de la disponibilidad |
| `nombre` | sí | 2–100 caracteres |
| `email` | sí | formato de email, hasta 254 |
| `telefono` | sí | 9 dígitos españoles (6/7/8/9…) o internacional con `+`; se guarda en E.164 |
| `empresa` | no | hasta 120 |
| `mensaje` | no | "¿Qué te gustaría resolver?", hasta 1.000. Va a las notas de la cita |
| `id_solicitud` | sí | uuid que genera la web **una vez por envío del formulario** y repite si reintenta |
| `sitio_web` | — | **campo trampa**: oculto en la página y siempre vacío (ver abajo) |

**200**
```json
{
  "ok": true,
  "motivo": "reservada",
  "cita": {
    "inicio": "2026-10-27T10:00:00+01:00",
    "fecha_label": "martes 27 de octubre",
    "hora": "10:00",
    "duracion_minutos": 45,
    "servicio": "Demo de Aegora"
  }
}
```
- `motivo: "ya_estaba_reservada"`: el mismo `id_solicitud` ya reservó (un doble clic o un
  reintento), o esa persona ya tiene plaza a esa hora. Para el usuario es lo mismo: tiene su
  plaza. Se pinta igual que `reservada`.

**Qué pasa por dentro** (no es contrato, pero explica las respuestas):
- El contacto se busca por teléfono. **Si ya existe, se reutiliza y NO se modifica**: un
  formulario público no puede cambiar el nombre o el email de una ficha que ya está en el
  CRM. Si no existe, se crea con lo que llega.
- La cita lleva en las notas el `mensaje` y "Reservada desde la web".
- `id_solicitud` se convierte en la `idempotency_key` de la cita (`web:<id_solicitud>`).

## Campo trampa (`sitio_web`)
Un `<input>` que la persona no ve (fuera de pantalla, `tabindex="-1"`, `autocomplete="off"`,
`aria-hidden="true"`), y que muchos bots rellenan. Si llega con algo, el webhook **contesta lo
mismo que una reserva correcta sin reservar nada**: un 200 con la cita que se pidió. Así el bot
no aprende a esquivarlo. No usar `display:none`, que algunos bots detectan.

## Errores

| HTTP | `motivo` | cuándo | qué trae además |
|---|---|---|---|
| 400 | `datos_invalidos` | algún campo no cumple su regla | `campos`: `{ "email": "formato", "nombre": "obligatorio" }` |
| 400 | `parametros_invalidos` | `desde`/`dias` mal en la disponibilidad | — |
| 403 | `origen_no_permitido` | `Origin` fuera de la lista | — |
| 409 | `hueco_no_disponible` | el hueco se llenó entre consultar y reservar | `huecos_del_dia`: los que quedan ese día, mismo formato que en la disponibilidad |
| 429 | `demasiadas_peticiones` | límite por IP | — |
| 503 | `no_disponible` | el Booking API o Directus no responden | — |
| 500 | `error` | cualquier otra cosa | — |

Valores de `campos`: `obligatorio`, `formato`, `largo`.

## Lo que la interfaz tiene que resolver por su cuenta
- **Aviso de privacidad junto al botón** (Art. 13 RGPD): para qué se usan los datos (gestionar
  la demo y contactar sobre ella) y enlace a `/politica-privacidad`. No hace falta casilla:
  la base es la petición del propio interesado (Art. 6.1.b). Una casilla **aparte y sin marcar**
  solo si algún día hay newsletter.
- **No hay email de confirmación** todavía: la plataforma no manda correos. La confirmación es
  la pantalla final. Ofrecer ahí "Añadir a mi calendario" con un `.ics` generado en el
  navegador desde `cita` (no hace falta servidor).
- Ante `hueco_no_disponible`, enseñar `huecos_del_dia` sin volver a pedir los datos.

## Pendiente
- El servicio "Demo de Aegora" existe en `dev` y `demo` creado a mano; **no está en ningún
  seed**. Para `ops` hará falta uno.
- Cómo se entera Aegora de una reserva nueva: hoy aparece en el panel y en el `.ics` de quien
  la atiende. Si hace falta aviso inmediato, una tarea o un WhatsApp al equipo.
- **Correo de confirmación con enlace de Google Meet, desde `equipo@aegora.es`** (pedido
  21/oct/2026). Es lo siguiente: hoy no se manda nada. Encaja después de `Code · Resultado` en
  `WEB · Reservar`, sin esperar a que termine (la web no debe pagar los segundos del envío).
