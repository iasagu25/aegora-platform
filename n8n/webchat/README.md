# Webchat — widget V1

Widget mínimo sin dependencias para probar el flujo conversacional de Lucía
por webchat. Cadena completa:

```
widget.js  --POST /webchat-->  WEBCHAT · Adapter  -->  AGENT · Lucía · Entry  -->  AGENT · Lucía · Core
```

## Ficheros

| | |
|---|---|
| `widget.js` | Script embebible. Inyecta su CSS + DOM, botón flotante, panel de chat. |
| `demo.html` | Página de prueba local que carga `widget.js`. |

## Contrato HTTP

**Request** `POST <endpoint>`:
```json
{ "message": "Quiero una cita", "session_key": "<id de hilo o null>" }
```
**Response**:
```json
{ "reply": "Claro, ¿qué día te viene bien?", "needs_user_reply": true, "client_session_id": "w1abc…" }
```

El widget guarda `client_session_id` en `localStorage["aegora_webchat_sid"]` y
lo reenvía como `session_key` en cada turno (el Adapter le antepone `webchat:`).
Si el widget no manda id, el Adapter mintea uno y lo devuelve.

## Embeber

```html
<script src="https://TU-CDN/widget.js"
        data-endpoint="https://n8n.tu-dominio/webhook/webchat"
        data-title="Lucía"
        data-greeting="¡Hola! ¿En qué puedo ayudarte?"></script>
```

- `data-endpoint` (obligatorio): URL del webhook de producción del workflow
  `WEBCHAT · Adapter`. En modo test de n8n es `/webhook-test/webchat`.
- `data-title`, `data-greeting`: opcionales.

## Requisitos en n8n

1. Importar `n8n/workflows/WEBCHAT-Adapter.json` y `AGENT-Lucia-Entry.json`
   (+ el Core y sus tools).
2. `WEBCHAT · Adapter` → nodo **Config**: `allowed_origins` (`*` o lista de
   dominios separada por comas) y `tenant`.
3. Activar el workflow `WEBCHAT · Adapter` (el webhook de producción solo
   responde con el workflow activo).
4. CORS: el nodo Webhook lleva `allowedOrigins: '*'` para V1. Restríngelo por
   tenant cuando se publique.

## Fuera de V1

Streaming, adjuntos, audio, indicador de "escribiendo…", auth de usuario,
histórico persistente en el cliente, i18n. WhatsApp = otro adapter (WABA).
