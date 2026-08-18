<template>
  <div class="aegora-tasks-layout">
    <div
      v-if="loading"
      class="state-panel"
    >
      Cargando tareas…
    </div>

    <div
      v-else-if="error"
      class="state-panel state-panel--error"
    >
      No se pudieron cargar las tareas.
    </div>

    <div
      v-else-if="!items || items.length === 0"
      class="state-panel"
    >
      No hay tareas que mostrar.
    </div>

    <div
      v-else
      class="task-list"
    >
      <article
        v-for="item in items"
        :key="item.id"
        class="task-card"
        :class="cardClasses(item)"
        tabindex="0"
        @click="handleCardClick(item)"
        @keydown.enter.prevent="handleCardClick(item)"
        @keydown.space.prevent="handleCardClick(item)"
      >
        <input
          v-if="selectMode"
          class="task-select"
          type="checkbox"
          :checked="isSelected(item.id)"
          :aria-label="`Seleccionar ${item.title || 'tarea'}`"
          @click.stop
          @change.stop="toggleSelection(item.id)"
        />

        <div class="task-main">
          <div class="task-header">
            <h3 class="task-title">
              {{ item.title || 'Sin título' }}
            </h3>

            <span
              v-if="priorityLabel(item.priority)"
              class="priority-chip"
              :class="`priority-chip--${item.priority || 'normal'}`"
            >
              {{ priorityLabel(item.priority) }}
            </span>
          </div>

          <p class="task-contact">
            {{ contactLabel(item.contact_id) }}
          </p>

          <p
            v-if="item.description"
            class="task-description"
          >
            {{ item.description }}
          </p>

          <div class="task-footer">
            <span
              class="due-state"
              :class="`due-state--${dueInfo(item).state}`"
            >
              <v-icon
                :name="dueInfo(item).icon"
                small
              />
              {{ dueInfo(item).label }}
            </span>

            <span
              v-if="taskStateLabel(item)"
              class="task-status"
            >
              {{ taskStateLabel(item) }}
            </span>
          </div>
        </div>
      </article>
    </div>

    <nav
      v-if="totalPages && totalPages > 1"
      class="pagination"
      aria-label="Paginación de tareas"
    >
      <button
        type="button"
        class="pagination-button"
        :disabled="page <= 1"
        @click="page -= 1"
      >
        Anterior
      </button>

      <span class="pagination-label">
        Página {{ page }} de {{ totalPages }}
      </span>

      <button
        type="button"
        class="pagination-button"
        :disabled="page >= totalPages"
        @click="page += 1"
      >
        Siguiente
      </button>
    </nav>
  </div>
</template>

<script>
import {
  computed,
  onBeforeUnmount,
  ref,
} from 'vue';

