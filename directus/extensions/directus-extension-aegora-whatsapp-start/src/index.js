import InterfaceComponent from './interface.vue';

export default {
  id: 'aegora-whatsapp-start',
  name: 'Escribir por WhatsApp',
  icon: 'chat',
  description: 'Abre la conversación de WhatsApp del contacto (y la crea si no existe), para escribirle tras una llamada.',
  component: InterfaceComponent,

  // Campo de presentación: no guarda nada en el contacto. Vive en el alias
  // `contacts.whatsapp` (special alias + no-data).
  types: ['alias'],
  localTypes: ['presentation'],
  group: 'presentation',

  // Sin opciones: todo sale del propio contacto.
  options: null,
};
