-- =============================================================
-- V10 · Consulta de faltantes de pronóstico por día
-- Permite al administrador ver qué participantes aprobados NO han
-- ingresado marcador para los partidos de una fecha determinada.
-- No revela el marcador pronosticado: solo informa si existe o no.
-- =============================================================

create or replace function public.admin_prediction_status_for_day(target_date date default null)
returns table (
  match_id bigint,
  kickoff timestamptz,
  home_team text,
  away_team text,
  user_id uuid,
  nombre text,
  username text,
  telefono text,
  cedula text,
  has_prediction boolean,
  prediction_updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  d date;
begin
  if not public.is_admin() then
    raise exception 'Solo el administrador puede consultar faltantes de pronósticos';
  end if;

  d := coalesce(target_date, (public.effective_now() at time zone 'America/Bogota')::date);

  return query
  with day_matches as (
    select m.id, m.kickoff, m.home_team, m.away_team
    from public.matches m
    where (m.kickoff at time zone 'America/Bogota')::date = d
  ), approved_users as (
    select p.id, p.nombre, p.username, p.telefono, p.cedula
    from public.profiles p
    where coalesce(p.is_admin, false) = false
      and coalesce(p.approval_status, 'pending') = 'approved'
  )
  select
    dm.id as match_id,
    dm.kickoff,
    dm.home_team,
    dm.away_team,
    au.id as user_id,
    au.nombre,
    au.username,
    au.telefono,
    au.cedula,
    (pr.id is not null) as has_prediction,
    pr.updated_at as prediction_updated_at
  from day_matches dm
  cross join approved_users au
  left join public.predictions pr
    on pr.match_id = dm.id
   and pr.user_id = au.id
  order by dm.kickoff asc, au.nombre asc, au.username asc;
end;
$$;

revoke all on function public.admin_prediction_status_for_day(date) from public;
grant execute on function public.admin_prediction_status_for_day(date) to authenticated;

-- Prueba opcional en SQL Editor, estando logueado como admin en la app:
-- select * from public.admin_prediction_status_for_day(current_date);
