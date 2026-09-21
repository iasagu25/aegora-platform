#!/usr/bin/env python3
"""Mete el prompt del .md dentro del nodo del agente.

`n8n/prompts/lucia-v2.md` y el `systemMessage` de `AGENT-Lucia-Core-v2.json`
tenían el mismo texto por disciplina, no por construcción: dos copias de 10.000
caracteres que solo coinciden mientras nadie se despiste. Y despistarse aquí no
da ningún error -- el agente se comporta distinto y no hay nada que mirar.

El fichero .md manda. El JSON es artefacto.

    python3 n8n/build-prompt.py            # comprueba y dice si divergen
    python3 n8n/build-prompt.py --write    # escribe el .md dentro del JSON
"""

import json
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent
PROMPT = RAIZ / "prompts" / "lucia-v2.md"
WORKFLOW = RAIZ / "workflows" / "AGENT-Lucia-Core-v2.json"


def bloque_del_md(texto: str) -> str:
    """El prompt es el único bloque ``` del documento; lo de fuera es para quien lo mantiene."""
    partes = texto.split("```")
    if len(partes) < 3:
        raise SystemExit(f"ERROR: {PROMPT} no tiene un bloque delimitado por ```.")
    if len(partes) > 3:
        raise SystemExit(
            f"ERROR: {PROMPT} tiene más de un bloque ```. "
            "El prompt tiene que ser el único, o no se sabe cuál es."
        )
    return partes[1].strip("\n")


def nodo_del_agente(datos: dict) -> dict:
    candidatos = [n for n in datos["nodes"] if n["type"].endswith(".agent")]
    if len(candidatos) != 1:
        raise SystemExit(
            f"ERROR: se esperaba exactamente un nodo de agente en {WORKFLOW.name}, "
            f"hay {len(candidatos)}."
        )
    return candidatos[0]


def main() -> int:
    escribir = "--write" in sys.argv[1:]

    prompt = bloque_del_md(PROMPT.read_text(encoding="utf-8"))
    datos = json.loads(WORKFLOW.read_text(encoding="utf-8"))
    nodo = nodo_del_agente(datos)

    opciones = nodo["parameters"].setdefault("options", {})
    actual = opciones.get("systemMessage", "")
    # El '=' de delante es lo que le dice a n8n que el campo es una expresión:
    # sin él las interpolaciones {{ }} viajarían como texto literal.
    deseado = "=" + prompt

    if actual == deseado:
        print(f"OK: el prompt del nodo coincide con {PROMPT.name} ({len(prompt)} caracteres).")
        return 0

    if not escribir:
        print(f"DIVERGEN: el nodo tiene {len(actual)} caracteres y {PROMPT.name} tiene {len(deseado)}.")
        print("El .md manda. Ejecuta con --write para llevarlo al JSON.")
        return 1

    opciones["systemMessage"] = deseado
    WORKFLOW.write_text(
        json.dumps(datos, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Escrito: {len(prompt)} caracteres de {PROMPT.name} en {WORKFLOW.name}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
