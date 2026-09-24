# Despachador HTTP de tools — `TOOLS-Dispatcher.json`

Una URL que expone las siete herramientas de Lucía a una plataforma externa de
agentes de voz (Retell, ElevenLabs Agents, la que sea).

## Por qué existe, y por qué el agente de voz NO llama a Entry

El turno del Core v2 tarda ~5,5 s (medido; ver `CLAUDE.md`). En un chat se tolera;
por teléfono son cinco segundos de silencio y el que llama cuelga. Así que en voz
**la plataforma trae su propio bucle LLM** —rápido y con streaming— y nuestras
tools son sus *custom functions*.

Eso no es un apaño para voz: es literalmente la arquitectura de v2 —*el LLM
entiende y redacta, las tools son dueñas de los hechos y de las escrituras*—
servida por HTTP en vez de por `Execute Workflow`.

**Y es la pieza que no depende de qué plataforma elijas.** Con ella montada,
probar la segunda es media tarde.

## Endpoint

    POST https://<WEBHOOK_HOST>/webhook/tool

Autenticación: **Header Auth** de n8n, con una credencial por tenant llamada
`Tool Dispatcher`. Se crea a mano en la UI de n8n del tenant (el blob va cifrado
y ningún script lo toca), y `render-workflows.sh` resuelve su id por el token
`__CRED_TOOL_DISPATCHER__`.

## Cuerpo

```json
{
  "tool": "reservar_cita",
  "args": { "fecha": "2026-09-25", "hora": "10:00", "servicio": "consulta fiscal" },
  "identidad": { "telefono": "34600111222", "session_key": "voz:34600111222" }
}
```

**`identidad.telefono` la rellena la PLATAFORMA desde los metadatos de la llamada,
nunca el modelo.** Es la misma regla que en WhatsApp: el teléfono lo pone el canal
y no se pregunta jamás. Si se cablea como un parámetro que el LLM pueda escribir,
cualquiera que llame puede operar sobre las citas de otra persona -- exactamente
el agujero que se cerró en el webhook de WhatsApp validando la firma.

`session_key` es opcional; si falta se compone como `voz:<telefono>`. Un hilo por
número y canal: una llamada y un WhatsApp del mismo cliente son conversaciones
distintas pero **el mismo contacto**.

### El dialecto de Retell (y por qué hubo que aceptarlo)

En una *custom function* de Retell **no se puede plantillar el cuerpo**: solo se
declara el esquema JSON de lo que rellena el modelo. Así que `identidad` no puede
existir — si se pusiera como parámetro del esquema, la rellenaría el LLM, que es
justo lo que el despachador existe para impedir.

Lo que Retell envía es esto, y basta:

```json
{ "name": "consultar_info",
  "args": { "pregunta": "horario del sábado" },
  "call": { "from_number": "+34600111222", "call_id": "…" } }
```

`Code · Validar` acepta los dos dialectos: `tool` o `name`, y el teléfono de
`identidad.telefono`, de `call.from_number` o —solo para webcalls, donde no hay
número— de `call.retell_llm_dynamic_variables.telefono`, que **fija quien crea la
llamada en el servidor, no el modelo**. `args` nunca es fuente de identidad,
aunque el modelo cuele ahí un teléfono.

Consecuencia práctica: **deja `Payload: args only` APAGADO** en cada función de
Retell. Encendido manda solo los argumentos, se pierde el objeto `call` y toda
llamada muere en `falta_identidad`.

## Qué acepta cada tool del modelo

Lo demás (teléfono, sesión, URLs, zona horaria) lo pone el servidor y se ignora
si viene en `args`.

| tool | argumentos del modelo |
|---|---|
| `anotar_tarea` | `asunto`, `tipo`, `prioridad`, `fecha_limite`, `hora_limite`, `para_quien`, `detalle`, `mensaje_original` |
| `cancelar_cita` | `fecha`, `hora` |
| `consultar_disponibilidad` | `fecha`, `fecha_hasta`, `franja`, `servicio`, `profesional` |
| `consultar_info` | `pregunta` |
| `mis_citas` | — |
| `reprogramar_cita` | `fecha`, `hora`, `fecha_nueva`, `hora_nueva` |
| `reservar_cita` | `fecha`, `hora`, `servicio`, `profesional`, `nombre`, `empresa` |

La fuente de verdad es el propio JSON del workflow, no esta tabla.

## Respuesta

La de la tool, **tal cual**: `{ok, motivo, ...}`. Esos contratos ya están
diseñados para que un LLM decida qué decir (`varios_servicios` con `opciones`,
`falta_identidad` con `falta`, `hueco_no_disponible` con `huecos_del_dia`…), así
que reinterpretarlos aquí sería inventar una segunda verdad.

Los errores de la puerta responden con la misma forma para que la plataforma no
necesite dos caminos: `falta_tool`, `herramienta_desconocida`, `falta_identidad`.

## Probarlo

    curl -s -X POST https://lucia.demo.aegora.es/webhook/tool \
      -H 'Content-Type: application/json' \
      -H '<cabecera de la credencial>: <valor>' \
      -d '{"tool":"consultar_info","args":{"pregunta":"¿qué horario tenéis?"},
           "identidad":{"telefono":"34600111222"}}'

Empezar por `consultar_info` y `mis_citas`: son de solo lectura y no arriesgan
nada. Dejar `reservar_cita` y `cancelar_cita` para cuando el resto responda bien.

## Lo que NO hace

- **No conversa.** No hay prompt aquí; el prompt vive en la plataforma de voz
  (parte de `n8n/prompts/lucia-v2.md`, quitándole el markdown: por teléfono no
  hay listas ni negritas, y hay que decir dos o tres huecos y ofrecer más).
- **No guarda la conversación.** La transcripción la tiene la plataforma; llevarla
  a `conversation_messages` es trabajo aparte, y entonces la bandeja de Directus
  enseñaría también las llamadas.
- **No transfiere a una persona.** Eso lo hace la plataforma de voz y hay que
  configurarlo: un agente sin salida es una trampa para quien llama.

## Confirmación por WhatsApp (24/sep/2026)

Después de `Responder` -- con la respuesta ya entregada a la plataforma de voz --,
`Code · ¿Confirmar por WhatsApp?` decide si hay que avisar al cliente y, si toca, lanza
`WHATSAPP · Enviar plantilla` **sin esperar a que termine**:

| la tool devuelve | plantilla |
|---|---|
| `reservar_cita` → `ok: true, motivo: reservada` | `aegora_cita_confirmada` |
| `reprogramar_cita` → `ok: true, motivo: reprogramada` | `aegora_cita_confirmada` (servicio de `antes`, día y hora de `cita`) |
| `cancelar_cita` → `ok: true, motivo: cancelada` | `aegora_cita_anulada` |
| cualquier otra cosa, o `canal` distinto de `voz` | nada (`no_aplica`) |

Parámetros: `[servicio, fecha_label, hora]`. Si falta alguno no se envía nada y la
ejecución dice por qué.
