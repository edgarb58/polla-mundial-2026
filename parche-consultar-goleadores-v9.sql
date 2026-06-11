-- =========================================================
-- PARCHE V9 · Consulta pública de apuestas de goleador
-- Polla Mundial 2026
-- =========================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run.
-- Permite que participantes aprobados consulten las apuestas
-- de goleador de todos cuando ya cerró el plazo de goleador.
-- No permite editar apuestas ajenas ni revela Top 4.

create or replace function public.get_goleador_predictions()
returns table (
  user_id uuid,
  nombre text,
  username text,
  goleador text,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  requester uuid := auth.uid();
  requester_is_admin boolean := false;
  requester_approved boolean := false;
  deadline timestamptz;
begin
  if requester is null then
    raise exception 'No autenticado';
  end if;

  select coalesce(p.is_admin,false), coalesce(p.is_approved,false)
    into requester_is_admin, requester_approved
  from public.profiles p
  where p.id = requester;

  if requester_is_admin is not true and requester_approved is not true then
    raise exception 'Solo participantes aprobados pueden consultar las apuestas de goleador';
  end if;

  select c.goleador_deadline
    into deadline
  from public.config c
  where c.id = 1;

  if requester_is_admin is not true and public.effective_now() < deadline then
    raise exception 'Las apuestas de goleador estarán disponibles cuando cierre el plazo';
  end if;

  return query
  select
    p.id as user_id,
    p.nombre::text as nombre,
    p.username::text as username,
    b.goleador::text as goleador,
    b.updated_at
  from public.bonus_predictions b
  join public.profiles p on p.id = b.user_id
  where coalesce(p.is_approved,false) = true
    and coalesce(trim(b.goleador),'') <> ''
  order by lower(trim(b.goleador)), p.nombre, p.username;
end;
$$;

grant execute on function public.get_goleador_predictions() to authenticated;
