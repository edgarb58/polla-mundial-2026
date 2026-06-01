-- ============================================================================
-- PARCHE V4 · Reinicio seguro de resultados de simulación
-- Polla Mundial 2026
-- Ejecutar en Supabase > SQL Editor > New query > Run
-- No borra usuarios, aprobaciones, pagos ni pronósticos.
-- ============================================================================

create or replace function public.reset_tournament_results_v4()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_matches int := 0;
  v_predictions int := 0;
  v_bonus_predictions int := 0;
  v_notifications int := 0;
begin
  -- Validación directa de administrador. Evita depender de otra función RPC.
  if not exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_admin = true
  ) then
    raise exception 'Solo un administrador puede reiniciar resultados';
  end if;

  -- 1) Dejar todos los partidos como no jugados.
  update public.matches
     set home_score = null,
         away_score = null,
         finished = false;
  get diagnostics v_matches = row_count;

  -- 2) Borrar puntos calculados de pronósticos. No borra los pronósticos.
  update public.predictions
     set points = null;
  get diagnostics v_predictions = row_count;

  -- 3) Borrar puntos bonus calculados. No borra apuestas bonus de usuarios.
  update public.bonus_predictions
     set points = null;
  get diagnostics v_bonus_predictions = row_count;

  -- 4) Borrar resultados oficiales del bonus.
  update public.bonus_official
     set goleador = null,
         top1 = null,
         top2 = null,
         top3 = null,
         top4 = null
   where id = 1;

  -- 5) Apagar modo simulación.
  update public.config
     set sim_now = null
   where id = 1;

  -- 6) Limpiar notificaciones de resultados de prueba.
  -- Primero elimina lecturas por compatibilidad con instalaciones sin ON DELETE CASCADE.
  delete from public.notification_reads nr
  using public.notifications n
  where nr.notification_id = n.id
    and (
      n.kind = 'result'
      or n.title ilike 'Resultado:%'
      or n.title ilike 'Resultados bonus%'
    );

  delete from public.notifications n
  where n.kind = 'result'
     or n.title ilike 'Resultado:%'
     or n.title ilike 'Resultados bonus%';
  get diagnostics v_notifications = row_count;

  return jsonb_build_object(
    'ok', true,
    'matches_reset', v_matches,
    'predictions_reset', v_predictions,
    'bonus_predictions_reset', v_bonus_predictions,
    'notifications_deleted', v_notifications
  );
end;
$$;

grant execute on function public.reset_tournament_results_v4() to authenticated;

-- Forzar recarga del cache de funciones de PostgREST/Supabase.
notify pgrst, 'reload schema';

-- Compatibilidad con versiones anteriores del HTML que llaman reset_tournament_results(boolean).
create or replace function public.reset_tournament_results(clear_result_notifications boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  return public.reset_tournament_results_v4();
end;
$$;

grant execute on function public.reset_tournament_results(boolean) to authenticated;
notify pgrst, 'reload schema';
