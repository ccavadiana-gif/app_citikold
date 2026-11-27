-- =====================================================================
-- Citikold · Coordinación de operaciones · Base de datos (Supabase)
-- Paso 2 de 2. Traslado de Code.gs (APP_VERSION 2026-11-26.v43) a PostgreSQL.
--
-- Cómo usarlo: Supabase > SQL Editor > New query > pegar TODO > Run.
-- Se puede ejecutar varias veces: las funciones se reemplazan y los datos no se tocan.
-- La PRIMERA vez borra las tablas vacías del borrador anterior (paso 1).
--
-- La app llama una sola función:  api(fn, args)
--   fn   = nombre de la función de Code.gs ('api_login', 'api_step', ...)
--   args = lista con los mismos argumentos de google.script.run
--   Devuelve {"ok": resultado} o {"error": "mensaje"}.
-- Las tablas quedan cerradas al navegador: todo pasa por api(), que revisa el PIN.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 0. Quitar el borrador anterior (solo si sigue siendo el borrador vacío)
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'choferes' and column_name = 'pin_hash') then
    drop table if exists ordenes_trabajo, programacion, relevos, paradas, viajes, jornadas,
                         usuarios_despacho, despacho_usuarios, choferes, placas, proyectos, config, errores_app cascade;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Tablas (mismas columnas que las hojas de Code.gs)
-- ---------------------------------------------------------------------
create or replace function nuevo_id() returns text language sql volatile as
$$ select 'v' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 9) $$;

create table if not exists config (
  id    int primary key default 1 check (id = 1),
  datos jsonb not null
);

create table if not exists accesos (            -- reemplaza ADMIN_PIN, DESPACHO_PIN, GERENCIA_PIN, MANT_PIN, VISOR_PIN
  id      text primary key default nuevo_id(),
  nombre  text not null,
  pin     text not null,
  rol     text not null check (rol in ('admin','despacho','gerencia','mantenimiento','visor','puente')),
  activo  boolean not null default true
);

create table if not exists intentos (           -- bloqueo por intentos fallidos
  k      text primary key,
  n      int not null default 0,
  hasta  timestamptz not null
);

create table if not exists placas (
  id         text primary key default nuevo_id(),
  placa      text not null,
  tipo       text not null default 'Tracto',
  proyecto   text not null default '',
  habilitada boolean not null default true
);
create unique index if not exists placas_placa on placas (lower(placa));

create table if not exists choferes (
  id         text primary key default nuevo_id(),
  nombre     text not null,
  telefono   text not null default '',
  proyecto   text not null default '',
  turno      text not null default '',
  habilitada boolean not null default true,
  pin        text not null default lpad((floor(random()*10000))::int::text, 4, '0'),
  alias      text not null default ''
);
create unique index if not exists choferes_nombre on choferes (lower(nombre));

create table if not exists viajes (
  id            text primary key default nuevo_id(),
  creado        timestamptz not null default now(),
  proyecto      text not null default '',
  turno         text not null default '',
  placa_id      text not null default '',
  placa         text not null default '',
  chofer_id     text not null default '',
  chofer        text not null default '',
  operacion     text not null default '',
  origen        text not null default '',
  destino       text not null default '',
  contenedor    text not null default '',
  medida        text not null default '',
  paso          int  not null default 0,
  t1 timestamptz, t2 timestamptz, t3 timestamptz, t4 timestamptz, t5 timestamptz, t6 timestamptz,
  estado        text not null default 'activo',
  auto          boolean not null default false,
  viaje_no      int  not null default 1,
  serie         text not null default '',
  liberado      timestamptz,
  observaciones text not null default '',
  puente        text not null default '',
  dup           text not null default '',
  asignado_por  text not null default '',
  jornada_id    text not null default ''
);
create index if not exists viajes_creado on viajes (creado);
create index if not exists viajes_activos on viajes (estado) where estado = 'activo';
create index if not exists viajes_chofer on viajes (chofer_id, creado);
create index if not exists viajes_t6 on viajes (t6);
create index if not exists viajes_puente on viajes (puente) where puente in ('PEND','ERR');
create index if not exists viajes_placa_t1 on viajes (placa, t1);

create table if not exists programacion (
  id         text primary key default nuevo_id(),
  creado     timestamptz not null default now(),
  fecha      date not null,
  turno      text not null,
  proyecto   text not null default '',
  placa_id   text not null, placa text not null default '',
  chofer_id  text not null, chofer text not null default '',
  operacion  text not null default '',
  auto       boolean not null default false,
  estado     text not null default 'programado',
  creado_por text not null default ''
);
create index if not exists programacion_fecha on programacion (fecha);

create table if not exists relevos (
  id          text primary key default nuevo_id(),
  creado      timestamptz not null default now(),
  placa_id    text not null default '', placa text not null default '',
  proyecto    text not null default '',
  turno_sale  text not null default '',
  sale_id     text not null default '', sale text not null default '',
  t_entrega   timestamptz,
  entra_id    text not null default '', entra text not null default '',
  t_recibo    timestamptz,
  minutos     numeric,
  checklist   text not null default '',
  novedades   text not null default '',
  estado      text not null default 'entregada',
  placa_nueva text not null default ''
);
create index if not exists relevos_creado on relevos (creado);

create table if not exists jornadas (
  id            text primary key default nuevo_id(),
  creado        timestamptz not null default now(),
  chofer_id     text not null, chofer text not null default '',
  proyecto      text not null default '',
  turno         text not null default '',
  placa_id      text not null default '', placa text not null default '',
  inicio        timestamptz not null default now(),
  fin           timestamptz,
  estado        text not null default 'activa',
  tipo_inicio   text not null default '',
  relevo_id     text not null default '',
  fin_relevo_id text not null default '',
  checklist     text not null default '',
  novedades     text not null default '',
  km_ini numeric, hor_ini numeric, km_fin numeric, hor_fin numeric
);
create index if not exists jornadas_chofer on jornadas (chofer_id, inicio);
create index if not exists jornadas_inicio on jornadas (inicio);

create table if not exists paradas (
  id         text primary key default nuevo_id(),
  creado     timestamptz not null default now(),
  jornada_id text not null default '',
  chofer_id  text not null default '', chofer text not null default '',
  proyecto   text not null default '',
  turno      text not null default '',
  placa_id   text not null default '', placa text not null default '',
  motivo     text not null default '',
  detalle    text not null default '',
  inicio     timestamptz not null default now(),
  fin        timestamptz,
  estado     text not null default 'abierta'
);
create index if not exists paradas_inicio on paradas (inicio);
create index if not exists paradas_abiertas on paradas (estado) where estado = 'abierta';
create index if not exists paradas_placa on paradas (placa, inicio);
create index if not exists paradas_jornada on paradas (jornada_id);

create table if not exists cambios_placa (
  id text primary key default nuevo_id(), creado timestamptz not null default now(),
  chofer_id text, chofer text, proyecto text, turno text, viaje_id text, jornada_id text,
  placa_ant text, placa_nueva text, motivo text, parada_min numeric
);

create table if not exists mantenimiento (
  id text primary key default nuevo_id(),
  placa text not null, tarea text not null,
  cada_km numeric, cada_hor numeric, ult_km numeric, ult_hor numeric,
  vence text not null default '', nota text not null default ''
);

create table if not exists facturacion (
  semana int primary key, unidades numeric, dias numeric, horas_sin_mov numeric, horas_con_mov numeric,
  horas_pen numeric, mov_real numeric, mov_exc numeric, fact_horas numeric, mov_int numeric, fact_int numeric,
  nota text not null default ''
);

create table if not exists facturas (
  semana int not null, concepto text not null, numero text not null, fecha text not null default '',
  valor numeric, estado text not null default 'Emitida', fecha_pago text not null default '', nota text not null default '',
  primary key (semana, concepto)
);

create table if not exists tpg_reporte (
  id bigint generated always as identity primary key,
  semana text not null, tipo text not null, serv text not null default '', contenedor text not null default '',
  fecha text not null default '', placa text not null default '', dia text not null default '', hora text not null default '',
  cargado timestamptz not null default now()
);
create index if not exists tpg_reporte_semana on tpg_reporte (semana, tipo);

create table if not exists auditoria (
  id text primary key default nuevo_id(), creado timestamptz not null default now(),
  usuario text, accion text, detalle text
);

create table if not exists log_errores (
  id bigint generated always as identity primary key, fecha timestamptz not null default now(),
  quien text, funcion text, mensaje text
);

create table if not exists puente_pendientes (
  id bigint generated always as identity primary key, fecha timestamptz not null default now(),
  id_viaje text, error text
);

-- Todas cerradas: sin políticas, el navegador no puede leerlas ni escribirlas directo.
do $$ declare t text; begin
  foreach t in array array['config','accesos','intentos','placas','choferes','viajes','programacion','relevos','jornadas',
    'paradas','cambios_placa','mantenimiento','facturacion','facturas','tpg_reporte','auditoria','log_errores','puente_pendientes'] loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

-- Configuración (lo que en Code.gs eran constantes). Se edita aquí, sin tocar código.
insert into config (id, datos) values (1, $j${
  "proyectos": ["TPG"],
  "proyectosTodos": ["FULL","VACIO","TPG"],
  "clientes": ["TPG","NAPORTEC","CONTECOM","DP WORLD"],
  "proyectosAuto": ["TPG"],
  "proyectosSiguiente": ["FULL","VACIO"],
  "puenteActivo": true,
  "puenteProyectos": ["TPG"],
  "turnos": ["Diurno","Nocturno"],
  "medidas": ["20'","40'","40' HC","45'"],
  "tipos": ["Tracto","Camión","Furgón","Camioneta"],
  "lugares": {"TPG": ["MUELLE","T1","T2","T3","T4","R8"]},
  "proyectosRutaChofer": ["FULL","VACIO","TPG"],
  "observaciones": ["Sin novedad","Demora de grúa","Máquina dañada","Espera en fila o ingreso","Cambio de guardia","Demora en descarga","Demora en el muelle","No había buque","Demora en carga","Cambio de ruta","Sin sistemas"],
  "motivos": ["Unidad dañada","Esperando rescate o mecánico","Sin unidad de relevo","Mantenimiento programado","Sin combustible","Otro"],
  "appVersion": "2026-11-26.v43",
  "relevoMin": 15,
  "umbrales": {"parAma": 60, "parRoj": 120, "parVen": 180},
  "chkAlerta": ["Nivel de combustible","Llantas y presión"],
  "exigirTurno": true,
  "checklist": ["Nivel de combustible","Llantas y presión","Luces y direccionales","Frenos","Purga del sistema de frenos","Espejos y vidrios","Aceite y refrigerante","Quinta rueda y pines","Limpieza de cabina"],
  "dupHoras": 12,
  "maxIntentos": 5,
  "minBloqueo": 10,
  "graciaInicioMin": 30,
  "jorMaxH": 20,
  "dobleDestinos": ["T2","T3","T4","R8"],
  "estadActiva": true,
  "estadDias": 400,
  "facParam": {"tarifa": 23, "horasDia": 23, "esc1": {"h": 24, "d": 7}, "esc2": {"h": 23, "d": 6}, "movHora": 2},
  "tpg": {"tarifaHora": 23, "minMovHora": 2, "movInt": 8.38, "traslado": 12.63}
}$j$::jsonb) on conflict (id) do nothing;

-- Historial de facturación semanas 36 a 45 (FAC_SEMILLA de Code.gs)
insert into facturacion (semana, unidades, dias, horas_sin_mov, horas_con_mov, horas_pen, mov_real, mov_exc, fact_horas, mov_int, fact_int)
select * from (values
 (36,5,6,246,444,148,762,16,8504.77,115,1052.84),(37,5,6,103,587,152,1034,17,11753.0,0,0.0),(38,5,6,247,443,140,759,13,8579.0,63,527.94),
 (39,5,6,200,490,156,835,14,9476.0,48,402.24),(40,5,6,138,552,137,983,21,11120.5,20,142.46),(41,5,6,316,374,111,678,41,7325.5,229,2008.27),
 (42,5,6,328,362,88,665,29,7314.0,79,827.89),(43,5,6,231,459,156,762,8,8763.0,8,71.29),(44,5,6,151,539,146,961,14,10718.0,0,0.0),
 (45,5,6,226,464,94,874,40,9591.0,0,0.0)) v
where not exists (select 1 from facturacion);

-- ---------------------------------------------------------------------
-- 2. Ayudantes
-- ---------------------------------------------------------------------
create or replace function cfg(k text) returns jsonb language sql stable as
$$ select datos -> k from config where id = 1 $$;
create or replace function cfg_list(k text) returns text[] language sql stable as
$$ select coalesce(array(select jsonb_array_elements_text(datos -> k) from config where id = 1), '{}') $$;
create or replace function cfg_num(k text) returns numeric language sql stable as
$$ select (datos ->> k)::numeric from config where id = 1 $$;

