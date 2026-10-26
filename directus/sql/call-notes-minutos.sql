-- =============================================================================
-- Aegora · minutos de cada llamada, para el informe del gestor
--
-- POR QUÉ ESTO EXISTE
-- `call_notes.duracion_segundos` lo escribe `VOZ · Nota de llamada` con lo que manda
-- Retell. El informe de Insights quiere "minutos al teléfono", y un panel de Directus
-- suma un campo pero no sabe dividirlo. Así que el dato se guarda también en minutos.
--
-- Minutos ENTEROS redondeando hacia arriba: una llamada de 40 segundos es un minuto, que
-- es como cuenta cualquier factura de teléfono y como lo entiende el gestor.
--
-- Lo pone la base de datos y no el workflow: así vale también para las notas que ya
-- existían y para cualquier otra vía que escriba una nota.
--
-- El relleno de las filas que ya existen va dentro de un DO que comprueba que la columna
-- exista: el dry-run de apply-schema valida este fichero ANTES de crearla.
--
-- Idempotente.
-- =============================================================================

CREATE OR REPLACE FUNCTION aegora_call_notes_minutos()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.duracion_minutos := CASE
    WHEN NEW.duracion_segundos IS NULL THEN NULL
    ELSE ceil(NEW.duracion_segundos / 60.0)::integer
  END;
  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'call_notes'
                AND column_name = 'duracion_minutos') THEN
    EXECUTE 'DROP TRIGGER IF EXISTS aegora_call_notes_minutos ON call_notes';
    EXECUTE 'CREATE TRIGGER aegora_call_notes_minutos
               BEFORE INSERT OR UPDATE OF duracion_segundos, duracion_minutos ON call_notes
               FOR EACH ROW EXECUTE FUNCTION aegora_call_notes_minutos()';
    EXECUTE 'UPDATE call_notes
                SET duracion_minutos = ceil(duracion_segundos / 60.0)::integer
              WHERE duracion_segundos IS NOT NULL
                AND duracion_minutos IS DISTINCT FROM ceil(duracion_segundos / 60.0)::integer';
  END IF;
END;
$$;
