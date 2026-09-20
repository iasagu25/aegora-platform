#!/usr/bin/env python3

"""
Aegora · qué cobertura de backup se perdería al re-renderizar el manifiesto.

El manifiesto decide QUÉ se respalda. Quitarle una base o una ruta persistente
es tan grave como vaciar un secreto de un .env, y con peor sintomatología: no
falla nada, simplemente deja de copiarse algo y no se sabe hasta que hace falta.

Imprime una línea por entrada que desaparecería. Sin salida, nada se pierde.
"""

import json
import sys


def entradas(ruta):
    with open(ruta, encoding="utf-8") as f:
        d = json.load(f)

    bases = set(d.get("databases") or [])
    rutas = {e["path"] for e in (d.get("persistent_paths") or []) if "path" in e}
    ficheros = {
        e["destination"]
        for e in (d.get("configuration_files") or [])
        if "destination" in e
    }
    return bases, rutas, ficheros


def main() -> None:
    if len(sys.argv) != 3:
        print("Uso: chk_manifest.py ACTUAL NUEVO", file=sys.stderr)
        raise SystemExit(1)

    a_bases, a_rutas, a_ficheros = entradas(sys.argv[1])
    n_bases, n_rutas, n_ficheros = entradas(sys.argv[2])

    for base in sorted(a_bases - n_bases):
        print(f"    base de datos '{base}': dejaría de respaldarse")

    for ruta in sorted(a_rutas - n_rutas):
        print(f"    ruta '{ruta}': dejaría de respaldarse")

    for fichero in sorted(a_ficheros - n_ficheros):
        print(f"    fichero '{fichero}': dejaría de respaldarse")


if __name__ == "__main__":
    main()
