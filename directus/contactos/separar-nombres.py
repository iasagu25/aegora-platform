#!/usr/bin/env python3
"""
Separa el nombre de pila de una agenda exportada del móvil y deja un TSV para REVISAR
a mano y luego importar con `importar-contactos.sh` (que lo lee tal cual).

    separar-nombres.py ENTRADA SALIDA [--sin-telefono RUTA]

Para qué existe (agenda de jca, 23/nov/2026): al pasar la agenda a una hoja, la etiqueta
del contacto se cortó por palabras -- 1ª palabra a APELLIDOS, 2ª a NOMBRE, el resto a
Empresa/referencia --. Como la gente se guarda los contactos como "Adrian Chiringuito",
el nombre de pila acabó casi siempre en APELLIDOS, y ninguna columna es fiable fila a fila.
Importarla tal cual haría que Lucía saludara "Hola, Chiringuito".

Reglas:
- El NOMBRE es la primera palabra de la etiqueta (en el orden APELLIDOS, NOMBRE, Empresa)
  que sea un nombre de pila de `nombres-de-pila.txt`. Si le sigue otro que forma nombre
  compuesto ("Maria Jose", "Juan Antonio"), van los dos.
- APELLIDOS es el resto de la etiqueta, sin lo que va entre paréntesis ni los prefijos de
  ordenar ("A", "AA"). No son apellidos de verdad: es lo que hace que el gestor distinga a
  quince Adrianes ("Adrian Chiringuito", "Adrian circuito"). Lucía saluda por el nombre.
- Si ninguna palabra es un nombre de pila (un negocio, "Albañil Moratalla"), la etiqueta
  entera va como nombre y la fila se marca para revisar.
- La empresa NO se rellena: en esta agenda esa columna es el resto de la etiqueta, no una
  empresa. La etiqueta completa va a `nombre_completo`, que el importador deja en las notas.
- Sin teléfono válido no sale en SALIDA (no se importaría); va a --sin-telefono si se pide.
- La columna `revisar` dice por qué mirar una fila. Las que la llevan vacía son las que
  el script ha resuelto sin dudas.
"""
import csv
import importlib.util
import os
import re
import sys
import unicodedata

sys.dont_write_bytecode = True  # no dejar __pycache__ junto a los scripts
AQUI = os.path.dirname(os.path.abspath(__file__))
_sp = importlib.util.spec_from_file_location('leer_agenda', os.path.join(AQUI, 'leer-agenda.py'))
la = importlib.util.module_from_spec(_sp)
_sp.loader.exec_module(la)

PRIMERO_DE_COMPUESTO = {'maria', 'jose', 'juan', 'ana', 'miguel', 'luis', 'francisco', 'pedro',
                        'antonio', 'juana', 'rosa', 'mari', 'jesus', 'angel', 'carlos', 'jm'}
SEGUNDO_DE_COMPUESTO = {'maria', 'jose'}  # "Eva Maria", "Ignacio Jose"
INICIAL_MARIA = {'m', 'ma', 'mª'}


def trocear(texto):
    """Palabras de la etiqueta, separando las pegadas: "Lidia-Farmacia", "AlbertoAbogado"."""
    texto = re.sub(r'(?<=[a-záéíóúñ])(?=[A-ZÁÉÍÓÚÑ])', ' ', texto)
    texto = re.sub(r'(?<=\w)-(?=\w)', ' ', texto)
    return texto.split()
# "Padre Andrea" puede ser Andrea o su padre: el script no lo sabe, la persona sí.
PARENTESCO = {'padre', 'madre', 'marido', 'mujer', 'esposa', 'esposo', 'novio', 'novia',
              'hermano', 'hermana', 'hijo', 'hija', 'sobrino', 'sobrina', 'cunado', 'cunada',
              'abuelo', 'abuela', 'tio', 'tia', 'suegro', 'suegra', 'primo', 'prima', 'de',
              'mama', 'papa', 'daddy', 'mummy', 'amigo', 'amiga', 'socio', 'vecino', 'vecina'}
PROPIO = re.compile(r'\b(oficina|despacho|yo)\b', re.I)
CABECERA = ['linea', 'revisar', 'NOMBRE', 'APELLIDOS', 'nombre_completo',
            'telefono 1', 'telefono 2', 'telefono 3', 'EMAIL']


def clave(palabra):
    p = palabra.strip('()[].,;:-¿?¡!"\'')
    return unicodedata.normalize('NFKD', p).encode('ascii', 'ignore').decode().lower()


def cargar_nombres():
    nombres = set()
    with open(os.path.join(AQUI, 'nombres-de-pila.txt'), encoding='utf-8') as f:
        for linea in f:
            if not linea.startswith('#'):
                nombres.update(clave(p) for p in linea.split())
    nombres.discard('')
    return nombres


def bonito(palabra):
    p = palabra.strip('()[].,;:-¿?¡!"\'')
    return p[:1].upper() + p[1:].lower() if p.islower() or p.isupper() else p