export default {
  inheritAttrs: false,

  emits: [
    'update:selection',
  ],

  props: {
    collection: {
      type: String,
      required: true,
    },

    items: {
      type: Array,
      default: () => [],
    },

    loading: {
      type: Boolean,
      default: false,
    },

    error: {
      type: [Array, Object, Error],
      default: null,
    },

    page: {
      type: Number,
      default: 1,
    },

    totalPages: {
      type: Number,
      default: 1,
    },

    selection: {
      type: Array,
      default: () => [],
    },

    selectMode: {
      type: Boolean,
      default: false,
    },

    readonly: {
      type: Boolean,
      default: false,
    },
  },

  setup(props, { emit }) {
    const now = ref(new Date());

    const timer = window.setInterval(() => {
      now.value = new Date();
    }, 60_000);

    onBeforeUnmount(() => {
      window.clearInterval(timer);
    });

    const selectionSet = computed(
      () => new Set(props.selection ?? [])
    );

    function isSelected(id) {
      return selectionSet.value.has(id);
    }

    function toggleSelection(id) {
      const next = new Set(props.selection ?? []);

      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }

      emit('update:selection', [...next]);
    }

    function handleCardClick(item) {
      if (props.selectMode) {
        toggleSelection(item.id);
        return;
      }

      const adminBase =
        window.location.pathname
          .split('/content/')[0] || '/admin';

      window.location.assign(
        `${adminBase}/content/${encodeURIComponent(
          props.collection
        )}/${encodeURIComponent(item.id)}`
      );
    }

    function contactLabel(contact) {
      if (!contact) {
        return 'Sin contacto';
      }

      const name = [
        contact.first_name,
        contact.last_name,
      ]
        .filter(Boolean)
        .join(' ')
        .trim();

      if (contact.company && name) {
        return `${contact.company} · ${name}`;
      }

      return (
        contact.company ||
        name ||
        'Sin contacto'
      );
    }

    function priorityLabel(priority) {
      const labels = {
        low: 'Baja',
        normal: 'Normal',
        high: 'Alta',
        urgent: 'Urgente',
      };

      return labels[priority] ?? null;
    }

    function taskStateLabel(item) {
      if (
        item.status === 'completed' ||
        item.completed_at
      ) {
        return 'Completada';
      }

      if (item.status === 'cancelled') {
        return 'Cancelada';
      }

      return null;
    }

    function isSameLocalDay(a, b) {
      return (
        a.getFullYear() === b.getFullYear() &&
        a.getMonth() === b.getMonth() &&
        a.getDate() === b.getDate()
      );
    }

    function tomorrowFrom(date) {
      const result = new Date(date);

      result.setDate(
        result.getDate() + 1
      );

      return result;
    }

    function formatTime(date) {
      return new Intl.DateTimeFormat(
        'es-ES',
        {
          hour: '2-digit',
          minute: '2-digit',
        }
      ).format(date);
    }

    function formatShortDate(date) {
      return new Intl.DateTimeFormat(
        'es-ES',
        {
          day: 'numeric',
          month: 'short',
        }
      ).format(date);
    }

    function overdueLabel(milliseconds) {
      const minutes = Math.max(
        1,
        Math.floor(
          milliseconds / 60_000
        )
      );

      if (minutes < 60) {
        return `${minutes} min`;
      }

      const hours = Math.floor(
        minutes / 60
      );

      if (hours < 24) {
        return `${hours} h`;
      }

      const days = Math.floor(
        hours / 24
      );

      return `${days} d`;
    }

    function dueInfo(item) {
      if (
        item.status === 'completed' ||
        item.completed_at
      ) {
        return {
          state: 'completed',
          label: 'Completada',
          icon: 'check_circle',
        };
      }

      if (item.status === 'cancelled') {
        return {
          state: 'cancelled',
          label: 'Cancelada',
          icon: 'block',
        };
      }

      if (!item.due_at) {
        return {
          state: 'none',
          label: 'Sin fecha',
          icon: 'event_busy',
        };
      }

      const due = new Date(
        item.due_at
      );

      if (
        Number.isNaN(
          due.getTime()
        )
      ) {
        return {
          state: 'none',
          label: 'Fecha no válida',
          icon: 'event_busy',
        };
      }

      const current = now.value;

      if (
        due.getTime() <
        current.getTime()
      ) {
        return {
          state: 'overdue',
          label:
            `Retrasada · ${
              overdueLabel(
                current.getTime() -
                due.getTime()
              )
            }`,
          icon: 'error',
        };
      }

      if (
        isSameLocalDay(
          due,
          current
        )
      ) {
        return {
          state: 'today',
          label:
            `Hoy · ${
              formatTime(due)
            }`,
          icon: 'schedule',
        };
      }

      if (
        isSameLocalDay(
          due,
          tomorrowFrom(current)
        )
      ) {
        return {
          state: 'upcoming',
          label:
            `Mañana · ${
              formatTime(due)
            }`,
          icon: 'schedule',
        };
      }

      return {
        state: 'upcoming',
        label:
          `${formatShortDate(due)} · ${
            formatTime(due)
          }`,
        icon: 'schedule',
      };
    }

    function cardClasses(item) {
      const info = dueInfo(item);

      return {
        'task-card--overdue':
          info.state === 'overdue',

        'task-card--today':
          info.state === 'today',

        'task-card--completed':
          info.state === 'completed',

        'task-card--cancelled':
          info.state === 'cancelled',
      };
    }

    return {
      isSelected,
      toggleSelection,
      handleCardClick,
      contactLabel,
      priorityLabel,
      taskStateLabel,
      dueInfo,
      cardClasses,
    };
  },
};
</script>

<style scoped>
.aegora-tasks-layout {
  width: 100%;
  padding: 12px 16px 24px;
}

.task-list {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  gap: 10px;
  width: 100%;
}

