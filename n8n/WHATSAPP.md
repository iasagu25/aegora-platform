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

## Número de pruebas de Meta (para `dev`)

Meta da un **número de prueba gratuito** por app, y es exactamente lo que quieres
para un tenant de desarrollo. Dos cosas que no son evidentes:

**El webhook se define en la APP, no en el número** (App → WhatsApp →
Configuración). Por eso no aparece en la pantalla del número. Y de ahí sale lo
importante: **una app = un webhook**. La app de `demo` ya apunta a su host, así
que `dev` necesita **su propia app de Meta**, no un número más dentro de la de
`demo`. Las dos pueden colgar del mismo Meta Business.

**El número de prueba solo escribe a 5 destinatarios** que tú das de alta y
verificas en el panel. Para `dev` no es una limitación, es una red: ese tenant
no puede escribirle a un cliente real por error.

Pasos:

1. developers.facebook.com → Crear app, tipo **Empresa** → añadir el producto
   **WhatsApp**. Meta crea el número de prueba y un WABA de prueba.
2. En *API Setup*: apuntar el **Phone number ID** y dar de alta tu móvil en
   *To* (te llega un código de verificación).
3. **App Secret**: App → Configuración → Básica.
4. **Webhook**: App → WhatsApp → Configuración →
   URL `https://lucia.dev.aegora.es/webhook/whatsapp`, verify token el tuyo,
   y suscribirse al campo **`messages`**.
5. **Token permanente**: el que enseña *API Setup* caduca en 24 h y `dev` se
   rompería a diario. Hace falta un System User token como el de arriba.

El resto (fichero `secrets/whatsapp.env`, credencial de n8n, `render-workflows.sh`)
es idéntico a un tenant de pago. El número de prueba **no se puede convertir**
después en uno real, pero para `dev` da igual: nunca va a serlo.

## En n8n (por tenant)

- Credencial **Header Auth** `WhatsApp` (el nombre ya no lleva el tenant):
  `Authorization: Bearer <WHATSAPP_TOKEN>`.
- Nodo `Config (editar por tenant)`: `phone_number_id`, `verify_token`,
  `app_secret`, `graph_version`, `tenant`, `require_signature`.
  Los `REPLACE_*` del JSON son placeholders a propósito — esos valores **no van
  a Git**. Ya **no hay que reescribirlos a mano tras cada import**:
  `render-workflows.sh` los rellena desde `secrets/whatsapp.env` (y te dice en
  el plan si no los encuentra, en vez de importar un adapter roto en silencio).
  En sentido contrario, `export-workflows.sh` los devuelve a `REPLACE_*`.
- Activar el workflow (el webhook de producción solo responde activo).

> El campo `app_secret` tiene que ser el **App Secret** (32 hex de App →
> Configuración → Básica), NO el token de acceso. Si empieza por `EAA…` es un
> token y la firma nunca cuadrará. Fue exactamente lo que pasó durante meses.
>
> `require_signature` está en **`true`**: una petición sin firma válida se
> descarta. Es lo que impide que cualquiera que conozca la URL del webhook
> falsifique un evento de Meta y haga actuar a Lucía como si fuera otro número.
> Si se toca el App Secret, comprobar `firma` en la salida de
> `Code · Verificar firma` ANTES de dar por bueno el cambio: con la exigencia
> activada, un secreto equivocado deja WhatsApp mudo sin error visible.

## Cuando Meta ve el mensaje y a n8n no llega nada

Síntoma: la URL se verifica, `messages` está suscrito, el panel de Meta enseña la
carga útil del mensaje entrante... y en n8n no hay ni una ejecución. Nuestro
extremo responde (`curl -X POST` al webhook devuelve 200), así que el problema
está del lado de Meta.

Hay **dos niveles de suscripción** y solo uno se configura en la pantalla del
webhook: el de la *app* (la URL y los campos) y el del **WABA**, que tiene que
estar suscrito a esa app. Con números de prueba el segundo no siempre se crea
solo, y su ausencia produce exactamente este síntoma.

Comprobarlo:

    sudo bash -c 'set -a; . /opt/aegora/tenants/<t>/secrets/whatsapp.env; set +a;
      curl -s "https://graph.facebook.com/v21.0/${WHATSAPP_WABA_ID}/subscribed_apps" \
        -H "Authorization: Bearer ${WHATSAPP_TOKEN}"'

Si responde `(#200) You do not have permission to access this field`, el problema
es el TOKEN, no la suscripción -- ni siquiera se puede leer. Se ve de un vistazo:

    curl -s "https://graph.facebook.com/v21.0/debug_token?input_token=${WHATSAPP_TOKEN}&access_token=${WHATSAPP_TOKEN}"

Qué mirar en la respuesta:
- `scopes` tiene que incluir **`whatsapp_business_management`**. Con solo
  `whatsapp_business_messaging` se puede ENVIAR pero no tocar suscripciones, y es
  lo que falta cuando se genera el token deprisa.
- `granular_scopes` sin `target_ids` delata que **el WABA no está asignado** al
  usuario del sistema -- que es la causa de fondo, no un detalle.
- `expires_at` distinto de `0` es un token temporal: el tenant se rompe solo en
  24 h sin que nadie haya tocado nada.

Y al regenerar el token hay que cambiarlo en **dos sitios**: `secrets/whatsapp.env`
y la credencial `WhatsApp` del n8n de ese tenant, que ningún script toca. Cambiar
solo el fichero deja el adapter enviando con el token viejo.

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