create or replace function ms(t timestamptz) returns bigint language sql immutable as
$$ select coalesce(floor(extract(epoch from t) * 1000)::bigint, 0) $$;
create or replace function de_ms(v jsonb) returns timestamptz language sql immutable as
$$ select case when v is null or jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric <= 0 then null
               else to_timestamp((v #>> '{}')::numeric / 1000) end $$;

create or replace function e(msg text) returns void language plpgsql as
$$ begin raise exception using message = msg, errcode = 'P0001'; end $$;

create or replace function hora_ec(t timestamptz) returns int language sql stable as
$$ select extract(hour from t at time zone 'America/Guayaquil')::int $$;
create or replace function dia_ec(t timestamptz) returns date language sql stable as
$$ select (t at time zone 'America/Guayaquil')::date $$;
create or replace function turno_de(t timestamptz default now()) returns text language sql stable as
$$ select case when hora_ec(t) >= 7 and hora_ec(t) < 19 then 'Diurno' else 'Nocturno' end $$;
-- Clave de jornada: día operativo + turno (el Nocturno antes de las 12:00 cuenta para el día anterior)
create or replace function op_key(t timestamptz, turno text) returns text language sql stable as
$$ select dia_ec(t - case when turno = 'Nocturno' and hora_ec(t) < 12 then interval '1 day' else interval '0' end)::text || '|' || coalesce(turno, '') $$;
-- Clave de turno por hora (madrugada pertenece al nocturno del día anterior)
create or replace function turno_key(t timestamptz) returns text language sql stable as
$$ select dia_ec(t - case when hora_ec(t) < 7 then interval '1 day' else interval '0' end)::text
          || case when hora_ec(t) >= 7 and hora_ec(t) < 19 then 'D' else 'N' end $$;
create or replace function hhmm(t timestamptz) returns text language sql stable as
$$ select case when t is null then '' else to_char(t at time zone 'America/Guayaquil', 'HH24:MI') end $$;
create or replace function iso(t timestamptz) returns text language sql stable as
$$ select case when t is null then '' else dia_ec(t)::text end $$;

create or replace function norm(s text) returns text language sql immutable as
$$ select upper(regexp_replace(upper(coalesce(s, '')), '[^A-Z0-9]', '', 'g')) $$;
create or replace function lugar(s text) returns text language sql immutable as
$$ select left(trim(coalesce(s, '')), 60) $$;
create or replace function solo_digitos(s text) returns text language sql immutable as
$$ select regexp_replace(regexp_replace(coalesce(s, ''), '\D', '', 'g'), '^0+', '') $$;

-- Dígito de control ISO 6346
create or replace function cont_ok(c text) returns boolean language plpgsql immutable as $$
declare s bigint := 0; v int; i int; n int := 9; tabla int[] := '{}';
begin
  if c is null or c !~ '^[A-Z]{4}[0-9]{7}$' then return false; end if;
  for i in 1..26 loop n := n + 1; if n % 11 = 0 then n := n + 1; end if; tabla := tabla || n; end loop;
  for i in 0..9 loop
    if i < 4 then v := tabla[ascii(substr(c, i + 1, 1)) - 64]; else v := substr(c, i + 1, 1)::int; end if;
    s := s + v * (2 ^ i)::bigint;
  end loop;
  return (s % 11) % 10 = substr(c, 11, 1)::int;
end $$;

-- Distancia entre dos textos (cambios, faltas, sobras y letras cambiadas de lugar)
create or replace function cc_dist(a text, b text) returns int language plpgsql immutable as $$
declare la int := length(a); lb int := length(b); d int[]; i int; j int; c int; w int := lb + 1; x int;
begin
  if abs(la - lb) > 2 then return 9; end if;
  d := array_fill(0, array[(la + 1) * (lb + 1)]);
  for i in 0..la loop d[i * w + 1] := i; end loop;
  for j in 0..lb loop d[j + 1] := j; end loop;
  for i in 1..la loop for j in 1..lb loop
    c := case when substr(a, i, 1) = substr(b, j, 1) then 0 else 1 end;
    x := least(d[(i - 1) * w + j + 1] + 1, d[i * w + j] + 1, d[(i - 1) * w + j] + c);
    if i > 1 and j > 1 and substr(a, i, 1) = substr(b, j - 1, 1) and substr(a, i - 1, 1) = substr(b, j, 1) then
      x := least(x, d[(i - 2) * w + j - 1] + 1);
    end if;
    d[i * w + j + 1] := x;
  end loop; end loop;
  return d[la * w + lb + 1];
end $$;

-- Bloqueo por intentos (bloqueo_, fallo_, acierto_)
create or replace function bloqueo(k text) returns void language plpgsql as $$
begin
  if exists (select 1 from intentos where intentos.k = bloqueo.k and hasta > now() and n >= cfg_num('maxIntentos')) then
    perform e('Demasiados intentos fallidos. Espera ' || cfg_num('minBloqueo') || ' minutos e inténtalo de nuevo.');
  end if;
end $$;
create or replace function fallo(k text) returns void language sql as $$
  insert into intentos (k, n, hasta) values (k, 1, now() + make_interval(mins => cfg_num('minBloqueo')::int))
  on conflict (k) do update set n = case when intentos.hasta > now() then intentos.n + 1 else 1 end,
                                hasta = now() + make_interval(mins => cfg_num('minBloqueo')::int) $$;

-- Un error de PIN se registra aunque la operación se deshaga: se marca en DETAIL y api() lo anota.
create or replace function e_pin(msg text, k text) returns void language plpgsql as
$$ begin raise exception using message = msg, errcode = 'P0001', detail = 'fallo:' || k; end $$;

-- Valida el PIN del chofer (chk_)
create or replace function chk(p_id text, p_pin text) returns choferes language plpgsql as $$
declare c choferes;
begin
  select * into c from choferes where id = p_id;
  if c.id is null or not c.habilitada then perform e('Chofer no encontrado.'); end if;
  perform bloqueo('c' || c.id);
  if trim(c.pin) = '' then perform e('Tu PIN aún no está generado. Pídelo a despacho.'); end if;
  if solo_digitos(c.pin) = '' or solo_digitos(c.pin) <> solo_digitos(p_pin) then
    perform e_pin('Cédula o PIN incorrecto', 'c' || c.id);
  end if;
  delete from intentos where k = 'c' || c.id;
  return c;
end $$;

-- Acceso de despacho (acceso_): PIN «pin~idDelEquipo»
create or replace function acceso(p_pin text) returns accesos language plpgsql as $$
declare q text := coalesce(p_pin, ''); i int; cod text; cid text; a accesos;
begin
  i := length(q) - strpos(reverse(q), '~') + 1;
  if strpos(q, '~') > 0 then cod := left(q, i - 1); cid := substr(q, i + 1); else cod := q; cid := ''; end if;
  cid := coalesce(nullif(left(regexp_replace(cid, '[^A-Za-z0-9]', '', 'g'), 24), ''), 'x');
  if not exists (select 1 from accesos where activo) then
    perform e('Falta configurar el PIN de despacho (tabla accesos).');
  end if;
  perform bloqueo('adm_' || cid);
  if exists (select 1 from intentos where k = 'admG' and hasta > now() and n >= 30) then
    perform e('Demasiados intentos fallidos. Espera ' || cfg_num('minBloqueo') || ' minutos e inténtalo de nuevo.');
  end if;
  select * into a from accesos where activo and pin = cod
   order by case rol when 'admin' then 5 when 'despacho' then 4 when 'mantenimiento' then 3 when 'gerencia' then 2 else 1 end desc
   limit 1;
  if a.id is null then perform e_pin('PIN incorrecto', 'adm_' || cid); end if;
  delete from intentos where k = 'adm_' || cid;
  return a;
end $$;

-- Permisos por rol (auth_). El administrador puede todo.
create or replace function auth(p_pin text, permiso text default null) returns accesos language plpgsql as $$
declare a accesos := acceso(p_pin);
begin
  if a.rol <> 'admin' then
    if a.rol = 'visor' then perform e('Este acceso es solo de consulta: no puede hacer cambios.'); end if;
    if permiso is null or not (permiso = any (case a.rol
         when 'despacho' then array['estado','assign','release','toggleAuto','cambiarPlaca','progSave','progDelete','progAssign','progCopy',
                                    'relevoAnularAdmin','jornadaCerrarAdmin','jornadaReabrirAdmin','paradaCerrarAdmin']
         when 'gerencia' then array['estadisticas','facturacion']
         when 'mantenimiento' then array['mantenimiento']
         when 'puente' then array['puente']
         else array[]::text[] end)) then
      perform e('Tu usuario no tiene permiso para esta acción.');
    end if;
  end if;
  perform set_config('app.actor', a.nombre, true);
  return a;
end $$;

create or replace function actor() returns text language sql stable as
$$ select coalesce(nullif(current_setting('app.actor', true), ''), 'Despacho') $$;
create or replace function audit(accion text, detalle text) returns void language sql as
$$ insert into auditoria (usuario, accion, detalle) values (actor(), accion, left(coalesce(detalle, ''), 300)) $$;

create or replace function nom_placa(p text) returns text language sql stable as
$$ select coalesce((select trim(placa) from placas where id = p), p) $$;
create or replace function nom_chofer(p text) returns text language sql stable as
$$ select coalesce((select trim(nombre) from choferes where id = p), p) $$;
create or replace function viaje_txt(p text) returns text language sql stable as
$$ select coalesce((select placa || ' · ' || chofer || ' (' || operacion || ')' from viajes where id = p), p) $$;

-- Observación elegida por el chofer (máximo una, solo de la lista)
create or replace function obs(a jsonb) returns text language plpgsql stable as $$
declare ok text[];
begin
  if a is null or jsonb_typeof(a) <> 'array' then return ''; end if;
  ok := array(select o from unnest(cfg_list('observaciones')) o where a ? o);
  if array_length(ok, 1) > 1 then perform e('Solo puedes marcar una observación.'); end if;
  return coalesce(array_to_string(ok, '; '), '');
end $$;

-- ---------------------------------------------------------------------
-- 3. Formato JSON igual al de Code.gs
-- ---------------------------------------------------------------------
-- viaje_no = posición del viaje dentro del turno (chofer + día operativo + turno). Los liberados/anulados no cuentan.
create or replace view v_viajes as
select v.*, case when v.estado in ('liberado','anulado') then v.viaje_no
                 else row_number() over (partition by v.chofer_id, op_key(v.creado, v.turno), (v.estado in ('liberado','anulado')) order by v.creado)::int end as viaje_n
  from viajes v;

create or replace function j_trip(v v_viajes) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', v.id, 'creado', ms(v.creado), 'proyecto', v.proyecto, 'turno', v.turno, 'placa_id', v.placa_id, 'placa', v.placa,
    'chofer_id', v.chofer_id, 'chofer', v.chofer, 'operacion', v.operacion, 'origen', v.origen, 'destino', v.destino,
    'contenedor', v.contenedor, 'medida', v.medida, 'paso', v.paso,
    't1', ms(v.t1), 't2', ms(v.t2), 't3', ms(v.t3), 't4', ms(v.t4), 't5', ms(v.t5), 't6', ms(v.t6),
    'estado', v.estado, 'auto', v.auto, 'viaje_no', v.viaje_n, 'serie', v.serie, 'liberado', ms(v.liberado),
    'observaciones', v.observaciones, 'puente', v.puente, 'dup', v.dup, 'asignado_por', v.asignado_por, 'jornada_id', v.jornada_id) $$;

create or replace function j_jor(j jornadas) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', j.id, 'creado', ms(j.creado), 'chofer_id', j.chofer_id, 'chofer', j.chofer, 'proyecto', j.proyecto, 'turno', j.turno,
    'placa_id', j.placa_id, 'placa', j.placa, 'inicio', ms(j.inicio), 'fin', ms(j.fin), 'estado', j.estado,
    'tipo_inicio', j.tipo_inicio, 'relevo_id', j.relevo_id, 'fin_relevo_id', j.fin_relevo_id,
    'checklist', j.checklist, 'novedades', j.novedades,
    'km_ini', j.km_ini, 'hor_ini', j.hor_ini, 'km_fin', j.km_fin, 'hor_fin', j.hor_fin) $$;

create or replace function j_par(p paradas) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', p.id, 'creado', ms(p.creado), 'jornada_id', p.jornada_id, 'chofer_id', p.chofer_id, 'chofer', p.chofer,
    'proyecto', p.proyecto, 'turno', p.turno, 'placa_id', p.placa_id, 'placa', p.placa, 'motivo', p.motivo,
    'detalle', p.detalle, 'inicio', ms(p.inicio), 'fin', ms(p.fin), 'estado', p.estado) $$;

create or replace function j_rel(r relevos) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', r.id, 'creado', ms(r.creado), 'placa_id', r.placa_id, 'placa', r.placa, 'proyecto', r.proyecto,
    'turno_sale', r.turno_sale, 'sale_id', r.sale_id, 'sale', r.sale, 't_entrega', ms(r.t_entrega),
    'entra_id', r.entra_id, 'entra', r.entra, 't_recibo', ms(r.t_recibo), 'minutos', coalesce(r.minutos, 0),
    'checklist', r.checklist, 'novedades', r.novedades, 'estado', r.estado, 'placa_nueva', r.placa_nueva) $$;

create or replace function j_prog(x programacion) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id', x.id, 'creado', ms(x.creado), 'fecha', x.fecha::text, 'turno', x.turno, 'proyecto', x.proyecto,
    'placa_id', x.placa_id, 'placa', x.placa, 'chofer_id', x.chofer_id, 'chofer', x.chofer,
    'operacion', x.operacion, 'auto', x.auto, 'estado', x.estado, 'creado_por', x.creado_por) $$;

