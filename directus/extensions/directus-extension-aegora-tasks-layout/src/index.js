import { computed, ref, toRefs, watch } from 'vue';
import { useItems } from '@directus/extensions-sdk';
import LayoutComponent from './layout.vue';

export default {
  id: 'aegora-tasks-layout',
  name: 'Aegora Tasks',
  icon: 'task_alt',
  component: LayoutComponent,

  slots: {
    options: () => null,
    sidebar: () => null,
    actions: () => null,
  },

  setup(props) {
    const {
      collection,
      filter,
      filterSystem,
      search,
    } = toRefs(props);

    const page = ref(1);
    const limit = ref(50);

    const fields = ref([
      'id',
      'title',
      'description',
      'status',
      'priority',
      'due_at',
      'completed_at',
      'created_at',
      'contact_id.id',
      'contact_id.first_name',
      'contact_id.last_name',
      'contact_id.company',
      'assignee_id.id',
      'assignee_id.first_name',
      'assignee_id.last_name',
    ]);

    const sort = ref([
      'due_at',
      '-created_at',
    ]);

    const combinedFilter = computed(() => {
      const parts = [
        filterSystem?.value ?? null,
        filter?.value ?? null,
      ].filter(Boolean);

      if (parts.length === 0) {
        return null;
      }

      if (parts.length === 1) {
        return parts[0];
      }

      return {
        _and: parts,
      };
    });

    const {
      items,
      loading,
      error,
      itemCount,
      totalPages,
      getItemCount,
      getItems,
    } = useItems(collection, {
      fields,
      sort,
      limit,
      page,
      filter: combinedFilter,
      search,
    });

    const refreshCount = async () => {
      try {
        await getItemCount();
      } catch {
        // useItems expone el error de la petición por separado.
      }
    };

    watch(
      [filter, filterSystem, search],
      () => {
        page.value = 1;
        refreshCount();
      },
      {
        deep: true,
      }
    );

    refreshCount();

    return {
      items,
      loading,
      error,
      page,
      limit,
      itemCount,
      totalPages,
      getItems,
    };
  },
};
