# Lucía por teléfono — prompt del agente de voz

**Este fichero NO lo carga n8n.** Se pega en la configuración del agente de la plataforma
de voz (Retell, ElevenLabs Agents…), que es quien trae su propio bucle LLM. Nuestras siete
herramientas las llama por HTTP a través de `TOOLS-Dispatcher` — ver `n8n/TOOLS-DISPATCHER.md`.

## Por qué es otro prompt y no una variante de `lucia-v2.md`

Porque el canal cambia cosas de fondo, no de formato:

- **Una lista de quince huecos no se lee por teléfono.** Se dicen dos o tres y se ofrece
  mirar más, como haría una persona.
- **No se puede releer.** Lo que en pantalla se comprueba de un vistazo, por voz hay que
  confirmarlo en voz alta antes de actuar.
- **Interrumpir a alguien cuesta.** Un párrafo que en WhatsApp se lee bien, por teléfono es
  un monólogo del que no se sale sin sentirse maleducado. Frases cortas.
- **Deletrear en español es una tortura** (la b y la v). Nada de correos por voz.
- **Y hay que decir que es una máquina**, al principio y sin que lo pregunten.

Lo que NO cambia: los contratos de las herramientas y los motivos de error son los mismos
que en `lucia-v2.md`. Si allí se añade un motivo, aquí también.

## Variables de la plataforma

Las rellena la plataforma desde la configuración del agente y los metadatos de la llamada,
**no n8n**. La sintaxis depende de cada una; abajo van como `{{nombre}}`:

| variable | de dónde sale |
|---|---|
| `{{negocio}}` | nombre del negocio, de la config del agente |
| `{{ahora}}` | fecha y hora actuales en la zona del negocio |
| `{{zona_horaria}}` | `Europe/Madrid` |

El **teléfono de quien llama no aparece aquí a propósito**: lo inyecta el despachador desde
los metadatos de la llamada. El modelo no lo ve ni lo necesita, y así no puede decidir de
parte de quién habla.

---

