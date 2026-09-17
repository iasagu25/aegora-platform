#!/usr/bin/env python3

"""
Aegora · en qué orden hay que publicar los workflows de n8n.

n8n no publica un workflow cuyos sub-workflows no estén ya publicados, así que
el orden importa. Por nombre de fichero NO sale bien: `AGENT-Lucia-Core-v2` va
antes que `LUCIA-TOOL-*` alfabéticamente y depende de las siete.

Así que el orden se deduce del grafo real: quién llama a quién según los nodos
`executeWorkflow` y `toolWorkflow`, y se publica de las hojas hacia arriba.
Añadir una tool nueva no obliga a tocar nada aquí.

Uso:
  workflow-order.py DIR        imprime `<id>\\t<fichero>`, dependencias primero
"""

import json
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def referencias(node: dict):
    """El id del workflow al que llama este nodo, si llama a alguno."""
    valor = (node.get("parameters") or {}).get("workflowId")
    if isinstance(valor, dict):
        valor = valor.get("value")
    if isinstance(valor, str) and valor.strip():
        return valor.strip()
    return None


def main() -> None:
    if len(sys.argv) != 2:
        fail("Uso: workflow-order.py DIR")

    directorio = Path(sys.argv[1])
    if not directorio.is_dir():
        fail(f"No existe el directorio: {directorio}")

    fichero_de, depende_de = {}, {}
    for f in sorted(directorio.glob("*.json")):
        data = json.loads(f.read_text(encoding="utf-8"))
        wid = data["id"]
        fichero_de[wid] = f.name
        depende_de[wid] = {
            ref for ref in (referencias(n) for n in data.get("nodes", [])) if ref
        }

    # Solo cuentan las dependencias que están en este mismo lote: una referencia
    # a algo que no versionamos no puede ordenarse ni hace falta.
    for wid in depende_de:
        depende_de[wid] &= set(fichero_de)

    orden, visitados, en_curso = [], set(), set()

    def visitar(wid: str, camino: list) -> None:
        if wid in visitados:
            return
        if wid in en_curso:
            # Un ciclo no es un error fatal: n8n permite que dos workflows se
            # llamen mutuamente. Se corta y se publica en el orden que salga.
            ciclo = " -> ".join(fichero_de.get(x, x) for x in camino + [wid])
            print(f"AVISO: dependencia circular, se publica en el orden que salga: {ciclo}",
                  file=sys.stderr)
            return
        en_curso.add(wid)
        for dep in sorted(depende_de[wid]):
            visitar(dep, camino + [wid])
        en_curso.discard(wid)
        visitados.add(wid)
        orden.append(wid)

    for wid in sorted(fichero_de, key=lambda x: fichero_de[x]):
        visitar(wid, [])

    for wid in orden:
        print(f"{wid}\t{fichero_de[wid]}")


if __name__ == "__main__":
    main()
