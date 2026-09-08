-- =============================================================================
-- directus/sql/booking-indexes.sql
-- Capa SQL idempotente de índices y constraints del modelo de booking.
--
-- Referencia: handover técnico post-LumaDock, sección 12.2 (Prioridad 2).
-- base.yaml cubre el modelo Directus pero no es un sistema completo de
-- migraciones para índices compuestos y constraints; esta capa lo complementa.
--
-- Idempotente: reejecutable sin efectos. Todas las sentencias usan
-- IF NOT EXISTS. Los bloques sobre `resources` y `services_resources` se
-- autoprotegen (comprueban tabla/columna) porque esas columnas todavía no
-- están snapshotadas en directus/schema/base.yaml — Prioridad 1 solo cerró
-- appointments, availability_rules, availability_exceptions y
-- appointment_resources.
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
-- services_resources  (pool OR: recursos alternativos por servicio)
-- El handover lo nombra "service_resources"; la colección Directus real es
-- "services_resources". Bloque autoprotegido: columnas aún no en base.yaml.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF to_regclass('public.services_resources') IS NULL THEN
        RAISE NOTICE 'services_resources: tabla ausente, se omiten sus índices';
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'services_resources' AND column_name = 'service_id') THEN
        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_services_resources_service_id '
             || 'ON services_resources (service_id)';
    ELSE
        RAISE NOTICE 'services_resources.service_id ausente, índice omitido';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'services_resources' AND column_name = 'resource_id') THEN
        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_services_resources_resource_id '
             || 'ON services_resources (resource_id)';
    ELSE
        RAISE NOTICE 'services_resources.resource_id ausente, índice omitido';
    END IF;

    -- UNIQUE service_resources(service_id, resource_id).
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'services_resources' AND column_name = 'service_id')
       AND EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'services_resources' AND column_name = 'resource_id') THEN
        EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS uq_services_resources_service_resource '
             || 'ON services_resources (service_id, resource_id)';
    ELSE
        RAISE NOTICE 'services_resources(service_id, resource_id) incompleto, UNIQUE omitido';
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- resources  — columnas M2O aún no snapshotadas en base.yaml.
-- Bloque autoprotegido: si tabla/columna no existen todavía, se omite con
-- NOTICE en lugar de abortar el apply.
-- -----------------------------------------------------------------------------
DO $$
BEGIN
    IF to_regclass('public.resources') IS NULL THEN
        RAISE NOTICE 'resources: tabla ausente, se omiten sus índices';
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'resources' AND column_name = 'employee_id') THEN
        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_resources_employee_id ON resources (employee_id)';
    ELSE
        RAISE NOTICE 'resources.employee_id ausente, índice omitido';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'resources' AND column_name = 'location_id') THEN
        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_resources_location_id ON resources (location_id)';
    ELSE
        RAISE NOTICE 'resources.location_id ausente, índice omitido';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'resources' AND column_name = 'calendar_id') THEN
        EXECUTE 'CREATE INDEX IF NOT EXISTS idx_resources_calendar_id ON resources (calendar_id)';
    ELSE
        RAISE NOTICE 'resources.calendar_id ausente, índice omitido';
    END IF;
END $$;
