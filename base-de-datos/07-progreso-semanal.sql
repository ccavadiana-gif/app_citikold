-- 07 · Progreso semanal del chofer
-- Agrega 'semana' a driver_state: viajes finalizados por día (lunes a domingo, hora de Ecuador)
-- de la semana actual y de la anterior. Se ejecuta en el SQL Editor de Supabase. Se puede repetir sin problema.
-- Si no se ejecuta, la app sigue funcionando igual y solo no muestra el gráfico.

create or replace function semana_chofer(p_chofer text) returns jsonb language sql stable as $$
  with p as (select (date_trunc('week', now() at time zone 'America/Guayaquil'))::date as lunes),
  d as (select dia_ec(t6) as dia, count(*)::int as n
          from viajes, p
         where chofer_id = p_chofer and estado = 'finalizado' and t6 is not null
           and dia_ec(t6) >= p.lunes - 7 and dia_ec(t6) < p.lunes + 7
         group by 1)
  select jsonb_build_object(
    'lunes', (select lunes::text from p),
    'hoy', dia_ec(now())::text,
    'dias', (select jsonb_agg(coalesce((select n from d where dia = p.lunes + i), 0) order by i) from p, generate_series(0, 6) i),
    'previa', (select coalesce(sum(n), 0)::int from d, p where d.dia < p.lunes)) $$;

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
    'semana', semana_chofer(p_chofer),
    'ver', cfg('appVersion') #>> '{}');
end $$;
