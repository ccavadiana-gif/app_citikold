-- Corrección del puente al dashboard: marcar los viajes como enviados (error: column reference "estado" is ambiguous).
-- Se puede ejecutar varias veces.
drop function if exists f_puente_marcar(text, text, text);
create or replace function f_puente_marcar(p_id text, p_estado text, p_err text) returns jsonb language plpgsql as $$
begin
  if p_estado not in ('OK','OK1','ERR') then perform e('Estado no válido.'); end if;
  update viajes set puente = p_estado where id = p_id;
  if not found then perform e('No se encontró el viaje.'); end if;
  if p_estado = 'ERR' then insert into puente_pendientes (id_viaje, error) values (p_id, left(coalesce(p_err, ''), 300)); end if;
  return 'true';
end $$;
revoke all on function f_puente_marcar(text, text, text) from public, anon, authenticated;
notify pgrst, 'reload schema';
