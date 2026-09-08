-- =============================================================================
-- directus/sql/booking-indexes.sql
-- Capa SQL idempotente de índices y constraints del modelo de booking.
--
-- Referencia: handover técnico post-LumaDock, sección 12.2 (Prioridad 2).
-- base.yaml cubre el modelo Directus pero no es un sistema completo de
-- migraciones para índices compuestos y constraints; esta capa lo complementa.
--
-- Idempotente: reejecutable sin efectos. Todas las sentencias usan
-- IF NOT EXISTS. Asume que el modelo de booking (Prioridad 1) ya está
-- aplicado en el tenant: appointments, appointment_resources,
-- availability_rules, availability_exceptions, resources y service_resources
-- con sus columnas. Si una columna no existe todavía, la sentencia falla
-- de forma explícita ("column ... does not exist"): aplica primero el
-- schema base.
--
-- Nombre de la junction pool-OR: service_resources (singular), igual que el
-- handover. La colección con typeo "services_resources" fue corregida.
--
-- Ejecución: directus/apply-schema.sh envuelve este fichero en una
-- transacción y controla su resultado:
--   - dry-run  -> BEGIN ... ROLLBACK  (valida sin persistir)
--   - --apply  -> BEGIN ... COMMIT
-- No añadir control de transacción (BEGIN/COMMIT) dentro de este fichero.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- appointments
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_appointments_service_id  ON appointments (service_id);
CREATE INDEX IF NOT EXISTS idx_appointments_calendar_id ON appointments (calendar_id);
CREATE INDEX IF NOT EXISTS idx_appointments_location_id ON appointments (location_id);
CREATE INDEX IF NOT EXISTS idx_appointments_start_at    ON appointments (start_at);
CREATE INDEX IF NOT EXISTS idx_appointments_end_at      ON appointments (end_at);
CREATE INDEX IF NOT EXISTS idx_appointments_status      ON appointments (status);

-- Compuesto: resolución de solapes por estado y ventana temporal.
CREATE INDEX IF NOT EXISTS idx_appointments_status_start_end
    ON appointments (status, start_at, end_at);

-- Idempotencia del Booking API: única cuando está informada (reintentos n8n).
CREATE UNIQUE INDEX IF NOT EXISTS uq_appointments_idempotency_key
    ON appointments (idempotency_key)
    WHERE idempotency_key IS NOT NULL;

-- -----------------------------------------------------------------------------
-- appointment_resources  (junction AND: recursos comprometidos por una cita)
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_appointment_resources_appointment_id
    ON appointment_resources (appointment_id);
CREATE INDEX IF NOT EXISTS idx_appointment_resources_resource_id
    ON appointment_resources (resource_id);

-- UNIQUE appointment_resources(appointment_id, resource_id).
CREATE UNIQUE INDEX IF NOT EXISTS uq_appointment_resources_appointment_resource
    ON appointment_resources (appointment_id, resource_id);

-- -----------------------------------------------------------------------------
-- availability_rules  (allow-list de disponibilidad por recurso)
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_availability_rules_resource_id
    ON availability_rules (resource_id);

-- Compuesto: lookup de reglas por recurso y día ISO.
CREATE INDEX IF NOT EXISTS idx_availability_rules_resource_day
    ON availability_rules (resource_id, day_of_week);

-- -----------------------------------------------------------------------------
-- availability_exceptions  (desviaciones puntuales sobre la allow-list)
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_availability_exceptions_resource_id
    ON availability_exceptions (resource_id);

-- Compuesto: excepciones de un recurso que caen en una ventana temporal.
CREATE INDEX IF NOT EXISTS idx_availability_exceptions_resource_start_end
    ON availability_exceptions (resource_id, start_at, end_at);

-- -----------------------------------------------------------------------------
-- service_resources  (pool OR: recursos alternativos por servicio)
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_service_resources_service_id
    ON service_resources (service_id);
CREATE INDEX IF NOT EXISTS idx_service_resources_resource_id
    ON service_resources (resource_id);

-- UNIQUE service_resources(service_id, resource_id).
CREATE UNIQUE INDEX IF NOT EXISTS uq_service_resources_service_resource
    ON service_resources (service_id, resource_id);

-- -----------------------------------------------------------------------------
-- resources
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_resources_employee_id ON resources (employee_id);
CREATE INDEX IF NOT EXISTS idx_resources_location_id ON resources (location_id);
CREATE INDEX IF NOT EXISTS idx_resources_calendar_id ON resources (calendar_id);
