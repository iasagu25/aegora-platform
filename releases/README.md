# Releases de plataforma

Un release es un tag `vAAAA.MM.DD` (`.2`, `.3`… si sale más de uno el mismo día) sobre
`main`, con su nota aquí: `releases/vAAAA.MM.DD.md`. Por qué y cómo encaja todo:
[`docs/VERSIONADO.md`](../docs/VERSIONADO.md).

## Cortar un release (local)

1. `dev` ya tiene aplicado lo que va a salir, y se ha probado ahí.
2. Si cambió `aegora-booking`, subir `BOOKING_REF` en `release.env` al sha probado en `dev`.
3. Escribir `releases/vAAAA.MM.DD.md` copiando la nota anterior: qué cambia, pasos
   manuales de antes y después, riesgos. Lo que cambia sale de
   `git log --oneline <tag anterior>..HEAD`.
4. Commit de la nota, tag anotado y push de los dos:

   ```bash
   git tag -a v2026.12.03 -m "v2026.12.03"
   git push origin main v2026.12.03
   ```

## Llevar un tenant a un release (VPS)

Mientras `main` esté en el mismo commit que el tag, basta con el checkout en `main`: el
registro reconoce el tag porque mira el commit, no la rama. Si `main` ya ha avanzado
(estás iterando en `dev`), se despliega desde el tag y se vuelve:

```bash
cd /opt/aegora/platform && git fetch origin --tags && git checkout v2026.12.03
```

```bash
cd /opt/aegora/platform && git checkout main && git reset --hard origin/main
```

Los pasos, hasta que exista `actualizar-tenant.sh` (fase 2), están en la nota de cada
release. Después de aplicar, comprobar:

```bash
sudo /opt/aegora/platform/scripts/aegora-estado.sh
```

## Reglas

- **Un tenant que no es `dev` solo recibe tags**, y el release entero: nada de `--only`.
- **Un solo tren**: todos los clientes van al mismo release. Si uno se queda atrás, se
  apunta en la nota del release siguiente y por qué.
- **Los borrados de esquema van en un release posterior** al que deja de usarlos.
- Un tag publicado no se mueve. Si sale mal, se corrige en el siguiente.