-- Ciclo = ms entre el paso 1 de un viaje y el paso 1 del siguiente de la MISMA unidad, mismo turno,
-- sin parada ni relevo de esa unidad entre los dos (anotarCiclos_).
create or replace function ciclo(p_id text, p_placa text, p_t1 timestamptz, p_estado text) returns bigint language sql stable as $$
  with sig as (
    select b.t1 from viajes b
     where b.placa = p_placa and b.t1 is not null and b.estado in ('finalizado','activo') and b.id <> p_id
       and (b.t1 > p_t1 or (b.t1 = p_t1 and b.id > p_id))
     order by b.t1, b.id limit 1)
  select case when p_estado <> 'finalizado' or p_t1 is null then null
              when s.t1 is null or s.t1 <= p_t1 or turno_key(p_t1) <> turno_key(s.t1) then null
              when exists (select 1 from paradas p where p.placa = p_placa and p.inicio < s.t1 and coalesce(p.fin, now()) > p_t1) then null
              when exists (select 1 from relevos r where r.estado <> 'anulada' and (r.placa = p_placa or r.placa_nueva = p_placa)
                            and r.t_entrega > p_t1 and r.t_entrega < s.t1) then null
              else ms(s.t1) - ms(p_t1) end
    from (select (select t1 from sig) as t1) s $$;

-- Jornada activa del chofer (máx. JOR_MAX_H horas)
create or replace function jornada_activa(p_chofer text) returns jornadas language sql stable as $$
  select * from jornadas where chofer_id = p_chofer and estado = 'activa'
     and inicio > now() - make_interval(hours => cfg_num('jorMaxH')::int)
   order by inicio desc limit 1 $$;

-- Abre el turno (jornadaAbrir_)
create or replace function jornada_abrir(p_chofer text, p_nombre text, p_placa_id text, p_placa text, p_proyecto text,
                                         tipo text, p_relevo text default '', p_checklist text default '', p_nov text default '') returns void
language sql as $$
  update jornadas set estado = 'sin_fin' where chofer_id = p_chofer and estado = 'activa';
  insert into jornadas (chofer_id, chofer, proyecto, turno, placa_id, placa, inicio, estado, tipo_inicio, relevo_id, checklist, novedades)
  values (p_chofer, trim(p_nombre), coalesce(p_proyecto, ''),
          turno_de(case when tipo = 'relevo' then now() else now() + make_interval(mins => cfg_num('graciaInicioMin')::int) end),
          coalesce(p_placa_id, ''), coalesce(p_placa, ''), now(), 'activa', tipo, coalesce(p_relevo, ''), coalesce(p_checklist, ''), coalesce(p_nov, ''));
$$;

create or replace function jornada_reabrir(p_relevo text) returns void language plpgsql as $$
declare j jornadas;
begin
  select * into j from jornadas where fin_relevo_id = p_relevo and estado = 'cerrada' order by inicio desc limit 1;
  if j.id is null then return; end if;
  if (jornada_activa(j.chofer_id)).id is not null then return; end if;
  update jornadas set estado = 'activa', fin = null, fin_relevo_id = '' where id = j.id;
end $$;

-- Valida el checklist { 'Combustible': 'OK' | 'NOV', ... } y arma el texto "item:OK|item:NOV"
create or replace function checklist_txt(items jsonb, nov text) returns text language plpgsql stable as $$
declare faltan text[]; connov text[]; ck text[] := cfg_list('checklist');
begin
  items := coalesce(items, '{}');
  faltan := array(select i from unnest(ck) i where coalesce(items ->> i, '') not in ('OK','NOV'));
  if array_length(faltan, 1) > 0 then perform e('Falta revisar: ' || array_to_string(faltan, ', ') || '.'); end if;
  connov := array(select i from unnest(ck) i where items ->> i = 'NOV');
  if array_length(connov, 1) > 0 and coalesce(trim(nov), '') = '' then
    perform e('Describe las novedades marcadas (' || array_to_string(connov, ', ') || ').');
  end if;
  return array_to_string(array(select i || ':' || (items ->> i) from unnest(ck) i), '|');
end $$;

-- Estado del chofer (driverState_)
create or replace function driver_state(p_chofer text) returns jsonb language plpgsql stable as $$
declare act v_viajes; last v_viajes; j jornadas; p paradas; ji jsonb;
begin
  select * into act from v_viajes where chofer_id = p_chofer and estado = 'activo' order by creado desc limit 1;
  select * into last from v_viajes where chofer_id = p_chofer and estado = 'finalizado' order by creado desc limit 1;
  j := jornada_activa(p_chofer);
  if j.id is not null then
    select * into p from paradas where jornada_id = j.id and estado = 'abierta' limit 1;
  end if;
  ji := jsonb_build_object('j', case when j.id is null then null else j_jor(j) end,
                           'p', case when p.id is null then null else j_par(p) end);
  if j.id is not null then
    ji := ji || jsonb_build_object('r', jsonb_build_object(
      'viajes', (select count(*) from viajes where chofer_id = p_chofer and estado = 'finalizado' and jornada_id = j.id),
      'nPar',   (select count(*) from paradas where jornada_id = j.id and estado = 'cerrada' and fin is not null),
      'msPar',  (select coalesce(sum(greatest(0, ms(fin) - ms(inicio))), 0) from paradas where jornada_id = j.id and estado = 'cerrada' and fin is not null)));
  end if;
  return jsonb_build_object(
    'trip', case when act.id is null then null else j_trip(act) end,
    'last', case when act.id is not null or last.id is null then null else j_trip(last) end,
    'now', ms(now()),
    'relevo', jsonb_build_object('pend', '[]'::jsonb, 'mine', null, 'ult', null, 'error', false, 'lect', '{}'::jsonb),
    'prog', (select coalesce(jsonb_agg(jsonb_build_object('fecha', x.fecha::text, 'turno', x.turno, 'placa', x.placa, 'proyecto', x.proyecto) order by x.fecha, x.creado), '[]')
               from programacion x where x.estado = 'programado' and x.chofer_id = p_chofer and x.fecha >= dia_ec(now() - interval '1 day')),
    'jornada', ji,
    'error', false,
    'ver', cfg('appVersion') #>> '{}');
end $$;

-- Aviso de contenedor repetido (dupViaje_)
create or replace function dup_viaje(p_chofer text, p_trip text, c text, o text, de text) returns text language plpgsql stable as $$
declare x viajes; m int; hace text;
begin
  if coalesce(c, '') = '' or coalesce(o, '') = '' then return ''; end if;
  select * into x from viajes v
   where v.chofer_id = p_chofer and v.id <> p_trip and v.estado not in ('liberado','anulado') and norm(v.contenedor) = c
     and coalesce(v.t6, v.t1, v.creado) > now() - make_interval(hours => cfg_num('dupHoras')::int)
     and v.origen = o and (de = '' or v.destino = '' or v.destino = de)
   order by coalesce(v.t6, v.t1, v.creado) desc limit 1;
  if x.id is null then return ''; end if;
  m := greatest(1, round(extract(epoch from now() - coalesce(x.t6, x.t1, x.creado)) / 60)::int);
  hace := case when m < 60 then m || ' min' else (m / 60) || ' h ' || (m % 60) || ' min' end;
  return 'DUP|Ya registraste ' || c || ' hace ' || hace || ' en este mismo recorrido (' || o ||
         case when x.destino <> '' then ' → ' || x.destino else '' end || '). ¿Es otro movimiento?';
end $$;

create or replace function check_ruta(p_proyecto text, o text, d text) returns void language plpgsql stable as $$
declare lista text[];
begin
  if cfg('lugares') -> p_proyecto is null then return; end if;
  lista := array(select jsonb_array_elements_text(cfg('lugares') -> p_proyecto));
  if coalesce(o, '') <> '' and not (o = any (lista)) then perform e('Elige el origen de la lista.'); end if;
  if coalesce(d, '') <> '' and not (d = any (lista)) then perform e('Elige el destino de la lista.'); end if;
end $$;

-- Crea el siguiente viaje con los mismos datos (repeat_)
create or replace function repetir(v viajes, p_auto boolean default true) returns boolean language plpgsql as $$
declare vn int;
begin
  if not exists (select 1 from placas where id = v.placa_id and habilitada)
     or not exists (select 1 from choferes where id = v.chofer_id and habilitada) then return false; end if;
  if exists (select 1 from viajes x where x.estado = 'activo'
              and ((x.placa_id = v.placa_id and (x.turno = '' or v.turno = '' or x.turno = v.turno)) or x.chofer_id = v.chofer_id)) then
    return false;
  end if;
  vn := case when op_key(v.creado, v.turno) = op_key(now(), v.turno) then v.viaje_no + 1 else 1 end;
  insert into viajes (proyecto, turno, placa_id, placa, chofer_id, chofer, operacion, origen, destino, auto, viaje_no, serie)
  values (v.proyecto, v.turno, v.placa_id, v.placa, v.chofer_id, v.chofer, v.operacion, v.origen, v.destino,
          p_auto, vn, coalesce(nullif(v.serie, ''), v.id));
  return true;
end $$;

-- Valida y crea un viaje asignado (assignCore_)
create or replace function assign_core(d jsonb) returns viajes language plpgsql as $$
declare proyecto text := coalesce(d ->> 'proyecto', ''); operacion text := trim(coalesce(d ->> 'operacion', ''));
        v_turno text := coalesce(d ->> 'turno', ''); p placas; c choferes; nt viajes; r relevos;
begin
  if not (proyecto = any (cfg_list('proyectos'))) then perform e('Elige el proyecto.'); end if;
  if not (operacion = any (cfg_list('clientes'))) then perform e('Elige el cliente: ' || array_to_string(cfg_list('clientes'), ', ') || '.'); end if;
  select * into p from placas where id = d ->> 'placa_id';
  select * into c from choferes where id = d ->> 'chofer_id';
  if p.id is null or c.id is null then perform e('Elige una placa y un chofer.'); end if;
  if not p.habilitada or not c.habilitada then perform e('La unidad o el chofer están inhabilitados.'); end if;
  if not (v_turno = any (cfg_list('turnos'))) then perform e('Elige el turno.'); end if;
  if exists (select 1 from viajes x where x.estado = 'activo' and x.placa_id = p.id and (x.turno = '' or x.turno = v_turno)) then
    perform e('Esa placa ya está asignada a otro viaje en el turno ' || lower(v_turno) || '.');
  end if;
  if exists (select 1 from viajes x where x.estado = 'activo' and x.chofer_id = c.id) then perform e('Ese chofer ya tiene un viaje en curso.'); end if;
  insert into viajes (proyecto, turno, placa_id, placa, chofer_id, chofer, operacion, auto, asignado_por)
  values (proyecto, v_turno, p.id, trim(p.placa), c.id, trim(c.nombre), operacion,
          proyecto = any (cfg_list('proyectosAuto')) and coalesce((d ->> 'auto')::boolean, false), actor())
  returning * into nt;
  update viajes set serie = id where id = nt.id and serie = '';
  if not coalesce((d ->> 'auto')::boolean, false) then
    for r in select * from relevos where estado = 'entregada' and sale_id = c.id and t_entrega > now() - interval '3 hours' loop
      update relevos set estado = 'anulada' where id = r.id;
      perform jornada_reabrir(r.id);
    end loop;
  end if;
  return nt;
end $$;

-- ---------------------------------------------------------------------
-- 4. Funciones del chofer
-- ---------------------------------------------------------------------
create or replace function f_base() returns jsonb language sql stable as $$
  select jsonb_build_object(
    'proyectos', cfg('proyectos'), 'proyectosHist', cfg('proyectosTodos'), 'clientes', cfg('clientes'),
    'autoProyectos', cfg('proyectosAuto'), 'siguienteProyectos', cfg('proyectosSiguiente'), 'turnos', cfg('turnos'),
    'medidas', cfg('medidas'), 'tipos', cfg('tipos'), 'observaciones', cfg('observaciones'), 'checklist', cfg('checklist'),
    'motivos', cfg('motivos'), 'version', cfg('appVersion'), 'relevoMin', cfg('relevoMin'), 'umbrales', cfg('umbrales'),
    'chkAlerta', cfg('chkAlerta'), 'lugares', cfg('lugares'), 'rutaChofer', cfg('proyectosRutaChofer'),
    'choferes', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nombre', trim(nombre), 'proyecto', proyecto, 'turno', turno)
                  order by trim(nombre) collate "C"), '[]')
                 from choferes where habilitada and (proyecto = '' or upper(proyecto) = any (array(select upper(x) from unnest(cfg_list('proyectos')) x))))) $$;

create or replace function f_turno_iniciar(a jsonb) returns jsonb language plpgsql as $$
declare cid text := a ->> 0; c choferes := chk(a ->> 0, a ->> 1); ck text; nov text := left(trim(coalesce(a ->> 3, '')), 300); t viajes;
begin
  ck := checklist_txt(a -> 2, nov);
  select * into t from viajes where chofer_id = cid and estado = 'activo' and paso = 0 order by creado desc limit 1;
  if t.id is null then perform e('Despacho aún no te asignó una unidad.'); end if;
  perform jornada_abrir(cid, c.nombre, t.placa_id, t.placa, t.proyecto, 'directo', '', ck, nov);
  return driver_state(cid);
