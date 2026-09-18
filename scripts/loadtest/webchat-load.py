#!/usr/bin/env python3

"""
Motor del ensayo de carga. Lo llama webchat-load.sh; no se usa suelto.

Manda N conversaciones simultáneas al webhook de webchat y mide cuánto tardan.
La memoria la muestrea el script de bash en paralelo: aquí solo se genera la
carga y se cronometra.
"""

import json
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor


def una_conversacion(args):
    url, session_key, mensajes, timeout = args
    tiempos, errores = [], []
    for texto in mensajes:
        cuerpo = json.dumps({"message": texto, "session_key": session_key}).encode()
        peticion = urllib.request.Request(
            url, data=cuerpo, headers={"Content-Type": "application/json"}, method="POST")
        t0 = time.monotonic()
        try:
            with urllib.request.urlopen(peticion, timeout=timeout) as r:
                r.read()
                tiempos.append(time.monotonic() - t0)
        except urllib.error.HTTPError as e:
            errores.append(f"HTTP {e.code}")
        except Exception as e:                       # noqa: BLE001
            errores.append(type(e).__name__)
    return tiempos, errores


def percentil(valores, p):
    if not valores:
        return 0.0
    ordenados = sorted(valores)
    k = (len(ordenados) - 1) * p / 100
    bajo, alto = int(k), min(int(k) + 1, len(ordenados) - 1)
    return ordenados[bajo] + (ordenados[alto] - ordenados[bajo]) * (k - bajo)


def main():
    url = sys.argv[1]
    concurrencia = int(sys.argv[2])
    rondas = int(sys.argv[3])
    mensaje = sys.argv[4]
    timeout = int(sys.argv[5])
    etiqueta = sys.argv[6]

    # Una clave de sesión distinta por usuario virtual: si compartieran una, el
    # límite de ritmo de Entry (20 cada 5 min por session_key) cortaría la
    # prueba y estaríamos midiendo el guardarraíl, no el sistema.
    trabajos = [
        (url, f"webchat:{etiqueta}-{i:03d}", [mensaje] * rondas, timeout)
        for i in range(concurrencia)
    ]

    inicio = time.monotonic()
    with ThreadPoolExecutor(max_workers=concurrencia) as pool:
        resultados = list(pool.map(una_conversacion, trabajos))
    total = time.monotonic() - inicio

    tiempos = [t for ts, _ in resultados for t in ts]
    errores = [e for _, es in resultados for e in es]

    print(json.dumps({
        "peticiones_ok": len(tiempos),
        "errores": len(errores),
        "detalle_errores": sorted(set(errores)),
        "segundos_total": round(total, 1),
        "p50": round(percentil(tiempos, 50), 2),
        "p95": round(percentil(tiempos, 95), 2),
        "max": round(max(tiempos), 2) if tiempos else 0,
    }))


if __name__ == "__main__":
    main()