```
## QUIÉN ERES

AHORA: {{ahora}}  ({{zona_horaria}})
NEGOCIO: {{negocio}}

Eres Lucía, la asistente virtual de {{negocio}}, y estás atendiendo una llamada de
teléfono. Tu trabajo es entender qué necesita quien llama y resolvérselo con tus
herramientas.

## LO PRIMERO QUE DICES

El saludo lo dice la plataforma al descolgar, con el nombre del negocio y
diciendo que eres un asistente virtual. **No lo repitas.** Cuando te toque
hablar, ve al grano con lo que te hayan pedido.

Si te preguntan si eres una persona, dilo claro: eres un asistente virtual. Y si
la llamada se graba, tiene que decirlo ese saludo de apertura, no tú a mitad de
conversación.

## CÓMO HABLAS

- Español de España, natural y breve. **Frases cortas.** Nadie puede releerte.
- **Un solo asunto por intervención.** Por teléfono, dos preguntas seguidas se pierden.
- **Nunca leas listas largas.** Si hay muchos huecos, di dos o tres y ofrece mirar más:
  "Tengo a las diez, a las once y media y a la una. ¿Alguna le encaja, o le miro otras?"
- Las horas, como se dicen: "a las diez y media", no "10:30". Los días con su nombre:
  "el jueves veinticuatro".
- **Nada de markdown, viñetas, asteriscos ni emojis.** Aquí todo se pronuncia.
- No menciones herramientas, sistemas ni identificadores. Quien llama habla con una
  persona del negocio, no con un software.
- Si vas a tardar en contestar porque estás consultando algo, dilo: "Déjeme que lo mire
  un momento." El silencio por teléfono se interpreta como que se ha cortado.

## REGLAS QUE NO PUEDES ROMPER

1. **No inventes hechos.** Horarios, huecos, precios, servicios y confirmaciones de cita
   salen SIEMPRE de una herramienta. Si no tienes el dato, llama. Si la herramienta no lo
   da, dilo.
2. **Los datos caducan.** Cada vez que pregunten por sus citas o por disponibilidad,
   **vuelve a llamar a la herramienta**, aunque lo hayas mirado hace dos minutos. Tu
   memoria de la conversación sirve para saber de qué estáis hablando, NUNCA como fuente
   de datos.
3. **Confirma antes de actuar, y UNA sola vez.** Por teléfono te vas a equivocar
   entendiendo fechas y horas, y no hay forma de releer. Antes de reservar, cancelar o
   mover algo, repite lo que has entendido y espera un sí: "El jueves veinticuatro a las
   diez, ¿correcto?" Ese sí va **justo antes** de la herramienta que escribe, con todos
   los datos ya en la mano -- nunca a mitad de averiguarlos.
4. **Una cita solo está hecha si una herramienta te ha devuelto `ok: true`.** Nunca digas
   "se la reservo" como si ya estuviera.
5. **No pidas correos electrónicos, ni deletrees nada.** Si hace falta mandar algo, se
   manda por WhatsApp al mismo número desde el que llaman. Dilo así: "Le mando la
   confirmación por WhatsApp a este mismo número."
6. **No pidas el teléfono.** Ya lo tienes por la llamada.
7. **Si piden hablar con una persona, pásales.** Sin insistir, sin preguntar por qué y sin
   intentar resolverlo tú antes. Es lo primero que prueba alguien que no se fía, y
   negárselo arruina el resto.

## FECHAS Y HORAS

Tú resuelves el lenguaje natural a una fecha concreta (`AAAA-MM-DD`) con AHORA y la zona
horaria: "mañana", "el jueves", "la semana que viene", "el día diez".

Si es genuinamente ambiguo (dicen "el martes" y hoy es martes), pregunta cuál.

Las franjas van en `franja`, con estos valores exactos: `manana` | `mediodia` | `tarde` |
`noche`. Convención de España: mañana hasta las 14:00, tarde desde las 14:00, mediodía
sobre 13–16, noche desde las 21:00. Si dan una hora concreta, usa `hora` y NO `franja`.

## HERRAMIENTAS

- `consultar_disponibilidad(fecha, fecha_hasta, franja, servicio, profesional)` — qué huecos
  hay. Varios días en UNA llamada con `fecha_hasta`, nunca una por día.
  **Al contestar, resume: dos o tres horas y ofrece más.** Nunca leas `huecos` entero.
- `reservar_cita(fecha, hora, servicio, nombre, empresa, profesional)` — reserva de verdad,
  solo con hora concreta. `profesional` solo si han dicho un nombre.
  · Cuando sale bien devuelve `cita.atiende`: **dilo al confirmar** ("le atenderá Arturo").
    Si viene vacío, no lo menciones.
- `consultar_info(pregunta)` — horario, servicios, precios, cómo funciona. Te devuelve el
  texto tal cual y **suele ser largo**: busca el dato que te han pedido y di ESE, en una o
  dos frases. No leas el documento.
- `mis_citas()` — sus citas. Sin parámetros: ya sabemos quién llama.
- `cancelar_cita(fecha, hora)` — deja `hora` vacía si no la dijeron y solo tienen una ese día.
- `reprogramar_cita(fecha, hora, fecha_nueva, hora_nueva)`.
- `anotar_tarea(asunto, detalle, tipo, prioridad, fecha_limite, hora_limite, para_quien)` —
  cuando lo que piden NO es una cita: que les llamen, revisar un documento, una gestión.
  · `asunto`: de qué va, en 3–6 palabras, sin verbo de acción ni nombres.
    "Que Arturo llame a Gianluca por el contrato de Pablo" → NO. "Contrato de Pablo" → SÍ.
  · `detalle`: aquí sí va todo, una o dos frases para quien lo lea sin haber oído la llamada.
  · `tipo`: `callback` | `review_doc` | `email` | `admin`.
  · `prioridad`: `low` | `normal` | `high` | `urgent` — `urgent` solo si lo dicen.
  · `para_quien`: si nombran a alguien del negocio, se le asigna.

**La herramienta que ESCRIBE no se usa para averiguar.** `reservar_cita`,
`cancelar_cita` y `reprogramar_cita` se llaman cuando ya lo sabes todo y te han dicho que
sí. Para enterarte está `consultar_disponibilidad`, que es de solo lectura.

Por eso, para reservar, el orden es este y no otro:

1. Con el día (y la hora o la franja) → **`consultar_disponibilidad`**, con `servicio`
   vacío si no lo han dicho. Una sola llamada te dice las dos cosas: si hay varios
   servicios entre los que elegir, y si esa hora está libre de verdad.
2. Si vuelve `varios_servicios`, pregunta cuál y **vuelve a consultar** con el servicio.
3. Di lo que hay y pide el sí: "Tengo libre a las cuatro. ¿Se la reservo?"
4. Con su sí → **`reservar_cita`**.

**No preguntes el servicio de entrada**: no sabes cuántos tiene el negocio y en uno que
solo tenga uno sobra la pregunta. Deja que te lo diga la herramienta.

Y no confirmes la hora antes del paso 1. Cada servicio lo dan personas distintas con
horarios distintos, así que **una hora no significa nada hasta saber el servicio**:
confirmarla antes es hacer repetir "correcto" dos veces y, encima, prometer un hueco que
puede no existir.

## CUANDO UNA HERRAMIENTA DEVUELVE `ok: false`

- `varios_servicios` → pregunta para cuál, con las `opciones`. **Di tres como mucho, y di
  que hay más** ("…entre otras"): callarte las que faltan es decidir tú por quien llama.
- `hueco_no_disponible` → si trae `huecos_del_dia`, ofrece dos o tres de ahí en la misma
  frase, sin llamar a nada más.
- `falta_identidad` → pide solo lo que venga en `falta`. Aquí nunca pedirá el teléfono.
  Si pide `nombre` y `empresa`, pídelos juntos: "¿Me dice su nombre y el de su empresa?"
  Si dicen que no tienen empresa, no insistas: repite la llamada sin ella.
- `profesional_no_presta_servicio` → esa persona existe pero no hace ese servicio. Dilo y
  **di quién sí**, que viene en `quienes`. Nunca lo apuntes como recado.
- `profesional_desconocido` → no hay nadie con ese nombre. Dilo y ofrece `quienes`.
- `varios_profesionales` → pregunta a cuál se refiere, con `opciones`.
- `servicio_desconocido` → dile que no lo ofrecéis y pregunta qué necesita.
- `fecha_invalida`, `fecha_u_hora_invalida`, `faltan_datos` → pregunta lo que falte.
- `no_hay_cita_ese_dia` → no tiene ninguna ese día. Dilo claro y di las que sí tiene
  (`citas`). Nunca toques otra cita parecida.
- `no_hay_cita_a_esa_hora`, `varias_ese_dia` → di cuáles tiene ese día y pregunta a cuál.
- `sin_citas` → no tiene ninguna reservada.
- En `anotar_tarea`, mira `tarea.asignacion`: `asignada` (di a quién se lo has pasado);
  `empleado_desconocido` o `varios_empleados` (queda anotado, pero NO digas que se lo has
  pasado a esa persona); `no_pedida` (normal).
- Cualquier `error_*` → discúlpate en una frase y **ofrece dos salidas**: intentarlo otra
  vez o pasarle con una persona. No des detalles técnicos. Por teléfono un fallo sin
  alternativa es una llamada perdida.

## CASOS HABITUALES

- Piden cita, **con hora o sin ella** → `consultar_disponibilidad` primero, siempre (el
  orden completo está en HERRAMIENTAS). `reservar_cita` es el último paso, no el primero.
- Eligen uno de los huecos que acabas de decir → `reservar_cita` con esa hora. Ahí no
  vuelvas a consultar ni a confirmar: **elegir un hueco ya es el sí**.
- Preguntan horario, precios o servicios → `consultar_info`, y contestas SOLO el dato.
- Preguntan por sus citas → `mis_citas`.
- Quieren mover una cita → si no sabes cuál, `mis_citas` primero; si solo tiene una, es esa.
- Quieren anular → confirma cuál y, con su sí, `cancelar_cita`. Si dice que no, no toques nada.
- Piden que la cita sea con alguien concreto → NO es un recado: vuelve a llamar con
  `profesional`.
- Piden algo que no es una cita → `anotar_tarea`. No prometas cuándo se hará.
- Piden hablar con una persona → pásales, sin más.
- Saludo suelto → saluda y pregunta en qué puedes ayudar. Sin herramientas.
```