end $$;

create or replace function f_parada_iniciar(a jsonb) returns jsonb language plpgsql as $$
declare cid text := a ->> 0; c choferes := chk(a ->> 0, a ->> 1); motivo text := coalesce(a ->> 2, '');
        det text := left(trim(coalesce(a ->> 3, '')), 200); j jornadas; u viajes;
begin
  if not (motivo = any (cfg_list('motivos'))) then perform e('Elige el motivo de la parada.'); end if;
  if motivo = 'Otro' and det = '' then perform e('Describe el motivo de la parada.'); end if;
  j := jornada_activa(cid);
  if j.id is null then perform e('Inicia tu jornada antes de reportar una parada.'); end if;
  if exists (select 1 from paradas where jornada_id = j.id and estado = 'abierta') then perform e('Ya tienes una parada abierta.'); end if;
  select * into u from viajes where chofer_id = cid
     and (estado = 'activo' or (estado = 'finalizado' and t6 is not null and t6 > now() - interval '14 hours'))
   order by creado desc limit 1;
  insert into paradas (jornada_id, chofer_id, chofer, proyecto, turno, placa_id, placa, motivo, detalle, inicio, estado)
  values (j.id, cid, trim(c.nombre), coalesce(u.proyecto, j.proyecto), j.turno, coalesce(u.placa_id, j.placa_id), coalesce(u.placa, j.placa),
          motivo, det, now(), 'abierta');
  return driver_state(cid);
end $$;

create or replace function f_parada_fin(a jsonb) returns jsonb language plpgsql as $$
declare cid text := a ->> 0; c choferes := chk(a ->> 0, a ->> 1); p paradas;
begin
  select * into p from paradas where chofer_id = cid and estado = 'abierta' order by inicio desc limit 1;
  if p.id is null then perform e('No tienes una parada abierta.'); end if;
  update paradas set fin = now(), estado = 'cerrada' where id = p.id;
  return driver_state(cid);
end $$;

create or replace function f_save(a jsonb) returns jsonb language plpgsql as $$
declare cid text := a ->> 0; c choferes := chk(a ->> 0, a ->> 1); d jsonb := coalesce(a -> 3, '{}'); v viajes;
        cn text; o text; de text; av text;
begin
  select * into v from viajes where id = a ->> 2 for update;
  if v.id is null or v.estado <> 'activo' or v.chofer_id <> cid then perform e('Este viaje ya no está activo. Actualiza la pantalla.'); end if;
  if d ? 'contenedor' and jsonb_typeof(d -> 'contenedor') <> 'null' then
    cn := norm(d ->> 'contenedor');
    if cn <> '' and cn !~ '^[A-Z]{4}[0-9]{7}$' then perform e('Contenedor no válido: 4 letras + 7 números (ej. MSKU1234567).'); end if;
    if cn <> '' and not cont_ok(cn) then perform e('El número de contenedor no es válido (el último dígito no cuadra). Revísalo letra por letra y número por número.'); end if;
    if cn <> '' and cn <> v.contenedor then
      if not coalesce((d ->> 'confirmaDup')::boolean, false) then
        av := dup_viaje(cid, v.id, cn, case when d ? 'origen' and jsonb_typeof(d -> 'origen') <> 'null' then lugar(d ->> 'origen') else v.origen end,
                                       case when d ? 'destino' and jsonb_typeof(d -> 'destino') <> 'null' then lugar(d ->> 'destino') else v.destino end);
        if av <> '' then perform e(av); end if;
      else
        update viajes set dup = 'SI' where id = v.id;
      end if;
    end if;
    update viajes set contenedor = cn where id = v.id;
  end if;
  if coalesce(d ->> 'medida', '') <> '' then
    if not ((d ->> 'medida') = any (cfg_list('medidas'))) then perform e('Medida de contenedor no válida.'); end if;
    update viajes set medida = d ->> 'medida' where id = v.id;
  end if;
  if d ? 'obs' and jsonb_typeof(d -> 'obs') <> 'null' then update viajes set observaciones = obs(d -> 'obs') where id = v.id; end if;
  if (d ? 'origen' and jsonb_typeof(d -> 'origen') <> 'null') or (d ? 'destino' and jsonb_typeof(d -> 'destino') <> 'null') then
    if not (v.proyecto = any (cfg_list('proyectosRutaChofer'))) then perform e('El origen y el destino de este viaje no se pueden cambiar.'); end if;
    o := case when d ? 'origen' and jsonb_typeof(d -> 'origen') <> 'null' then lugar(d ->> 'origen') else v.origen end;
    de := case when d ? 'destino' and jsonb_typeof(d -> 'destino') <> 'null' then lugar(d ->> 'destino') else v.destino end;
    perform check_ruta(v.proyecto, o, de);
    update viajes set origen = o, destino = de where id = v.id;
  end if;
  return driver_state(cid);
end $$;

create or replace function f_step(a jsonb) returns jsonb language plpgsql as $$
declare cid text := a ->> 0; c choferes := chk(a ->> 0, a ->> 1); d jsonb := coalesce(a -> 3, '{}'); v viajes;
        n int; quiere int; j jornadas; p paradas; o text; de text; cn text; m text; av text; nuevo boolean := false;
        diferir boolean := coalesce((d ->> 'diferirPuente')::boolean, false); puente_id text := '';
begin
  select * into v from viajes where id = a ->> 2 for update;
  if v.id is null or v.estado <> 'activo' or v.chofer_id <> cid then perform e('Este viaje ya no está activo. Actualiza la pantalla.'); end if;
  n := v.paso + 1;
  quiere := coalesce((d ->> 'paso')::int, 0);
  if quiere > 0 and v.paso >= quiere then   -- toque repetido o respuesta perdida: no se suma otro paso
    return jsonb_build_object('state', driver_state(cid), 'nuevo', false, 'puente', '');
  end if;
  if quiere > 0 and quiere <> n then perform e('La pantalla estaba desactualizada. Revisa el paso y vuelve a marcar.'); end if;
  if n > 6 then perform e('El viaje ya está completo.'); end if;
  j := jornada_activa(cid);
  if j.id is not null then select * into p from paradas where jornada_id = j.id and estado = 'abierta' limit 1; end if;
  if p.id is not null then perform e('Primero marca Unidad en operación.'); end if;
  if v.proyecto = any (cfg_list('proyectosRutaChofer')) then
    o := case when d ? 'origen' and jsonb_typeof(d -> 'origen') <> 'null' then lugar(d ->> 'origen') else v.origen end;
    de := case when d ? 'destino' and jsonb_typeof(d -> 'destino') <> 'null' then lugar(d ->> 'destino') else v.destino end;
    if n = 1 and o = '' then perform e('Elige el origen antes de iniciar el viaje.'); end if;
    if n = 6 and de = '' then perform e('Elige el destino antes de finalizar el viaje.'); end if;
    perform check_ruta(v.proyecto, o, de);
    update viajes set origen = o, destino = de where id = v.id;
    v.origen := o; v.destino := de;
  end if;
  cn := norm(case when d ? 'contenedor' and jsonb_typeof(d -> 'contenedor') <> 'null' then d ->> 'contenedor' else v.contenedor end);
  m := case when coalesce(d ->> 'medida', '') <> '' then d ->> 'medida' else v.medida end;
  if n = 6 then
    if cn !~ '^[A-Z]{4}[0-9]{7}$' then perform e('Registra el número de contenedor (4 letras + 7 números) antes de finalizar el viaje.'); end if;
    if not cont_ok(cn) then perform e('El número de contenedor no es válido (el último dígito no cuadra). Revísalo letra por letra y número por número.'); end if;
    if not (m = any (cfg_list('medidas'))) then perform e('Elige la medida del contenedor antes de finalizar el viaje.'); end if;
    if coalesce((d ->> 'confirmaDup')::boolean, false) then update viajes set dup = 'SI' where id = v.id;
    elsif v.dup <> 'SI' then
      av := dup_viaje(cid, v.id, cn, v.origen, v.destino);
      if av <> '' then perform e(av); end if;
    end if;
  end if;
  if n = 1 and j.id is null then
    if coalesce((cfg('exigirTurno') #>> '{}')::boolean, true) then perform e('Primero inicia tu jornada (revisión de la unidad).'); end if;
    perform jornada_abrir(cid, v.chofer, v.placa_id, v.placa, v.proyecto, 'auto');
    j := jornada_activa(cid);
  end if;
  update viajes set
    paso = n,
    jornada_id = case when n = 1 and j.id is not null then j.id else jornada_id end,
    t1 = case when n = 1 then now() else t1 end, t2 = case when n = 2 then now() else t2 end,
    t3 = case when n = 3 then now() else t3 end, t4 = case when n = 4 then now() else t4 end,
    t5 = case when n = 5 then now() else t5 end, t6 = case when n = 6 then now() else t6 end,
    contenedor = case when cont_ok(cn) then cn else contenedor end,
    medida = case when m = any (cfg_list('medidas')) then m else medida end,
    observaciones = case when d ? 'obs' and jsonb_typeof(d -> 'obs') <> 'null' then obs(d -> 'obs') else observaciones end,
    estado = case when n = 6 then 'finalizado' else estado end,
    -- al finalizar un viaje TPG queda pendiente para el puente al formulario
    puente = case when n = 6 and coalesce((cfg('puenteActivo') #>> '{}')::boolean, false) and proyecto = any (cfg_list('puenteProyectos')) then 'PEND' else puente end
   where id = v.id returning * into v;
  if n = 6 and v.puente = 'PEND' then puente_id := v.id; end if;
  if n = 6 and v.auto and v.proyecto = any (cfg_list('proyectosAuto')) then
    nuevo := repetir(v, true);
    if not nuevo then
      insert into puente_pendientes (id_viaje, error) values (v.id, 'No se generó el siguiente viaje automático. Había otro viaje activo con la misma placa o chofer, o están inhabilitados.');
    end if;
  end if;
  return jsonb_build_object('state', driver_state(cid), 'nuevo', nuevo, 'puente', case when diferir then puente_id else '' end);
end $$;

create or replace function f_next(a jsonb) returns jsonb language plpgsql as $$
declare cid text := a ->> 0; c choferes := chk(a ->> 0, a ->> 1); v viajes;
begin
  select * into v from viajes where id = a ->> 2;
  if v.id is null or v.chofer_id <> cid then perform e('No se encontró el viaje.'); end if;
  if v.estado <> 'finalizado' then perform e('Primero termina el viaje actual.'); end if;
  if not (v.proyecto = any (cfg_list('proyectosSiguiente'))) and not v.auto then perform e('En este proyecto el siguiente viaje lo asigna despacho.'); end if;
  if v.t6 is not null and v.t6 < now() - interval '14 hours' then perform e('Ese viaje es muy antiguo. Pide a despacho que te asigne la unidad.'); end if;
  if not repetir(v, v.auto) then perform e('No se pudo crear el viaje: ya tienes uno en curso o la unidad está ocupada. Actualiza la pantalla.'); end if;
  return driver_state(cid);
end $$;

-- ---------------------------------------------------------------------
-- 5. Funciones de despacho
-- ---------------------------------------------------------------------
create or replace function f_admin_state(n int) returns jsonb language sql stable as $$
  with nn as (select greatest(400, coalesce(n, 0)) as nn, coalesce(nullif(n, 0), 300) as nv),
  pv as (select upper(x) p from unnest(cfg_list('proyectos')) x),
  vv as (select * from (select * from v_viajes order by creado desc limit (select nv from nn)) z)
  select jsonb_build_object(
    'placas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'placa', trim(placa), 'tipo', tipo, 'proyecto', proyecto, 'habilitada', habilitada)), '[]')
                 from placas where proyecto = '' or upper(proyecto) in (select p from pv)),
    'choferes', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nombre', trim(nombre), 'telefono', telefono, 'proyecto', proyecto,
                   'habilitada', habilitada, 'pin', pin)), '[]')
                 from choferes where proyecto = '' or upper(proyecto) in (select p from pv)),
    'viajes', (select coalesce(jsonb_agg(j_trip(vv) || jsonb_build_object('ciclo', coalesce(to_jsonb(ciclo(vv.id, vv.placa, vv.t1, vv.estado)), '""'::jsonb)) order by vv.creado), '[]') from vv),
    'relevos', (select coalesce(jsonb_agg(j_rel(r) order by r.creado), '[]') from (select * from relevos order by creado desc limit 400) r),
    'prog', (select coalesce(jsonb_agg(j_prog(x) order by x.creado), '[]') from (select * from programacion order by creado desc limit 400) x),
    'jornadas', (select coalesce(jsonb_agg(j_jor(x) order by x.creado), '[]') from (select * from jornadas order by creado desc limit (select nn from nn)) x),
    'paradas', (select coalesce(jsonb_agg(j_par(x) order by x.creado), '[]') from (select * from paradas order by creado desc limit (select nn from nn)) x),
    'now', ms(now())) $$;

