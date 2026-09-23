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
# `active` tampoco se queda, y esto costó un rodeo: primero lo conservé por no
# perder información. Pero en n8n 2.x publicar es un acto explícito por id
# (`publish:workflow --id=…`) y **un sub-workflow tiene que estar publicado para
# que se le pueda llamar**. Con `active` dentro del JSON, importar un fichero
# con `active: false` -- que es lo que tenían las 7 tools de v2 en Git --
# despublicaría las herramientas de Lucía y la dejaría sin nada que llamar.
# Quién está publicado es estado del instance y lo decide el despliegue, no un
# fichero versionado.
KEEP_KEYS = ("id", "name", "nodes", "connections", "settings")

# Campos que son SECRETOS del tenant y nunca salen de él. Un export trae sus
# valores reales (n8n los guarda en claro en el nodo `Config`, no son
# credenciales cifradas), así que al normalizar se devuelven a su placeholder.
#
# Esto no es cosmética: sin ello, la primera captura de WHATSAPP · Adapter mete
# en Git el phone_number_id, el verify_token y el token de Meta. Estuvo a punto
# de pasar. La casa de estos valores es secrets/whatsapp.env.
# campo del nodo Config -> (placeholder en Git, variable de secrets/whatsapp.env)
SECRET_FIELDS = {
    "phone_number_id": ("REPLACE_PHONE_NUMBER_ID", "WHATSAPP_PHONE_NUMBER_ID"),
    "verify_token": ("REPLACE_VERIFY_TOKEN", "WHATSAPP_VERIFY_TOKEN"),
    "app_secret": ("REPLACE_APP_SECRET", "WHATSAPP_APP_SECRET"),
    # La API key de Retell, que es a la vez el secreto con el que firma sus
    # webhooks. Va aquí sobre todo por la dirección de VUELTA: sin esta entrada,
    # un export de un tenant configurado se traería la clave en claro a Git.
    "retell_api_key": ("REPLACE_RETELL_API_KEY", "RETELL_API_KEY"),
}

# Ajustes de comportamiento que cambian por tenant. Viven en un campo de un nodo
# Set, igual que los secretos de WhatsApp, y por la misma razón: su valor es un
# booleano y un token con valor `true` NO se puede revertir por valor -- al
# normalizar se convertirían en el token todos los `true` del JSON. El nombre del
# campo, en cambio, es unívoco.
#
# Llevan valor por defecto porque, al revés que un secreto, aquí no vale dejar el
# placeholder puesto: la cadena "__CONTACTO_PEDIR_EMPRESA__" es "verdadera" para
# cualquier comprobación laxa, así que un tenant sin configurar acabaría pidiendo
# la empresa a todo el mundo.
AJUSTES_TENANT = {
    "pedir_empresa": ("__CONTACTO_PEDIR_EMPRESA__", "CONTACTO_PEDIR_EMPRESA", "false"),
}

