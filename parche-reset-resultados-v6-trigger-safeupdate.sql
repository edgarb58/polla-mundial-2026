-- ============================================================================
-- PARCHE V6 · Reset resultados + corrección trigger bonus compatible Safe Update
-- Polla Mundial 2026
-- Ejecutar en Supabase > SQL Editor > New query > Run
-- Corrige: "UPDATE requires a WHERE clause" causado por recompute_bonus().
-- No borra usuarios, aprobaciones, pagos ni pronósticos.
-- ============================================================================

-- 1) Reemplazar el trigger de bonus para que SIEMPRE tenga WHERE.
-- El error persistía porque al limpiar bonus_official se disparaba este trigger,
-- y la versión original hacía: update bonus_predictions set points = ... sin WHERE.
create or replace function public.recompute_bonus()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  c public.config%rowtype;
begin
  select * into c from public.config where id = 1;

  update public.bonus_predictions b
     set points =
        (case when b.goleador is not null and b.goleador = NEW.goleador
              then c.pts_goleador else 0 end)
      + (case when b.top1 is not null and b.top1 in (NEW.top1,NEW.top2,NEW.top3,NEW.top4) then c.pts_top4_each else 0 end)
      + (case when b.top2 is not null and b.top2 in (NEW.top1,NEW.top2,NEW.top3,NEW.top4) then c.pts_top4_each else 0 end)
      + (case when b.top3 is not null and b.top3 in (NEW.top1,NEW.top2,NEW.top3,NEW.top4) then c.pts_top4_each else 0 end)
      + (case when b.top4 is not null and b.top4 in (NEW.top1,NEW.top2,NEW.top3,NEW.top4) then c.pts_top4_each else 0 end)
   where b.user_id is not null;

  return NEW;
end;
$$;

-- Asegurar que el trigger use la función corregida.
drop trigger if exists trg_recompute_bonus on public.bonus_official;
create trigger trg_recompute_bonus
after update on public.bonus_official
for each row execute function public.recompute_bonus();

-- 2) Reemplazar también el trigger de partidos con WHERE explícito.
create or replace function public.recompute_match()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  update public.predictions p
     set points = public.score_one(p.home_pred, p.away_pred, NEW.home_score, NEW.away_score)
   where p.match_id = NEW.id;

  return NEW;
end;
$$;

drop trigger if exists trg_recompute_match on public.matches;
create trigger trg_recompute_match
after update of home_score, away_score on public.matches
for each row execute function public.recompute_match();

-- 3) Eliminar versiones anteriores para evitar que la app llame una firma vieja.
drop function if exists public.reset_tournament_results(boolean);
drop function if exists public.reset_tournament_results();
drop function if exists public.reset_tournament_results_v4();
drop function if exists public.reset_tournament_results_v5();
drop function if exists public.reset_tournament_results_v6();

-- 4) Crear la función definitiva de limpieza.
create or replace function public.reset_tournament_results_v6()
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
  -- Solo administradores.
  if not exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_admin = true
  ) then
    raise exception 'Solo un administrador puede reiniciar resultados';
  end if;

  -- Reset de partidos. El update dispara recompute_match(), ya corregido con WHERE.
  update public.matches
     set home_score = null,
         away_score = null,
         finished = false
   where id >= 0;
  get diagnostics v_matches = row_count;

  -- Borrar puntos de pronósticos sin borrar pronósticos.
  update public.predictions
     set points = null
   where id >= 0;
  get diagnostics v_predictions = row_count;

  -- Borrar puntos bonus sin borrar apuestas bonus.
  update public.bonus_predictions
     set points = null
   where user_id is not null;
  get diagnostics v_bonus_predictions = row_count;

  -- Borrar resultado oficial bonus. Este update dispara recompute_bonus(), ya corregido con WHERE.
  update public.bonus_official
     set goleador = null,
         top1 = null,
         top2 = null,
         top3 = null,
         top4 = null
   where id = 1;

  -- Apagar modo simulación.
  update public.config
     set sim_now = null
   where id = 1;

  -- Limpiar notificaciones de resultados de prueba.
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
    'version', 'v6-trigger-safeupdate',
    'matches_reset', v_matches,
    'predictions_reset', v_predictions,
    'bonus_predictions_reset', v_bonus_predictions,
    'notifications_deleted', v_notifications
  );
end;
$$;

grant execute on function public.reset_tournament_results_v6() to authenticated;

-- 5) Compatibilidad con los botones HTML actuales.
create or replace function public.reset_tournament_results_v4()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  return public.reset_tournament_results_v6();
end;
$$;

grant execute on function public.reset_tournament_results_v4() to authenticated;

create or replace function public.reset_tournament_results_v5()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  return public.reset_tournament_results_v6();
end;
$$;

grant execute on function public.reset_tournament_results_v5() to authenticated;

create or replace function public.reset_tournament_results(clear_result_notifications boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  return public.reset_tournament_results_v6();
end;
$$;

grant execute on function public.reset_tournament_results(boolean) to authenticated;

notify pgrst, 'reload schema';

-- 6) Prueba opcional desde el SQL Editor después de guardar:
-- select public.recompute_bonus is not null;
-- La limpieza real debe ejecutarse desde la app iniciando sesión como admin,
-- porque la función valida auth.uid().