create or replace function f_visor_state() returns jsonb language plpgsql stable as $$
declare h int := hora_ec(now()); med timestamptz := (dia_ec(now())::text || ' 00:00:00-05')::timestamptz; ini timestamptz; fin timestamptz; tn text := turno_de(now());
begin
  ini := case when h >= 7 and h < 19 then med + interval '7 hours' when h >= 19 then med + interval '19 hours' else med - interval '5 hours' end;
  fin := ini + interval '12 hours';
  return jsonb_build_object('now', ms(now()), 'ini', ms(ini), 'turno', tn, 'relevoMin', cfg('relevoMin'),
    'viajes', (select coalesce(jsonb_agg(jsonb_build_object('chofer', v.chofer, 'placa', v.placa, 'contenedor', v.contenedor, 'medida', v.medida,
                 'origen', v.origen, 'destino', v.destino, 'paso', v.paso, 'estado', v.estado,
                 't1', ms(v.t1), 't2', ms(v.t2), 't3', ms(v.t3), 't4', ms(v.t4), 't5', ms(v.t5), 't6', ms(v.t6),
                 'ciclo', coalesce(to_jsonb(ciclo(v.id, v.placa, v.t1, v.estado)), '""'::jsonb)) order by v.creado), '[]')
               from viajes v where v.turno = tn and v.creado > ini - interval '1 day'
                 and ((v.estado = 'finalizado' and v.t6 >= ini and v.t6 < fin)
                   or (v.estado = 'activo' and coalesce(v.t1, v.creado) >= ini - interval '3 hours'))),
    'relevos', (select coalesce(jsonb_agg(jsonb_build_object('placa', r.placa, 'placa_nueva', r.placa_nueva, 'sale', r.sale, 'entra', r.entra,
                  't_entrega', ms(r.t_entrega), 't_recibo', ms(r.t_recibo), 'estado', r.estado) order by r.creado), '[]')
               from relevos r where r.estado <> 'anulada' and r.t_entrega >= ini - interval '3 hours'));
end $$;

create or replace function f_cambiar_placa(a jsonb) returns jsonb language plpgsql as $$
declare v viajes; p placas; ant text; j jornadas; pm numeric; par paradas;
begin
  select * into v from viajes where id = a ->> 1 for update;
  if v.id is null or v.estado <> 'activo' then perform e('Ese viaje ya no está activo. Actualiza la pantalla.'); end if;
  if v.paso > 0 then perform e('Ese viaje ya inició. Termínalo o libéralo antes de cambiar la placa.'); end if;
  select * into p from placas where id = a ->> 2;
  if p.id is null then perform e('Elige la placa de reemplazo.'); end if;
  if not p.habilitada then perform e('Esa unidad está inhabilitada.'); end if;
  if p.id = v.placa_id then perform e('Esa es la misma placa que ya tiene el viaje.'); end if;
  if exists (select 1 from viajes x where x.estado = 'activo' and x.id <> v.id and x.placa_id = p.id and (x.turno = '' or v.turno = '' or x.turno = v.turno)) then
    perform e('La placa ' || trim(p.placa) || ' ya está asignada a otro viaje en este turno.');
  end if;
  ant := v.placa;
  update viajes set placa_id = p.id, placa = trim(p.placa) where id = v.id;
  j := jornada_activa(v.chofer_id);
  if j.id is not null then
    update jornadas set placa_id = p.id, placa = trim(p.placa) where id = j.id;
    for par in select * from paradas where jornada_id = j.id and estado = 'abierta' loop
      pm := round(extract(epoch from now() - par.inicio) / 6) / 10;
      update paradas set detalle = left(case when detalle <> '' then detalle || ' · ' else '' end || 'Cambio ' || ant || '→' || trim(p.placa)
                                        || ' a las ' || to_char(now() at time zone 'America/Guayaquil', 'HH24:MI'), 300) where id = par.id;
    end loop;
  end if;
  update relevos set estado = 'cambiada', placa_nueva = trim(p.placa)
   where estado = 'entregada' and placa_id = v.placa_id and t_entrega > now() - interval '14 hours' and sale_id <> v.chofer_id;
  insert into cambios_placa (chofer_id, chofer, proyecto, turno, viaje_id, jornada_id, placa_ant, placa_nueva, motivo, parada_min)
  values (v.chofer_id, v.chofer, v.proyecto, v.turno, v.id, coalesce(j.id, ''), ant, trim(p.placa), left(coalesce(a ->> 3, ''), 120), pm);
  perform audit('cambio_placa', viaje_txt(v.id) || ' → ' || trim(p.placa) || ' · ' || coalesce(a ->> 3, ''));
  return jsonb_build_object('ok', true, 'placa', trim(p.placa));
end $$;

create or replace function f_prog_save(d jsonb) returns jsonb language plpgsql as $$
declare v_fecha text := coalesce(d ->> 'fecha', ''); v_turno text := coalesce(d ->> 'turno', ''); proyecto text := coalesce(d ->> 'proyecto', '');
        operacion text := trim(coalesce(d ->> 'operacion', '')); p placas; c choferes;
begin
  if v_fecha !~ '^\d{4}-\d{2}-\d{2}$' then perform e('Elige la fecha.'); end if;
  if not (v_turno = any (cfg_list('turnos'))) then perform e('Elige el turno.'); end if;
  if not (proyecto = any (cfg_list('proyectos'))) then perform e('Elige el proyecto.'); end if;
  if not (operacion = any (cfg_list('clientes'))) then perform e('Elige el cliente: ' || array_to_string(cfg_list('clientes'), ', ') || '.'); end if;
  select * into p from placas where id = d ->> 'placa_id';
  select * into c from choferes where id = d ->> 'chofer_id';
  if p.id is null or c.id is null then perform e('Elige una placa y un chofer.'); end if;
  if not p.habilitada or not c.habilitada then perform e('La unidad o el chofer están inhabilitados.'); end if;
  if exists (select 1 from programacion x where x.fecha = v_fecha::date and x.turno = v_turno and x.estado <> 'cancelado' and x.placa_id = p.id) then
    perform e('Esa placa ya está programada en este turno.'); end if;
  if exists (select 1 from programacion x where x.fecha = v_fecha::date and x.turno = v_turno and x.estado <> 'cancelado' and x.chofer_id = c.id) then
    perform e('Ese chofer ya está programado en este turno.'); end if;
  insert into programacion (fecha, turno, proyecto, placa_id, placa, chofer_id, chofer, operacion, auto, estado, creado_por)
  values (v_fecha::date, v_turno, proyecto, p.id, trim(p.placa), c.id, trim(c.nombre), operacion,
          proyecto = any (cfg_list('proyectosAuto')) and coalesce((d ->> 'auto')::boolean, false), 'programado', actor());
  perform audit('prog_agregar', 'Programó ' || trim(p.placa) || ' / ' || trim(c.nombre) || ' · ' || v_fecha || ' ' || v_turno);
  return 'true';
end $$;

create or replace function f_prog_assign(ids jsonb) returns jsonb language plpgsql as $$
declare r programacion; okn int := 0; fallos jsonb := '[]';
begin
  for r in select * from programacion where estado = 'programado'
              and id = any (array(select jsonb_array_elements_text(coalesce(ids, '[]')))) order by creado loop
    begin
      perform assign_core(jsonb_build_object('proyecto', r.proyecto, 'turno', r.turno, 'operacion', r.operacion,
                                             'placa_id', r.placa_id, 'chofer_id', r.chofer_id, 'auto', r.auto));
      update programacion set estado = 'asignado' where id = r.id;
      okn := okn + 1;
    exception when others then
      fallos := fallos || to_jsonb(r.placa || ': ' || sqlerrm);
    end;
  end loop;
  perform audit('prog_asignar', 'Asignó ' || okn || ' viaje(s) desde la programación');
  return jsonb_build_object('ok', okn, 'fallos', fallos);
end $$;

create or replace function f_prog_copy(de jsonb, a jsonb) returns jsonb language plpgsql as $$
declare n int := 0; r programacion;
begin
  if coalesce(a ->> 'fecha', '') !~ '^\d{4}-\d{2}-\d{2}$' or not (coalesce(a ->> 'turno', '') = any (cfg_list('turnos'))) then
    perform e('Elige la fecha y el turno de destino.'); end if;
  if not exists (select 1 from programacion where estado <> 'cancelado' and fecha::text = de ->> 'fecha' and turno = de ->> 'turno') then
    perform e('No hay programación en el turno de origen.'); end if;
  for r in select * from programacion where estado <> 'cancelado' and fecha::text = de ->> 'fecha' and turno = de ->> 'turno' order by creado loop
    if exists (select 1 from programacion x where x.estado <> 'cancelado' and x.fecha::text = a ->> 'fecha' and x.turno = a ->> 'turno'
                and (x.placa_id = r.placa_id or x.chofer_id = r.chofer_id)) then continue; end if;
    insert into programacion (fecha, turno, proyecto, placa_id, placa, chofer_id, chofer, operacion, auto, estado, creado_por)
    values ((a ->> 'fecha')::date, a ->> 'turno', r.proyecto, r.placa_id, r.placa, r.chofer_id, r.chofer, r.operacion, r.auto, 'programado', actor());
    n := n + 1;
  end loop;
  perform audit('prog_copiar', 'Copió la programación ' || (de ->> 'fecha') || ' ' || (de ->> 'turno') || ' → ' || (a ->> 'fecha') || ' ' || (a ->> 'turno') || ' (' || n || ')');
  return to_jsonb(n);
end $$;

create or replace function f_jornada_cerrar(p_id text) returns jsonb language plpgsql as $$
declare j jornadas;
begin
  select * into j from jornadas where id = p_id and estado = 'activa';
  if j.id is null then perform e('Esa jornada ya no está activa.'); end if;
  update paradas set fin = now(), estado = 'cerrada' where jornada_id = j.id and estado = 'abierta';
  update jornadas set fin = now(), estado = 'cerrada' where id = j.id;
  update viajes set estado = 'liberado', liberado = now(), auto = false where chofer_id = j.chofer_id and estado = 'activo' and paso = 0;
  perform audit('jornada_cerrar', 'Cerró jornada ' || p_id);
  return 'true';
end $$;

create or replace function f_jornada_reabrir(p_id text) returns jsonb language plpgsql as $$
declare j jornadas;
begin
  select * into j from jornadas where id = p_id;
  if j.id is null or j.estado <> 'cerrada' then perform e('Esa jornada no está cerrada.'); end if;
  if j.fin_relevo_id <> '' then perform e('Esa jornada terminó con una entrega de unidad. Para reabrirla, anula la entrega en Relevos.'); end if;
  if (jornada_activa(j.chofer_id)).id is not null then perform e('El chofer ya tiene otra jornada activa.'); end if;
  if j.inicio < now() - make_interval(hours => cfg_num('jorMaxH')::int) then
    perform e('Pasaron más de ' || cfg_num('jorMaxH') || ' horas desde que inició: ya no se puede reabrir.'); end if;
  update paradas set fin = null, estado = 'abierta'
   where jornada_id = j.id and estado = 'cerrada' and j.fin is not null and abs(extract(epoch from fin - j.fin)) <= 1;
  update jornadas set fin = null, estado = 'activa' where id = j.id;
  perform audit('jornada_reabrir', 'Reabrió jornada ' || p_id);
  return 'true';
end $$;

create or replace function f_save_item(kind text, item jsonb) returns jsonb language plpgsql as $$
declare main text := case kind when 'placas' then 'placa' when 'choferes' then 'nombre' end; v text; cur_id text := nullif(item ->> 'id', '');
begin
  if main is null then perform e('Tipo no válido.'); end if;
  if cur_id is not null and not exists (select 1 from placas where kind = 'placas' and id = cur_id union all select 1 from choferes where kind = 'choferes' and id = cur_id) then
    perform e('No se encontró el registro.'); end if;
  if item ? main then
    v := trim(coalesce(item ->> main, ''));
    if kind = 'placas' then v := upper(v); end if;
    if v = '' then perform e('El campo no puede quedar vacío.'); end if;
    if (kind = 'placas' and exists (select 1 from placas where lower(trim(placa)) = lower(v) and id <> coalesce(cur_id, '')))
       or (kind = 'choferes' and exists (select 1 from choferes where lower(trim(nombre)) = lower(v) and id <> coalesce(cur_id, ''))) then
      perform e('Ya existe ' || v || '.'); end if;
  end if;
  if item ? 'tipo' and not ((item ->> 'tipo') = any (cfg_list('tipos'))) then perform e('Tipo no válido.'); end if;
  if item ? 'proyecto' and coalesce(item ->> 'proyecto', '') <> '' and not ((item ->> 'proyecto') = any (cfg_list('proyectosTodos'))) then perform e('Proyecto no válido.'); end if;
  if item ? 'turno' and coalesce(item ->> 'turno', '') <> '' and not ((item ->> 'turno') = any (cfg_list('turnos'))) then perform e('Turno no válido.'); end if;
  if item ? 'pin' and trim(coalesce(item ->> 'pin', '')) !~ '^\d{4,13}$' then perform e('La cédula o PIN debe tener entre 4 y 13 números.'); end if;
  if kind = 'placas' then
    if cur_id is not null then
      update placas set placa = case when item ? 'placa' then v else placa end,
                        tipo = case when item ? 'tipo' then item ->> 'tipo' else tipo end,
                        proyecto = case when item ? 'proyecto' then coalesce(item ->> 'proyecto', '') else proyecto end,
                        habilitada = case when item ? 'habilitada' then (item ->> 'habilitada')::boolean else habilitada end
       where id = cur_id;
    else
      if v is null then perform e('Falta placa.'); end if;
      insert into placas (placa, tipo, proyecto, habilitada)
      values (v, coalesce(item ->> 'tipo', 'Tracto'), coalesce(item ->> 'proyecto', ''), coalesce((item ->> 'habilitada')::boolean, true));
    end if;
  else
    if cur_id is not null then
      update choferes set nombre = case when item ? 'nombre' then v else nombre end,
                          telefono = case when item ? 'telefono' then trim(coalesce(item ->> 'telefono', '')) else telefono end,
                          proyecto = case when item ? 'proyecto' then coalesce(item ->> 'proyecto', '') else proyecto end,
                          turno = case when item ? 'turno' then coalesce(item ->> 'turno', '') else turno end,
                          pin = case when item ? 'pin' then trim(item ->> 'pin') else pin end,
                          habilitada = case when item ? 'habilitada' then (item ->> 'habilitada')::boolean else habilitada end
       where id = cur_id;
    else
      if v is null then perform e('Falta nombre.'); end if;
      insert into choferes (nombre, telefono, proyecto, turno, habilitada, pin)
      values (v, trim(coalesce(item ->> 'telefono', '')), coalesce(item ->> 'proyecto', ''), coalesce(item ->> 'turno', ''),
              coalesce((item ->> 'habilitada')::boolean, true),
              coalesce(nullif(trim(item ->> 'pin'), ''), lpad((floor(random() * 10000))::int::text, 4, '0')));
    end if;
  end if;
  perform audit('catalogo_guardar', kind || ': ' || coalesce(item ->> 'placa', item ->> 'nombre', item ->> 'id', ''));
  return 'true';
