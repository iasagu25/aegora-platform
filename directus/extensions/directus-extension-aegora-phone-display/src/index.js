import DisplayComponent from './display.vue';

export default {
  id: 'aegora-phone-display',
  name: 'Aegora Phone',
  icon: 'phone',
  description: 'Teléfono principal con acciones de copiar y llamar.',

  component: DisplayComponent,

  types: ['alias'],
  localTypes: ['o2m'],

  options: null,

  fields: () => [
    'phone_number',
    'phone_normalized',
    'is_primary',
  ],
};