# Formas que delatan un secreto aunque el campo no esté en la lista de arriba.
# La lista nombrada tapa lo que sabemos; esto es la red por debajo.
SECRET_SHAPES = (
    (re.compile(r"\bEA[A-Za-z0-9]{40,}"), "token de Meta (EAA…)"),
    (re.compile(r"\bsk-[A-Za-z0-9_-]{20,}"), "clave de OpenAI (sk-…)"),
    (re.compile(r"\bghp_[A-Za-z0-9]{20,}"), "token de GitHub (ghp_…)"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\."), "JWT"),
    (re.compile(r"\bkey_[A-Za-z0-9]{24,}"), "clave de Retell (key_…)"),
)

# Los `id` de credencial TAMBIÉN atan al tenant. El README heredado decía que
# n8n las re-mapea por nombre al importar: es FALSO, lo resuelve por `id` y
# falla con "Credential with ID ... does not exist" aunque exista una con ese
# nombre (comprobado 17/sep/2026 en demo). Los 29 nodos que apuntan a `Directus`
# funcionan solo porque llevan dentro el id de demo; en otro tenant fallarían
# igual. Así que el id va en un token derivado del NOMBRE de la credencial, y
# `render` pregunta a n8n qué id tiene cada una.
TOKEN_CRED_PREFIX = "__CRED_"

TOKEN_DIRECTUS = "__DIRECTUS_BASE_URL__"
TOKEN_BOOKING = "__BOOKING_BASE_URL__"
TOKEN_TENANT = "__TENANT_ID__"
TOKEN_PRIVACY = "__PRIVACY_POLICY_URL__"
TOKEN_DISPLAY = "__TENANT_DISPLAY_NAME__"


def credential_slug(name: str) -> str:
    """`Booking API` -> `__CRED_BOOKING_API__`. Determinista en los dos sentidos."""
    limpio = re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").upper()
    return f"{TOKEN_CRED_PREFIX}{limpio}__"


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
        # El nombre con el que Lucía se presenta ("soy la asistente de ..."). Se
        # me escapó en el inventario inicial porque iba en mayúscula ("Aegora
        # Demo") y la búsqueda era sensible a mayúsculas. De ahí que el control
        # de residuos de abajo ya no lo sea.
        self.display = env("TENANT_DISPLAY_NAME")

    @property
    def pairs(self):
        """(token, valor concreto), del más específico al más genérico.

        El orden importa en `normalize`: la URL de privacidad contiene el id del
        tenant, así que tiene que sustituirse ANTES de que la regla del tenant
        le meta mano por dentro.
        """
        return (
            (TOKEN_PRIVACY, self.privacy),
            (TOKEN_DISPLAY, self.display),
            (TOKEN_DIRECTUS, self.directus),
            (TOKEN_BOOKING, self.booking),
        )


def render(text: str, tenant: Tenant) -> str:
    for token, value in tenant.pairs:
        text = text.replace(token, value)

    # Los secretos de WhatsApp, si el que llama los ha puesto en el entorno
    # (render-workflows.sh los lee de secrets/whatsapp.env). Sin ellos se quedan
    # los placeholders: importar así deja el adapter sin configurar, que es
    # mejor que romperlo en silencio, pero hay que saberlo.
    for placeholder, var in SECRET_FIELDS.values():
        valor = os.environ.get(var, "").strip()
        if valor:
            text = text.replace(placeholder, valor)

    # Ajustes de tenant: estos SIEMPRE se resuelven, con su valor por defecto si
    # el tenant no dice nada. Dejar el token puesto sería peor que no tenerlo.
    for placeholder, var, defecto in AJUSTES_TENANT.values():
        text = text.replace(placeholder, os.environ.get(var, "").strip() or defecto)

    # Ids de credencial, por nombre. El que llama pasa AEGORA_CREDENTIALS con lo
    # que tenga el n8n del tenant: {"Directus": "CFY5…", …}.
    for nombre, cred_id in credenciales_del_entorno().items():
        text = text.replace(credential_slug(nombre), cred_id)
    # El token del tenant aparece como valor entero ("__TENANT_ID__") y entre
    # comillas simples dentro de jsCode ('__TENANT_ID__'); un replace plano
    # cubre los dos.
    return text.replace(TOKEN_TENANT, tenant.tenant_id)


def credenciales_que_usan(sources) -> dict:
    """{nombre de credencial: [tipo, …]} mirando todos los workflows a la vez.

    Se recogen de una pasada para poder decirle a quien monta un tenant nuevo
    TODAS las credenciales que le faltan, con su nombre y su tipo, en vez de
    pararse en la primera.
    """
    usadas = {}
    for source in sources:
        data = json.loads(source.read_text(encoding="utf-8"))
        for node in data.get("nodes", []):
            for tipo, cred in (node.get("credentials") or {}).items():
                nombre = cred.get("name")
                if nombre:
                    usadas.setdefault(nombre, set()).add(tipo)
    return {k: sorted(v) for k, v in usadas.items()}


def credenciales_del_entorno() -> dict:
    crudo = os.environ.get("AEGORA_CREDENTIALS", "").strip()
    if not crudo:
        return {}
    try:
        datos = json.loads(crudo)
    except json.JSONDecodeError as exc:
        fail(f"AEGORA_CREDENTIALS no es JSON válido: {exc}")
    return {str(k): str(v) for k, v in datos.items()}


def tokenize_credentials(text: str) -> str:
    """El `id` de cada credencial, al token que toca por su nombre.

    Estructural sobre el JSON: el `id` y el `name` viven en el mismo objeto, así
    que el nombre de al lado es quien decide el token. Un replace textual no
    podría saberlo.
    """
    data = json.loads(text)
    for node in data.get("nodes", []):
        for cred in (node.get("credentials") or {}).values():
            nombre = cred.get("name")
            if nombre:
                cred["id"] = credential_slug(nombre)
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


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


def restore_secrets(text: str) -> str:
    """Devuelve a su placeholder los secretos y los ajustes que trae un export."""
    campos = {f: p for f, (p, _v) in SECRET_FIELDS.items()}
    campos.update({f: p for f, (p, _v, _d) in AJUSTES_TENANT.items()})
    for field, placeholder in campos.items():
        # Los campos de un nodo Set van como {"name": "<campo>", ..., "value": "<valor>"}.
        text = re.sub(
            rf'("name": "{re.escape(field)}",(?:\s*"[a-zA-Z]+": "[^"]*",)*\s*"value": )"[^"]*"',
            rf'\1"{placeholder}"',
            text,
        )
    return text


def find_secrets(text: str):
    """Lo que parece un secreto aunque no lo hayamos nombrado."""
    hits = []
    for pattern, que_es in SECRET_SHAPES:
        for match in pattern.finditer(text):
            hits.append(f"{que_es}: {match.group(0)[:12]}…")
    return hits


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
    # Sin IGNORECASE se coló "Aegora Demo" durante un día entero.
    for match in re.finditer(rf"\b{re.escape(tenant.tenant_id)}\b", text, re.IGNORECASE):
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

    if mode == "render":
        tiene = credenciales_del_entorno()
        faltan = {n: t for n, t in credenciales_que_usan(sources).items() if n not in tiene}
        if faltan:
            print(
                "\nERROR: en el n8n de este tenant faltan credenciales que usan "
                "los workflows.\nCréalas con ESTE nombre exacto (n8n las "
                "resuelve por id, no por nombre: el id lo recoge este script "
                "una vez existen) y repite:\n",
                file=sys.stderr,
            )
            for nombre, tipos in sorted(faltan.items()):
                print(f"  {nombre!r}   (tipo: {', '.join(tipos)})", file=sys.stderr)
            raise SystemExit(1)

    # Nada se escribe hasta que TODO ha pasado las comprobaciones: un secreto
    # escrito a medias ya está en el disco de quien luego hace `git add .`.
    salida = {}
    residue, secrets = {}, {}
    for source in sources:
        text = source.read_text(encoding="utf-8")

        if mode == "render":
            out = render(text, tenant)
            leftover = sorted(set(re.findall(r"__[A-Z][A-Z_]*__", out)))
            if leftover:
                fail(f"{source.name}: tokens sin resolver: {leftover}")
        else:
            if "--from-export" in flags:
                text = strip_export(text)
            out = tokenize_credentials(restore_secrets(normalize_text(text, tenant)))
            hits = find_residue(out, tenant)
            if hits:
                residue[source.name] = hits
            leaked = find_secrets(out)
            if leaked:
                secrets[source.name] = leaked

        salida[source.name] = out

    if secrets:
        print(
            "\nERROR: en los workflows normalizados hay valores con forma de "
            "secreto.\nNo se escribe nada: un secreto en Git no se borra "
            "revirtiendo el commit.\nSu sitio es secrets/ del tenant; si el "
            "campo es legítimo, añádelo a SECRET_FIELDS.\n",
            file=sys.stderr,
        )
        for name, hits in secrets.items():
            print(f"  {name}", file=sys.stderr)
            for hit in hits:
                print(f"      {hit}", file=sys.stderr)
        raise SystemExit(1)

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

    dst_dir.mkdir(parents=True, exist_ok=True)
    for nombre, contenido in salida.items():
        (dst_dir / nombre).write_text(contenido, encoding="utf-8")

    print(f"{mode}: {len(sources)} workflows -> {dst_dir}")


if __name__ == "__main__":
    main()