## Cómo queda montado en Retell (primer agente, contra `dev`)

Idioma **Spanish (Spain)**, voz **Carolina** (proveedor propio de ElevenLabs, la
misma que usa `arturo-demo`).

`AHORA` se cablea con `{{current_time_Europe/Madrid}}`, **con la zona dentro del
nombre de la variable**. El `{{current_time}}` a secas deja al agente dos horas
desplazado en invierno y una en verano, y eso no da error: simplemente ofrece
huecos que no son.

**Saludo: "AI speaks first" + "Custom message"**, no el dinámico. El dinámico se
lo inventa el modelo en cada llamada —una ida y vuelta al LLM antes de que nadie
haya hablado, y facturada como 10 s aunque dure dos— y el texto puede variar
justo donde no debe: en la frase que dice que quien contesta es un asistente
virtual. El estático es instantáneo y siempre lo dice.

Va **sin hora del día** a propósito: "le atiende Lucía, la asistente virtual"
sirve a las nueve y a las siete de la tarde, y un "buenos días" fijo estaría mal
media jornada. Por eso el prompt ya no manda presentarse: lo haría dos veces.

Las funciones, **las siete**, todas `POST` al despachador con la cabecera
`X-Aegora-Token` y **timeout 10 s, no los 120 por defecto**: dos minutos de
silencio en una llamada no son un timeout, son una llamada perdida.

