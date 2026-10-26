#!/usr/bin/env python3
"""Convierte una base de conocimiento en Markdown en un conjunto de seed para `knowledge`.

    python3 directus/seed/kb-desde-md.py ENTRADA.md SALIDA.json

Formato de entrada: cada `## Título` es una fila (`title`); su texto hasta el siguiente `##`
es el `body` (Markdown, tal cual); `sort` es el orden en el fichero; `active` siempre true.
Los comentarios HTML (`<!-- ... -->`) no se cargan.

Existe porque la KB de Aegora (tenant `ops`) vive en el repo `aegora-web`, junto a los
textos de la web que resume: un cambio en la web y en la KB se ven en el mismo commit. El
VPS solo tiene este repo, así que aquí va el JSON GENERADO, que no se edita a mano.
"""

import json
import re
import sys
from pathlib import Path


def convertir(texto: str, origen: str) -> dict:
    texto = re.sub(r"<!--.*?-->", "", texto, flags=re.S)
    filas, titulo, cuerpo = [], None, []

    def cerrar():
        if titulo is None:
            return
        body = "\n".join(cuerpo).strip()
        if not body:
            sys.exit(f"La sección '{titulo}' está vacía.")
        filas.append({"sort": len(filas) + 1, "active": True, "title": titulo, "body": body})

    for linea in texto.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", linea)
        if m:
            cerrar()
            titulo, cuerpo = m.group(1), []
        elif titulo is not None:
            cuerpo.append(linea)
    cerrar()

    if not filas:
        sys.exit("No hay ninguna sección '## Título' en la entrada.")
    titulos = [f["title"] for f in filas]
    repetidos = sorted({t for t in titulos if titulos.count(t) > 1})
    if repetidos:
        # load-seed busca por título: dos secciones iguales serían la misma fila.
        sys.exit(f"Títulos repetidos: {', '.join(repetidos)}")

    return {
        "_nota": [
            f"GENERADO con directus/seed/kb-desde-md.py desde {origen}. No editar a mano:",
            "se cambia el Markdown y se vuelve a generar.",
            "load-seed.sh no modifica filas que ya existan (busca por título): un texto cambiado",
            "en una sección que ya está cargada se actualiza en el panel, o se borra la fila y se",
            "vuelve a cargar.",
        ],
        "knowledge": filas,
    }


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    entrada, salida = Path(sys.argv[1]), Path(sys.argv[2])
    datos = convertir(entrada.read_text(encoding="utf-8"), sys.argv[1])
    salida.write_text(json.dumps(datos, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{len(datos['knowledge'])} secciones -> {salida}")


if __name__ == "__main__":
    main()
