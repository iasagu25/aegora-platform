<template>
  <div class="aegora-wa">
    <p v-if="!contactoId" class="nota">Guarda el contacto para poder escribirle.</p>
    <p v-else-if="telefonos === null" class="nota">Cargando teléfonos…</p>
    <p v-else-if="telefonos.length === 0" class="nota">
      Este contacto no tiene ningún móvil. Añade uno en «Teléfonos» y guarda.
    </p>
    <template v-else>
      <div class="botones">
        <button
          v-for="t in telefonos"
          :key="t.digitos"
          type="button"
          class="boton"
          :disabled="!!abriendo"
          @click="abrir(t)"
        >
          {{ abriendo === t.digitos ? 'Abriendo…' : `Escribir por WhatsApp al ${t.mostrar}` }}
        </button>
      </div>
      <p class="nota">
        Abre su conversación (o la crea) para mandarle una plantilla aprobada, aunque nunca
        nos haya escrito. Si contesta, le atiende Lucía, y si hace falta te deja una tarea con
        aviso. Para llevarla tú, pon «Modo» en «Lo lleva una persona».
      </p>
    </template>
    <p v-if="error" class="error">{{ error }}</p>
  </div>
</template>

<script>
import { computed, inject, onMounted, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import { useApi } from '@directus/extensions-sdk';

// Mismo criterio que el resto de la plataforma: 9 dígitos que empiezan por 6/7/8/9 son
// un número español sin el 34. La clave del hilo es `whatsapp:<E.164 sin +>`, igual que
// la que crea el adapter cuando el cliente escribe: así, si contesta, cae en ESTE hilo.
const aE164 = (d) => (/^[6789]\d{8}$/.test(d) ? `34${d}` : d);
// Un fijo español (34 8xx / 34 9xx) no tiene WhatsApp, salvo que la ficha diga lo contrario.
const esFijoEs = (d) => /^34[89]\d{8}$/.test(d);
const bonito = (d) => (/^34\d{9}$/.test(d)
  ? `+34 ${d.slice(2, 5)} ${d.slice(5, 8)} ${d.slice(8)}` : `+${d}`);

export default {
  // Se declara `input` aunque no se emita nunca. Sin esto Directus engancha su escucha de
  // `input` al <div> raíz como evento NATIVO, y cualquier <select>/<textarea> de dentro
  // le manda el evento del navegador como valor del campo: al guardar, Directus intenta
  // escribir ese objeto y falla con `"isTrusted" is not allowed`.
  emits: ['input'],
  inheritAttrs: false,
  props: {
    primaryKey: { type: [String, Number], default: null },
  },

  setup(props) {
    const api = useApi();
    const router = useRouter();
    const values = inject('values', ref({}));

    const telefonos = ref(null);
    // El número que se está abriendo, o '' si ninguno. OJO: en el template va como
    // `!!abriendo`. Vue trata `disabled=""` como atributo PRESENTE (así es HTML), y con
    // la cadena vacía a pelo el botón salía desactivado siempre.
    const abriendo = ref('');
    const error = ref('');

    const contactoId = computed(() => {
      const pk = props.primaryKey;
      if (pk && pk !== '+') return pk;
      return (values.value && values.value.id) || null;
    });

    async function cargar() {
      if (!contactoId.value) { telefonos.value = null; return; }
      try {
        const { data } = await api.get('/items/contact_phones', {
          params: {
            filter: { contact_id: { _eq: contactoId.value } },
            fields: ['id', 'phone_number', 'phone_normalized', 'is_primary', 'can_whatsapp'],
            limit: 20,
          },
        });
        const vistos = new Set();
        telefonos.value = (data.data || [])
          .map((p) => ({ ...p, digitos: aE164(String(p.phone_normalized || p.phone_number || '').replace(/[^\d]/g, '')) }))
          .filter((p) => p.digitos && (p.can_whatsapp === true || !esFijoEs(p.digitos)))
          .sort((a, b) => (b.is_primary === true) - (a.is_primary === true))
          .filter((p) => (vistos.has(p.digitos) ? false : vistos.add(p.digitos)))
          .map((p) => ({ digitos: p.digitos, mostrar: bonito(p.digitos) }));
        error.value = '';
      } catch (e) {
        telefonos.value = [];
        error.value = 'No se pudieron leer los teléfonos. ' + detalle(e);
      }
    }

    async function abrir(t) {
      if (abriendo.value) return;
      abriendo.value = t.digitos;
      error.value = '';
      const clave = `whatsapp:${t.digitos}`;
      try {
        const { data } = await api.get('/items/conversation_sessions', {
          params: { filter: { session_key: { _eq: clave } }, fields: ['id', 'contact_id'], limit: 1 },
        });
        let sesion = (data.data || [])[0] || null;
        if (sesion && !sesion.contact_id) {
          // Un hilo que existía sin contacto (escribió antes de tener ficha): se enlaza.
          await api.patch(`/items/conversation_sessions/${sesion.id}`, { contact_id: contactoId.value });
        }
        if (!sesion) {
          const r = await api.post('/items/conversation_sessions', {
            session_key: clave,
            canal: 'whatsapp',
            contact_id: contactoId.value,
            // En `auto` a propósito (decidido 12/nov/2026): en `humano` nadie se entera
            // de que el cliente ha contestado hasta abrir el panel. Lucía contesta al
            // momento, tiene la plantilla en su memoria, y lo que no pueda resolver lo
            // deja en una tarea, que avisa al equipo por WhatsApp.
            modo: 'auto',
          });
          sesion = r.data.data;
        }
        router.push(`/content/conversation_sessions/${sesion.id}`);
      } catch (e) {
        error.value = 'No se pudo abrir la conversación. ' + detalle(e);
      } finally {
        abriendo.value = '';
      }
    }

    function detalle(e) {
      const errores = e && e.response && e.response.data && e.response.data.errors;
      if (Array.isArray(errores) && errores[0] && errores[0].message) return errores[0].message;
      return (e && e.message) || '';
    }

    onMounted(cargar);
    watch(contactoId, cargar);

    return { contactoId, telefonos, abriendo, error, abrir };
  },
};
</script>

<style scoped>
.aegora-wa { display: flex; flex-direction: column; gap: 8px; }
.botones { display: flex; flex-wrap: wrap; gap: 8px; }
.boton {
  background: var(--theme--primary);
  color: var(--theme--background);
  border: none;
  border-radius: var(--theme--border-radius);
  padding: 8px 16px;
  cursor: pointer;
  font: inherit;
}
.boton:disabled { opacity: 0.5; cursor: default; }
.nota { margin: 0; font-size: 12px; color: var(--theme--foreground-subdued); }
.error { margin: 0; font-size: 12px; color: var(--theme--danger); }
</style>