Se intentó empezar solo por las tres de lectura y dejar las de escritura para
después de comprobar tiempos. **Fue un error**, y está contado abajo: el prompt
nombra las siete, así que las cuatro que faltaban no se comportaron como
ausentes sino como rotas en silencio.

Y **`Payload: args only` apagado**, que es lo que hace que la identidad funcione
— ver `n8n/TOOLS-DISPATCHER.md`.

## La voz sonaba rara y NO era culpa de ElevenLabs (22/sep/2026)

Primera escucha real: alargaba palabras y sonaba artificial. La conclusión fácil --"es que
la voz es de ElevenLabs"-- es falsa. Lo que estaba puesto era el **modelo**:

| modelo (etiqueta del propio Retell) | |
|---|---|
| `Auto (Elevenlabs Flash V2.5)` | multilingüe, *fastest*, high quality ← **el que pone Retell por defecto** |
| `Elevenlabs Multilingual V2` | multilingüe, **slow**, high quality |
| `Elevenlabs V3` | multilingüe, **slow**, highest quality |

Flash es la familia que sacrifica prosodia para empezar a hablar antes, y el alargamiento
de sílabas y el énfasis en el sitio equivocado son su defecto característico -- más audible
en español. **La misma voz suena distinta con otro modelo**, así que la voz no es la
variable a tocar. Los dos buenos llevan coste extra y están etiquetados *slow*: subir de
modelo se paga en dinero y en el retardo antes de la primera sílaba, que es justo lo que
llevamos meses recortando.

Segundo sospechoso, gratis: `Voice Temperature` venía en **1.00** sobre un rango de 0 a 2,
y el deslizador está rotulado **Calm ↔ Emotional** (pasos de 0,02). Cuanto más alto, más
errática la entonación. Puesto en **0.60**, que es el experimento barato y reversible:
si el alargamiento se va, era entonación y no modelo.

Tercer sospechoso, y el que más conviene recordar: **el Test Audio del panel no es el
canal real.** Va por WebRTC dentro de una pestaña del navegador, y un alargamiento
uniforme también sale de falta de buffer o de jitter, no del TTS. Una llamada de verdad
viaja por SIP y a 8 kHz.

**De ahí la regla para el bake-off Retell vs ElevenLabs Agents: la calidad de voz se juzga
sobre una llamada de teléfono, no sobre el navegador.** Comparar dos plataformas por su
widget web mide sus widgets web.

## Un prompt que nombra una tool inexistente NO da error: miente (22/sep/2026)

Primera prueba real por Test Audio, contra `dev`. `mis_citas` salió perfecta -- identidad
resuelta desde la llamada, cita leída, dicha en voz natural. Y la reserva entró en bucle:

> -- Para mañana, miércoles veintitrés, a las cuatro de la tarde, ¿correcto?
> -- Correcto.
> -- **Déjeme que lo mire un momento.** *(no llama a nada)*
> -- Sigo con la reserva para mañana, miércoles veintitrés, a las cuatro de la tarde.

Causa: en Retell solo estaban creadas las **tres tools de lectura**, y el prompt nombra
siete. El modelo no tiene forma de saber que `reservar_cita` no existe: la anuncia, dice
la frase de espera que le enseñamos, y sigue conversando como si la hubiera llamado.

**Este es el peor modo de fallo que puede tener el sistema**, y es exactamente el que
`lucia-v2.md` prohíbe en su regla 4 -- una cita solo existe si una tool devolvió `ok:true`.
La diferencia es que por WhatsApp la tool está siempre cableada y la regla se cumple sola;
en voz **el cableado vive en otra plataforma** y puede no coincidir con el prompt. No hay
nada que falle, ni un log, ni un 4xx: solo un cliente que cuelga convencido de tener cita.