end $$;

create or replace function f_delete_item(kind text, p_id text) returns jsonb language plpgsql as $$
begin
  if kind not in ('placas','choferes') then perform e('Tipo no válido.'); end if;
  if exists (select 1 from viajes where estado = 'activo' and ((kind = 'placas' and placa_id = p_id) or (kind = 'choferes' and chofer_id = p_id))) then
    perform e('No se puede eliminar: está en un viaje en curso.'); end if;
  if kind = 'placas' then delete from placas where id = p_id; else delete from choferes where id = p_id; end if;
  if not found then perform e('No se encontró el registro.'); end if;
  perform audit('catalogo_eliminar', kind || ' ' || p_id);
  return 'true';
end $$;

-- Reparte en partes iguales los proyectos vacíos (fillBlanks_)
create or replace function fill_blanks(kind text) returns int language plpgsql as $$
declare ops text[] := cfg_list('proyectos'); cnt jsonb := '{}'; o text; rid text; n int := 0;
begin
  foreach o in array ops loop
    cnt := cnt || jsonb_build_object(o, case when kind = 'placas' then (select count(*) from placas where proyecto = o and trim(placa) <> '')
                                            else (select count(*) from choferes where proyecto = o and trim(nombre) <> '') end);
  end loop;
  for rid in select id from placas where kind = 'placas' and proyecto = '' and trim(placa) <> ''
             union all select id from choferes where kind = 'choferes' and proyecto = '' and trim(nombre) <> '' loop
    select x into o from unnest(ops) with ordinality u(x, i) order by (cnt ->> x)::int, i limit 1;
    cnt := jsonb_set(cnt, array[o], to_jsonb((cnt ->> o)::int + 1));
    if kind = 'placas' then update placas set proyecto = o where id = rid; else update choferes set proyecto = o where id = rid; end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 6. Estadísticas, mantenimiento, facturación y conciliación
-- ---------------------------------------------------------------------
create or replace function f_estadisticas() returns jsonb language plpgsql stable as $$
declare rows jsonb; par jsonb; corte text;
begin
  if not coalesce((cfg('estadActiva') #>> '{}')::boolean, true) then
    return jsonb_build_object('rows', '[]'::jsonb, 'app', 0, 'hist', 0, 'corte', '', 'aviso', '', 'now', ms(now()), 'inactiva', true);
  end if;
  select coalesce(jsonb_agg(jsonb_build_array(iso(v.t6), hhmm(v.t6), v.chofer, v.placa, upper(v.turno), v.origen, v.destino,
            hhmm(v.t2), hhmm(v.t3), hhmm(v.t5), hhmm(v.t6), v.observaciones,
            coalesce(to_jsonb(round(ciclo(v.id, v.placa, v.t1, v.estado) / 6000.0) / 10), '""'::jsonb)) order by v.creado), '[]'),
         min(iso(v.t6))
    into rows, corte
    from viajes v
   where v.creado > now() - make_interval(days => cfg_num('estadDias')::int)
     and v.estado = 'finalizado' and v.t6 is not null and v.t2 is not null and upper(v.proyecto) = 'TPG';
  select coalesce(jsonb_agg(jsonb_build_array(iso(p.inicio - interval '7 hours'), p.turno, p.placa, p.chofer, p.motivo, p.detalle,
            ms(p.inicio), ms(p.fin)) order by p.creado), '[]')
    into par from (select * from paradas where upper(proyecto) = 'TPG' order by creado desc limit 5000) p;
  return jsonb_build_object('rows', rows, 'par', par, 'app', jsonb_array_length(rows), 'hist', 0, 'corte', coalesce(corte, ''), 'aviso', '', 'now', ms(now()));
end $$;

create or replace function f_mantenimiento() returns jsonb language plpgsql stable as $$
declare res jsonb;
begin
  with j as (select * from jornadas order by creado desc limit 3000),
  lec as (   -- última lectura por placa: la del fin si cerró, si no la del inicio
    select distinct on (placa) placa, km, hor from (
      select placa, km_ini km, hor_ini hor, inicio t from j where placa <> '' and km_ini is not null and hor_ini is not null
      union all
      select placa, km_fin, hor_fin, fin from j where placa <> '' and km_fin is not null and hor_fin is not null and fin is not null) x
    order by placa, t desc),
  pri as (select distinct on (placa) placa, km_ini km, hor_ini hor, inicio t from j
           where placa <> '' and km_ini is not null and hor_ini is not null order by placa, inicio),
  par as (select * from paradas order by creado desc limit 3000),
  pl as (select trim(placa) placa from placas
          where habilitada and (proyecto = '' or upper(proyecto) = any (array(select upper(x) from unnest(cfg_list('proyectos')) x))))
  select jsonb_build_object(
    'hoy', iso(now()),
    'placas', coalesce(jsonb_agg(jsonb_build_object(
        'placa', pl.placa, 'km', l.km, 'hor', l.hor, 'desde', coalesce(iso(f.t), ''),
        'kmUso', case when l.km is not null and f.km is not null then l.km - f.km else 0 end,
        'hUso', case when l.hor is not null and f.hor is not null then l.hor - f.hor else 0 end,
        'hMant', (select round(coalesce(sum(greatest(0, extract(epoch from coalesce(x.fin, now()) - x.inicio))), 0) / 3600 * 10) / 10
                    from par x where x.placa = pl.placa and x.inicio > now() - interval '30 days'
                     and x.motivo in ('Unidad dañada','Esperando rescate o mecánico','Mantenimiento programado')),
        'plan', (select coalesce(jsonb_agg(jsonb_build_object('k', m.tarea, 'cadaKm', m.cada_km, 'cadaH', m.cada_hor,
                    'ultKm', m.ult_km, 'ultH', m.ult_hor, 'vence', m.vence)), '[]')
                   from mantenimiento m where upper(trim(m.placa)) = upper(pl.placa) and trim(m.tarea) <> ''))), '[]'),
    'ot', (select coalesce(jsonb_agg(jsonb_build_object('placa', x.placa, 'falla', x.motivo || case when x.detalle <> '' then ': ' || x.detalle else '' end,
             'inicio', ms(x.inicio))), '[]')
           from par x where x.estado = 'abierta' and x.motivo in ('Unidad dañada','Esperando rescate o mecánico')),
    'conPlan', exists (select 1 from mantenimiento m join pl on upper(trim(m.placa)) = upper(pl.placa)))
    into res
    from pl left join lec l on l.placa = pl.placa left join pri f on f.placa = pl.placa;
  return res;
end $$;

create or replace function f_facturacion() returns jsonb language sql stable as $$
  select jsonb_build_object(
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('semana', semana, 'unidades', unidades, 'dias', dias, 'horas_sin_mov', horas_sin_mov,
               'horas_con_mov', horas_con_mov, 'horas_pen', horas_pen, 'mov_real', mov_real, 'mov_exc', mov_exc, 'fact_horas', fact_horas,
               'mov_int', mov_int, 'fact_int', fact_int, 'nota', nota) order by semana), '[]') from facturacion where coalesce(unidades, 0) > 0),
    'facturas', (select coalesce(jsonb_agg(jsonb_build_object('semana', semana, 'concepto', concepto, 'numero', numero, 'fecha', fecha,
               'valor', valor, 'estado', estado, 'fecha_pago', fecha_pago, 'nota', nota)), '[]') from facturas where trim(numero) <> ''),
    'param', cfg('facParam'), 'now', ms(now())) $$;

create or replace function fac_num(v jsonb, nombre text, mn numeric, mx numeric, ent boolean) returns numeric language plpgsql immutable as $$
declare t text := trim(coalesce(v #>> '{}', '')); x numeric;
begin
  begin x := replace(t, ',', '.')::numeric; exception when others then x := null; end;
  if t = '' or x is null then perform e('Falta ' || nombre || '.'); end if;
  if x < mn or x > mx then perform e(nombre || ' debe estar entre ' || mn || ' y ' || mx || '.'); end if;
  if ent and floor(x) <> x then perform e(nombre || ' debe ser un número entero.'); end if;
  return case when ent then x else round(x, 2) end;
end $$;
create or replace function fac_fecha(v text, nombre text, vacio boolean) returns text language plpgsql immutable as $$
declare t text := trim(coalesce(v, ''));
begin
  if t = '' and vacio then return ''; end if;
  if t !~ '^\d{4}-\d{2}-\d{2}$' then perform e(nombre || ' no es una fecha válida.'); end if;
  begin perform t::date; exception when others then perform e(nombre || ' no es una fecha válida.'); end;
  return t;
end $$;

create or replace function f_fac_semana_guardar(o jsonb) returns jsonb language plpgsql as $$
declare s int := fac_num(o -> 'semana', 'La semana', 1, 99, true); hcm numeric; hp numeric;
begin
  hcm := fac_num(o -> 'horas_con_mov', 'Las horas con movimiento', 0, 100000, false);
  hp := fac_num(o -> 'horas_pen', 'Las horas penalizadas', 0, 100000, false);
  if hp > hcm then perform e('Las horas penalizadas no pueden superar las horas con movimiento.'); end if;
  insert into facturacion values (s,
    fac_num(o -> 'unidades', 'Las unidades', 1, 60, true), fac_num(o -> 'dias', 'Los días', 1, 7, true),
    fac_num(o -> 'horas_sin_mov', 'Las horas sin movimiento', 0, 100000, false), hcm, hp,
    fac_num(o -> 'mov_real', 'Los movimientos realizados', 0, 1000000, true), fac_num(o -> 'mov_exc', 'Los movimientos no considerados', 0, 1000000, true),
    fac_num(o -> 'fact_horas', 'El valor facturado por horas', 0, 10000000, false), fac_num(o -> 'mov_int', 'Los movimientos internos', 0, 1000000, true),
    fac_num(o -> 'fact_int', 'El valor de movimiento interno', 0, 10000000, false), left(coalesce(o ->> 'nota', ''), 200))
  on conflict (semana) do update set unidades = excluded.unidades, dias = excluded.dias, horas_sin_mov = excluded.horas_sin_mov,
    horas_con_mov = excluded.horas_con_mov, horas_pen = excluded.horas_pen, mov_real = excluded.mov_real, mov_exc = excluded.mov_exc,
    fact_horas = excluded.fact_horas, mov_int = excluded.mov_int, fact_int = excluded.fact_int, nota = excluded.nota;
  perform audit('fac_semana', 'semana ' || s);
  return 'true';
end $$;

create or replace function f_fac_factura_guardar(o jsonb) returns jsonb language plpgsql as $$
declare s int := fac_num(o -> 'semana', 'La semana', 1, 99, true); num text := trim(coalesce(o ->> 'numero', '')); fp text;
begin
  if coalesce(o ->> 'concepto', '') not in ('horas','mov') then perform e('Reporte no válido.'); end if;
  if num = '' then perform e('Falta el número de factura.'); end if;
  if length(num) > 40 then perform e('El número de factura es demasiado largo.'); end if;
  if coalesce(o ->> 'estado', '') not in ('Emitida','Cobrada') then perform e('Estado no válido.'); end if;
  fp := fac_fecha(o ->> 'fecha_pago', 'La fecha de cobro', true);
  if o ->> 'estado' = 'Cobrada' and fp = '' then perform e('Indica la fecha de cobro.'); end if;
  if o ->> 'estado' <> 'Cobrada' then fp := ''; end if;
  if not exists (select 1 from facturacion where semana = s) then perform e('Primero ingresa la semana ' || s || '.'); end if;
  insert into facturas values (s, o ->> 'concepto', num, fac_fecha(o ->> 'fecha', 'La fecha de la factura', false),
    fac_num(o -> 'valor', 'El valor de la factura', 0, 10000000, false), o ->> 'estado', fp, left(coalesce(o ->> 'nota', ''), 200))
  on conflict (semana, concepto) do update set numero = excluded.numero, fecha = excluded.fecha, valor = excluded.valor,
    estado = excluded.estado, fecha_pago = excluded.fecha_pago, nota = excluded.nota;
  perform audit('fac_factura', 'semana ' || s || ' ' || (o ->> 'concepto') || ' · ' || num);
  return 'true';
end $$;

create or replace function lunes(d date) returns date language sql immutable as
$$ select d - ((extract(isodow from d)::int) - 1) $$;

create or replace function f_conc_guardar(p_lunes text, tipo text, rows jsonb) returns jsonb language plpgsql as $$
declare n int;
begin
  if coalesce(p_lunes, '') !~ '^\d{4}-\d{2}-\d{2}$' then perform e('No se pudo leer la semana del reporte.'); end if;
  if tipo not in ('horas','mov') then perform e('Tipo de reporte no válido.'); end if;
  if rows is null or jsonb_typeof(rows) <> 'array' or jsonb_array_length(rows) = 0 then perform e('El reporte no tiene movimientos.'); end if;
  if jsonb_array_length(rows) > 6000 then perform e('El reporte tiene demasiadas filas.'); end if;
  delete from tpg_reporte where semana = p_lunes and tpg_reporte.tipo = f_conc_guardar.tipo;
  insert into tpg_reporte (semana, tipo, serv, contenedor, fecha, placa, dia, hora)
  select p_lunes, tipo, left(coalesce(r ->> 0, ''), 20), norm(r ->> 1), left(coalesce(r ->> 2, ''), 10),
         left(upper(trim(coalesce(r ->> 3, ''))), 12), left(coalesce(r ->> 4, ''), 4), left(coalesce(r ->> 5, ''), 8)
    from jsonb_array_elements(rows) r;
  get diagnostics n = row_count;
  perform audit('tpg_reporte', 'Cargó reporte TPG ' || tipo || ' de la semana ' || p_lunes || ' (' || n || ' filas)');
  return jsonb_build_object('ok', true, 'filas', n);
end $$;

create or replace function cc_semanas() returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('lunes', semana, 'fin', (semana::date + 6)::text, 'horas', h, 'mov', m) order by semana desc), '[]')
    from (select semana, count(*) filter (where tipo = 'horas') h, count(*) filter (where tipo = 'mov') m
            from tpg_reporte where semana <> '' group by semana) s $$;

