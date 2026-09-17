#!/usr/bin/env python3

"""
Aegora · los workflows de n8n, sin el tenant dentro.

En Git los workflows llevan tokens en vez de valores concretos. Al desplegar se
renderizan contra un tenant; al exportar de vuelta se normalizan. Las dos
direcciones viven aquí a propósito: son inversas, y si se implementan en dos
sitios se separan (nos ha pasado ya con cosas mucho menores).

Por qué tokens y no un nodo `Config` por workflow, que es lo que proponía el
README: un `Config` funciona DENTRO de un workflow, así que para que la URL
llegue a una hoja como `06 · CONTACT · Get` hay que añadirle el nodo Y que cada
`Execute Workflow` que la llama le pase el valor Y que ese llamante lo tenga a
su vez -- un cambio de contrato en cascada, con fallo silencioso si te dejas un
eslabón. Y sobre todo: un `Config` no puede hacer nada con las ~30 referencias
a credenciales por nombre, que era el hardcode más numeroso. La URL base es tan
constante durante la vida de un tenant como el nombre de su contenedor, así que
se renderiza al desplegar, igual que `compose.yml.tpl` y `.env.tpl`.

Tokens (sintaxis `__X__` a propósito: no choca con los ~65 `${...}` de los
template literals de los Code nodes, ni con las expresiones `{{ }}` de n8n):

  __DIRECTUS_BASE_URL__     http://<tenant>-directus:8055
  __BOOKING_BASE_URL__      http://<tenant>-booking:3000
  __TENANT_ID__             el id del tenant
  __PRIVACY_POLICY_URL__    política de privacidad que cita Lucía

Dos valores NO llevan token, se quedan neutros: los nombres de credencial
(`Directus`, `WhatsApp`) y los `webhookId`. Cada tenant tiene su propia
instancia de n8n, así que calificarlos con el tenant era ruido. Por eso las dos
direcciones son asimétricas aquí: `normalize` quita el sufijo ` · <tenant>` si
lo encuentra (para digerir exports viejos), y `render` no lo vuelve a poner.

Uso:
  workflow-tokens.py render    SRC_DIR DST_DIR
  workflow-tokens.py normalize SRC_DIR DST_DIR [--from-export] [--allow-residue]

Lee de entorno: TENANT_ID, DIRECTUS_BASE_URL, BOOKING_BASE_URL,
PRIVACY_POLICY_URL.

`--from-export` es para la salida cruda de `n8n export:workflow`: además de los
tokens, se queda solo con las claves de la convención (id, name, nodes,
connections, settings) y tira pinData, versionId, timestamps y demás ruido.
Sin ese flag trabaja sobre el texto tal cual, que deja el diff limpio.
"""

import json
import os
import re
import sys
from pathlib import Path

# Lo único que se conserva de un export. El resto (pinData, versionId,
# createdAt/updatedAt, meta, tags, triggerCount, staticData, shared...) es
# estado de la instancia, no del workflow, y ensucia el diff en cada captura.
#
# `active` sí se queda: dice si el workflow está en marcha, que es información
# de verdad y no ata al tenant. Tirarla haría que un export perdiera en silencio
# algo que el fichero traía -- y además no sabemos si importar sin ella
# desactiva un workflow que estaba activo (a verificar en el primer import).
KEEP_KEYS = ("id", "name", "active", "nodes", "connections", "settings")

TOKEN_DIRECTUS = "__DIRECTUS_BASE_URL__"
TOKEN_BOOKING = "__BOOKING_BASE_URL__"
TOKEN_TENANT = "__TENANT_ID__"
TOKEN_PRIVACY = "__PRIVACY_POLICY_URL__"


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        fail(f"Falta la variable de entorno {name}.")
    return value


class Tenant:
    def __init__(self) -> None:
        self.tenant_id = env("TENANT_ID")
        self.directus = env("DIRECTUS_BASE_URL").rstrip("/")
        self.booking = env("BOOKING_BASE_URL").rstrip("/")
        self.privacy = env("PRIVACY_POLICY_URL")

    @property
    def pairs(self):
        """(token, valor concreto), del más específico al más genérico.

        El orden importa en `normalize`: la URL de privacidad contiene el id del
        tenant, así que tiene que sustituirse ANTES de que la regla del tenant
        le meta mano por dentro.
        """
        return (
            (TOKEN_PRIVACY, self.privacy),
            (TOKEN_DIRECTUS, self.directus),
            (TOKEN_BOOKING, self.booking),
        )


