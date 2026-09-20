#!/usr/bin/env python3

"""
Aegora · qué valor del fichero ya renderizado corresponde a qué variable.

Lo usa render-tenant-config.sh para conservar valores que no están en
`tenant.env` ni en `secrets/` (BOOKING_DATABASE_URL, por ejemplo).

No se puede asumir que la variable y la clave se llamen igual: en
`booking/.env.tpl` la línea es `DATABASE_URL=${BOOKING_DATABASE_URL}`, así que
el valor de esa variable vive bajo la clave `DATABASE_URL`. Por eso se invierte
la plantilla en vez de buscar la variable por su nombre.

Imprime `VARIABLE<TAB>valor`, una por línea, solo para las que tienen valor.
"""

import re
import sys

PAR = re.compile(r"\s*([A-Z0-9_]+)=\$\{([A-Z0-9_]+)\}\s*")


def main() -> None:
    if len(sys.argv) != 3:
        print("Uso: invert-template.py PLANTILLA FICHERO_RENDERIZADO", file=sys.stderr)
        raise SystemExit(1)

    plantilla, existente = sys.argv[1], sys.argv[2]

    # Solo las líneas cuyo valor es EXACTAMENTE una variable. Si la plantilla
    # compone (`URL=https://${HOST}/x`) no hay forma fiable de despejarla, así
    # que no se intenta: esas tienen que venir de tenant.env o de secrets/.
    clave_de_var = {}
    with open(plantilla, encoding="utf-8") as f:
        for linea in f:
            m = PAR.fullmatch(linea.rstrip("\n"))
            if m:
                clave_de_var[m.group(2)] = m.group(1)

    if not clave_de_var:
        return

    valores = {}
    with open(existente, encoding="utf-8") as f:
        for linea in f:
            linea = linea.strip()
            if not linea or linea.startswith("#") or "=" not in linea:
                continue
            k, _, v = linea.partition("=")
            valores[k.strip()] = v.strip()

    for var, clave in sorted(clave_de_var.items()):
        valor = valores.get(clave, "")
        if valor:
            print(f"{var}\t{valor}")


if __name__ == "__main__":
    main()
