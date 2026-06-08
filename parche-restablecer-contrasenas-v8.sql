-- =========================================================
-- PARCHE V8 · Restablecer contraseñas desde Admin
-- Polla Mundial 2026
-- =========================================================
-- Ejecutar en Supabase → SQL Editor → New query → Run.
-- Crea una función RPC segura para que SOLO administradores
-- puedan asignar una contraseña temporal a participantes.

create extension if not exists pgcrypto with schema extensions;

create or replace function public.admin_reset_user_password(
  target_user_id uuid,
  new_password text
)
returns void
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  requester uuid := auth.uid();
  requester_is_admin boolean := false;
  target_is_admin boolean := false;
begin
  if requester is null then
    raise exception 'No autenticado';
  end if;

  select coalesce(p.is_admin,false)
    into requester_is_admin
  from public.profiles p
  where p.id = requester;

  if requester_is_admin is not true then
    raise exception 'Solo un administrador puede restablecer contraseñas';
  end if;

  if target_user_id is null then
    raise exception 'Usuario destino inválido';
  end if;

  if target_user_id = requester then
    raise exception 'No puedes restablecer tu propia contraseña desde este panel';
  end if;

  if length(coalesce(new_password,'')) < 6 then
    raise exception 'La contraseña debe tener mínimo 6 caracteres';
  end if;

  if not exists (select 1 from public.profiles p where p.id = target_user_id) then
    raise exception 'El participante no existe';
  end if;

  select coalesce(p.is_admin,false)
    into target_is_admin
  from public.profiles p
  where p.id = target_user_id;

  if target_is_admin is true then
    raise exception 'No se puede restablecer la contraseña de otro administrador desde este panel';
  end if;

  if not exists (select 1 from auth.users u where u.id = target_user_id) then
    raise exception 'La cuenta de acceso no existe en Auth';
  end if;

  update auth.users
  set encrypted_password = extensions.crypt(new_password, extensions.gen_salt('bf')),
      updated_at = now(),
      recovery_sent_at = null
  where id = target_user_id;

  insert into public.notifications (user_id, title, body, kind)
  values (
    target_user_id,
    'Contraseña restablecida',
    'El administrador restableció tu contraseña. Ingresa con la clave temporal y cámbiala desde Perfil.',
    'admin'
  );
end;
$$;

grant execute on function public.admin_reset_user_password(uuid,text) to authenticated;
