-- Corrección de Conciliación (error: record "a" is not assigned yet). Se puede ejecutar varias veces.
create or replace function f_conciliacion(p_lunes text) returns jsonb language plpgsql stable as $$
declare sem jsonb := cc_semanas(); lu text := p_lunes; t jsonb; tp record; soloapp jsonb := '[]'; solotpg jsonb := '[]';
        ap record; x record; mc text; mdia text; mplaca text; md int; dd int; usados text[] := '{}'; sug jsonb; sugtpg jsonb := '{}'; tarifa jsonb := cfg('tpg');
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
  for ap in select * from cc_app(lu) a where not exists (select 1 from tpg_reporte r where r.semana = lu and r.contenedor = a.c) loop
    md := 3; mc := null; mdia := null; mplaca := null; sug := null;
    for x in select z ->> 'c' c, z ->> 'dia' dia, z ->> 'placa' placa from jsonb_array_elements(solotpg) z where not ((z ->> 'c') = any (usados)) loop
      dd := cc_dist(ap.c, x.c);
      if dd < md or (dd = md and mc is not null and x.placa = ap.placa and mplaca is distinct from ap.placa) then md := dd; mc := x.c; mdia := x.dia; mplaca := x.placa; end if;
    end loop;
    if mc is not null and md <= 2 then
      usados := usados || mc;
      sug := jsonb_build_object('c', mc, 'dia', mdia, 'placa', mplaca, 'd', md);
      sugtpg := sugtpg || jsonb_build_object(mc, jsonb_build_object('id', ap.id, 'c', ap.c, 'dia', ap.dia, 'placa', ap.placa, 'd', md));
    end if;
    soloapp := soloapp || (jsonb_build_object('id', ap.id, 'c', ap.raw, 'cn', ap.c, 'dia', ap.dia, 'placa', ap.placa, 'chofer', ap.chofer,
      'ruta', ap.o || ' → ' || ap.d, 'malo', ap.c !~ '^[A-Z]{4}[0-9]{7}$', 'iso', ap.c ~ '^[A-Z]{4}[0-9]{7}$' and not cont_ok(ap.c))
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
notify pgrst, 'reload schema';
