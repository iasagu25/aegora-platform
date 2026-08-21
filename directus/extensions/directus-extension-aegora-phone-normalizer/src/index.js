import { defineHook } from '@directus/extensions-sdk';

const DEFAULT_COUNTRY_CODE = '34';

const CONFIG = {
  contact_phones: {
    source: 'phone_number',
    target: 'phone_normalized',
  },

  employees: {
    source: 'phone',
    target: 'phone_normalized',
  },
};

function clean(value) {
  if (value === undefined || value === null) {
    return null;
  }

  const text = String(value).trim();

  return text === ''
    ? null
    : text;
}

function normalizePhone(
  value,
  defaultCountryCode = DEFAULT_COUNTRY_CODE
) {
  const original = clean(value);

  if (!original) {
    return null;
  }

  /*
   * Conservamos únicamente dígitos y "+".
   *
   * Ejemplos:
   *   612 345 678
   *   612-345-678
   *   +34 612 345 678
   *   (34) 612345678
   */
  let normalized =
    original.replace(/[^\d+]/g, '');

  /*
   * Prefijo internacional 00:
   *
   * 0034612345678
   * →
   * +34612345678
   */
  if (normalized.startsWith('00')) {
    normalized =
      `+${normalized.slice(2)}`;
  }

  /*
   * Número nacional español:
   *
   * 612345678
   * →
   * +34612345678
   */
  if (/^\d{9}$/.test(normalized)) {
    normalized =
      `+${defaultCountryCode}${normalized}`;
  }

  /*
   * Número español con código de país
   * pero sin "+":
   *
   * 34612345678
   * →
   * +34612345678
   */
  if (/^34\d{9}$/.test(normalized)) {
    normalized =
      `+${normalized}`;
  }

  /*
   * Validación estructural E.164:
   *
   * "+" seguido de entre 8 y 15 dígitos.
   * El primer dígito del country code no puede ser 0.
   *
   * Esto NO valida que el número realmente exista.
   */
  if (!/^\+[1-9]\d{7,14}$/.test(normalized)) {
    throw new Error(
      `No se pudo normalizar el teléfono a formato E.164: ${original}`
    );
  }

  return normalized;
}

function normalizePayload(payload, config) {
  if (!payload || typeof payload !== 'object') {
    return payload;
  }

  /*
   * Directus también puede trabajar con bulk create.
   */
  if (Array.isArray(payload)) {
    return payload.map(
      item => normalizePayload(item, config)
    );
  }

  const {
    source,
    target,
  } = config;

  /*
   * phone_normalized nunca es input autorizado.
   *
   * Si alguien intenta enviarlo directamente
   * sin modificar el teléfono original,
   * simplemente lo descartamos.
   */
  if (
    Object.prototype.hasOwnProperty.call(payload, target) &&
    !Object.prototype.hasOwnProperty.call(payload, source)
  ) {
    delete payload[target];
  }

  /*
   * En UPDATE es importante no hacer nada si
   * el teléfono no forma parte del payload.
   *
   * Por ejemplo, cambiar solamente:
   *   employee.status
   *
   * no debe tocar phone_normalized.
   */
  if (
    !Object.prototype.hasOwnProperty.call(payload, source)
  ) {
    return payload;
  }

  payload[target] =
    normalizePhone(payload[source]);

  return payload;
}

export default defineHook(
  ({ filter }, { logger }) => {

    const handleMutation = (
      payload,
      meta
    ) => {
      const collection =
        meta?.collection;

      const config =
        CONFIG[collection];

      if (!config) {
        return payload;
      }

      const result =
        normalizePayload(
          payload,
          config
        );

      logger.debug(
        `[Aegora Phone Normalizer] ${collection}`
      );

      return result;
    };

    filter(
      'items.create',
      handleMutation
    );

    filter(
      'items.update',
      handleMutation
    );
  }
);
