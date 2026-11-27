"""Convierte la hoja de Apps Script (.xlsx descargado) en SQL para Supabase.
Uso: python3 -I importar.py hoja.xlsx salida_dir
Genera 03-datos-N.sql (partes de ~600 KB) con insert ... on conflict do update: la hoja manda."""
import sys, os, json, datetime, re
from zoneinfo import ZoneInfo
import openpyxl

EC = ZoneInfo('America/Guayaquil')
TIME = {'creado','t1','t2','t3','t4','t5','t6','liberado','t_entrega','t_recibo','inicio','fin','cargado'}
NUM = {'paso','viaje_no','minutos','km_ini','hor_ini','km_fin','hor_fin','parada_min','cada_km','cada_hor','ult_km','ult_hor',
       'unidades','dias','horas_sin_mov','horas_con_mov','horas_pen','mov_real','mov_exc','fact_horas','mov_int','fact_int','valor'}
BOOL = {'habilitada','auto'}
TABLAS = {   # hoja -> (tabla, columnas, clave)
  'Placas': ('placas', ['id','placa','tipo','proyecto','habilitada'], 'id'),
  'Choferes': ('choferes', ['id','nombre','telefono','proyecto','turno','habilitada','pin','alias'], 'id'),
  'Viajes': ('viajes', ['id','creado','proyecto','turno','placa_id','placa','chofer_id','chofer','operacion','origen','destino','contenedor','medida','paso',
                        't1','t2','t3','t4','t5','t6','estado','auto','viaje_no','serie','liberado','observaciones','puente','dup','asignado_por','jornada_id'], 'id'),
  'Programacion': ('programacion', ['id','creado','fecha','turno','proyecto','placa_id','placa','chofer_id','chofer','operacion','auto','estado','creado_por'], 'id'),
  'Relevos': ('relevos', ['id','creado','placa_id','placa','proyecto','turno_sale','sale_id','sale','t_entrega','entra_id','entra','t_recibo','minutos',
                          'checklist','novedades','estado','placa_nueva'], 'id'),
  'Jornadas': ('jornadas', ['id','creado','chofer_id','chofer','proyecto','turno','placa_id','placa','inicio','fin','estado','tipo_inicio','relevo_id',
                            'fin_relevo_id','checklist','novedades','km_ini','hor_ini','km_fin','hor_fin'], 'id'),
  'Paradas': ('paradas', ['id','creado','jornada_id','chofer_id','chofer','proyecto','turno','placa_id','placa','motivo','detalle','inicio','fin','estado'], 'id'),
  'Cambios_Placa': ('cambios_placa', ['id','creado','chofer_id','chofer','proyecto','turno','viaje_id','jornada_id','placa_ant','placa_nueva','motivo','parada_min'], 'id'),
  'Mantenimiento': ('mantenimiento', ['id','placa','tarea','cada_km','cada_hor','ult_km','ult_hor','vence','nota'], 'id'),
  'Facturacion': ('facturacion', ['semana','unidades','dias','horas_sin_mov','horas_con_mov','horas_pen','mov_real','mov_exc','fact_horas','mov_int','fact_int','nota'], 'semana'),
  'Facturas': ('facturas', ['semana','concepto','numero','fecha','valor','estado','fecha_pago','nota'], 'semana, concepto'),
  'TPG_Reporte': ('tpg_reporte', ['semana','tipo','serv','contenedor','fecha','placa','dia','hora','cargado'], None),
  'Auditoria': ('auditoria', ['id','creado','usuario','accion','detalle'], 'id'),
}
NOT_NULL_TEXT_DEFAULT = True

def q(s): return "'" + str(s).replace("'", "''") + "'"

def ts(v):
    if v is None or v == '': return 'null'
    if isinstance(v, datetime.datetime):
        return q(v.replace(tzinfo=EC).isoformat())
    if isinstance(v, datetime.date):
        return q(datetime.datetime(v.year, v.month, v.day, tzinfo=EC).isoformat())
    if isinstance(v, (int, float)):
        if v > 1e11: return q(datetime.datetime.fromtimestamp(v / 1000, tz=datetime.timezone.utc).isoformat())
        if 20000 < v < 80000:   # número de serie de fecha de Excel
            d = datetime.datetime(1899, 12, 30) + datetime.timedelta(days=v)
            return q(d.replace(tzinfo=EC).isoformat())
        return 'null'
    s = str(v).strip()
    m = re.match(r'^(\d{1,2})/(\d{1,2})/(\d{4})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?$', s)
    if m:
        d, mo, y, h, mi, se = m.groups()
        return q(datetime.datetime(int(y), int(mo), int(d), int(h or 0), int(mi or 0), int(se or 0), tzinfo=EC).isoformat())
    if re.match(r'^\d{10,}$', s): return ts(float(s))
    return 'null'

def num(v):
    if v is None or v == '': return 'null'
    try: return repr(float(str(v).replace(',', '.'))) if not isinstance(v, bool) else 'null'
    except ValueError: return 'null'

def boolv(v): return 'false' if (v is False or re.match(r'^(false|no|0|inactivo)$', str(v).strip(), re.I)) else 'true'

