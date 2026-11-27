#!/usr/bin/env bash
# =============================================================================
# aegora-estado.sh — en qué versión está cada tenant, capa por capa.
#
#   sudo scripts/aegora-estado.sh             # tabla de todos los tenants
#   scripts/aegora-estado.sh --tenant jca     # detalle de uno, componente a componente
#   scripts/aegora-estado.sh --tenant jca --historial 20
#   scripts/aegora-estado.sh --comprobar dev v2026.11.26   # ¿tiene ese release ENTERO?
#                                                         # (sale 0 si sí; lo usa actualizar-tenant.sh)
#
# Solo lee. Lee state/despliegues.jsonl de cada tenant, que escriben los propios scripts
# al terminar su --apply (scripts/lib/registrar-despliegue.sh). No toca contenedores ni
# secretos. En el VPS va con sudo: los directorios de los tenants son de root y sin
# permiso para atravesarlos no se llega al registro (la tabla lo dice, no los esconde).
#
# Cómo leer la tabla (y qué hace que una celda salga en amarillo): docs/VERSIONADO.md.
# Un "—" es "no hay registro": la capa no se ha aplicado desde que existe el registro
# (26/nov/2026). No quiere decir que esté vacía, quiere decir que no lo sabemos.
# =============================================================================
set -Eeuo pipefail

RAIZ="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
TENANTS_ROOT="${AEGORA_TENANTS_ROOT:-/opt/aegora/tenants}"
TENANT=""
HISTORIAL=0
COMPROBAR_RELEASE=""

