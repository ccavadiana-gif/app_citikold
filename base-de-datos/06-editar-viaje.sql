-- Editar un viaje desde Historial (reemplaza corregir la hoja a mano). Solo administrador. Queda en auditoría.
-- Se puede ejecutar varias veces.
create or replace function f_viaje_editar(p_id text, o jsonb) returns jsonb language plpgsql as $$
declare v viajes; n viajes; p placas; c choferes; cambios text[] := '{}'; k text; i int; tt timestamptz[];
begin
  select * into v from viajes where id = p_id for update;
  if v.id is null then perform e('No encontré ese viaje. Actualiza la pantalla.'); end if;
  if v.estado = 'anulado' then perform e('Ese viaje está anulado: no se puede editar.'); end if;
  n := v;
  if o ? 'turno' then
    n.turno := trim(o ->> 'turno');
    if not (n.turno = any (cfg_list('turnos'))) then perform e('Elige el turno de la lista.'); end if;
  end if;
  if o ? 'placa_id' and coalesce(o ->> 'placa_id', '') <> coalesce(v.placa_id, '') then
    select * into p from placas where id = o ->> 'placa_id';
    if p.id is null then perform e('Elige la placa de la lista.'); end if;
    n.placa_id := p.id; n.placa := trim(p.placa);
  end if;
  if o ? 'chofer_id' and coalesce(o ->> 'chofer_id', '') <> coalesce(v.chofer_id, '') then
    select * into c from choferes where id = o ->> 'chofer_id';
    if c.id is null then perform e('Elige el chofer de la lista.'); end if;
    n.chofer_id := c.id; n.chofer := trim(c.nombre);
  end if;
  if o ? 'origen' then n.origen := upper(lugar(o ->> 'origen')); end if;
  if o ? 'destino' then n.destino := upper(lugar(o ->> 'destino')); end if;
  perform check_ruta(n.proyecto, n.origen, n.destino);
  if o ? 'contenedor' then
    n.contenedor := norm(o ->> 'contenedor');
    if n.contenedor <> '' and n.contenedor !~ '^[A-Z]{4}[0-9]{7}$' then
      perform e('El contenedor debe tener 4 letras y 7 números, por ejemplo MSKU1234567.'); end if;
  end if;
  if o ? 'medida' then
    n.medida := trim(o ->> 'medida');
    if n.medida <> '' and not (n.medida = any (cfg_list('medidas'))) then perform e('Elige la medida de la lista.'); end if;
  end if;
  if o ? 'observaciones' then n.observaciones := left(trim(coalesce(o ->> 'observaciones', '')), 500); end if;
  for i in 1..6 loop
    if o ? ('t' || i) then
      case i when 1 then n.t1 := de_ms(o -> 't1'); when 2 then n.t2 := de_ms(o -> 't2'); when 3 then n.t3 := de_ms(o -> 't3');
             when 4 then n.t4 := de_ms(o -> 't4'); when 5 then n.t5 := de_ms(o -> 't5'); else n.t6 := de_ms(o -> 't6'); end case;
    end if;
  end loop;
  tt := array[n.t1, n.t2, n.t3, n.t4, n.t5, n.t6];
  for i in 2..6 loop
    if tt[i] is not null and tt[i-1] is null then perform e('Falta la hora del paso ' || (i-1) || '.'); end if;
    if tt[i] is not null and tt[i] < tt[i-1] then perform e('La hora del paso ' || i || ' es anterior a la del paso ' || (i-1) || '.'); end if;
  end loop;
  if v.estado = 'finalizado' and n.t6 is null then perform e('Un viaje finalizado necesita la hora del paso 6.'); end if;
  if n.t6 is not null and n.t6 > now() + interval '5 minutes' then perform e('La hora del paso 6 está en el futuro.'); end if;

  if n.turno is distinct from v.turno then cambios := cambios || ('turno ' || v.turno || ' → ' || n.turno); end if;
  if n.placa is distinct from v.placa then cambios := cambios || ('placa ' || v.placa || ' → ' || n.placa); end if;
  if n.chofer is distinct from v.chofer then cambios := cambios || ('chofer ' || v.chofer || ' → ' || n.chofer); end if;
  if n.origen is distinct from v.origen then cambios := cambios || ('origen ' || coalesce(nullif(v.origen, ''), '(vacío)') || ' → ' || coalesce(nullif(n.origen, ''), '(vacío)')); end if;
  if n.destino is distinct from v.destino then cambios := cambios || ('destino ' || coalesce(nullif(v.destino, ''), '(vacío)') || ' → ' || coalesce(nullif(n.destino, ''), '(vacío)')); end if;
  if n.contenedor is distinct from v.contenedor then cambios := cambios || ('contenedor ' || coalesce(nullif(v.contenedor, ''), '(vacío)') || ' → ' || coalesce(nullif(n.contenedor, ''), '(vacío)')); end if;
  if n.medida is distinct from v.medida then cambios := cambios || ('medida ' || coalesce(nullif(v.medida, ''), '(vacío)') || ' → ' || coalesce(nullif(n.medida, ''), '(vacío)')); end if;
  if n.observaciones is distinct from v.observaciones then cambios := cambios || 'observaciones'::text; end if;
  for i in 1..6 loop
    if (array[v.t1, v.t2, v.t3, v.t4, v.t5, v.t6])[i] is distinct from tt[i] then
      cambios := cambios || ('hora paso ' || i || ' ' || coalesce(to_char((array[v.t1, v.t2, v.t3, v.t4, v.t5, v.t6])[i] at time zone 'America/Guayaquil', 'DD/MM HH24:MI'), '(vacía)')
                             || ' → ' || coalesce(to_char(tt[i] at time zone 'America/Guayaquil', 'DD/MM HH24:MI'), '(vacía)'));
    end if;
  end loop;
  if array_length(cambios, 1) is null then perform e('No cambiaste nada.'); end if;

  update viajes set turno = n.turno, placa_id = n.placa_id, placa = n.placa, chofer_id = n.chofer_id, chofer = n.chofer,
         origen = n.origen, destino = n.destino, contenedor = n.contenedor, medida = n.medida, observaciones = n.observaciones,
         t1 = n.t1, t2 = n.t2, t3 = n.t3, t4 = n.t4, t5 = n.t5, t6 = n.t6
   where id = v.id;
  perform audit('viaje_editar', 'Editó el viaje de ' || v.placa || ' · ' || v.chofer || ' · ' || iso(coalesce(v.t6, v.creado)) || ': ' || array_to_string(cambios, ' · '));
  return jsonb_build_object('cambios', to_jsonb(cambios), 'puente', v.puente);
end $$;

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
  when 'api_viajeEditar' then perform auth(a ->> 0); return f_viaje_editar(a ->> 1, coalesce(a -> 2, '{}'));
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
revoke all on function f_viaje_editar(text, jsonb) from public, anon, authenticated;
revoke all on function api_core(text, jsonb) from public, anon, authenticated;
notify pgrst, 'reload schema';