def txt(v, col):
    if v is None: return "''"
    if isinstance(v, datetime.datetime): return q(v.strftime('%Y-%m-%d') if col in ('fecha','vence','semana') and v.hour == 0 and v.minute == 0 else v.strftime('%d/%m/%Y %H:%M:%S'))
    if isinstance(v, datetime.date): return q(v.isoformat())
    if isinstance(v, float) and v.is_integer(): v = int(v)
    return q(v)

def fecha(v):
    if isinstance(v, (datetime.datetime, datetime.date)): return q(v.strftime('%Y-%m-%d'))
    s = str(v or '').strip()
    m = re.match(r'^(\d{1,2})/(\d{1,2})/(\d{4})', s)
    if m: return q(f'{m[3]}-{int(m[2]):02d}-{int(m[1]):02d}')
    return q(s[:10]) if re.match(r'^\d{4}-\d{2}-\d{2}', s) else 'null'

def val(col, v, tabla):
    if col in TIME and not (tabla == 'tpg_reporte' and col != 'cargado'): return ts(v)
    if tabla == 'programacion' and col == 'fecha': return fecha(v)
    if col in NUM or (tabla in ('facturacion','facturas') and col == 'semana'): return num(v) if not (tabla in ('facturacion','facturas') and col == 'semana') else (str(int(float(v))) if v not in (None, '') else 'null')
    if col in BOOL: return boolv(v)
    return txt(v, col)

def main():
    src, out = sys.argv[1], sys.argv[2]
    wb = openpyxl.load_workbook(src, data_only=True, read_only=True)
    stmts, resumen = [], []
    for hoja, (tabla, cols, clave) in TABLAS.items():
        ws = next((wb[n] for n in wb.sheetnames if n.strip().lower() == hoja.lower()), None)
        if ws is None: resumen.append(f'{hoja}: no está'); continue
        rows = list(ws.iter_rows(values_only=True))
        if not rows: resumen.append(f'{hoja}: vacía'); continue
        head = [str(h or '').strip().lower() for h in rows[0]]
        usa = [c for c in cols if c in head]
        n = 0
        for r in rows[1:]:
            d = {}
            for i, h in enumerate(head):   # si una columna se repite, gana la primera
                if h and h not in d: d[h] = r[i] if i < len(r) else None
            if clave == 'id' and str(d.get('id') or '').strip() == '': continue
            if tabla == 'placas' and not str(d.get('placa') or '').strip(): continue
            if tabla == 'choferes' and not str(d.get('nombre') or '').strip(): continue
            if tabla in ('facturacion','facturas') and str(d.get('semana') or '').strip() == '': continue
            if tabla == 'facturas' and not str(d.get('numero') or '').strip(): continue
            if tabla == 'tpg_reporte' and not str(d.get('semana') or '').strip(): continue
            if tabla == 'mantenimiento' and (not str(d.get('placa') or '').strip() or not str(d.get('tarea') or '').strip()): continue
            vals = []
            for c in usa:
                x = val(c, d.get(c), tabla)
                if x == 'null' and c in ('creado','inicio') and tabla != 'tpg_reporte': x = 'now()'
                if tabla == 'tpg_reporte' and c == 'cargado' and x == 'null': x = 'now()'
                vals.append(x)
            # la hoja manda: si la fila ya existe se actualiza (sirve para volver a cargar el día del cambio)
            ks = [k.strip() for k in clave.split(',')] if clave else []
            sets = ', '.join(f'{c}=excluded.{c}' for c in usa if c not in ks)
            conf = (f' on conflict ({clave}) do update set {sets}' if sets else f' on conflict ({clave}) do nothing') if clave else ''
            stmts.append(f'insert into {tabla} ({", ".join(usa)}) values ({", ".join(vals)}){conf};')
            n += 1
        if tabla == 'tpg_reporte' and n:   # sin clave: se borra la semana antes de cargarla, para no duplicar
            sem = sorted({str(r[head.index('semana')]).strip() for r in rows[1:] if r and str(r[head.index('semana')] or '').strip()})
            stmts.insert(len(stmts) - n, 'delete from tpg_reporte where semana in (' + ', '.join(q(x) for x in sem) + ');')
        resumen.append(f'{hoja}: {n} filas')
    os.makedirs(out, exist_ok=True)
    parte, buf, size, files = 1, [], 0, []
    def flush():
        nonlocal parte, buf, size
        if not buf: return
        fn = os.path.join(out, f'03-datos-{parte}.sql')
        with open(fn, 'w', encoding='utf-8') as f:
            f.write(f'-- Datos de la hoja de Apps Script · parte {parte}. Se puede ejecutar varias veces: no duplica y actualiza lo que cambió en la hoja.\nbegin;\n')
            f.write('\n'.join(buf)); f.write('\ncommit;\n')
        files.append(fn); parte += 1; buf, size = [], 0
    for s in stmts:
        buf.append(s); size += len(s)
        if size > 600_000: flush()
    flush()
    print('\n'.join(resumen)); print('\n'.join(files))

main()
