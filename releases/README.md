# Releases de plataforma

Un release es un tag `vAAAA.MM.DD` (`.2`, `.3`… si sale más de uno el mismo día) sobre
`main`, con su nota aquí: `releases/vAAAA.MM.DD.md`. Por qué y cómo encaja todo:
[`docs/VERSIONADO.md`](../docs/VERSIONADO.md).

## El ciclo de un release

1. **Iterar en `dev`** sobre `main`: commit, push, en el VPS `git reset --hard origin/main` y
   lo que haga falta (aquí sí vale `--only`).
2. **Preparar el release (local)**: escribir `releases/vAAAA.MM.DD.md` copiando la nota
   anterior (qué cambia, pasos manuales de antes y después, riesgos; lo que cambia sale de
   `git log --oneline <tag anterior>..HEAD`). Si cambió `aegora-booking`, subir
   `BOOKING_REF` en `release.env` al sha probado en `dev`. Commit y push.
3. **Pasada completa en `dev` con ese commit (VPS)**: es la prueba del release tal cual va
   a salir, nota incluida.

   ```bash
   cd /opt/aegora/platform && git fetch origin && git checkout main && git reset --hard origin/main
   ```

   ```bash
   cd /opt/aegora/platform && sudo ./provisioning/tenant/actualizar-tenant.sh --tenant dev --apply
   ```

   Si algo falla o se descubre un fallo probando, se arregla, nuevo commit, y se repite
   este paso: el tag no existe todavía, así que no hay nada que deshacer.
4. **Etiquetar ESE commit (local)** cuando `dev` esté bien:

   ```bash
   git tag -a v2026.12.03 -m "v2026.12.03" && git push origin v2026.12.03
   ```

   `aegora-estado.sh` reconoce el tag por el commit: `dev` pasa a salir con
   `v2026.12.03` sin repetir nada.
5. **El resto de tenants (VPS)**, de uno en uno, PLAN y luego `--apply`. Orden: `ops`
   (canario, es nuestro), `demo`, clientes.

   ```bash
   cd /opt/aegora/platform && git fetch origin --tags && git checkout v2026.12.03
   ```

   ```bash
   cd /opt/aegora/platform && sudo ./provisioning/tenant/actualizar-tenant.sh --tenant ops
   ```

   El PLAN dice si hay que añadir `--recrear` (cambia la configuración del tenant) o
   `--permitir-borrados` (el esquema borra algo). Al acabar con todos, el checkout vuelve
   a `main`:

   ```bash
   cd /opt/aegora/platform && git checkout main && git reset --hard origin/main
   ```

Y para ver dónde está cada uno, en cualquier momento:

```bash
sudo /opt/aegora/platform/scripts/aegora-estado.sh
```

## Reglas

- **Un tenant que no es `dev` solo recibe tags**, y el release entero: nada de `--only`.
  `actualizar-tenant.sh` lo impone: se niega fuera de un tag, con el checkout sucio o si
  ese release no consta entero en `dev`.
- **Un solo tren**: todos los clientes van al mismo release. Si uno se queda atrás, se
  apunta en la nota del release siguiente y por qué.
- **Los borrados de esquema van en un release posterior** al que deja de usarlos.
- Un tag publicado no se mueve. Si sale mal, se corrige en el siguiente.
