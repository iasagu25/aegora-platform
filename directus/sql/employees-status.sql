-- =============================================================================
-- Aegora · `employees.status` en minúscula, siempre
--
-- POR QUÉ ESTO EXISTE
-- Hasta el 24/sep/2026 las opciones del desplegable estaban al revés en el
-- esquema -- `{text: 'active', value: 'Active'}` -- mientras que el valor por
-- defecto de la columna era `active`. Un empleado recién creado quedaba en
-- `active` y uno al que alguien le cambiaba el estado desde el panel, en `Active`
-- o `Inactive`: los datos acababan mezclados y cualquier filtro por estado fallaba
-- con una de las dos mitades. Lo destapó el resumen diario, que no encontraba a
-- nadie filtrando por `Active`.
--
-- Las opciones ya están corregidas en base.yaml (`value: active|inactive`). Esto
-- arregla lo que ya se hubiera guardado mal. Idempotente: si todo está en
-- minúscula no toca ninguna fila, así que puede ir en cada `apply-schema`.
-- =============================================================================

UPDATE employees
   SET status = lower(status)
 WHERE status IS DISTINCT FROM lower(status);
