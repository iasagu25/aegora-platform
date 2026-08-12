#!/usr/bin/env python3

import os
import re
import sys
from pathlib import Path


VARIABLE_PATTERN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if len(sys.argv) != 3:
        fail(
            "Uso: render-template.py "
            "TEMPLATE OUTPUT"
        )

    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])

    if not source.is_file():
        fail(f"No existe el template: {source}")

    content = source.read_text(
        encoding="utf-8"
    )

    missing = sorted(
        {
            name
            for name in VARIABLE_PATTERN.findall(content)
            if name not in os.environ
        }
    )

    if missing:
        fail(
            "Variables sin definir: "
            + ", ".join(missing)
        )

    def replace(match: re.Match[str]) -> str:
        name = match.group(1)
        return os.environ[name]

    rendered = VARIABLE_PATTERN.sub(
        replace,
        content,
    )

    unresolved = VARIABLE_PATTERN.findall(rendered)

    if unresolved:
        fail(
            "Quedan variables sin resolver: "
            + ", ".join(sorted(set(unresolved)))
        )

    destination.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    destination.write_text(
        rendered,
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
