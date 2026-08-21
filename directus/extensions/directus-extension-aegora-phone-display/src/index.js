import DisplayComponent from './display.vue';

export default {
  id: 'aegora-phone-display',
  name: 'Aegora Phone',
  icon: 'phone',
  description: 'Teléfono con acciones de copiar y llamar.',

  component: DisplayComponent,

  types: ['string', 'alias'],
  localTypes: ['o2m'],

  options: null,

  fields: ({ collection, field }) => {
    if (collection === 'contacts' && field === 'phones') {
      return [
        'phone_number',
        'phone_normalized',
        'is_primary',
      ];
    }

    return [];
  },
};
