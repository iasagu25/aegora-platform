-- =============================================================================
-- Aegora · borrar un contacto cancela antes sus citas futuras
--
-- POR QUÉ ESTO EXISTE
-- El derecho de supresión del RGPD es una obligación del negocio, así que el
-- gestor tiene que poder borrar un contacto sin llamarnos. Pero las claves
-- ajenas ponen `appointments.contact_id` a NULL, y eso, que es correcto para una
-- cita pasada -- se va el dato personal, queda el registro --, en una cita FUTURA
-- deja un hueco reservado para nadie: en la agenda del gestor, sin forma de
-- saber de quién era ni a quién avisar. Y en silencio.
-- Pasó en `dev` el 21/sep/2026 a la primera: un borrado, tres citas huérfanas.
--
-- Y la ley dice lo mismo que la operativa: si dejas de tratar sus datos, dejas
-- de guardarle una hora.
--
-- POR QUÉ UN TRIGGER Y NO UN FLOW DE DIRECTUS
-- Es un invariante del dato, no un automatismo de la aplicación: una cita futura
-- no puede quedarse sin dueño venga el borrado de donde venga. Un Flow solo se
-- dispara si el borrado pasa por la API de Directus -- no desde `psql`, ni desde
-- un script de mantenimiento. Además esto es atómico con el borrado y viaja
-- dentro del `pg_dump`, así que un tenant restaurado lo conserva sin trabajo.
--
-- Idempotente: se puede aplicar tantas veces como haga falta.
-- =============================================================================

CREATE OR REPLACE FUNCTION aegora_cancelar_citas_futuras()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- Solo lo que todavía ocupa un hueco. `completed` y `no_show` son historia y
  -- no se tocan; `cancelled` ya está cancelada.
  UPDATE appointments
     SET status = 'cancelled',
         updated_at = now()
   WHERE contact_id = OLD.id
     AND status IN ('scheduled', 'confirmed')
     AND start_at > now();

  -- Las pasadas se quedan como están y pierden el contacto por la clave ajena
  -- (ON DELETE SET NULL): el negocio conserva que hubo una cita a esa hora, sin
  -- el dato personal. Eso es exactamente lo que pide una supresión.
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS aegora_contacts_before_delete ON contacts;

CREATE TRIGGER aegora_contacts_before_delete
  BEFORE DELETE ON contacts
  FOR EACH ROW
  EXECUTE FUNCTION aegora_cancelar_citas_futuras();
