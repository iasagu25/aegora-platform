# Conversación de Lucía — interfaz de Directus

Sustituye al `list-o2m` del campo `mensajes` de `conversation_sessions`.

## Por qué existe

La vista estándar de un O2M pinta una lista de registros ordenada por lo que
decide Directus, y **`list-o2m` no expone opción de ordenación**: el hilo salía
agrupado por autor en vez de cronológico, y no había forma de arreglarlo con
configuración. Contestar era "crear una fila y guardar".

Esto no es el caso del layout de calendario, que se descartó por competir con el
móvil que el cliente ya tiene: al pasar a WABA el negocio **pierde la app de
WhatsApp** y no hay alternativa. Además una *interface* es de las superficies más
estables de Directus, mucho más que un layout.

## Qué hace

- El hilo como conversación, ordenado por `created_at`, alineado por dirección.
- **El estado de la ventana de 24 h de WhatsApp**, con lo que queda. La ventana
  aplica también a la persona que escribe: un gestor que no la ve escribe, falla
  y deja de fiarse de la herramienta.
- Caja de respuesta. Crear la fila ES enviar: la recoge `HUMANO · Enviar
  pendientes`. Bloqueada, con el motivo escrito, cuando el canal no es WhatsApp,
  cuando la ventana está cerrada, o cuando el hilo sigue en modo `auto` -- si no,
  el cliente recibiría dos respuestas.
- **Las citas del contacto al lado del hilo.** No es adorno: es lo que evita que
  el gestor conteste "ya te la he apuntado" sin haberla creado, que es el único
  agujero que la memoria del agente no tapa.
- Sondeo cada 10 s, para que un mensaje nuevo aparezca sin recargar.

## Lo que NO hace

- No cambia `modo`. Ese campo está en el mismo formulario y un interface solo
  puede emitir el valor de SU campo; tocarlo por API por detrás pelearía con el
  estado del formulario. Se avisa y se deja la decisión en el desplegable.
- (Desde el 12/nov/2026 SÍ manda plantillas: ver abajo.)

## Plantillas (12/nov/2026)

Con WhatsApp, la caja tiene dos modos: **Mensaje** (texto libre, como siempre) y
**Plantilla**, que es lo único que sale con la ventana cerrada y por eso es el modo por
defecto en ese caso. Se elige la plantilla, la cita si la plantilla habla de una (día,
hora y servicio salen de ella), y el nombre viene de la ficha. Hay vista previa de lo que
recibirá el cliente.

- La lista sale de `n8n/whatsapp-templates.json` (las que llevan `gestor`), **importado al
  compilar**: tras tocar el catálogo, `npm run build` aquí y commit del `dist/`.
- La fila se crea con `plantilla`, `plantilla_parametros` y `texto` ya rellenado (lo que ven
  la bandeja y la memoria de Lucía). `HUMANO · Enviar pendientes` la manda como plantilla y
  no mira la ventana.
- Una plantilla vale en cualquier `modo`. En `auto`, si el cliente contesta, le responde
  Lucía; se avisa debajo de la vista previa.
- WhatsApp no admite saltos de línea en una variable: el texto libre se une con « · ».

## Construir

    npm install && npm run build

`dist/` va versionado: es lo que copia `configure-directus-extensions.sh` al
tenant. `node_modules` no.
