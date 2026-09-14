# WhatsApp — `WHATSAPP-Adapter.json`

`WhatsApp Cloud API (WABA) → WHATSAPP · Adapter → AGENT · Lucía · Entry → Core`.
**Entry y Core no se tocan**: el adapter traduce entre Meta y el contrato de Entry.

## Alta en Meta (por tenant)

1. **System User token permanente**: business.facebook.com → Configuración del
   negocio → Usuarios → Usuarios del sistema. Asignar como activos **la App**
   (rol *Administrar aplicación*) **y el WABA** (control total) — hacen falta
   las dos. Generar token con caducidad *Nunca* y permisos
   `whatsapp_business_messaging` + `whatsapp_business_management`.
2. Guardar en `/opt/aegora/tenants/<tenant>/secrets/whatsapp.env` (root, 600):
   `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_WABA_ID`,
   `WHATSAPP_VERIFY_TOKEN` (te lo inventas: `openssl rand -hex 16`),
   `WHATSAPP_APP_SECRET` (App → Configuración → Básica).
3. **Webhook** en la App → WhatsApp → Configuración:
   - URL: `https://${WEBHOOK_HOST}/webhook/whatsapp`
   - Verify token: el `WHATSAPP_VERIFY_TOKEN`
   - Suscribirse al campo **`messages`**.

## En n8n (por tenant)

- Credencial **Header Auth** `WhatsApp · demo`:
  `Authorization: Bearer <WHATSAPP_TOKEN>`.
- Nodo `Config (editar por tenant)`: `phone_number_id`, `verify_token`,
  `app_secret`, `graph_version`, `tenant`, `require_signature`.
  Los `REPLACE_*` del JSON son placeholders a propósito — esos valores **no van
  a Git**.
- Activar el workflow (el webhook de producción solo responde activo).

## Cómo funciona

- Dos triggers de Webhook en el mismo path `whatsapp`, uno por método: n8n 2.31
  no admite varios métodos en un solo nodo Webhook pese a lo que sugiere su UI
  (probar con un array `httpMethod` se queda silenciosamente en uno solo). El de
  **GET** atiende la verificación `hub.challenge`; el de **POST**, los eventos
  reales. Ambos alimentan el mismo `Config` y de ahí en adelante el flujo es único.
- **GET** de verificación: compara `hub.verify_token` y devuelve `hub.challenge`
  en texto plano.
- **POST**: responde **200 de inmediato** y sigue procesando. Meta reintrega si
  tardas, y la cadena Core+tools puede pasar de 10 s.
- **Firma** `X-Hub-Signature-256`: HMAC-SHA256 del cuerpo **crudo** con el App
  Secret. El nodo Webhook va con `rawBody: true`. Empieza con
  `require_signature: false` y mira en el log de la ejecución la línea
  `[whatsapp] firma=...`; cuando diga `valida`, **ponlo a true**.
- **Duplicados**: el `wamid` viaja como `client_message_id` hasta Entry, que lo
  guarda en `conversation_sessions.state.last_client_message_id` y descarta la
  reentrega sin llamar al Core ni responder.
- **Statuses** (`sent`/`delivered`/`read`) llegan al mismo webhook y se ignoran.
- **No-texto** (audio, imagen): responde que de momento solo lee texto.
- `session_key` = `whatsapp:<E.164 sin +>`, así que el hilo es por número y el
  teléfono identifica al contacto desde el primer mensaje (a diferencia del
  webchat, que empieza anónimo).

## Aviso de privacidad — botón CTA-URL

El primer mensaje de cada sesión lleva el aviso de privacidad que ya compone Entry
(`n8n/CONTRACT-lucia-core.md` no aplica aquí, es interno de Entry). En WhatsApp se
manda como un **mensaje interactivo `cta_url`** separado del texto normal, con un
botón que abre la política de privacidad — no como un enlace en el propio texto:
WhatsApp no soporta enlaces con texto personalizado en mensajes de texto normales.

Consecuencia: cuando `privacy_prompt` viene relleno, `WHATSAPP · Adapter` manda **dos**
mensajes seguidos (botón, luego la respuesta real si la hay) en vez de uno. Tocar el
botón solo abre el navegador — no genera ninguna respuesta que el adapter tenga que
interpretar, a diferencia de los botones de respuesta rápida (tipo "Sí"/"No"), que sí
necesitarían manejar un mensaje entrante nuevo.

**Límite real de WhatsApp**: el texto del botón (`display_text`) no puede pasar de
**20 caracteres**. "Política de Privacidad" no cabe (22); se usa por defecto
`Ver política` (12), editable en el nodo `Config` de `AGENT-Lucia-Entry`
(`privacy_button_label`).

## Pendiente

- **Multi-tenant**: hoy el `phone_number_id` y el token son del tenant en el
  nodo Config. Con varios WABA habrá que resolver el tenant a partir del
  `phone_number_id` que viene en `value.metadata`, y guardar esas credenciales
  por tenant en Directus (Embedded Signup).
- **Debounce**: en WhatsApp la gente manda 3 mensajes cortos seguidos; hoy cada
  uno dispara un turno. Habría que esperar ~2-3 s y concatenar.
- **Plantillas**: para escribir fuera de la ventana de 24 h (recordatorios de
  cita) hacen falta plantillas aprobadas por Meta.
