import InterfaceComponent from './interface.vue';

export default {
  id: 'aegora-conversation',
  name: 'Conversación de Lucía',
  icon: 'forum',
  description: 'El hilo como conversación, con caja de respuesta y el estado de la ventana de WhatsApp.',
  component: InterfaceComponent,

  // Sustituye al `list-o2m` del campo `mensajes` de conversation_sessions: es un
  // alias O2M, así que hay que declararlo como tal o Directus no lo ofrece.
  types: ['alias'],
  localTypes: ['o2m'],
  group: 'relational',
  relational: true,

  // Sin panel de opciones a propósito: no hay nada que configurar por tenant.
  // Todo lo que necesita lo saca del propio registro.
  options: null,
};
