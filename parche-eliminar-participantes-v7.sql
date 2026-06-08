-- ============================================================================
-- PARCHE V7 · Eliminar participantes registrados/aprobados desde Admin
-- Polla Mundial 2026 · Ejecutar en Supabase > SQL Editor > New query
-- ============================================================================
-- Qué hace:
-- - Crea una función segura que solo puede ejecutar un administrador.
-- - Elimina al participante de Auth y de profiles.
-- - Limpia sus pronósticos, bonus y lecturas/notificaciones asociadas.
-- - No permite que el admin se elimine a sí mismo desde la app.
-- - No permite eliminar otros administradores desde la app, por seguridad.

create or replace function public.admin_delete_participant(target_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_profile public.profiles%rowtype;
  v_deleted_auth int := 0;
  v_deleted_profile int := 0;
  v_deleted_predictions int := 0;
  v_deleted_bonus int := 0;
  v_deleted_reads int := 0;
  v_deleted_notifications int := 0;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede eliminar participantes';
  end if;

  if target_user_id is null then
    raise exception 'Usuario inválido';
  end if;

  if target_user_id = auth.uid() then
    raise exception 'No puedes eliminar tu propio usuario desde la app';
  end if;

  select * into v_profile
  from public.profiles
  where id = target_user_id;

  if not found then
    raise exception 'El participante no existe o ya fue eliminado';
  end if;

  if coalesce(v_profile.is_admin, false) then
    raise exception 'Por seguridad no se puede eliminar otro administrador desde la app';
  end if;

  -- Evita que una FK approved_by bloquee la eliminación del perfil.
  update public.profiles
     set approved_by = null
   where approved_by = target_user_id;

  delete from public.notification_reads
   where user_id = target_user_id;
  get diagnostics v_deleted_reads = row_count;

  delete from public.notifications
   where user_id = target_user_id;
  get diagnostics v_deleted_notifications = row_count;

  delete from public.predictions
   where user_id = target_user_id;
  get diagnostics v_deleted_predictions = row_count;

  delete from public.bonus_predictions
   where user_id = target_user_id;
  get diagnostics v_deleted_bonus = row_count;

  -- Borra el perfil por si la cuenta Auth no existiera por algún registro incompleto.
  delete from public.profiles
   where id = target_user_id;
  get diagnostics v_deleted_profile = row_count;

  -- Borra la cuenta de autenticación para que el usuario no pueda volver a entrar
  -- y para liberar el usuario/email interno si se quiere registrar de nuevo.
  delete from auth.users
   where id = target_user_id;
  get diagnostics v_deleted_auth = row_count;

  return jsonb_build_object(
    'ok', true,
    'deleted_user_id', target_user_id,
    'username', v_profile.username,
    'nombre', v_profile.nombre,
    'deleted_auth', v_deleted_auth,
    'deleted_profile', v_deleted_profile,
    'deleted_predictions', v_deleted_predictions,
    'deleted_bonus', v_deleted_bonus,
    'deleted_notification_reads', v_deleted_reads,
    'deleted_targeted_notifications', v_deleted_notifications
  );
end;
$$;

revoke all on function public.admin_delete_participant(uuid) from public;
grant execute on function public.admin_delete_participant(uuid) to authenticated;