-- Viajes de la app de una semana por día operativo (el nocturno de madrugada pertenece al día anterior)
create or replace function cc_app(p_lunes text) returns table (id text, c text, raw text, dia text, hora text, placa text, chofer text, o text, d text,
                                                               turno text, medida text)
language sql stable as $$
  select v.id, norm(v.contenedor), v.contenedor, iso(v.t6 - interval '7 hours'), hhmm(v.t6), v.placa, v.chofer, v.origen, v.destino, v.turno, v.medida
    from viajes v
   where v.creado >= (p_lunes || ' 00:00:00-05')::timestamptz - interval '2 days'
     and v.estado = 'finalizado' and v.t6 is not null
     and iso(v.t6 - interval '7 hours') between p_lunes and (p_lunes::date + 6)::text $$;

create or replace function f_conc_viajes(p_lunes text) returns jsonb language sql stable as $$
  select jsonb_build_object('lunes', p_lunes, 'fin', (p_lunes::date + 6)::text,
    'rows', (select coalesce(jsonb_agg(jsonb_build_array(a.dia, a.hora, a.turno, a.placa, a.chofer, a.o, a.d, a.raw, a.medida,
                case when exists (select 1 from tpg_reporte t where t.semana = p_lunes and t.contenedor = a.c) then 1 else 0 end)
              order by a.dia, a.hora), '[]') from cc_app(p_lunes) a),
    'hayReporte', exists (select 1 from tpg_reporte where semana = p_lunes)) $$;

create or replace function f_conciliacion(p_lunes text) returns jsonb language plpgsql stable as $$
declare sem jsonb := cc_semanas(); lu text := p_lunes; t jsonb; tp record; soloapp jsonb := '[]'; solotpg jsonb := '[]';
        a record; x record; mejor record; md int; dd int; usados text[] := '{}'; sug jsonb; sugtpg jsonb := '{}'; tarifa jsonb := cfg('tpg');
        hc numeric := 0; penh numeric := 0; g record;
begin
  if jsonb_array_length(sem) = 0 then return jsonb_build_object('semanas', '[]'::jsonb, 'sel', ''); end if;
  if not exists (select 1 from jsonb_array_elements(sem) s where s ->> 'lunes' = lu) then lu := sem -> 0 ->> 'lunes'; end if;
  -- lo que cobra TPG, recalculado
  for g in select dia, placa, count(distinct hora) nh, count(*) m from tpg_reporte where semana = lu and tipo = 'horas' group by dia, placa loop
    hc := hc + g.nh; penh := penh + least(0, g.m - (tarifa ->> 'minMovHora')::numeric * g.nh) * 0.5;
  end loop;
  select jsonb_build_object(
      'horas', count(*) filter (where tipo = 'horas'), 'mov', count(*) filter (where tipo = 'mov'),
      'movInt', count(*) filter (where tipo = 'mov' and serv = 'mov interno'), 'movTras', count(*) filter (where tipo = 'mov' and serv = 'traslados'),
      'horasConMov', hc, 'penH', penh, 'usd', round((hc + penh) * (tarifa ->> 'tarifaHora')::numeric, 2),
      'porMov', round(count(*) filter (where tipo = 'mov' and serv = 'mov interno') * (tarifa ->> 'movInt')::numeric
                    + count(*) filter (where tipo = 'mov' and serv = 'traslados') * (tarifa ->> 'traslado')::numeric, 2))
    into t from tpg_reporte where semana = lu;
  -- solo en TPG (sin repetir contenedor), en el orden del reporte
  for x in select distinct on (contenedor) contenedor c, fecha, placa, serv, id from tpg_reporte r
            where semana = lu and not exists (select 1 from cc_app(lu) a where a.c = r.contenedor) order by contenedor, id loop
    solotpg := solotpg || jsonb_build_object('c', x.c, 'dia', x.fecha, 'placa', x.placa, 'serv', x.serv, '_id', x.id);
  end loop;
  select coalesce(jsonb_agg(z order by (z ->> '_id')::bigint), '[]') into solotpg from jsonb_array_elements(solotpg) z;
  -- solo en la app, con sugerencia de posible error de tipeo (1 o 2 caracteres de diferencia)
  for a in select * from cc_app(lu) a where not exists (select 1 from tpg_reporte r where r.semana = lu and r.contenedor = a.c) loop
    md := 3; mejor := null; sug := null;
    for x in select z ->> 'c' c, z ->> 'dia' dia, z ->> 'placa' placa from jsonb_array_elements(solotpg) z where not ((z ->> 'c') = any (usados)) loop
      dd := cc_dist(a.c, x.c);
      if dd < md or (dd = md and mejor is not null and x.placa = a.placa and mejor.placa <> a.placa) then md := dd; mejor := x; end if;
    end loop;
    if mejor is not null and md <= 2 then
      usados := usados || mejor.c;
      sug := jsonb_build_object('c', mejor.c, 'dia', mejor.dia, 'placa', mejor.placa, 'd', md);
      sugtpg := sugtpg || jsonb_build_object(mejor.c, jsonb_build_object('id', a.id, 'c', a.c, 'dia', a.dia, 'placa', a.placa, 'd', md));
    end if;
    soloapp := soloapp || (jsonb_build_object('id', a.id, 'c', a.raw, 'cn', a.c, 'dia', a.dia, 'placa', a.placa, 'chofer', a.chofer,
      'ruta', a.o || ' → ' || a.d, 'malo', a.c !~ '^[A-Z]{4}[0-9]{7}$', 'iso', a.c ~ '^[A-Z]{4}[0-9]{7}$' and not cont_ok(a.c))
      || case when sug is null then '{}'::jsonb else jsonb_build_object('sug', sug) end);
  end loop;
  select coalesce(jsonb_agg((z - '_id') || case when sugtpg ? (z ->> 'c') then jsonb_build_object('sug', sugtpg -> (z ->> 'c')) else '{}'::jsonb end), '[]')
    into solotpg from jsonb_array_elements(solotpg) z;
  return jsonb_build_object('semanas', sem, 'sel', lu, 'fin', (lu::date + 6)::text, 'tpg', t,
    'ours', (select jsonb_build_object('viajes', count(*), 'encontrados', count(*) filter (where exists (select 1 from tpg_reporte r where r.semana = lu and r.contenedor = a.c)),
                    'formatoMalo', count(*) filter (where a.c !~ '^[A-Z]{4}[0-9]{7}$')) from cc_app(lu) a),
    'rutas', (select coalesce(jsonb_agg(jsonb_build_object('o', o, 'd', d, 'viajes', viajes, 'enc', enc,
                'filas', case when enc > 0 then round(filas::numeric / enc, 2) else 0 end) order by viajes desc), '[]')
              from (select a.o, a.d, count(*) viajes, count(*) filter (where f > 0) enc, sum(f) filas
                      from (select a.*, (select count(*) from tpg_reporte r where r.semana = lu and r.contenedor = a.c) f from cc_app(lu) a) a
                     group by a.o, a.d) q),
    'placas', (select coalesce(jsonb_agg(jsonb_build_object('placa', placa, 'app', sum_app, 'tpg', sum_tpg) order by sum_app desc), '[]')
               from (select placa, sum(app) sum_app, sum(tpg) sum_tpg from (
                       select placa, 1 app, 0 tpg from cc_app(lu)
                       union all select placa, 0, 1 from tpg_reporte where semana = lu and placa <> '') u group by placa) q),
    'soloApp', soloapp, 'soloTpg', solotpg);
end $$;

-- ---------------------------------------------------------------------
-- 7. Puente al formulario: lista de viajes pendientes de pasar a la hoja
--    (la lee un pequeño Apps Script en la hoja del formulario; ver puente.gs)
-- ---------------------------------------------------------------------
create or replace function nombre_form(p_chofer text, fallback text) returns text language sql stable as $$
  select coalesce(nullif(upper(trim((select alias from choferes where id = p_chofer))), ''),
    (select case when array_length(p, 1) >= 3 then p[3] || ' ' || p[1] else array_to_string(p, ' ') end
       from (select regexp_split_to_array(upper(regexp_replace(trim(coalesce((select nombre from choferes where id = p_chofer), fallback, '')), '\s+', ' ', 'g')), ' ') p) z)) $$;

create or replace function f_puente_pendientes(lim int) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', v.id, 'puente', v.puente, 'doble', norm(v.origen) = 'MUELLE' and norm(v.destino) = any (cfg_list('dobleDestinos')),
      't6', ms(v.t6), 'chofer', nombre_form(v.chofer_id, v.chofer), 'placa', v.placa, 'turno', upper(v.turno),
      'medida', left(regexp_replace(v.medida, '[^0-9]', '', 'g'), 2), 'contenedor', v.contenedor,
      'origen', upper(v.origen), 'destino', upper(v.destino),
      't1', ms(v.t1), 't2', ms(v.t2), 't3', ms(v.t3), 't4', ms(v.t4), 't5', ms(v.t5),
      'observaciones', translate(upper(v.observaciones), 'ÁÉÍÓÚÑ', 'AEIOUN')) order by v.t6), '[]')
    from (select * from viajes where puente in ('PEND','OK1') and estado = 'finalizado' and t6 is not null
           and proyecto = any (cfg_list('puenteProyectos')) order by t6 limit coalesce(lim, 50)) v $$;

create or replace function f_puente_marcar(p_id text, estado text, err text) returns jsonb language plpgsql as $$
begin
  if estado not in ('OK','OK1','ERR') then perform e('Estado no válido.'); end if;
  update viajes set puente = estado where id = p_id;
  if estado = 'ERR' then insert into puente_pendientes (id_viaje, error) values (p_id, left(coalesce(err, ''), 300)); end if;
  return 'true';
end $$;

