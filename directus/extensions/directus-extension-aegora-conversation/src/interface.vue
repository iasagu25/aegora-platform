<template>
  <div class="aegora-conversation">
    <!-- Cabecera: canal, quién lleva el hilo y si se puede escribir -->
    <div class="cabecera">
      <span class="chip">{{ canal || 'sin canal' }}</span>

      <span class="chip" :class="enRelevo ? 'chip--persona' : 'chip--lucia'">
        {{ enRelevo ? 'Lo lleva una persona' : 'Lucía responde' }}
      </span>

      <span class="chip" :class="ventana.clase">{{ ventana.texto }}</span>

      <button class="recargar" type="button" :disabled="cargando" @click="recargar">
        {{ cargando ? 'Actualizando…' : 'Actualizar' }}
      </button>
    </div>

    <!-- Las citas del contacto, al lado del hilo. No es adorno: sin esto el
         gestor contesta "ya te la he apuntado" sin saber si existe. -->
    <div v-if="contactoId" class="citas">
      <span class="citas-titulo">Citas de este contacto:</span>
      <span v-if="citas === null" class="citas-vacio">cargando…</span>
      <span v-else-if="citas.length === 0" class="citas-vacio">ninguna próxima</span>
      <span v-for="cita in citas" :key="cita.id" class="cita">
        {{ fechaLarga(cita.start_at) }}<template v-if="nombreServicio(cita)"> · {{ nombreServicio(cita) }}</template>
      </span>
    </div>

    <p v-if="error" class="aviso aviso--error">{{ error }}</p>

    <!-- El hilo -->
    <div v-if="sinGuardar" class="aviso">
      Guarda la conversación para poder ver y escribir mensajes.
    </div>
    <div v-else-if="mensajes === null" class="aviso">Cargando el hilo…</div>
    <div v-else-if="mensajes.length === 0" class="aviso">Todavía no hay mensajes.</div>
    <div v-else ref="hilo" class="hilo">
      <div
        v-for="mensaje in mensajes"
        :key="mensaje.id"
        class="linea"
        :class="`linea--${lado(mensaje)}`"
      >
        <div class="burbuja" :class="`burbuja--${mensaje.autor || 'lucia'}`">
          <div class="quien">
            {{ etiquetaAutor(mensaje.autor) }}
            <span class="cuando">{{ hora(mensaje.created_at) }}</span>
          </div>
          <div class="texto">{{ mensaje.texto }}</div>
          <div v-if="estadoVisible(mensaje)" class="estado" :class="`estado--${mensaje.estado_envio}`">
            {{ etiquetaEstado(mensaje.estado_envio) }}
            <template v-if="mensaje.error"> · {{ mensaje.error }}</template>
          </div>
        </div>
      </div>
    </div>

    <!-- Respuesta -->
    <div v-if="!sinGuardar" class="responder">
      <p v-if="motivoBloqueo" class="aviso aviso--bloqueo">{{ motivoBloqueo }}</p>

      <template v-else>
        <textarea
          v-model="borrador"
          class="caja"
          rows="3"
          placeholder="Escribe tu respuesta…"
          :disabled="enviando"
          @keydown.ctrl.enter.prevent="enviar"
          @keydown.meta.enter.prevent="enviar"
        />
        <div class="acciones">
          <span class="pista">Ctrl+Intro para enviar</span>
          <button
            class="enviar"
            type="button"
            :disabled="enviando || borrador.trim().length === 0"
            @click="enviar"
          >
            {{ enviando ? 'Enviando…' : 'Enviar' }}
          </button>
        </div>
      </template>
    </div>
  </div>
</template>

