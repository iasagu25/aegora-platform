# Escribir por WhatsApp — interfaz de Directus

Campo de presentación `contacts.whatsapp`: un botón por cada móvil del contacto que abre
su conversación de WhatsApp en la bandeja (`conversation_sessions`) y la **crea si no
existe**, con la misma clave que usa el adapter (`whatsapp:<E.164 sin +>`). Así, si el
cliente contesta, su respuesta cae en ese mismo hilo.

## Por qué existe

Tras una llamada, el gestor quiere mandar algo por WhatsApp a alguien que nunca nos ha
escrito. No hay hilo, y la ventana de 24 h está cerrada: solo vale una plantilla. Desde
aquí se llega al hilo y, en él, la caja de respuesta de `directus-extension-aegora-conversation`
deja elegir la plantilla.

- Un hilo nuevo nace en `modo: auto` (decidido 12/nov/2026). En `humano` nadie se entera de
  que el cliente ha contestado hasta abrir el panel; en `auto` contesta Lucía, que tiene la
  plantilla en su memoria, y lo que no resuelva acaba en una tarea con aviso al equipo.
  Quien quiera llevarla él cambia «Modo» en el hilo.
- Un fijo español no sale, salvo que el teléfono tenga `can_whatsapp`.
- El gestor necesita `create` sobre `conversation_sessions` (`configure-tenant-role.sh`).

## Construir

    npm install && npm run build

`dist/` va versionado. En local, `node_modules` puede ser un enlace al de
`directus-extension-aegora-conversation` (mismas dependencias).
