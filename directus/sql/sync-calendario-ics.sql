-- =============================================================================
-- Aegora · cada empleado tiene una clave secreta para su calendario .ics
--
-- POR QUÉ ESTO EXISTE
-- `CALENDARIO · ICS` (n8n) publica las citas de cada empleado en un enlace al que se
-- suscribe desde Outlook, Google o el iPhone. Ese enlace no lleva usuario ni
-- contraseña -- ningún calendario sabe enviarlos al suscribirse --, así que lo único
-- que lo protege es que no se pueda adivinar: `employees.calendario_token`.
--
-- La clave la pone la base de datos, no n8n: en los Code node de n8n no hay
-- criptografía (ni `crypto` ni Web Crypto), y `Math.random()` no sirve para esto.
-- `gen_random_uuid()` sí: 122 bits aleatorios del generador del sistema.
--
-- Invalidar un enlace es vaciar el campo: el trigger pone otra clave al guardar.
--
-- El relleno de los empleados que ya existen va dentro de un DO que comprueba que la
-- columna exista: el dry-run de apply-schema valida este fichero ANTES de crear las
-- columnas nuevas, y un UPDATE directo fallaría ahí.
--
-- Idempotente: se puede aplicar tantas veces como haga falta.
-- =============================================================================

CREATE OR REPLACE FUNCTION aegora_calendario_token()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.calendario_token IS NULL OR btrim(NEW.calendario_token) = '' THEN
    NEW.calendario_token := replace(gen_random_uuid()::text, '-', '');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS aegora_employees_calendario_token ON employees;
CREATE TRIGGER aegora_employees_calendario_token
  BEFORE INSERT OR UPDATE ON employees
  FOR EACH ROW
  EXECUTE FUNCTION aegora_calendario_token();

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'employees'
                AND column_name = 'calendario_token') THEN
    EXECUTE 'UPDATE employees SET calendario_token = replace(gen_random_uuid()::text, ''-'', '''')
              WHERE calendario_token IS NULL OR btrim(calendario_token) = ''''';
  END IF;
END;
$$;