.task-card {
  position: relative;
  display: flex;
  width: 100%;
  min-width: 0;

  border:
    1px solid
    var(--theme--border-color-subdued);

  border-left:
    4px solid transparent;

  border-radius:
    var(--theme--border-radius, 8px);

  background:
    var(--theme--background);

  cursor: pointer;

  transition:
    border-color 120ms ease,
    box-shadow 120ms ease,
    background-color 120ms ease;
}

.task-card:hover,
.task-card:focus-visible {
  border-color:
    var(--theme--primary);

  outline: none;

  box-shadow:
    0 2px 10px
    rgb(0 0 0 / 8%);
}

.task-card--overdue {
  border-left-color:
    var(--theme--danger);
}

.task-card--today {
  border-left-color:
    var(--theme--warning);
}

.task-card--completed,
.task-card--cancelled {
  opacity: 0.62;
}

.task-select {
  flex: 0 0 auto;
  margin: 18px 0 0 16px;
}

.task-main {
  min-width: 0;
  flex: 1;
  padding: 15px 16px 14px;
}

.task-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 12px;
}

.task-title {
  min-width: 0;
  margin: 0;

  color:
    var(--theme--foreground);

  font-size: 15px;
  font-weight: 650;
  line-height: 1.35;
  overflow-wrap: anywhere;
}

.task-contact {
  margin: 5px 0 0;

  color:
    var(--theme--foreground-subdued);

  font-size: 13px;
  line-height: 1.35;
}

.task-description {
  display: -webkit-box;

  margin: 10px 0 0;

  overflow: hidden;

  color:
    var(--theme--foreground-subdued);

  font-size: 13px;
  line-height: 1.45;

  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
}

.task-footer {
  display: flex;
  align-items: center;
  flex-wrap: wrap;

  gap: 8px 12px;

  margin-top: 13px;
}

.due-state {
  display: inline-flex;
  align-items: center;

  gap: 5px;

  min-width: 0;

  color:
    var(--theme--foreground-subdued);

  font-size: 12px;
  font-weight: 600;
}

.due-state--overdue {
  color:
    var(--theme--danger);
}

.due-state--today {
  color:
    var(--theme--warning);
}

.priority-chip,
.task-status {
  display: inline-flex;
  align-items: center;

  min-height: 22px;

  padding: 2px 8px;

  border-radius: 999px;

  background:
    var(--theme--background-subdued);

  color:
    var(--theme--foreground-subdued);

  font-size: 11px;
  font-weight: 650;
  line-height: 1;

  white-space: nowrap;
}

.priority-chip--urgent {
  background:
    color-mix(
      in srgb,
      var(--theme--danger) 12%,
      transparent
    );

  color:
    var(--theme--danger);
}

.priority-chip--high {
  background:
    color-mix(
      in srgb,
      var(--theme--warning) 12%,
      transparent
    );

  color:
    var(--theme--warning);
}

.state-panel {
  width: 100%;

  padding: 32px 20px;

  border:
    1px dashed
    var(--theme--border-color-subdued);

  border-radius:
    var(--theme--border-radius, 8px);

  color:
    var(--theme--foreground-subdued);

  text-align: center;
}

.state-panel--error {
  color:
    var(--theme--danger);
}

.pagination {
  display: flex;
  align-items: center;
  justify-content: center;

  gap: 14px;

  margin-top: 18px;
}

.pagination-button {
  min-height: 34px;

  padding: 0 12px;

  border:
    1px solid
    var(--theme--border-color-subdued);

  border-radius:
    var(--theme--border-radius, 6px);

  background:
    var(--theme--background);

  color:
    var(--theme--foreground);

  cursor: pointer;
}

.pagination-button:hover:not(:disabled) {
  border-color:
    var(--theme--primary);

  color:
    var(--theme--primary);
}

.pagination-button:disabled {
  cursor: default;
  opacity: 0.45;
}

.pagination-label {
  color:
    var(--theme--foreground-subdued);

  font-size: 12px;
}

@media (max-width: 600px) {
  .aegora-tasks-layout {
    padding: 8px 8px 20px;
  }

  .task-list {
    gap: 8px;
  }

  .task-card {
    border-radius: 7px;
  }

  .task-main {
    padding: 13px 12px 12px;
  }

  .task-header {
    gap: 8px;
  }

  .task-title {
    font-size: 14px;
  }

  .task-footer {
    justify-content:
      space-between;
  }
}
</style>