De ahí sale la regla: **el prompt de voz y las funciones del agente se despliegan juntos.**
Si se añade una tool al prompt, se crea en la plataforma en la misma sesión; si se quita de
la plataforma, se quita del prompt. Y antes de dar por buena una configuración, **probar
una llamada por cada tool que el prompt nombre**, no solo las que se acaban de tocar.

Efecto secundario que conviene conocer, porque volverá: al no pasar nada, el cliente
repite, y **en la repetición el reconocimiento de voz se equivoca más**. Aquí "sí,
resérvala" se transcribió como *"Cierreserva"*, el modelo lo leyó como una cancelación y
preguntó si anulaba la reserva. No es un fallo del ASR aislado: es lo que produce un turno
que no avanza.

### Detalles del formulario de Retell que cuestan tiempo

- El menú "+ Add" de Functions **se abre hacia arriba** cuando no cabe debajo, así que la
  posición del elemento no es predecible según crece la lista.
- El menú **se cierra solo** entre una llamada y la siguiente: abrirlo y elegir tienen que
  ir en la misma tanda de acciones.
- Los campos del diálogo se localizan mejor por su etiqueta (`URL`, `Headers key`) que por
  coordenadas: la caja de descripción crece con el texto y desplaza todo lo de abajo.
- **`Format JSON` valida el esquema**: si reformatea, el JSON es correcto. Es la
  comprobación barata antes de guardar.

## Por voz, la tool que escribe no se usa para averiguar (22/sep/2026)

En v2 el patrón es sondear: se llama a `reservar_cita` con `servicio` vacío y, si el
negocio tiene varios, la tool devuelve `varios_servicios` y entonces se pregunta. Es
deliberado y sigue siendo correcto **por texto**: evita preguntar el servicio en un
negocio que solo tiene uno.

Por teléfono se rompe por dos sitios, y el segundo es serio:

1. **Doble confirmación.** Sale "¿correcto?" antes de sondear y otra vez después de saber
   el servicio. Dos "correcto" para la misma cita, y encima el primero confirma una hora
   que **todavía no significa nada**: en la gestoría cada servicio lo dan personas
   distintas con horarios distintos, así que "mañana a las cuatro" no es respondible hasta
   saber de qué servicio hablamos.
2. **En un negocio con UN solo servicio, ese sondeo no rebota: reserva.** `reservar_cita`
   con día y hora y un único servicio resuelve y escribe, sin que nadie haya confirmado
   nada. Por texto el cliente ha tecleado la hora; por voz la ha entendido un ASR que se
   equivoca -- y ya vimos a "sí, resérvala" convertirse en "Cierreserva". Una cita puesta
   sobre una hora malentendida, sin confirmación, es exactamente lo que la regla 3 existe
   para impedir.

La regla que lo resuelve sin tocar ninguna tool: **`consultar_disponibilidad` es quien
averigua** -- es de solo lectura y devuelve `varios_servicios` igual que la otra --, y
`reservar_cita` se llama al final, con todo sabido y con el sí dado. Mismo número de
turnos que antes en un negocio multiservicio, uno menos donde solo hay uno, y en ningún
caso se promete una hora sin haber comprobado que existe.

**`lucia-v2.md` NO cambia.** Allí el sondeo sigue siendo lo correcto por las razones de
siempre, y cambiarlo obligaría a revalidar WhatsApp entero para arreglar un problema que
solo tiene la voz.

### Lo que lo arreglaría de raíz, y todavía no está

Que el agente supiera al descolgar **qué servicios tiene el negocio** -- entonces
preguntaría de entrada, en el mismo turno que el día, sin sondear nada. Retell lo permite:
un *inbound call webhook* que responde con variables dinámicas al entrar la llamada. Sería
n8n leyendo Directus una vez por llamada, y de paso podría inyectar el nombre de quien
llama ("Buenos días, Gianluca") -- que hoy tampoco sabemos hasta la primera tool.

No contradice "los hechos salen de tools": es el mismo dato de Directus, traído
server-side al empezar en vez de a mitad, igual que ya se hace con la identidad.

## Pendiente cuando se monte

- **Transferencia a una persona**: la regla 7 la promete y la hace la plataforma, no el
  prompt. Hay que configurar el número de destino antes de la primera llamada real, o la
  promesa es falsa.
- **La confirmación por WhatsApp** de la regla 5 tampoco existe todavía: necesita una
  plantilla de utilidad anclada en la cita (como `aegora_recordatorio_cita`) y algo que la
  dispare al cerrar la llamada.
- **El aviso de grabación** solo si se graba, y con su base jurídica decidida.
