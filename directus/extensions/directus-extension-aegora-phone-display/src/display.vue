<template>
  <div
    v-if="displayPhone"
    class="aegora-phone"
  >
    <span class="phone-number">
      {{ displayPhone }}
    </span>

    <button
      class="phone-action"
      type="button"
      title="Copiar teléfono"
      @click.stop="copyPhone"
    >
      <v-icon
        name="content_copy"
        small
      />
    </button>

    <a
      v-if="callNumber"
      class="phone-action"
      :href="`tel:${callNumber}`"
      title="Llamar"
      @click.stop
    >
      <v-icon
        name="call"
        small
      />
    </a>

    <span
      v-if="extraPhones > 0"
      class="phone-extra"
    >
      +{{ extraPhones }}
    </span>
  </div>

  <span v-else>
    —
  </span>
</template>

<script>
import { computed } from 'vue';

export default {
  props: {
    value: {
      type: [String, Array, Object],
      default: null,
    },
  },

  setup(props) {
    console.log(
      '[Aegora Phone Display] value:',
      props.value,
      'type:',
      typeof props.value,
      'array:',
      Array.isArray(props.value)
    );
    const isScalar = computed(() => {
      return typeof props.value === 'string';
    });

    const phones = computed(() => {
      if (
        !props.value ||
        isScalar.value
      ) {
        return [];
      }

      if (Array.isArray(props.value)) {
        return props.value;
      }

      return [props.value];
    });

    const primaryPhone = computed(() => {
      if (phones.value.length === 0) {
        return null;
      }

      return (
        phones.value.find(
          (phone) => phone?.is_primary === true
        ) ??
        phones.value[0]
      );
    });

    const displayPhone = computed(() => {
      if (isScalar.value) {
        return props.value || null;
      }

      const phone = primaryPhone.value;

      if (!phone) {
        return null;
      }

      return (
        phone.phone_number ??
        phone.phone_normalized ??
        null
      );
    });

    const callNumber = computed(() => {
      if (isScalar.value) {
        return props.value || null;
      }

      const phone = primaryPhone.value;

      if (!phone) {
        return null;
      }

      return (
        phone.phone_normalized ??
        phone.phone_number ??
        null
      );
    });

    const extraPhones = computed(() => {
      if (isScalar.value) {
        return 0;
      }

      return Math.max(
        phones.value.length - 1,
        0
      );
    });

    async function copyPhone() {
      const phone = callNumber.value;

      if (!phone) {
        return;
      }

      try {
        await navigator.clipboard.writeText(phone);
      } catch (error) {
        console.error(
          'No se pudo copiar el teléfono',
          error
        );
      }
    }

    return {
      displayPhone,
      callNumber,
      extraPhones,
      copyPhone,
    };
  },
};
</script>

<style scoped>
.aegora-phone {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  white-space: nowrap;
}

.phone-number {
  overflow: hidden;
  text-overflow: ellipsis;
}

.phone-action {
  display: inline-flex;
  align-items: center;
  justify-content: center;

  border: 0;
  padding: 0;

  background: transparent;
  color: var(--theme--foreground-subdued);

  cursor: pointer;
  text-decoration: none;
}

.phone-action:hover {
  color: var(--theme--primary);
}

.phone-extra {
  color: var(--theme--foreground-subdued);
  font-size: 12px;
}
</style>