usage() {
  sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)    [[ $# -ge 2 ]] || { echo "Falta valor para --tenant." >&2; exit 1; }; TENANT="$2"; shift 2 ;;
    --historial) [[ $# -ge 2 ]] || { echo "Falta valor para --historial." >&2; exit 1; }; HISTORIAL="$2"; shift 2 ;;
    --comprobar) [[ $# -ge 3 ]] || { echo "Uso: --comprobar TENANT RELEASE" >&2; exit 1; }
                 TENANT="$2"; COMPROBAR_RELEASE="$3"; shift 3 ;;
    --help|-h)   usage; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; exit 1 ;;
  esac
done

[[ -d "$TENANTS_ROOT" ]] || { echo "No existe ${TENANTS_ROOT}." >&2; exit 1; }

ULTIMO_TAG="$(git -c safe.directory='*' -C "$RAIZ" tag --list 'v*' --sort=-version:refname 2>/dev/null | head -n1 || true)"
CHECKOUT_COMMIT="$(git -c safe.directory='*' -C "$RAIZ" rev-parse --short=12 HEAD 2>/dev/null || true)"
CHECKOUT_TAG="$(git -c safe.directory='*' -C "$RAIZ" describe --tags --exact-match --match 'v*' HEAD 2>/dev/null || true)"

# commit -> tag de cada release, para nombrar con su tag lo que se aplicó en ese commit
# ANTES de cortarlo (lo normal en `dev`: se prueba y luego se etiqueta).
TAGS_JSON="$(
  for t in $(git -c safe.directory='*' -C "$RAIZ" tag --list 'v*' 2>/dev/null); do
    c="$(git -c safe.directory='*' -C "$RAIZ" rev-parse --short=12 "${t}^{commit}" 2>/dev/null || true)"
    [[ -n "$c" ]] && printf '%s %s\n' "$c" "$t"
  done | python3 -c 'import sys,json; print(json.dumps(dict(l.split() for l in sys.stdin if l.strip())))'
)"

COLOR=0
[[ -t 1 ]] && COLOR=1

exec python3 - "$TENANTS_ROOT" "$TENANT" "$HISTORIAL" "$ULTIMO_TAG" "$CHECKOUT_COMMIT" "$CHECKOUT_TAG" "$COLOR" "$COMPROBAR_RELEASE" "$TAGS_JSON" <<'PY'
import json, os, sys, datetime

raiz, solo, historial, ultimo_tag, co_commit, co_tag, color, comprobar, tags_json = sys.argv[1:10]
tag_de_commit = json.loads(tags_json or "{}")
historial = int(historial or 0)
color = color == "1"

# Columnas de la tabla. Cada una agrupa los componentes que registra cada script.
# Si se añade un script que modifica un tenant, su componente va aquí.
GRUPOS = [
    ("esquema",   ["esquema"]),
    ("directus",  ["extensiones", "vistas", "ui", "espanol", "presets", "insights"]),
    ("permisos",  ["rol-gestor", "rol-n8n"]),
    ("workflows", ["workflows"]),
    ("booking",   ["booking"]),
    ("config",    ["config"]),
]
# Se registran pero no son versión de nada (crear plantillas que falten): solo en el detalle.
OTROS = ["plantillas-whatsapp"]

def amarillo(t): return f"\033[33m{t}\033[0m" if color else t
def gris(t):     return f"\033[2m{t}\033[0m" if color else t

def etiqueta(e):
    if e is None:
        return None
    if e.get("sucio"):
        return (e.get("commit") or "?")[:7] + "*"
    # Aplicado en el commit de un release antes de etiquetarlo = ese release.
    return e.get("release") or tag_de_commit.get(e.get("commit") or "") or (e.get("commit") or "?")[:7]

def leer(tenant):
    """Lista de entradas; [] si no hay registro; None si no se puede leer (permisos)."""
    if not os.access(os.path.join(raiz, tenant), os.X_OK):
        return None
    f = os.path.join(raiz, tenant, "state", "despliegues.jsonl")
    entradas = []
    try:
        with open(f, encoding="utf-8") as fh:
            for linea in fh:
                linea = linea.strip()
                if linea:
                    try:
                        entradas.append(json.loads(linea))
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    except PermissionError:
        return None
    return entradas

def estado_componentes(entradas):
    """Por componente: la última pasada completa y los parciales posteriores."""
    res = {}
    for e in entradas:
        c = e.get("componente")
        r = res.setdefault(c, {"completa": None, "parciales": [], "ultima": None})
        r["ultima"] = e
        if e.get("parcial"):
            r["parciales"].append(e)
        else:
            r["completa"] = e
            r["parciales"] = []
    return res

def celda_grupo(comps, estado):
    """(texto, aviso) de una columna."""
    etiquetas = []
    parciales = []
    for c in comps:
        s = estado.get(c)
        if s:
            et = etiqueta(s["completa"])
            if et:
                etiquetas.append(et)
            parciales += s["parciales"]
    if not etiquetas and not parciales:
        return "—", False
    distintas = sorted(set(etiquetas))
    aviso = False
    if len(distintas) == 1:
        texto = distintas[0]
        if len(etiquetas) < len(comps):
            texto += f" ({len(etiquetas)}/{len(comps)})"
            aviso = True
    elif not distintas:
        texto = "solo parcial"
        aviso = True
    else:
        texto = "mixto"
        aviso = True
    if parciales:
        nombres = sorted({p["parcial"] for p in parciales})
        texto += " + parcial(" + ",".join(nombres) + ")"
        aviso = True
    return texto, aviso

def hace(fecha):
    try:
        d = datetime.datetime.fromisoformat(fecha)
    except (TypeError, ValueError):
        return "?"
    dias = (datetime.datetime.now(d.tzinfo) - d).days
    return "hoy" if dias <= 0 else f"{dias} d"

# Cualquier subdirectorio es un tenant. NO se filtra por "tiene config/tenant.env": sin
# permiso para entrar, esa comprobación da False y el tenant desaparecía de la tabla en
# silencio (26/nov/2026: tabla vacía con cuatro tenants y su registro escrito). Mejor
# enseñarlo y decir que falta permiso.
tenants = sorted(
    t for t in os.listdir(raiz)
    if not t.startswith(".") and os.path.isdir(os.path.join(raiz, t))
) if not solo else [solo]

if solo and not os.path.isdir(os.path.join(raiz, solo)):
    print(f"No existe el tenant {solo} en {raiz}.", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------- ¿release entero?
# Todas las piezas de GRUPOS con su última pasada completa en ese release y sin parciales
# detrás. Es la condición "ya ha corrido en dev" de actualizar-tenant.sh: se define aquí,
# junto a GRUPOS, para que la tabla y la comprobación no puedan discrepar.
if comprobar:
    entradas = leer(solo)
    if entradas is None:
        print(f"No se puede leer el registro de {solo} (¿sudo?).")
        sys.exit(2)
    estado = estado_componentes(entradas)
    faltan = []
    for _, comps in GRUPOS:
        for c in comps:
            s = estado.get(c)
            if not s or not s["completa"] or etiqueta(s["completa"]) != comprobar:
                faltan.append(f"{c}={etiqueta(s['completa']) if s and s['completa'] else '—'}")
            elif s["parciales"]:
                faltan.append(f"{c}=parcial después")
    if faltan:
        print(f"{solo} no tiene {comprobar} entero: " + ", ".join(faltan))
        sys.exit(1)
    print(f"{solo} tiene {comprobar} entero.")
    sys.exit(0)

print(f"Último release: {ultimo_tag or '(ninguno)'}   "
      f"checkout: {co_tag or 'sin tag'} @ {co_commit or '?'}")
print()

# ---------------------------------------------------------------- detalle de uno
if solo:
    entradas = leer(solo)
    if entradas is None:
        print(f"No se puede leer el registro de {solo}: prueba con sudo.", file=sys.stderr)
        sys.exit(1)
    if not entradas:
        print(f"{solo}: sin registro todavía. Se empieza a llenar con el primer --apply de cada capa.")
        sys.exit(0)
    estado = estado_componentes(entradas)
    filas = [("componente", "versión", "cuándo", "quién", "detalle")]
    avisos = []
    orden = [c for _, cs in GRUPOS for c in cs] + OTROS
    orden += sorted(c for c in estado if c not in orden)
    for c in orden:
        s = estado.get(c)
        if not s:
            filas.append((c, "—", "", "", ""))
            continue
        comp = s["completa"]
        filas.append((c, etiqueta(comp) or "—",
                      (comp or {}).get("fecha", "")[:16].replace("T", " "),
                      (comp or {}).get("usuario", "") or "",
                      (comp or {}).get("detalle") or ""))
        for p in s["parciales"]:
            filas.append(("", f"+ parcial({p['parcial']}) @ {etiqueta(p)}",
                          p.get("fecha", "")[:16].replace("T", " "),
                          p.get("usuario", "") or "", p.get("detalle") or ""))
            avisos.append(c)
    anchos = [max(len(str(f[i])) for f in filas) for i in range(5)]
    for i, f in enumerate(filas):
        linea = "  ".join(str(v).ljust(anchos[j]) for j, v in enumerate(f)).rstrip()
        print(gris(linea) if i == 0 else (amarillo(linea) if f[1].startswith("+ parcial") else linea))
    if historial:
        print()
        print(f"Últimas {historial} pasadas:")
        for e in entradas[-historial:]:
            print("  " + e.get("fecha", "")[:16].replace("T", " ") + "  "
                  + e.get("componente", "?").ljust(20) + (etiqueta(e) or "?")
                  + (f"  parcial({e['parcial']})" if e.get("parcial") else "")
                  + (f"  {e['detalle']}" if e.get("detalle") else "")
                  + f"  [{e.get('usuario', '')}]")
    sys.exit(0)

# ---------------------------------------------------------------- tabla de todos
cabecera = ["tenant", "release"] + [g for g, _ in GRUPOS] + ["último cambio"]
filas = []
for t in tenants:
    entradas = leer(t)
    if entradas is None:
        filas.append(([t, "(sin permiso: sudo)"] + [""] * len(GRUPOS) + [""], [False] * (len(GRUPOS) + 3)))
        continue
    estado = estado_componentes(entradas)
    celdas, avisos = [], []
    for _, comps in GRUPOS:
        texto, aviso = celda_grupo(comps, estado)
        celdas.append(texto)
        avisos.append(aviso)
    # Release del tenant: solo si todas las columnas registradas dicen lo mismo, sin parciales.
    conocidas = [c for c in celdas if c != "—"]
    if not entradas:
        release, aviso_rel = "—", False
    elif any(avisos) or len(set(conocidas)) != 1:
        release, aviso_rel = "mixto", True
    else:
        v = conocidas[0]
        release, aviso_rel = (v, False) if v.startswith("v") else (f"(rama) {v}", False)
        if len(conocidas) < len(celdas):
            release += " (incompleto)"
            aviso_rel = True
        elif v.startswith("v") and ultimo_tag and v != ultimo_tag:
            release += " (detrás)"
            aviso_rel = True
    ultima = max((e.get("fecha", "") for e in entradas), default="")
    filas.append(([t, release] + celdas + [hace(ultima) if ultima else "—"],
                  [False, aviso_rel] + avisos + [False]))

if not filas:
    print(f"No hay ningún tenant en {raiz}.", file=sys.stderr)
    sys.exit(1)

anchos = [max(len(cabecera[i]), *(len(f[0][i]) for f in filas)) if filas else len(cabecera[i])
          for i in range(len(cabecera))]
print(gris("  ".join(c.ljust(anchos[i]) for i, c in enumerate(cabecera)).rstrip()))
for valores, avisos in filas:
    partes = []
    for i, v in enumerate(valores):
        txt = v.ljust(anchos[i])
        partes.append(amarillo(txt) if avisos[i] else txt)
    print("  ".join(partes).rstrip())

sin_permiso = [v[0] for v, _ in filas if v[1].startswith("(sin permiso")]
if sin_permiso:
    print()
    print(amarillo(f"No se pueden leer {', '.join(sin_permiso)}: sus directorios son de root. "
                   "Vuelve a ejecutarlo con sudo."))

print()
print(gris("— = sin registro todavía · (n/m) = solo n de las m piezas de la columna registradas · "
           "* = checkout con cambios sin commitear · detalle: --tenant X"))
PY