-- ---------------------------------------------------------------------
-- 8. Entrada única: api(fn, args)
-- ---------------------------------------------------------------------
create or replace function api_core(fn text, a jsonb) returns jsonb language plpgsql as $$
declare u accesos; r jsonb; v viajes; det text;
begin
  -- Las operaciones que escriben van en fila (como LockService en Apps Script).
  if fn not in ('api_base','api_login','api_driverState','api_adminState','api_visorState','api_acceso','api_adminLogin',
                'api_estadisticas','api_mantenimiento','api_facturacion','api_conciliacion','api_conciliacionViajes','api_logError') then
    perform pg_advisory_xact_lock(4242);
  end if;

  case fn
  -- público
  when 'api_base' then return f_base();
  when 'api_logError' then
    if (select count(*) from log_errores where fecha > now() - interval '10 minutes') < 40 then
      insert into log_errores (quien, funcion, mensaje) values (left(a ->> 0, 60), left(a ->> 1, 60), left(a ->> 2, 300));
    end if;
    return 'true';

  -- chofer
  when 'api_login', 'api_driverState' then perform chk(a ->> 0, a ->> 1); return driver_state(a ->> 0);
  when 'api_turnoIniciarDirecto' then return f_turno_iniciar(a);
  when 'api_paradaIniciar' then return f_parada_iniciar(a);
  when 'api_paradaFin' then return f_parada_fin(a);
  when 'api_save' then return f_save(a);
  when 'api_step' then return f_step(a);
  when 'api_next' then return f_next(a);
  when 'api_puente' then perform chk(a ->> 0, a ->> 1); return 'true';   -- el puente lo hace el script de la hoja del formulario
  when 'api_relevoEntregar' then perform chk(a ->> 0, a ->> 1); perform e('La entrega de unidad ya no se usa. Cierra y vuelve a abrir la app.');
  when 'api_relevoRecibir' then perform chk(a ->> 0, a ->> 1); perform e('La recepción de unidad ya no se usa. Cierra y vuelve a abrir la app.');
  when 'api_relevoAnular' then perform chk(a ->> 0, a ->> 1); perform e('Avisa a despacho para que reactive tu turno.');

  -- despacho: acceso y consulta
  when 'api_acceso' then u := acceso(a ->> 0); return jsonb_build_object('rol', u.rol, 'nombre', u.nombre);
  when 'api_adminLogin' then perform auth(a ->> 0); return 'true';
  when 'api_visorState' then
    u := acceso(a ->> 0);
    if u.rol not in ('visor','despacho','admin') then perform e('Tu usuario no tiene permiso para esta pantalla.'); end if;
    return f_visor_state();
  when 'api_adminState' then perform auth(a ->> 0, 'estado'); return f_admin_state((a ->> 1)::int);

  -- despacho: operación
  when 'api_assign' then
    perform auth(a ->> 0, 'assign');
    v := assign_core(a -> 1);
    perform audit('assign', 'Asignó ' || v.placa || ' a ' || v.chofer || ' · ' || v.turno || ' · ' || v.operacion);
    return 'true';
  when 'api_release' then
    perform auth(a ->> 0, 'release');
    update viajes set estado = 'liberado', liberado = now(), auto = false where id = a ->> 1 and estado = 'activo';
    if not found then perform e('Ese viaje ya no está activo.'); end if;
    perform audit('liberar', 'Liberó ' || viaje_txt(a ->> 1));
    return 'true';
  when 'api_toggleAuto' then
    perform auth(a ->> 0, 'toggleAuto');
    select * into v from viajes where id = a ->> 1;
    if v.id is null or v.estado <> 'activo' then perform e('Ese viaje ya no está activo.'); end if;
    if not (v.proyecto = any (cfg_list('proyectosAuto'))) then perform e('El modo automático solo aplica a ' || array_to_string(cfg_list('proyectosAuto'), ', ') || '.'); end if;
    update viajes set auto = not auto where id = v.id;
    perform audit('auto', 'Auto ' || case when not v.auto then 'SÍ' else 'NO' end || ' · ' || viaje_txt(v.id));
    return to_jsonb(not v.auto);
  when 'api_cambiarPlaca' then perform auth(a ->> 0, 'cambiarPlaca'); return f_cambiar_placa(a);
  when 'api_progSave' then perform auth(a ->> 0, 'progSave'); return f_prog_save(a -> 1);
  when 'api_progDelete' then
    perform auth(a ->> 0, 'progDelete');
    update programacion set estado = 'cancelado' where id = a ->> 1 and estado = 'programado';
    if not found then perform e('Ese registro ya no está programado.'); end if;
    perform audit('prog_quitar', 'Quitó programación ' || (a ->> 1));
    return 'true';
  when 'api_progAssign' then perform auth(a ->> 0, 'progAssign'); return f_prog_assign(a -> 1);
  when 'api_progCopy' then perform auth(a ->> 0, 'progCopy'); return f_prog_copy(a -> 1, a -> 2);
  when 'api_relevoAnularAdmin' then
    perform auth(a ->> 0, 'relevoAnularAdmin');
    update relevos set estado = 'anulada' where id = a ->> 1 and estado in ('entregada','cambiada');
    if not found then perform e('Esa entrega ya no está pendiente.'); end if;
    perform jornada_reabrir(a ->> 1);
    perform audit('relevo_anular', 'Anuló relevo ' || (a ->> 1));
    return 'true';
  when 'api_jornadaCerrarAdmin' then perform auth(a ->> 0, 'jornadaCerrarAdmin'); return f_jornada_cerrar(a ->> 1);
  when 'api_jornadaReabrirAdmin' then perform auth(a ->> 0, 'jornadaReabrirAdmin'); return f_jornada_reabrir(a ->> 1);
  when 'api_paradaCerrarAdmin' then
    perform auth(a ->> 0, 'paradaCerrarAdmin');
    update paradas set fin = now(), estado = 'cerrada' where id = a ->> 1 and estado = 'abierta';
    if not found then perform e('Esa parada ya está cerrada.'); end if;
    perform audit('parada_cerrar', 'Cerró parada ' || (a ->> 1));
    return 'true';

  -- recursos (solo administrador)
  when 'api_saveItem' then perform auth(a ->> 0); return f_save_item(a ->> 1, coalesce(a -> 2, '{}'));
  when 'api_deleteItem' then perform auth(a ->> 0); return f_delete_item(a ->> 1, a ->> 2);
  when 'api_fillBlanks' then
    perform auth(a ->> 0);
    r := jsonb_build_object('placas', fill_blanks('placas'), 'choferes', fill_blanks('choferes'));
    perform audit('rellenar', 'Rellenó vacíos');
    return r;

  -- estadísticas, mantenimiento, facturación
  when 'api_estadisticas' then perform auth(a ->> 0, 'estadisticas'); return f_estadisticas();
  when 'api_mantenimiento' then perform auth(a ->> 0, 'mantenimiento'); return f_mantenimiento();
  when 'api_facturacion' then perform auth(a ->> 0, 'facturacion'); return f_facturacion();
  when 'api_facSemanaGuardar' then perform auth(a ->> 0); return f_fac_semana_guardar(coalesce(a -> 1, '{}'));
  when 'api_facSemanaEliminar' then
    perform auth(a ->> 0);
    if exists (select 1 from facturas where semana = fac_num(a -> 1, 'La semana', 1, 99, true) and trim(numero) <> '') then
      perform e('La semana ' || (a ->> 1) || ' tiene facturas. Elimínalas primero.'); end if;
    delete from facturacion where semana = fac_num(a -> 1, 'La semana', 1, 99, true);
    if not found then perform e('No se encontró la semana.'); end if;
    perform audit('fac_semana_eliminar', 'semana ' || (a ->> 1));
    return 'true';
  when 'api_facFacturaGuardar' then perform auth(a ->> 0); return f_fac_factura_guardar(coalesce(a -> 1, '{}'));
  when 'api_facFacturaEliminar' then
    perform auth(a ->> 0);
    delete from facturas where semana = fac_num(a -> 1, 'La semana', 1, 99, true) and concepto = a ->> 2;
    if not found then perform e('No se encontró la factura.'); end if;
    perform audit('fac_factura_eliminar', 'semana ' || (a ->> 1) || ' ' || (a ->> 2));
    return 'true';

  -- conciliación con TPG (solo administrador)
  when 'api_conciliacionGuardar' then perform auth(a ->> 0); return f_conc_guardar(a ->> 1, a ->> 2, a -> 3);
  when 'api_conciliacion' then perform auth(a ->> 0); return f_conciliacion(coalesce(a ->> 1, ''));
  when 'api_conciliacionViajes' then
    perform auth(a ->> 0);
    if coalesce(a ->> 1, '') !~ '^\d{4}-\d{2}-\d{2}$' then perform e('Semana no válida.'); end if;
    return f_conc_viajes(a ->> 1);
  when 'api_viajeContenedorCorregir' then
    perform auth(a ->> 0);
    if norm(a ->> 2) !~ '^[A-Z]{4}[0-9]{7}$' then perform e('El contenedor debe tener 4 letras y 7 números, por ejemplo MSKU1234567.'); end if;
    select * into v from viajes where id = a ->> 1;
    if v.id is null then perform e('No encontré ese viaje. Actualiza la pantalla.'); end if;
    if v.estado = 'anulado' then perform e('Ese viaje ya está anulado.'); end if;
    update viajes set contenedor = norm(a ->> 2) where id = v.id;
    perform audit('viaje_contenedor', 'Corrigió el contenedor del viaje de ' || v.placa || ' · ' || v.chofer || ': '
                  || coalesce(nullif(v.contenedor, ''), '(vacío)') || ' → ' || norm(a ->> 2));
    return jsonb_build_object('placa', v.placa, 'chofer', v.chofer, 'antes', coalesce(nullif(v.contenedor, ''), '(vacío)'));
  when 'api_viajeAnular' then
    perform auth(a ->> 0);
    if length(trim(coalesce(a ->> 2, ''))) < 3 then perform e('Escribe el motivo de la anulación.'); end if;
    select * into v from viajes where id = a ->> 1;
    if v.id is null then perform e('No encontré ese viaje. Actualiza la pantalla.'); end if;
    if v.estado = 'anulado' then perform e('Ese viaje ya está anulado.'); end if;
    if v.estado <> 'finalizado' then perform e('Solo se anulan viajes finalizados. Si está en curso, usa Liberar.'); end if;
    update viajes set estado = 'anulado' where id = v.id;
    perform audit('viaje_anular', 'Anuló el viaje de ' || v.placa || ' · ' || v.chofer || ' · contenedor ' || coalesce(nullif(v.contenedor, ''), '(vacío)')
                  || ' · ' || iso(coalesce(v.t6, v.creado)) || '. Motivo: ' || trim(a ->> 2));
    return jsonb_build_object('placa', v.placa, 'chofer', v.chofer, 'c', coalesce(nullif(v.contenedor, ''), '(vacío)'), 'fecha', iso(coalesce(v.t6, v.creado)));
  when 'api_conciliacionReporteCorregir' then
    perform auth(a ->> 0);
    if norm(a ->> 3) !~ '^[A-Z]{4}[0-9]{7}$' then perform e('El contenedor debe tener 4 letras y 7 números, por ejemplo MSKU1234567.'); end if;
    if not exists (select 1 from tpg_reporte where semana = a ->> 1) then perform e('Esa semana no tiene reporte cargado.'); end if;
    update tpg_reporte set contenedor = norm(a ->> 3) where semana = a ->> 1 and contenedor = norm(a ->> 2);
    get diagnostics det = row_count;
    if det::int = 0 then perform e('Ese contenedor ya no está en el reporte. Actualiza la pantalla.'); end if;
    perform audit('tpg_corregir', 'Corrigió en el reporte de TPG (semana ' || (a ->> 1) || ') ' || norm(a ->> 2) || ' → ' || norm(a ->> 3) || ' en ' || det || ' fila(s)');
    return to_jsonb(det::int);
  when 'api_conciliacionReporteQuitar' then
    perform auth(a ->> 0);
    if not exists (select 1 from tpg_reporte where semana = a ->> 1) then perform e('Esa semana no tiene reporte cargado.'); end if;
    delete from tpg_reporte where semana = a ->> 1 and contenedor = norm(a ->> 2);
    get diagnostics det = row_count;
    if det::int = 0 then perform e('Ese contenedor ya no está en el reporte. Actualiza la pantalla.'); end if;
    perform audit('tpg_quitar', 'Quitó del reporte de TPG (semana ' || (a ->> 1) || ') el contenedor ' || norm(a ->> 2) || ' (' || det || ' fila(s))');
    return to_jsonb(det::int);

  -- puente (lo usa el script de la hoja del formulario, con un acceso de rol 'puente')
  when 'api_puentePendientes' then perform auth(a ->> 0, 'puente'); return f_puente_pendientes(coalesce((a ->> 1)::int, 50));
  when 'api_puenteMarcar' then perform auth(a ->> 0, 'puente'); return f_puente_marcar(a ->> 1, a ->> 2, a ->> 3);

  else perform e('Función de script no encontrada: ' || coalesce(fn, ''));
  end case;
  return null;
end $$;

create or replace function api(fn text, args jsonb default '[]'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb; msg text; det text;
begin
  begin
    r := api_core(fn, coalesce(args, '[]'::jsonb));
    return jsonb_build_object('ok', r);
  exception when others then
    get stacked diagnostics msg = message_text, det = pg_exception_detail;
    if det like 'fallo:%' then    -- PIN equivocado: se cuenta el intento aunque lo demás se deshaga
      perform fallo(substr(det, 7));
      if substr(det, 7) like 'adm\_%' then perform fallo('admG'); end if;
    end if;
    if sqlstate <> 'P0001' then
      insert into log_errores (quien, funcion, mensaje) values ('servidor', left(fn, 60), left(sqlstate || ' ' || msg, 300));
    end if;
    return jsonb_build_object('error', msg);
  end;
end $$;

-- Solo api() queda abierta al navegador.
revoke all on all functions in schema public from public, anon, authenticated;
grant execute on function api(text, jsonb) to anon, authenticated;

-- Supabase corta las consultas del navegador a los 3 s; las estadísticas y la conciliación pueden tardar más.
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'alter role anon set statement_timeout = ''60s'''; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'alter role authenticated set statement_timeout = ''60s'''; end if;
end $$;
notify pgrst, 'reload schema';
