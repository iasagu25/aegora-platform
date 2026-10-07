# Workflows aparcados

Están construidos pero **fuera de `n8n/workflows/`**, así que `render-workflows.sh` no los
importa ni exige sus credenciales. Para activarlos, se mueven de vuelta a `n8n/workflows/`.

| workflow | por qué está aquí | qué hace falta para sacarlo |
|---|---|---|
| `CALENDARIO-Outlook.json` | Sincronización Aegora → Outlook vía Microsoft Graph. Probada hasta el token (correcto, con `Calendars.ReadWrite`); Graph devuelve 401 porque el directorio de pruebas no tiene Exchange Online. | Un cliente real con Microsoft 365 (MX en `*.mail.protection.outlook.com`). Entonces: credencial `Microsoft Graph` en TODOS los tenants (el render la exige), mostrar `employees.sincronizar_calendario` y la colección `calendar_sync` en `base.yaml`, y probarlo en `dev` con un buzón con licencia. Ver `CLAUDE.md`. |