def separar(palabras, nombres):
    """-> (nombre, apellidos, motivo_para_revisar o '')"""
    claves = [clave(p) for p in palabras]
    i = next((j for j, c in enumerate(claves) if c in nombres), None)
    if i is None:
        etiqueta = ' '.join(palabras).strip()
        return etiqueta, '', 'sin nombre de pila: va la etiqueta entera como nombre'

    usadas = {i}
    nombre = bonito(palabras[i])
    motivo = ''
    if any(c in PARENTESCO for c in claves):
        familia = next(palabras[j] for j, c in enumerate(claves) if c in PARENTESCO)
        motivo = f'«{familia}» en la etiqueta: ¿es {nombre} o alguien de su entorno?'
    if i > 0 and claves[i - 1] in INICIAL_MARIA:
        nombre = 'M. ' + nombre
        usadas.add(i - 1)
    siguiente = i + 1
    if siguiente < len(palabras) and claves[siguiente] in nombres:
        if claves[i] in PRIMERO_DE_COMPUESTO or claves[siguiente] in SEGUNDO_DE_COMPUESTO:
            nombre += ' ' + bonito(palabras[siguiente])
            usadas.add(siguiente)
        else:
            motivo = (motivo + '; ' if motivo else '') + f'dos nombres seguidos ({palabras[i]} {palabras[siguiente]}): ¿dos personas?'

    # Resto de la etiqueta, sin lo que va entre paréntesis ni prefijos de ordenar.
    resto, dentro = [], False
    for j, p in enumerate(palabras):
        abre, cierra = p.startswith('('), p.endswith(')')
        if abre:
            dentro = True
        if j not in usadas and not dentro and not re.fullmatch(r'a+\d*|[\d+\-.]+', claves[j] or '-'):
            resto.append(p.strip('.,;:-()'))
        if cierra:
            dentro = False
    return nombre, ' '.join(x for x in resto if x), motivo


def main(entrada, salida, sin_tel_ruta):
    nombres = cargar_nombres()
    with open(entrada, encoding='utf-8-sig', newline='') as f:
        filas = list(csv.reader(f, delimiter='\t'))
    cab = [la.limpio(c).lower() for c in filas[0]]
    col = {c: i for i, c in reversed(list(enumerate(cab)))}

    def v(fila, nombre):
        i = col.get(nombre)
        return la.limpio(fila[i]) if i is not None and i < len(fila) else ''

    salen, sin_tel, visto = [], [], {}  # visto: teléfono -> línea donde se queda
    for n, fila in enumerate(filas[1:], start=2):
        partes = [v(fila, 'apellidos'), v(fila, 'nombre'), v(fila, 'empresa/referencia')]
        tels = [v(fila, f'telefono {k}') for k in (1, 2, 3)]
        email = v(fila, 'email')
        if not any(partes + tels + [email, v(fila, 'nombre_completo')]):
            continue
        etiqueta = v(fila, 'nombre_completo') or ' '.join(p for p in partes if p)
        palabras = trocear(' '.join(p for p in partes if p))

        revisar = []
        if palabras:
            nombre, apellidos, motivo = separar(palabras, nombres)
            if motivo:
                revisar.append(motivo)
        else:
            nombre, apellidos = '', ''
            revisar.append('sin nombre: no se importa si no le pones uno')

        validos, propios = [], []
        for t in tels:
            if not t:
                continue
            e164 = la.normalizar(t)
            if not e164:
                revisar.append(f'teléfono que no se pudo leer: {t}')
                continue
            if e164 not in validos:
                validos.append(e164)
            if e164 in visto:
                revisar.append(f'teléfono {e164} repetido con la línea {visto[e164]} (se queda en aquella)')
            elif e164 not in propios:
                propios.append(e164)
        if validos and not propios:
            revisar.append('NO ENTRA: todos sus teléfonos son de otra fila. ¿Es la misma persona?')
        if PROPIO.search(etiqueta):
            revisar.append('¿número del propio negocio? Si lo es, borra la fila')

        fila_salida = [n, '; '.join(revisar), nombre, apellidos, etiqueta] + (tels + [''] * 3)[:3] + [email]
        if not validos:
            sin_tel.append(fila_salida)
            continue
        for e in propios:
            visto[e] = n
        salen.append(fila_salida)

    def escribir(ruta, lineas):
        with open(ruta, 'w', encoding='utf-8', newline='') as f:
            w = csv.writer(f, delimiter='\t', lineterminator='\n')
            w.writerow(CABECERA)
            w.writerows(lineas)

    escribir(salida, salen)
    if sin_tel_ruta:
        escribir(sin_tel_ruta, sin_tel)
    marcadas = sum(1 for l in salen if l[1])
    print(f'{salida}: {len(salen)} contactos, {marcadas} marcados para revisar', file=sys.stderr)
    print(f'sin teléfono válido (no salen): {len(sin_tel)}', file=sys.stderr)


if __name__ == '__main__':
    args = sys.argv[1:]
    sin_tel_ruta = None
    if '--sin-telefono' in args:
        i = args.index('--sin-telefono')
        sin_tel_ruta = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2:
        sys.exit('Uso: separar-nombres.py ENTRADA SALIDA [--sin-telefono RUTA]')
    main(args[0], args[1], sin_tel_ruta)