<script>
import { computed, inject, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { useApi } from '@directus/extensions-sdk';

const CADA = 10000;

export default {
  props: {
    primaryKey: { type: [String, Number], default: null },
  },

  setup(props) {
    const api = useApi();
    // `values` es el estado VIVO del formulario, no lo que hay en la base: así
    // el aviso de "pon el hilo en modo persona" reacciona en cuanto se cambia el
    // desplegable, sin esperar a guardar.
    const values = inject('values', ref({}));

    const mensajes = ref(null);
    const citas = ref(null);
    const borrador = ref('');
    const cargando = ref(false);
    const enviando = ref(false);
    const error = ref('');
    const hilo = ref(null);
    let temporizador = null;

    const sesionId = computed(() => {
      const pk = props.primaryKey;
      // Directus usa "+" como clave de un registro que aún no existe.
      if (pk && pk !== '+') return pk;
      return (values.value && values.value.id) || null;
    });
    const sinGuardar = computed(() => !sesionId.value);
    const canal = computed(() => (values.value && values.value.canal) || '');
    const enRelevo = computed(() => (values.value && values.value.modo) === 'humano');
    const contactoId = computed(() => (values.value && values.value.contact_id) || null);

    const ventana = computed(() => {
      if (canal.value !== 'whatsapp') {
        return { clase: 'chip--neutro', texto: 'Sin ventana (no es WhatsApp)' };
      }
      const hasta = values.value && values.value.ventana_hasta
        ? Date.parse(values.value.ventana_hasta) : NaN;
      if (!Number.isFinite(hasta)) {
        return { clase: 'chip--cerrada', texto: 'Ventana desconocida' };
      }
      const restan = hasta - Date.now();
      if (restan <= 0) return { clase: 'chip--cerrada', texto: 'Ventana cerrada' };
      const horas = Math.floor(restan / 3600000);
      const minutos = Math.floor((restan % 3600000) / 60000);
      return {
        clase: 'chip--abierta',
        texto: horas > 0 ? `Ventana abierta · ${horas} h ${minutos} min` : `Ventana abierta · ${minutos} min`,
      };
    });

    // Por qué no se puede escribir, en el orden en que se lo explicarías a alguien.
    const motivoBloqueo = computed(() => {
      if (canal.value !== 'whatsapp') {
        return 'Este canal no admite enviar un mensaje más tarde. Solo WhatsApp.';
      }
      if (!enRelevo.value) {
        return 'Lucía está respondiendo este hilo. Cambia «Modo» a «Lo lleva una persona» y guarda antes de escribir tú, o le contestaréis los dos.';
      }
      if (ventana.value.clase === 'chip--cerrada') {
        return 'La ventana de 24 h de WhatsApp está cerrada: el cliente no escribe desde hace más de un día. Hasta que vuelva a escribir, solo se le puede mandar una plantilla aprobada por Meta.';
      }
      return '';
    });

    async function cargar({ silencioso = false } = {}) {
      if (!sesionId.value) return;
      if (!silencioso) cargando.value = true;
      try {
        const { data } = await api.get('/items/conversation_messages', {
          params: {
            filter: { session_id: { _eq: sesionId.value } },
            fields: ['id', 'texto', 'autor', 'direccion', 'estado_envio', 'error', 'created_at'],
            sort: ['created_at'],
            limit: 300,
          },
        });
        mensajes.value = data.data || [];
        error.value = '';
        await nextTick();
        abajo();
      } catch (e) {
        error.value = 'No se pudo cargar el hilo. ' + detalle(e);
      } finally {
        cargando.value = false;
      }
    }

    async function cargarCitas() {
      if (!contactoId.value) { citas.value = null; return; }
      try {
        const { data } = await api.get('/items/appointments', {
          params: {
            filter: {
              contact_id: { _eq: contactoId.value },
              status: { _in: ['scheduled', 'confirmed'] },
              start_at: { _gte: '$NOW' },
            },
            fields: ['id', 'start_at', 'status', 'service_id.name'],
            sort: ['start_at'],
            limit: 5,
          },
        });
        citas.value = data.data || [];
      } catch {
        // Informativo: si no se pueden leer, el hilo sigue sirviendo.
        citas.value = [];
      }
    }

    async function enviar() {
      const texto = borrador.value.trim();
      if (!texto || enviando.value || !sesionId.value) return;
      enviando.value = true;
      error.value = '';
      try {
        // Crear la fila ES enviar: HUMANO · Enviar pendientes la recoge. Se
        // mandan los campos explícitos aunque tengan default, para no depender
        // de que el esquema del tenant esté al día.
        await api.post('/items/conversation_messages', {
          session_id: sesionId.value,
          contact_id: contactoId.value,
          canal: canal.value || null,
          texto,
          direccion: 'saliente',
          autor: 'humano',
          estado_envio: 'pendiente',
        });
        borrador.value = '';
        await cargar({ silencioso: true });
      } catch (e) {
        error.value = 'No se pudo poner el mensaje en cola. ' + detalle(e);
      } finally {
        enviando.value = false;
      }
    }

    function detalle(e) {
      const errores = e && e.response && e.response.data && e.response.data.errors;
      if (Array.isArray(errores) && errores[0] && errores[0].message) return errores[0].message;
      return (e && e.message) || '';
    }

    function abajo() {
      if (hilo.value) hilo.value.scrollTop = hilo.value.scrollHeight;
    }

    const lado = (m) => (m.direccion === 'entrante' ? 'izquierda' : 'derecha');
    const etiquetaAutor = (a) =>
      a === 'cliente' ? 'Cliente' : a === 'humano' ? 'Tú' : 'Lucía';
    const etiquetaEstado = (e) => ({
      pendiente: 'En cola', enviando: 'Enviando', enviado: 'Enviado',
      fallido: 'No se pudo enviar', recibido: 'Recibido',
    })[e] || e;
    // El estado solo dice algo de lo que sale; un entrante siempre es "recibido".
    const estadoVisible = (m) => m.direccion === 'saliente' && m.estado_envio !== 'enviado';
    const nombreServicio = (c) => (c.service_id && c.service_id.name) || '';

    const hora = (iso) => {
      if (!iso) return '';
      try {
        return new Date(iso).toLocaleString('es-ES', {
          day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
        });
      } catch { return iso; }
    };
    const fechaLarga = (iso) => {
      if (!iso) return '';
      try {
        return new Date(iso).toLocaleString('es-ES', {
          weekday: 'short', day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit',
        });
      } catch { return iso; }
    };

    async function recargar() {
      await Promise.all([cargar(), cargarCitas()]);
    }

    onMounted(() => {
      recargar();
      // Sondeo: un mensaje nuevo del cliente tiene que aparecer sin recargar la
      // página. Silencioso para no parpadear cada diez segundos.
      temporizador = setInterval(() => cargar({ silencioso: true }), CADA);
    });
    onBeforeUnmount(() => { if (temporizador) clearInterval(temporizador); });

    watch(sesionId, () => recargar());
    watch(contactoId, () => cargarCitas());

    return {
      mensajes, citas, borrador, cargando, enviando, error, hilo,
      sinGuardar, canal, enRelevo, contactoId, ventana, motivoBloqueo,
      enviar, recargar, lado, etiquetaAutor, etiquetaEstado, estadoVisible,
      nombreServicio, hora, fechaLarga,
    };
  },
};
</script>

<style scoped>
.aegora-conversation {
  border: var(--theme--border-width) solid var(--theme--border-color-subdued);
  border-radius: var(--theme--border-radius);
  background: var(--theme--background);
  overflow: hidden;
}

.cabecera {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: center;
  padding: 10px 12px;
  background: var(--theme--background-subdued);
  border-bottom: 1px solid var(--theme--border-color-subdued);
}

.chip {
  font-size: 12px;
  padding: 2px 8px;
  border-radius: 12px;
  background: var(--theme--background);
  border: 1px solid var(--theme--border-color-subdued);
  color: var(--theme--foreground-subdued);
}
.chip--persona { color: var(--theme--primary); border-color: var(--theme--primary); }
.chip--lucia { color: var(--theme--foreground-subdued); }
.chip--abierta { color: var(--theme--success, #2ecda7); }
.chip--cerrada { color: var(--theme--warning); border-color: var(--theme--warning); }
.chip--neutro { opacity: 0.7; }

.recargar {
  margin-left: auto;
  font-size: 12px;
  background: none;
  border: none;
  color: var(--theme--primary);
  cursor: pointer;
}
.recargar:disabled { color: var(--theme--foreground-subdued); cursor: default; }

.citas {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: baseline;
  padding: 8px 12px;
  font-size: 12px;
  border-bottom: 1px solid var(--theme--border-color-subdued);
}
.citas-titulo { color: var(--theme--foreground-subdued); }
.citas-vacio { color: var(--theme--foreground-subdued); font-style: italic; }
.cita {
  padding: 2px 8px;
  border-radius: 12px;
  background: var(--theme--background-subdued);
  color: var(--theme--foreground);
}

.hilo {
  max-height: 460px;
  overflow-y: auto;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.linea { display: flex; }
.linea--izquierda { justify-content: flex-start; }
.linea--derecha { justify-content: flex-end; }

.burbuja {
  max-width: 78%;
  padding: 8px 10px;
  border-radius: var(--theme--border-radius);
  background: var(--theme--background-subdued);
  border: 1px solid var(--theme--border-color-subdued);
}
.burbuja--lucia { border-color: var(--theme--border-color-subdued); }
.burbuja--humano { border-color: var(--theme--primary); }

.quien {
  display: flex;
  gap: 8px;
  justify-content: space-between;
  font-size: 11px;
  color: var(--theme--foreground-subdued);
  margin-bottom: 2px;
}

.texto { white-space: pre-wrap; word-break: break-word; color: var(--theme--foreground); }

.estado { margin-top: 4px; font-size: 11px; color: var(--theme--foreground-subdued); }
.estado--fallido { color: var(--theme--danger); }

.responder { border-top: 1px solid var(--theme--border-color-subdued); padding: 10px 12px; }

.caja {
  width: 100%;
  resize: vertical;
  font: inherit;
  color: var(--theme--foreground);
  background: var(--theme--background);
  border: 1px solid var(--theme--border-color-subdued);
  border-radius: var(--theme--border-radius);
  padding: 8px;
}

.acciones { display: flex; align-items: center; justify-content: space-between; margin-top: 8px; }
.pista { font-size: 11px; color: var(--theme--foreground-subdued); }

.enviar {
  background: var(--theme--primary);
  color: var(--theme--background);
  border: none;
  border-radius: var(--theme--border-radius);
  padding: 6px 16px;
  cursor: pointer;
}
.enviar:disabled { opacity: 0.5; cursor: default; }

.aviso { margin: 0; padding: 12px; font-size: 13px; color: var(--theme--foreground-subdued); }
.aviso--error { color: var(--theme--danger); }
.aviso--bloqueo {
  padding: 8px 10px;
  background: var(--theme--background-subdued);
  border-radius: var(--theme--border-radius);
}
</style>
