-- =============================================================================
-- Aegora · las citas que cambian quedan marcadas para la sincronización de calendario
--
-- POR QUÉ ESTO EXISTE
-- `CALENDARIO · Outlook` (n8n) tiene que enterarse de TODO lo que cambia una cita,
-- venga de donde venga: Lucía reservando por el Booking API, un gestor editando en
-- el panel, o el trigger de supresión cancelando las citas de un contacto borrado
-- (contacts-erasure.sql). Un Flow de Directus solo vería lo que pasa por su API;
-- un webhook del Booking API, solo lo suyo. La base de datos lo ve todo.
--
-- Así que aquí solo se MARCA (`appointments.calendario_pendiente = true`), y n8n
-- recoge lo marcado cada minuto y deja el calendario como debe estar. Marcar de más
-- es inofensivo: n8n recalcula desde cero y, si no hay nada que cambiar, no toca
-- Outlook.
--
-- Qué marca:
--   - una cita nueva;
--   - un cambio de hora, estado, contacto, servicio, título o notas (lo que se ve en
--     el evento). Que n8n desmarque la cita NO cambia nada de eso, y por eso no
--     vuelve a marcarla: sin esa comparación, esto sería un bucle;
--   - un cambio en quién atiende (`appointment_resources`): el evento cambia de buzón;
--   - un empleado que activa o desactiva la sincronización, o cambia de email: sus
--     citas futuras, para que aparezcan en su calendario o desaparezcan de él.
--
-- Sin `CREATE TRIGGER ... OF columna` a propósito: el dry-run de apply-schema valida
-- este fichero ANTES de crear las columnas nuevas, y un trigger por columna falla si
-- la columna aún no existe. Las comprobaciones van dentro de las funciones, que
-- plpgsql resuelve al ejecutarse.
--
-- Se llama `sync-calendario.sql` y no `calendar-sync.sql` por el ORDEN: apply-schema
-- aplica los .sql por orden alfabético, y en el dry-run las columnas nuevas aún no
-- existen. Si este fichero fuera antes que `employees-status.sql`, el UPDATE de ese
-- dispararía el trigger de empleados y fallaría por una columna que no está.
--
-- Idempotente: se puede aplicar tantas veces como haga falta.
-- =============================================================================

CREATE OR REPLACE FUNCTION aegora_calendario_marcar_cita()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.calendario_pendiente := true;
  ELSIF (NEW.start_at, NEW.end_at, NEW.status, NEW.contact_id, NEW.service_id, NEW.title, NEW.notes)
        IS DISTINCT FROM
        (OLD.start_at, OLD.end_at, OLD.status, OLD.contact_id, OLD.service_id, OLD.title, OLD.notes) THEN
    NEW.calendario_pendiente := true;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS aegora_appointments_calendario ON appointments;
CREATE TRIGGER aegora_appointments_calendario
  BEFORE INSERT OR UPDATE ON appointments
  FOR EACH ROW
  EXECUTE FUNCTION aegora_calendario_marcar_cita();


CREATE OR REPLACE FUNCTION aegora_calendario_marcar_por_recurso()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    UPDATE appointments SET calendario_pendiente = true WHERE id = NEW.appointment_id;
  END IF;
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    UPDATE appointments SET calendario_pendiente = true WHERE id = OLD.appointment_id;
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS aegora_appointment_resources_calendario ON appointment_resources;
CREATE TRIGGER aegora_appointment_resources_calendario
  AFTER INSERT OR UPDATE OR DELETE ON appointment_resources
  FOR EACH ROW
  EXECUTE FUNCTION aegora_calendario_marcar_por_recurso();


CREATE OR REPLACE FUNCTION aegora_calendario_marcar_por_empleado()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF (NEW.sincronizar_calendario, NEW.email, NEW.status)
     IS DISTINCT FROM (OLD.sincronizar_calendario, OLD.email, OLD.status) THEN
    UPDATE appointments a
       SET calendario_pendiente = true
      FROM appointment_resources ar
      JOIN resources r ON r.id = ar.resource_id
     WHERE ar.appointment_id = a.id
       AND ar.role = 'primary'
       AND r.employee_id = NEW.id
       AND a.end_at > now();
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS aegora_employees_calendario ON employees;
CREATE TRIGGER aegora_employees_calendario
  AFTER UPDATE ON employees
  FOR EACH ROW
  EXECUTE FUNCTION aegora_calendario_marcar_por_empleado();

