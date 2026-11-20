#!/usr/bin/env python3
"""
Lee una agenda de contactos (TSV o CSV exportado de una hoja de cálculo) y la deja en
la forma que espera `importar-contactos.sh`: un JSON por la salida estándar con las
filas ya normalizadas y los problemas encontrados.

NO habla con Directus. Lo que decide aquí es solo lo que se puede saber mirando el
fichero; lo que depende de lo que ya hay en el tenant lo decide el importador.

Columnas (cabecera, sin distinguir mayúsculas; el resto se ignora):
    APELLIDOS · NOMBRE · Empresa/referencia · nombre_completo
    telefono 1 · telefono 2 · telefono 3 · EMAIL

Reglas, y por qué:
- Teléfonos a E.164 con la MISMA regla que la extensión `aegora-phone-normalizer` de
  Directus (9 dígitos -> +34, 34 + 9 dígitos -> +34, 00 -> +). Si aquí se normalizara
  distinto, la comprobación de "ya existe" fallaría en silencio y duplicaría contactos.
- Un teléfono repetido en el fichero se queda en la PRIMERA fila. Las siguientes entran
  sin él y con una nota: dos contactos con el mismo número hacen que Lucía no sepa quién
  llama (Resolve Contact devuelve `ambiguous`) -- peor que un contacto sin teléfono.
- Una fila sin ningún nombre (ni nombre, ni apellidos, ni nombre completo, ni empresa)
  NO se importa: Lucía saluda por el nombre y un "Hola, (sin nombre)" es peor que nada.
- Un email que no tiene forma de email va a las notas, no al campo `email`.
- Nada se reescribe: ni mayúsculas, ni orden de nombre y apellidos. Es la agenda del
  cliente; solo se quitan espacios sobrantes.
"""
import csv
import json
import re
import sys

COLUMNAS = {
    'apellidos': 'apellidos',
    'nombre': 'nombre',
    'empresa/referencia': 'empresa',
    'nombre_completo': 'completo',
    'telefono 1': 't1',
    'telefono 2': 't2',
    'telefono 3': 't3',
    'email': 'email',
}
OBLIGATORIAS = {'nombre', 't1'}

EMAIL = re.compile(r'^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$')


def limpio(v):
    return re.sub(r'\s+', ' ', (v or '')).strip()


def normalizar(tel):
    """Copia de normalizePhone() de la extensión de Directus. Devuelve None si no vale."""
    v = re.sub(r'[^\d+]', '', tel or '')
    if not v:
        return None
    if v.startswith('00'):
        v = '+' + v[2:]
    if re.fullmatch(r'\d{9}', v):
        v = '+34' + v
    if re.fullmatch(r'34\d{9}', v):
        v = '+' + v
    return v if re.fullmatch(r'\+[1-9]\d{7,14}', v) else None


def etiqueta(e164):
    if re.match(r'^\+34[67]', e164):
        return 'mobile'
    if re.match(r'^\+34[89]', e164):
        return 'work'
    return 'other'


def main(ruta, origen):
    with open(ruta, encoding='utf-8-sig', newline='') as f:
        muestra = f.read(4096)
        f.seek(0)
        sep = '\t' if muestra.count('\t') >= muestra.count(',') else ','
        filas = list(csv.reader(f, delimiter=sep))

    if not filas:
        sys.exit('El fichero está vacío.')

    cab = [limpio(c).lower() for c in filas[0]]
    idx = {}
    for i, c in enumerate(cab):
        if c in COLUMNAS and COLUMNAS[c] not in idx:
            idx[COLUMNAS[c]] = i
    faltan = {k for k in OBLIGATORIAS if k not in idx}
    if faltan:
        sys.exit(f'Faltan columnas en la cabecera: {sorted(faltan)}. Hay: {cab}')

    def col(fila, clave):
        i = idx.get(clave)
        return limpio(fila[i]) if i is not None and i < len(fila) else ''

    contactos, problemas = [], []
    visto = {}  # teléfono -> (línea, etiqueta de la agenda)

    for n, fila in enumerate(filas[1:], start=2):
        ap, no, emp, comp = (col(fila, k) for k in ('apellidos', 'nombre', 'empresa', 'completo'))
        email = col(fila, 'email')
        crudos = [col(fila, k) for k in ('t1', 't2', 't3')]
        crudos = [t for t in crudos if t]

        if not any([ap, no, emp, comp, email] + crudos):
            continue  # fila vacía: ni se cuenta

        agenda = comp or ' '.join(x for x in (no, ap, emp) if x)

        # Nombre: el de la columna NOMBRE; si no hay, lo que haya, en este orden.
        if no:
            first, last = no, (ap or None)
        elif ap:
            first, last = ap, None
        elif comp:
            first, last = comp, None
        elif emp:
            first, last = emp, None
        else:
            problemas.append({'linea': n, 'tipo': 'sin_nombre',
                              'detalle': ', '.join(crudos + ([email] if email else []))})
            continue

        notas = [f'Importado de {origen}. En la agenda: «{agenda}».']

        if email and not EMAIL.match(email):
            problemas.append({'linea': n, 'tipo': 'email_no_valido', 'detalle': f'{agenda}: {email}'})
            notas.append(f'En la columna de email de la agenda ponía: {email}')
            email = ''

        telefonos = []
        for t in crudos:
            e164 = normalizar(t)
            if not e164:
                problemas.append({'linea': n, 'tipo': 'telefono_no_valido', 'detalle': f'{agenda}: {t}'})
                notas.append(f'Teléfono de la agenda que no se pudo leer: {t}')
                continue
            if any(x['phone_normalized'] == e164 for x in telefonos):
                continue  # el mismo número dos veces en la misma fila
            if e164 in visto:
                linea, otro = visto[e164]
                problemas.append({'linea': n, 'tipo': 'telefono_repetido',
                                  'detalle': f'{agenda} comparte {e164} con «{otro}» (línea {linea}); se queda en aquella'})
                notas.append(f'El teléfono {t} está también en «{otro}» y se ha dejado solo en esa ficha. Revisar.')
                continue
            visto[e164] = (n, agenda)
            telefonos.append({
                'phone_number': e164,
                'phone_normalized': e164,
                'label': etiqueta(e164),
                'is_primary': not telefonos,
                'can_whatsapp': False,
            })

        contactos.append({
            'linea': n,
            'first_name': first,
            'last_name': last,
            'company': emp or None,
            'email': email or None,
            'notes': '\n'.join(notas),
            'phones': telefonos,
        })

    json.dump({'contactos': contactos, 'problemas': problemas}, sys.stdout, ensure_ascii=False)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('Uso: leer-agenda.py FICHERO "descripción del origen"')
    main(sys.argv[1], sys.argv[2])