def render(text: str, tenant: Tenant) -> str:
    for token, value in tenant.pairs:
        text = text.replace(token, value)
    # El token del tenant aparece como valor entero ("__TENANT_ID__") y entre
    # comillas simples dentro de jsCode ('__TENANT_ID__'); un replace plano
    # cubre los dos.
    return text.replace(TOKEN_TENANT, tenant.tenant_id)


def normalize_text(text: str, tenant: Tenant) -> str:
    for token, value in tenant.pairs:
        text = text.replace(value, token)

    tid = re.escape(tenant.tenant_id)

    # El id del tenant, solo donde de verdad lo es: como valor completo de un
    # campo, o como literal entre comillas simples dentro de un Code node
    # (los fallbacks `|| 'demo'`). Nunca como palabra suelta en prosa.
    text = re.sub(rf'"value": "{tid}"', f'"value": "{TOKEN_TENANT}"', text)
    text = re.sub(rf"'{tid}'", f"'{TOKEN_TENANT}'", text)

    # Nombres de credencial: se les quita el sufijo del tenant y no se les
    # vuelve a poner. `Directus · demo` -> `Directus`.
    text = re.sub(rf'("name": "[^"]+) · {tid}"', r'\1"', text)

    # webhookId: `aegora-whatsapp-demo-get` -> `aegora-whatsapp-get`.
    text = re.sub(rf'("webhookId": "[^"]*?)-{tid}', r"\1", text)

    return text


def strip_export(text: str) -> str:
    """Deja un export crudo en la forma de la convención."""
    data = json.loads(text)
    kept = {k: data[k] for k in KEEP_KEYS if k in data}
    missing = [k for k in ("id", "name", "nodes", "connections") if k not in kept]
    if missing:
        fail("El export no tiene " + ", ".join(missing) + ".")
    return json.dumps(kept, indent=2, ensure_ascii=False) + "\n"


def find_residue(text: str, tenant: Tenant):
    """Lo que sigue oliendo a este tenant después de normalizar.

    Es la red de seguridad de todo esto: sin ella, el siguiente export vuelve a
    meter el tenant en Git y nadie se entera hasta que falla un tenant nuevo.
    """
    hits = []
    for match in re.finditer(rf"\b{re.escape(tenant.tenant_id)}\b", text):
        start = max(0, match.start() - 60)
        hits.append(text[start:match.end() + 30].replace("\n", " "))
    return hits


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}

    unknown = flags - {"--from-export", "--allow-residue"}
    if unknown:
        fail("Opción desconocida: " + ", ".join(sorted(unknown)))

    if len(args) != 3 or args[0] not in ("render", "normalize"):
        fail("Uso: workflow-tokens.py render|normalize SRC_DIR DST_DIR")

    mode, src_dir, dst_dir = args[0], Path(args[1]), Path(args[2])

    if not src_dir.is_dir():
        fail(f"No existe el directorio de origen: {src_dir}")

    tenant = Tenant()
    sources = sorted(src_dir.glob("*.json"))
    if not sources:
        fail(f"No hay ningún .json en {src_dir}")

    dst_dir.mkdir(parents=True, exist_ok=True)

    residue = {}
    for source in sources:
        text = source.read_text(encoding="utf-8")

        if mode == "render":
            out = render(text, tenant)
            leftover = re.findall(r"__[A-Z][A-Z_]*__", out)
            if leftover:
                fail(f"{source.name}: tokens sin resolver: {sorted(set(leftover))}")
        else:
            if "--from-export" in flags:
                text = strip_export(text)
            out = normalize_text(text, tenant)
            hits = find_residue(out, tenant)
            if hits:
                residue[source.name] = hits

        (dst_dir / source.name).write_text(out, encoding="utf-8")

    if residue and "--allow-residue" not in flags:
        print(
            f"\nERROR: después de normalizar sigue habiendo '{tenant.tenant_id}' "
            "en los workflows.\n"
            "Cada línea es un hardcode nuevo que hay que tokenizar (o prosa "
            "legítima, y entonces se pasa --allow-residue).\n",
            file=sys.stderr,
        )
        for name, hits in residue.items():
            print(f"  {name}", file=sys.stderr)
            for hit in hits:
                print(f"      …{hit}…", file=sys.stderr)
        raise SystemExit(1)

    print(f"{mode}: {len(sources)} workflows -> {dst_dir}")


if __name__ == "__main__":
    main()
