-- =========================================================
-- PARCHE V16 · Consulta pública organizada del Top 4
-- Polla Mundial 2026
-- =========================================================
-- Permite que cualquier participante aprobado consulte el Top 4
-- de los demás usuarios cuando ya cerró el plazo del Top 4.
-- Los administradores pueden consultar siempre.

create or replace function public.get_top4_predictions()
returns table (
  user_id uuid,
  nombre text,
  username text,
  top1 text,
  top2 text,
  top3 text,
  top4 text,
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

  select
    coalesce(p.is_admin,false),
    coalesce(p.approval_status = 'approved', false)
  into requester_is_admin, requester_approved
  from public.profiles p
  where p.id = requester;

  if requester_is_admin is not true and requester_approved is not true then
    raise exception 'Solo participantes aprobados pueden consultar el Top 4';
  end if;

  select c.top4_deadline
  into deadline
  from public.config c
  where c.id = 1;

  -- Los administradores pueden consultar siempre.
  -- Los participantes consultan cuando ya cerró el plazo del Top 4.
  if requester_is_admin is not true and public.effective_now() < deadline then
    raise exception 'El Top 4 de los demás usuarios estará disponible cuando cierre el plazo';
  end if;

  return query
  select
    p.id as user_id,
    p.nombre::text as nombre,
    p.username::text as username,
    b.top1::text as top1,
    b.top2::text as top2,
    b.top3::text as top3,
    b.top4::text as top4,
    b.updated_at
  from public.profiles p
  left join public.bonus_predictions b on b.user_id = p.id
  where coalesce(p.is_admin,false) = true
     or coalesce(p.approval_status,'pending') = 'approved'
  order by
    case when coalesce(trim(b.top1),'') <> ''
       or coalesce(trim(b.top2),'') <> ''
       or coalesce(trim(b.top3),'') <> ''
       or coalesce(trim(b.top4),'') <> '' then 0 else 1 end,
    p.nombre,
    p.username;
end;
$$;

grant execute on function public.get_top4_predictions() to authenticated;

-- Prueba rápida opcional después de ejecutarlo:
-- select * from public.get_top4_predictions();
