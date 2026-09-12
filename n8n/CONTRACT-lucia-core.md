# Contrato — `AGENT-Lucia-Core` (CONGELADO)

`n8n/workflows/AGENT-Lucia-Core.json` (id `aegoraAgentLuciaCore`). Lo invoca
`AGENT-Lucia-Entry` vía `Execute Workflow`. Este contrato es la frontera entre
la capa de canal/entrada y el cerebro. **No se cambia sin actualizar Entry.**

## Entrada (Entry → Core)

| campo | tipo | V1 |
|---|---|---|
| `message` | string | **req.** texto crudo del usuario en este turno |
| `sessionID` | string | **req.** `=== session_key`. Estable entre turnos. **Lo fija Entry**, nunca el LLM. Es la clave de `Postgres Chat Memory`. |
| `client_id` | string | tenant (`"demo"`) |
| `canal` | string | `"webchat"` \| `"whatsapp"` |
| `flujo_activo` | string\|null | de `conversation_sessions`; pista de reanudación para el router |
| `contact_phone` | string\|null | resuelto por Entry desde el canal (webchat: normalmente `null`) |
| `contact_name` | string\|null | identidad conocida, si la hay |
| `contact_company` | string\|null | |
| `booking_base_url` | string | base del Booking API del tenant |
| `directus_base_url` | string | base de Directus del tenant |
| `tenant_timezone` | string | IANA (`"Europe/Madrid"`) |
| `tool_forzada` | string\|null | reservado; V1 siempre `null` |
| `no_reinterpretar_intencion` | bool | reservado; V1 siempre `false` |
| `pending_appointment_id` | string\|null | cita ya localizada en un reschedule/cancel en curso. Entry la guarda en `state.pending_appointment_id` y la reinyecta mientras `flujo_activo` sea reschedule/cancel; el router la usa para NO volver a listar/desambiguar cada turno. |
| `last_appointment_id` | string\|null | última cita creada/tocada en la sesión (NO caduca con el flujo). `Emparejar cita` la usa como referencia implícita ("mejor pasarla al jueves" tras reservar) solo cuando ningún otro filtro (día/hora/ordinal) descartó ninguna candidata y el mensaje no es una petición en bloque ("todas"/"ambas"). |
| `offered_alt_slots` | boolean | true si el turno anterior ofreció "¿quieres que te diga los huecos libres?" tras un slot_taken/slot_conflict. Se consume en un turno. |
| `offered_alt_slots_date` | string\|null | la fecha exacta (`YYYY-MM-DD`) que falló, capturada en el momento del slot_conflict — el Core la copia tal cual, no la reinterpreta. |
| `offered_alt_slots_time` | string\|null | la hora (`HH:mm`) que falló; el router corta en seco si se vuelve a pedir ese mismo par fecha+hora. |
| `pending_appointment_service_id` | string\|null | servicio de la cita localizada, para poder consultar huecos al reprogramar sin volver a leer la cita. |
| `service_query`, `date`, `time`, `appointment_ref`, `appointment_date`, `appointment_time` | string\|null | **V1: Entry NO los envía.** La continuidad de slots la da `Postgres Chat Memory` + la regla CONTINUIDAD del prompt del Core. Se mantienen como inputs del trigger para paso explícito de slots en el futuro. |
| `texto_usuario` | string\|null | alias legacy de `message`; el prompt usa `texto_usuario || message`. |

## Salida (Core → Entry) — un único item

Todas las ramas producen un borrador determinista y pasan por
`Código · outcome` → **`Redactor`** (LLM `gpt-4o-mini` que solo reescribe el
borrador con tono natural, sin tocar datos; `onError` → borrador) →
**`Salida · normalizar`**, que garantiza esta forma exacta:

| campo | tipo | significado |
|---|---|---|
| `ok` | boolean | éxito de la operación (`false` = falló, normalmente recuperable) |
| `intent` | string\|null | intención clasificada/ejecutada (`create_appointment`, `reschedule_appointment`, `cancel_appointment`, `list_availability`, `create_task`, `knowledge`, `null`) |
| `reply_to_user` | string | texto a enviar al usuario (siempre presente; puede ser `""`) |
| `needs_user_reply` | boolean | `true` = esperando al usuario → la conversación sigue abierta |
| `flujo_activo` | string\|null | regla ÚNICA (abajo) |
| `contact_id` | string\|null | presente si un tool resolvió/creó contacto este turno; V1 **best-effort** |
| `pending_appointment_id` | string\|null | cita localizada este turno en un reschedule/cancel; Entry la persiste mientras el flujo siga abierto y la limpia en cuanto `flujo_activo` vuelve a `null` |
| `last_appointment_id` | string\|null | cita recién creada/reprogramada este turno; Entry la persiste sin caducar (se sobreescribe al tocar otra) |
| `awaiting_slots_offer` | boolean | true solo en el turno del slot_taken/slot_conflict; Entry lo guarda y lo reinyecta UNA vez, luego se limpia solo (cada turno lo sobreescribe con su propio valor, no hay `_prev`) |
| `contact_phone` | string\|null | teléfono que el Core extrajo del usuario este turno; Entry lo guarda en `state.contact_phone` y lo re-inyecta como `contact_phone` en turnos siguientes (así la identidad persiste entre intenciones) |
| `result` | object\|null | payload estructurado opcional (`appointment` / `task`) para logging |

### Regla única de `flujo_activo`

```
flujo_activo = null      si  needs_user_reply === false   (operación terminada)
                          o  intent es null / vacío        (saludo / genérico)
flujo_activo = intent     en cualquier otro caso           (seguimos en la operación)
```

Sin casos especiales. `slot_taken` / `ambigua` / "falta un dato" →
`needs_user_reply: true` → `flujo_activo = intent` → el siguiente mensaje del
usuario continúa la misma operación.

## Qué hace Entry con la salida

```
conversation_sessions.flujo_activo = out.flujo_activo
if (out.contact_id) conversation_sessions.contact_id = out.contact_id
conversation_sessions.updated_at   = now()
→ adapter: { reply: out.reply_to_user, needs_user_reply: out.needs_user_reply,
             session_key, canal, to: reply_to }
```

## Notas / deuda conocida

- **Memoria conversacional**: `Postgres Chat Memory` (`memoryPostgresChat`)
  sobre la BD `n8n_<tenant>`, tabla `n8n_chat_histories` (se crea sola),
  `sessionKey = sessionID`, `contextWindowLength: 10`. Sobrevive a reimports
  del workflow. Requiere la credencial `Postgres account` del tenant
  (re-seleccionar al importar; el `id` del JSON es un placeholder).
- `contact_id` en la salida es best-effort en V1 (los tools `19/22/23` aún no
  lo devuelven de forma consistente). Mientras tanto, Entry se apoya en el
  `contact.phone` que el Core re-extrae de memoria cada turno y los tools
  re-resuelven el contacto. Cuando queramos identidad firme: que `19/22/23`
  emitan `contact_id` y `Salida · normalizar` ya lo recoge.
- `booking_base_url` / `directus_base_url` / `tenant_timezone` los pone el nodo
  `Config (editar por tenant)` del Core con fallbacks `demo-*`. Multi-tenant =
  misma deuda que el `http://demo-directus:8055` hardcodeado en `00-25`.
