-- ============================================================================
-- PARCHE V2 · Aprobación de participantes y control de pagos
-- Polla Mundial 2026 · Ejecutar en Supabase > SQL Editor > New query
-- Compatible con la última versión del proyecto subida por el usuario.
-- ============================================================================

-- 1) Registro de migraciones para que este parche sea seguro si se ejecuta otra vez.
create table if not exists public.app_migrations (
  key text primary key,
  applied_at timestamptz not null default now()
);

-- 2) Nuevas columnas en profiles.
alter table public.profiles
  add column if not exists approval_status text not null default 'pending',
  add column if not exists payment_status text not null default 'debe',
  add column if not exists amount_due numeric(12,2) not null default 0,
  add column if not exists amount_paid numeric(12,2) not null default 0,
  add column if not exists payment_note text,
  add column if not exists approved_at timestamptz,
  add column if not exists approved_by uuid references public.profiles(id),
  add column if not exists payment_updated_at timestamptz;

-- 3) Validaciones de estado.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_approval_status_chk'
  ) then
    alter table public.profiles
      add constraint profiles_approval_status_chk
      check (approval_status in ('pending','approved','rejected'));
  end if;

  if not exists (
    select 1 from pg_constraint where conname = 'profiles_payment_status_chk'
  ) then
    alter table public.profiles
      add constraint profiles_payment_status_chk
      check (payment_status in ('debe','saldo_pendiente','pagado'));
  end if;
end $$;

-- 4) Primera ejecución: no bloquea usuarios que ya existían antes de instalar el control.
do $$
declare inserted_rows int;
begin
  insert into public.app_migrations(key) values ('approval_payments_v2')
  on conflict (key) do nothing;

  get diagnostics inserted_rows = row_count;

  if inserted_rows > 0 then
    update public.profiles
    set approval_status = 'approved',
        approved_at = coalesce(approved_at, now())
    where approval_status = 'pending';
  end if;

  update public.profiles
  set approval_status = 'approved',
      approved_at = coalesce(approved_at, now())
  where is_admin = true;
end $$;

-- 5) Función: usuario aprobado o admin.
create or replace function public.is_participant_approved(u uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select p.is_admin or p.approval_status = 'approved'
    from public.profiles p
    where p.id = u
  ), false);
$$;

grant execute on function public.is_participant_approved(uuid) to authenticated, anon;

-- 6) Trigger de registro: los nuevos usuarios entran como pendientes.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  insert into public.profiles (
    id, username, nombre, cedula, telefono,
    approval_status, payment_status, amount_due, amount_paid
  )
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1)),
    coalesce(new.raw_user_meta_data->>'nombre', ''),
    new.raw_user_meta_data->>'cedula',
    new.raw_user_meta_data->>'telefono',
    'pending',
    'debe',
    0,
    0
  )
  on conflict (id) do update set
    username = excluded.username,
    nombre = excluded.nombre,
    cedula = excluded.cedula,
    telefono = excluded.telefono;

  return new;
end;
$$;

drop trigger if exists trg_new_user on auth.users;
create trigger trg_new_user
after insert on auth.users
for each row
execute function public.handle_new_user();

-- 7) Seguridad: el usuario NO se puede autoaprobar ni cambiar pagos.
-- Solo admin modifica profiles. La lectura sigue abierta porque la app usa nombres
-- en tabla, ranking y pronósticos visibles.
drop policy if exists p_profiles_upd on public.profiles;
drop policy if exists p_profiles_admin on public.profiles;
create policy p_profiles_admin on public.profiles
for all
using (public.is_admin())
with check (public.is_admin());

-- 8) Seguridad: solo participantes aprobados pueden crear/editar pronósticos.
drop policy if exists p_pred_ins on public.predictions;
create policy p_pred_ins on public.predictions
for insert
with check (
  auth.uid() = user_id
  and public.is_participant_approved(user_id)
  and not public.match_locked(match_id)
);

drop policy if exists p_pred_upd on public.predictions;
create policy p_pred_upd on public.predictions
for update
using (
  auth.uid() = user_id
  and public.is_participant_approved(user_id)
  and not public.match_locked(match_id)
)
with check (
  auth.uid() = user_id
  and public.is_participant_approved(user_id)
  and not public.match_locked(match_id)
);

-- 9) Seguridad: solo participantes aprobados pueden crear/editar bonus.
drop policy if exists p_bonus_ins on public.bonus_predictions;
create policy p_bonus_ins on public.bonus_predictions
for insert
with check (
  auth.uid() = user_id
  and public.is_participant_approved(user_id)
);

drop policy if exists p_bonus_upd on public.bonus_predictions;
create policy p_bonus_upd on public.bonus_predictions
for update
using (
  auth.uid() = user_id
  and public.is_participant_approved(user_id)
)
with check (
  auth.uid() = user_id
  and public.is_participant_approved(user_id)
);

-- 10) Tabla de posiciones: solo participantes aprobados y admins.
create or replace view public.leaderboard as
  select
    p.id                                   as user_id,
    p.username,
    p.nombre,
    coalesce(sum(pr.points), 0)
      + coalesce(max(b.points), 0)         as total_points,
    coalesce(sum((pr.points = (select pts_exact from public.config where id=1))::int), 0) as exactos,
    coalesce(count(pr.points), 0)          as partidos_calificados,
    coalesce(max(b.points), 0)             as bonus_points
  from public.profiles p
  left join public.predictions pr on pr.user_id = p.id
  left join public.bonus_predictions b on b.user_id = p.id
  where p.is_admin = true or p.approval_status = 'approved'
  group by p.id, p.username, p.nombre;

grant select on public.leaderboard to anon, authenticated;

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

