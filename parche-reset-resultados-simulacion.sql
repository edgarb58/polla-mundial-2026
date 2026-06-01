-- =========================================================
-- PARCHE: limpiar resultados de simulación / reiniciar torneo
-- =========================================================
-- Borra marcadores oficiales, deja partidos como no jugados,
-- reinicia puntos calculados y apaga el modo simulación.
-- No borra usuarios, participantes, pagos ni pronósticos.

create or replace function public.reset_tournament_results(clear_result_notifications boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_matches int := 0;
  v_predictions int := 0;
  v_bonus int := 0;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede reiniciar resultados';
  end if;

  update public.matches
     set home_score = null,
         away_score = null,
         finished = false;
  get diagnostics v_matches = row_count;

  update public.predictions
     set points = null;
  get diagnostics v_predictions = row_count;

  update public.bonus_predictions
     set points = null;
  get diagnostics v_bonus = row_count;

  update public.bonus_official
     set goleador = null,
         top1 = null,
         top2 = null,
         top3 = null,
         top4 = null
   where id = 1;

  update public.config
     set sim_now = null
   where id = 1;

  if clear_result_notifications then
    delete from public.notifications
     where kind = 'result'
        or title ilike 'Resultado:%'
        or title ilike 'Resultados bonus%';
  end if;

  return jsonb_build_object(
    'ok', true,
    'matches_reset', v_matches,
    'predictions_reset', v_predictions,
    'bonus_predictions_reset', v_bonus
  );
end;
$$;

grant execute on function public.reset_tournament_results(boolean) to authenticated;
