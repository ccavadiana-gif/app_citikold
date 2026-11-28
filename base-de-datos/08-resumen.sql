-- Resumen gerencial: movimientos por tipo y turno, incidencias, demoras del terminal y movimientos por proveedor en TPG.
-- Aditivo: tablas nuevas + 3 funciones nuevas + 3 casos nuevos en api_core. No toca la pantalla del chofer.

create table if not exists res_semana (
  semana int primary key,
  porteo int not null default 0, traslados int not null default 0,
  diurno int not null default 0, nocturno int not null default 0,
  inc_oper int not null default 0, inc_dano int not null default 0,
  esp_descarga numeric not null default 0, esp_muelle numeric not null default 0, esp_carga numeric not null default 0,
  esp_cambio_mov numeric not null default 0, esp_cambio_guardia numeric not null default 0,
  mensaje text not null default '', incidencia text not null default ''
);
create table if not exists res_proveedor (
  semana int not null, proveedor text not null, mov int not null default 0,
  primary key (semana, proveedor)
);
alter table res_semana enable row level security;
alter table res_proveedor enable row level security;

create or replace function f_resumen() returns jsonb language sql stable as $$
  select jsonb_build_object(
    'sem', (select coalesce(jsonb_agg(to_jsonb(r) order by semana), '[]') from res_semana r),
    'prov', (select coalesce(jsonb_agg(jsonb_build_object('semana', semana, 'proveedor', proveedor, 'mov', mov) order by semana, proveedor), '[]') from res_proveedor)
  ) $$;

create or replace function f_res_semana_guardar(o jsonb) returns jsonb language plpgsql as $$
declare s int := fac_num(o -> 'semana', 'La semana', 1, 99, true);
begin
  insert into res_semana values (s,
    fac_num(o -> 'porteo', 'Los movimientos de porteo', 0, 1000000, true), fac_num(o -> 'traslados', 'Los traslados', 0, 1000000, true),
    fac_num(o -> 'diurno', 'Los movimientos diurnos', 0, 1000000, true), fac_num(o -> 'nocturno', 'Los movimientos nocturnos', 0, 1000000, true),
    fac_num(o -> 'inc_oper', 'Las incidencias de operaciones', 0, 1000, true), fac_num(o -> 'inc_dano', 'Las incidencias por daño estructural', 0, 1000, true),
    fac_num(o -> 'esp_descarga', 'Las horas de demora en descarga', 0, 100000, false), fac_num(o -> 'esp_muelle', 'Las horas de demora de ingreso de muelle', 0, 100000, false),
    fac_num(o -> 'esp_carga', 'Las horas de demora en la carga', 0, 100000, false), fac_num(o -> 'esp_cambio_mov', 'Las horas por cambio de movimiento', 0, 100000, false),
    fac_num(o -> 'esp_cambio_guardia', 'Las horas por cambio de guardia', 0, 100000, false),
    left(coalesce(o ->> 'mensaje', ''), 400), left(coalesce(o ->> 'incidencia', ''), 400))
  on conflict (semana) do update set porteo = excluded.porteo, traslados = excluded.traslados, diurno = excluded.diurno, nocturno = excluded.nocturno,
    inc_oper = excluded.inc_oper, inc_dano = excluded.inc_dano, esp_descarga = excluded.esp_descarga, esp_muelle = excluded.esp_muelle,
    esp_carga = excluded.esp_carga, esp_cambio_mov = excluded.esp_cambio_mov, esp_cambio_guardia = excluded.esp_cambio_guardia,
    mensaje = excluded.mensaje, incidencia = excluded.incidencia;
  perform audit('res_semana', 'semana ' || s);
  return 'true';
end $$;

create or replace function f_res_prov_guardar(o jsonb) returns jsonb language plpgsql as $$
declare s int := fac_num(o -> 'semana', 'La semana', 1, 99, true); x jsonb; nom text; n int := 0;
begin
  if jsonb_typeof(o -> 'filas') <> 'array' then perform e('No llegaron los proveedores.'); end if;
  delete from res_proveedor where semana = s;
  for x in select * from jsonb_array_elements(o -> 'filas') loop
    nom := upper(left(trim(coalesce(x ->> 'proveedor', '')), 40));
    if nom = '' then continue; end if;
    insert into res_proveedor values (s, nom, fac_num(x -> 'mov', 'Los movimientos de ' || nom, 0, 10000000, true))
      on conflict (semana, proveedor) do update set mov = excluded.mov;
    n := n + 1;
  end loop;
  perform audit('res_proveedores', 'semana ' || s || ' · ' || n || ' proveedores');
  return 'true';
end $$;

revoke all on function f_resumen() from public, anon, authenticated;
revoke all on function f_res_semana_guardar(jsonb) from public, anon, authenticated;
revoke all on function f_res_prov_guardar(jsonb) from public, anon, authenticated;

-- api_core: se agregan los 3 casos sin reescribir el resto de la función
do $$
declare d text := pg_get_functiondef('public.api_core(text,jsonb)'::regprocedure); m1 text := E'  when ''api_facSemanaEliminar'' then'; m2 text := '''api_facturacion'',''api_conciliacion''';
begin
  if d like '%api_resumen%' then return; end if;
  if (length(d) - length(replace(d, m1, ''))) <> length(m1) then raise exception 'marcador 1 no único'; end if;
  if (length(d) - length(replace(d, m2, ''))) <> length(m2) then raise exception 'marcador 2 no único'; end if;
  d := replace(d, m2, '''api_facturacion'',''api_resumen'',''api_conciliacion''');
  d := replace(d, m1, E'  when ''api_resumen'' then perform auth(a ->> 0, ''facturacion''); return f_resumen();\n'
    || E'  when ''api_resSemanaGuardar'' then perform auth(a ->> 0); return f_res_semana_guardar(coalesce(a -> 1, ''{}''));\n'
    || E'  when ''api_resProvGuardar'' then perform auth(a ->> 0); return f_res_prov_guardar(coalesce(a -> 1, ''{}''));\n' || m1);
  execute d;
end $$;
