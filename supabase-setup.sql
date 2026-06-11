-- ============================================================================
--  POLLA MUNDIAL 2026  ·  Configuración del Backend (Supabase / PostgreSQL)
--  Ejecuta TODO este script en:  Supabase  ->  SQL Editor  ->  New query
--  Es idempotente: puedes volver a correrlo sin romper nada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Limpieza opcional (descomenta SOLO si quieres reinstalar desde cero)
-- ----------------------------------------------------------------------------
-- drop table if exists predictions, bonus_predictions, bonus_official,
--   notifications, notification_reads, matches, teams, profiles, config cascade;
-- drop function if exists effective_now, score_one, recompute_match,
--   recompute_bonus, handle_new_user, leaderboard_rows cascade;

-- ----------------------------------------------------------------------------
-- 1. TABLAS
-- ----------------------------------------------------------------------------

-- Configuración global (fila única, id = 1)
create table if not exists config (
  id            int primary key default 1,
  lock_minutes  int  not null default 10,
  pts_exact     int  not null default 6,
  pts_result    int  not null default 3,
  pts_partial   int  not null default 1,
  pts_goleador  int  not null default 10,
  pts_top4_each int  not null default 5,
  goleador_deadline timestamptz not null default '2026-06-11T19:00:00Z',
  top4_deadline     timestamptz not null default '2026-06-28T00:00:00Z',
  sim_now       timestamptz,                 -- para PRUEBAS: simula la hora actual
  constraint config_singleton check (id = 1)
);
insert into config (id) values (1) on conflict (id) do nothing;

-- Registro de migraciones internas de la app
create table if not exists app_migrations (
  key text primary key,
  applied_at timestamptz not null default now()
);

-- Perfiles (extiende auth.users)
create table if not exists profiles (
  id        uuid primary key references auth.users(id) on delete cascade,
  username  text unique not null,
  nombre    text not null,
  cedula    text,
  telefono  text,
  is_admin  boolean not null default false,
  approval_status text not null default 'pending' check (approval_status in ('pending','approved','rejected')),
  payment_status  text not null default 'debe' check (payment_status in ('debe','saldo_pendiente','pagado')),
  amount_due       numeric(12,2) not null default 0,
  amount_paid      numeric(12,2) not null default 0,
  payment_note     text,
  approved_at      timestamptz,
  approved_by      uuid references profiles(id),
  payment_updated_at timestamptz,
  created_at timestamptz not null default now()
);

-- Catálogo de selecciones (nombre + código de bandera)
create table if not exists teams (
  name text primary key,
  flag text not null
);

-- Partidos (grupos + eliminatorias que publique el admin)
create table if not exists matches (
  id         bigint generated always as identity primary key,
  round      text not null default 'group',  -- group|r32|r16|qf|sf|third|final
  group_code text,
  jornada    int,
  home_team  text not null,
  away_team  text not null,
  kickoff    timestamptz not null,
  venue      text,
  home_score int,
  away_score int,
  finished   boolean not null default false,
  created_at timestamptz not null default now()
);

-- Pronósticos de marcadores
create table if not exists predictions (
  id        bigint generated always as identity primary key,
  user_id   uuid not null references profiles(id) on delete cascade,
  match_id  bigint not null references matches(id) on delete cascade,
  home_pred int not null default 0,
  away_pred int not null default 0,
  points    int,
  updated_at timestamptz not null default now(),
  unique (user_id, match_id)
);

-- Pronósticos bonus (goleador + top 4)
create table if not exists bonus_predictions (
  user_id  uuid primary key references profiles(id) on delete cascade,
  goleador text,
  top1 text, top2 text, top3 text, top4 text,
  points   int,
  updated_at timestamptz not null default now()
);

-- Resultado oficial de los bonus (fila única, id = 1)
create table if not exists bonus_official (
  id int primary key default 1,
  goleador text,
  top1 text, top2 text, top3 text, top4 text,
  constraint bonus_official_singleton check (id = 1)
);
insert into bonus_official (id) values (1) on conflict (id) do nothing;

-- Notificaciones (user_id NULL = anuncio para todos)
create table if not exists notifications (
  id        bigint generated always as identity primary key,
  user_id   uuid references profiles(id) on delete cascade,
  title     text not null,
  body      text,
  kind      text not null default 'info',    -- info|match|result|admin
  created_at timestamptz not null default now()
);
create table if not exists notification_reads (
  notification_id bigint references notifications(id) on delete cascade,
  user_id uuid references profiles(id) on delete cascade,
  primary key (notification_id, user_id)
);

-- ----------------------------------------------------------------------------
-- 2. FUNCIONES AUXILIARES
-- ----------------------------------------------------------------------------

-- Hora "efectiva": usa sim_now si está puesta (modo prueba), si no la hora real.
create or replace function effective_now() returns timestamptz
language sql stable as $$
  select coalesce((select sim_now from config where id = 1), now());
$$;

-- ¿Está bloqueado un partido? (ya pasó el límite de edición)
create or replace function match_locked(m_id bigint) returns boolean
language sql stable as $$
  select effective_now() >= (
    select kickoff - make_interval(mins => (select lock_minutes from config where id=1))
    from matches where id = m_id
  );
$$;

-- ¿Ya empezó (o terminó) el partido? -> habilita ver pronósticos ajenos
create or replace function match_started(m_id bigint) returns boolean
language sql stable as $$
  select coalesce(
    (select finished from matches where id = m_id), false)
    or effective_now() >= (select kickoff from matches where id = m_id);
$$;

-- Puntaje de un pronóstico individual
create or replace function score_one(
  hp int, ap int, hs int, as_ int
) returns int language plpgsql stable as $$
declare c config%rowtype;
begin
  select * into c from config where id = 1;
  if hs is null or as_ is null then return null; end if;
  if hp = hs and ap = as_ then return c.pts_exact; end if;
  if sign(hp - ap) = sign(hs - as_) then return c.pts_result; end if;
  if hp = hs or ap = as_ then return c.pts_partial; end if;
  return 0;
end; $$;

-- Recalcula puntos de TODOS los pronósticos de un partido (al cargar resultado)
create or replace function recompute_match() returns trigger
language plpgsql security definer as $$
begin
  update predictions p
     set points = score_one(p.home_pred, p.away_pred, NEW.home_score, NEW.away_score)
   where p.match_id = NEW.id;
  return NEW;
end; $$;

drop trigger if exists trg_recompute_match on matches;
create trigger trg_recompute_match
  after update of home_score, away_score on matches
  for each row execute function recompute_match();

-- Recalcula puntos bonus de todos (al cargar el resultado oficial de bonus)
create or replace function recompute_bonus() returns trigger
language plpgsql security definer as $$
declare c config%rowtype;
begin
  select * into c from config where id = 1;
  update bonus_predictions b set points =
      (case when b.goleador is not null and b.goleador = NEW.goleador
            then c.pts_goleador else 0 end)
    + (case when b.top1 is not null and b.top1 in (NEW.top1,NEW.top2,NEW.top3,NEW.top4) then c.pts_top4_each else 0 end)
    + (case when b.top2 is not null and b.top2 in (NEW.top1,NEW.top2,NEW.top3,NEW.top4) then c.pts_top4_each else 0 end)
    + (case when b.top3 is not null and b.top3 in (NEW.top1,NEW.top2,NEW.top3,NEW.top4) then c.pts_top4_each else 0 end)
    + (case when b.top4 is not null and b.top4 in (NEW.top1,NEW.top2,NEW.top3,NEW.top4) then c.pts_top4_each else 0 end);
  return NEW;
end; $$;

drop trigger if exists trg_recompute_bonus on bonus_official;
create trigger trg_recompute_bonus
  after update on bonus_official
  for each row execute function recompute_bonus();

-- Crea el perfil automáticamente cuando alguien se registra (auth.users)
create or replace function handle_new_user() returns trigger
language plpgsql security definer as $$
begin
  insert into profiles (
    id, username, nombre, cedula, telefono,
    approval_status, payment_status, amount_due, amount_paid
  )
  values (
    NEW.id,
    coalesce(NEW.raw_user_meta_data->>'username', split_part(NEW.email,'@',1)),
    coalesce(NEW.raw_user_meta_data->>'nombre', ''),
    NEW.raw_user_meta_data->>'cedula',
    NEW.raw_user_meta_data->>'telefono',
    'pending',
    'debe',
    0,
    0
  );
  return NEW;
end; $$;

drop trigger if exists trg_new_user on auth.users;
create trigger trg_new_user
  after insert on auth.users
  for each row execute function handle_new_user();

-- ----------------------------------------------------------------------------
-- 3. SEGURIDAD (Row Level Security)  ·  el corazón anti-trampa
-- ----------------------------------------------------------------------------
alter table profiles            enable row level security;
alter table teams               enable row level security;
alter table matches             enable row level security;
alter table predictions         enable row level security;
alter table bonus_predictions   enable row level security;
alter table bonus_official      enable row level security;
alter table config              enable row level security;
alter table notifications       enable row level security;
alter table notification_reads  enable row level security;

-- atajo: ¿el usuario actual es admin?
create or replace function is_admin() returns boolean
language sql stable security definer as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false);
$$;

-- atajo: ¿el usuario actual está aprobado o es admin?
create or replace function is_participant_approved(u uuid default auth.uid()) returns boolean
language sql stable security definer as $$
  select coalesce((
    select p.is_admin or p.approval_status = 'approved'
    from profiles p
    where p.id = u
  ), false);
$$;

-- PROFILES: todos leen (para tabla/ranking); solo admin modifica aprobación y pagos.
drop policy if exists p_profiles_sel on profiles;
create policy p_profiles_sel on profiles for select using (true);
drop policy if exists p_profiles_upd on profiles;
drop policy if exists p_profiles_admin on profiles;
create policy p_profiles_admin on profiles for all using (is_admin()) with check (is_admin());

-- TEAMS y MATCHES: lectura para todos; escritura solo admin.
drop policy if exists p_teams_sel on teams;
create policy p_teams_sel on teams for select using (true);
drop policy if exists p_teams_adm on teams;
create policy p_teams_adm on teams for all using (is_admin()) with check (is_admin());

drop policy if exists p_matches_sel on matches;
create policy p_matches_sel on matches for select using (true);
drop policy if exists p_matches_adm on matches;
create policy p_matches_adm on matches for all using (is_admin()) with check (is_admin());

-- CONFIG: todos leen; solo admin modifica.
drop policy if exists p_config_sel on config;
create policy p_config_sel on config for select using (true);
drop policy if exists p_config_adm on config;
create policy p_config_adm on config for all using (is_admin()) with check (is_admin());

-- PREDICTIONS  (lo más importante):
--  · Ver: las TUYAS siempre; las AJENAS solo cuando el partido YA ESTÁ CERRADO
--    (10 min antes del inicio), para que nadie copie pero todos puedan comparar.
--  · Crear/editar: solo las tuyas y SOLO si el partido no está bloqueado.
--  · 'points' lo pone el servidor (trigger), el cliente no puede tocarlo.
drop policy if exists p_pred_sel on predictions;
create policy p_pred_sel on predictions for select using (
  auth.uid() = user_id or match_locked(match_id) or is_admin()
);
drop policy if exists p_pred_ins on predictions;
create policy p_pred_ins on predictions for insert with check (
  auth.uid() = user_id and is_participant_approved(user_id) and not match_locked(match_id)
);
drop policy if exists p_pred_upd on predictions;
create policy p_pred_upd on predictions for update using (
  auth.uid() = user_id and is_participant_approved(user_id) and not match_locked(match_id)
) with check (
  auth.uid() = user_id and is_participant_approved(user_id) and not match_locked(match_id)
);

-- BONUS: ver propios siempre; ajenos solo tras el cierre. Editar antes del cierre.
drop policy if exists p_bonus_sel on bonus_predictions;
create policy p_bonus_sel on bonus_predictions for select using (
  auth.uid() = user_id or is_admin()
  or effective_now() >= (select top4_deadline from config where id=1)
);
drop policy if exists p_bonus_ins on bonus_predictions;
create policy p_bonus_ins on bonus_predictions for insert with check (auth.uid() = user_id and is_participant_approved(user_id));
drop policy if exists p_bonus_upd on bonus_predictions;
create policy p_bonus_upd on bonus_predictions for update using (auth.uid() = user_id and is_participant_approved(user_id))
  with check (auth.uid() = user_id and is_participant_approved(user_id));

drop policy if exists p_bonus_off_sel on bonus_official;
create policy p_bonus_off_sel on bonus_official for select using (true);
drop policy if exists p_bonus_off_adm on bonus_official;
create policy p_bonus_off_adm on bonus_official for all using (is_admin()) with check (is_admin());

-- NOTIFICATIONS: ves los anuncios globales y los tuyos; admin crea.
drop policy if exists p_notif_sel on notifications;
create policy p_notif_sel on notifications for select using (
  user_id is null or user_id = auth.uid() or is_admin()
);
drop policy if exists p_notif_adm on notifications;
create policy p_notif_adm on notifications for all using (is_admin()) with check (is_admin());

drop policy if exists p_nr_all on notification_reads;
create policy p_nr_all on notification_reads for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ----------------------------------------------------------------------------
-- 4. VISTA: tabla de posiciones (puntos de partidos + bonus)
-- ----------------------------------------------------------------------------
create or replace view leaderboard as
  select
    p.id                                   as user_id,
    p.username,
    p.nombre,
    coalesce(sum(pr.points), 0)
      + coalesce(max(b.points), 0)         as total_points,
    coalesce(sum((pr.points = (select pts_exact from config where id=1))::int), 0) as exactos,
    coalesce(count(pr.points), 0)          as partidos_calificados,
    coalesce(max(b.points), 0)             as bonus_points
  from profiles p
  left join predictions pr on pr.user_id = p.id
  left join bonus_predictions b on b.user_id = p.id
  where p.is_admin = true or p.approval_status = 'approved'
  group by p.id, p.username, p.nombre;

grant select on leaderboard to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 5. DATOS SEMILLA  ·  48 selecciones + 72 partidos de fase de grupos
-- ----------------------------------------------------------------------------
insert into teams (name, flag) values
  ('México', 'mx'),
  ('Sudáfrica', 'za'),
  ('Corea del Sur', 'kr'),
  ('República Checa', 'cz'),
  ('Canadá', 'ca'),
  ('Bosnia y Herzegovina', 'ba'),
  ('Catar', 'qa'),
  ('Suiza', 'ch'),
  ('Brasil', 'br'),
  ('Marruecos', 'ma'),
  ('Haití', 'ht'),
  ('Escocia', 'gb-sct'),
  ('Estados Unidos', 'us'),
  ('Paraguay', 'py'),
  ('Australia', 'au'),
  ('Turquía', 'tr'),
  ('Alemania', 'de'),
  ('Curazao', 'cw'),
  ('Costa de Marfil', 'ci'),
  ('Ecuador', 'ec'),
  ('Países Bajos', 'nl'),
  ('Japón', 'jp'),
  ('Suecia', 'se'),
  ('Túnez', 'tn'),
  ('Bélgica', 'be'),
  ('Egipto', 'eg'),
  ('Irán', 'ir'),
  ('Nueva Zelanda', 'nz'),
  ('España', 'es'),
  ('Cabo Verde', 'cv'),
  ('Arabia Saudita', 'sa'),
  ('Uruguay', 'uy'),
  ('Francia', 'fr'),
  ('Senegal', 'sn'),
  ('Iraq', 'iq'),
  ('Noruega', 'no'),
  ('Argentina', 'ar'),
  ('Argelia', 'dz'),
  ('Austria', 'at'),
  ('Jordania', 'jo'),
  ('Portugal', 'pt'),
  ('RD Congo', 'cd'),
  ('Uzbekistán', 'uz'),
  ('Colombia', 'co'),
  ('Inglaterra', 'gb-eng'),
  ('Croacia', 'hr'),
  ('Ghana', 'gh'),
  ('Panamá', 'pa')
on conflict (name) do update set flag = excluded.flag;

-- Carga los partidos solo si la tabla está vacía (evita duplicar al re-ejecutar)
insert into matches (round, group_code, jornada, home_team, away_team, kickoff, venue)
select * from (values
  ('group', 'A', 1, 'México', 'Sudáfrica', '2026-06-11T19:00:00Z'::timestamptz, 'Ciudad de México'),
  ('group', 'A', 1, 'Corea del Sur', 'República Checa', '2026-06-12T02:00:00Z'::timestamptz, 'Guadalajara'),
  ('group', 'A', 2, 'República Checa', 'Sudáfrica', '2026-06-18T16:00:00Z'::timestamptz, 'Atlanta'),
  ('group', 'A', 2, 'México', 'Corea del Sur', '2026-06-19T01:00:00Z'::timestamptz, 'Guadalajara'),
  ('group', 'A', 3, 'República Checa', 'México', '2026-06-25T01:00:00Z'::timestamptz, 'Ciudad de México'),
  ('group', 'A', 3, 'Sudáfrica', 'Corea del Sur', '2026-06-25T01:00:00Z'::timestamptz, 'Monterrey'),
  ('group', 'B', 1, 'Canadá', 'Bosnia y Herzegovina', '2026-06-12T19:00:00Z'::timestamptz, 'Toronto'),
  ('group', 'B', 1, 'Catar', 'Suiza', '2026-06-13T19:00:00Z'::timestamptz, 'San Francisco'),
  ('group', 'B', 2, 'Suiza', 'Bosnia y Herzegovina', '2026-06-18T19:00:00Z'::timestamptz, 'Los Ángeles'),
  ('group', 'B', 2, 'Canadá', 'Catar', '2026-06-18T22:00:00Z'::timestamptz, 'Vancouver'),
  ('group', 'B', 3, 'Suiza', 'Canadá', '2026-06-24T19:00:00Z'::timestamptz, 'Vancouver'),
  ('group', 'B', 3, 'Bosnia y Herzegovina', 'Catar', '2026-06-24T19:00:00Z'::timestamptz, 'Seattle'),
  ('group', 'C', 1, 'Brasil', 'Marruecos', '2026-06-13T22:00:00Z'::timestamptz, 'Nueva York/NJ'),
  ('group', 'C', 1, 'Haití', 'Escocia', '2026-06-14T01:00:00Z'::timestamptz, 'Boston'),
  ('group', 'C', 2, 'Escocia', 'Marruecos', '2026-06-19T22:00:00Z'::timestamptz, 'Boston'),
  ('group', 'C', 2, 'Brasil', 'Haití', '2026-06-20T01:00:00Z'::timestamptz, 'Filadelfia'),
  ('group', 'C', 3, 'Escocia', 'Brasil', '2026-06-24T22:00:00Z'::timestamptz, 'Miami'),
  ('group', 'C', 3, 'Marruecos', 'Haití', '2026-06-24T22:00:00Z'::timestamptz, 'Atlanta'),
  ('group', 'D', 1, 'Estados Unidos', 'Paraguay', '2026-06-13T01:00:00Z'::timestamptz, 'Los Ángeles'),
  ('group', 'D', 1, 'Australia', 'Turquía', '2026-06-14T04:00:00Z'::timestamptz, 'Vancouver'),
  ('group', 'D', 2, 'Turquía', 'Paraguay', '2026-06-20T04:00:00Z'::timestamptz, 'San Francisco'),
  ('group', 'D', 2, 'Estados Unidos', 'Australia', '2026-06-19T19:00:00Z'::timestamptz, 'Seattle'),
  ('group', 'D', 3, 'Turquía', 'Estados Unidos', '2026-06-26T02:00:00Z'::timestamptz, 'Los Ángeles'),
  ('group', 'D', 3, 'Paraguay', 'Australia', '2026-06-26T02:00:00Z'::timestamptz, 'San Francisco'),
  ('group', 'E', 1, 'Alemania', 'Curazao', '2026-06-14T17:00:00Z'::timestamptz, 'Houston'),
  ('group', 'E', 1, 'Costa de Marfil', 'Ecuador', '2026-06-14T23:00:00Z'::timestamptz, 'Filadelfia'),
  ('group', 'E', 2, 'Alemania', 'Costa de Marfil', '2026-06-20T20:00:00Z'::timestamptz, 'Toronto'),
  ('group', 'E', 2, 'Ecuador', 'Curazao', '2026-06-21T00:00:00Z'::timestamptz, 'Kansas City'),
  ('group', 'E', 3, 'Ecuador', 'Alemania', '2026-06-25T20:00:00Z'::timestamptz, 'Nueva York/NJ'),
  ('group', 'E', 3, 'Curazao', 'Costa de Marfil', '2026-06-25T20:00:00Z'::timestamptz, 'Filadelfia'),
  ('group', 'F', 1, 'Países Bajos', 'Japón', '2026-06-14T20:00:00Z'::timestamptz, 'Dallas'),
  ('group', 'F', 1, 'Suecia', 'Túnez', '2026-06-15T02:00:00Z'::timestamptz, 'Monterrey'),
  ('group', 'F', 2, 'Países Bajos', 'Suecia', '2026-06-20T17:00:00Z'::timestamptz, 'Houston'),
  ('group', 'F', 2, 'Túnez', 'Japón', '2026-06-21T04:00:00Z'::timestamptz, 'Kansas City'),
  ('group', 'F', 3, 'Japón', 'Suecia', '2026-06-25T23:00:00Z'::timestamptz, 'Dallas'),
  ('group', 'F', 3, 'Túnez', 'Países Bajos', '2026-06-25T23:00:00Z'::timestamptz, 'Kansas City'),
  ('group', 'G', 1, 'Bélgica', 'Egipto', '2026-06-15T19:00:00Z'::timestamptz, 'Seattle'),
  ('group', 'G', 1, 'Irán', 'Nueva Zelanda', '2026-06-16T01:00:00Z'::timestamptz, 'Los Ángeles'),
  ('group', 'G', 2, 'Bélgica', 'Irán', '2026-06-21T19:00:00Z'::timestamptz, 'Los Ángeles'),
  ('group', 'G', 2, 'Nueva Zelanda', 'Egipto', '2026-06-22T01:00:00Z'::timestamptz, 'Vancouver'),
  ('group', 'G', 3, 'Egipto', 'Irán', '2026-06-27T03:00:00Z'::timestamptz, 'Seattle'),
  ('group', 'G', 3, 'Nueva Zelanda', 'Bélgica', '2026-06-27T03:00:00Z'::timestamptz, 'Vancouver'),
  ('group', 'H', 1, 'España', 'Cabo Verde', '2026-06-15T16:00:00Z'::timestamptz, 'Atlanta'),
  ('group', 'H', 1, 'Arabia Saudita', 'Uruguay', '2026-06-15T22:00:00Z'::timestamptz, 'Miami'),
  ('group', 'H', 2, 'España', 'Arabia Saudita', '2026-06-21T16:00:00Z'::timestamptz, 'Atlanta'),
  ('group', 'H', 2, 'Uruguay', 'Cabo Verde', '2026-06-21T22:00:00Z'::timestamptz, 'Miami'),
  ('group', 'H', 3, 'Cabo Verde', 'Arabia Saudita', '2026-06-27T00:00:00Z'::timestamptz, 'Houston'),
  ('group', 'H', 3, 'Uruguay', 'España', '2026-06-27T00:00:00Z'::timestamptz, 'Guadalajara'),
  ('group', 'I', 1, 'Francia', 'Senegal', '2026-06-16T19:00:00Z'::timestamptz, 'Nueva York/NJ'),
  ('group', 'I', 1, 'Iraq', 'Noruega', '2026-06-16T22:00:00Z'::timestamptz, 'Boston'),
  ('group', 'I', 2, 'Francia', 'Iraq', '2026-06-22T21:00:00Z'::timestamptz, 'Filadelfia'),
  ('group', 'I', 2, 'Noruega', 'Senegal', '2026-06-23T00:00:00Z'::timestamptz, 'Nueva York/NJ'),
  ('group', 'I', 3, 'Noruega', 'Francia', '2026-06-26T19:00:00Z'::timestamptz, 'Boston'),
  ('group', 'I', 3, 'Senegal', 'Iraq', '2026-06-26T19:00:00Z'::timestamptz, 'Toronto'),
  ('group', 'J', 1, 'Argentina', 'Argelia', '2026-06-17T01:00:00Z'::timestamptz, 'Kansas City'),
  ('group', 'J', 1, 'Austria', 'Jordania', '2026-06-17T04:00:00Z'::timestamptz, 'San Francisco'),
  ('group', 'J', 2, 'Argentina', 'Austria', '2026-06-22T17:00:00Z'::timestamptz, 'Dallas'),
  ('group', 'J', 2, 'Jordania', 'Argelia', '2026-06-23T03:00:00Z'::timestamptz, 'San Francisco'),
  ('group', 'J', 3, 'Argelia', 'Austria', '2026-06-28T02:00:00Z'::timestamptz, 'Kansas City'),
  ('group', 'J', 3, 'Jordania', 'Argentina', '2026-06-28T02:00:00Z'::timestamptz, 'Dallas'),
  ('group', 'K', 1, 'Portugal', 'RD Congo', '2026-06-17T17:00:00Z'::timestamptz, 'Houston'),
  ('group', 'K', 1, 'Uzbekistán', 'Colombia', '2026-06-18T02:00:00Z'::timestamptz, 'Ciudad de México'),
  ('group', 'K', 2, 'Portugal', 'Uzbekistán', '2026-06-23T17:00:00Z'::timestamptz, 'Houston'),
  ('group', 'K', 2, 'Colombia', 'RD Congo', '2026-06-24T02:00:00Z'::timestamptz, 'Guadalajara'),
  ('group', 'K', 3, 'Colombia', 'Portugal', '2026-06-27T23:30:00Z'::timestamptz, 'Miami'),
  ('group', 'K', 3, 'RD Congo', 'Uzbekistán', '2026-06-27T23:30:00Z'::timestamptz, 'Atlanta'),
  ('group', 'L', 1, 'Inglaterra', 'Croacia', '2026-06-17T20:00:00Z'::timestamptz, 'Dallas'),
  ('group', 'L', 1, 'Ghana', 'Panamá', '2026-06-17T23:00:00Z'::timestamptz, 'Toronto'),
  ('group', 'L', 2, 'Inglaterra', 'Ghana', '2026-06-23T20:00:00Z'::timestamptz, 'Boston'),
  ('group', 'L', 2, 'Panamá', 'Croacia', '2026-06-23T23:00:00Z'::timestamptz, 'Toronto'),
  ('group', 'L', 3, 'Panamá', 'Inglaterra', '2026-06-27T21:00:00Z'::timestamptz, 'Nueva York/NJ'),
  ('group', 'L', 3, 'Croacia', 'Ghana', '2026-06-27T21:00:00Z'::timestamptz, 'Filadelfia')
) as v(round, group_code, jornada, home_team, away_team, kickoff, venue)
where not exists (select 1 from matches where round = 'group');

-- ============================================================================
--  FIN.  Ahora:
--   1) Regístrate en la app (será tu cuenta de admin).
--   2) Vuelve aquí y ejecuta, reemplazando tu_usuario:
--        update profiles set is_admin = true where username = 'tu_usuario';
--   3) ¡Listo! Ya puedes cargar resultados y administrar la polla.
-- ============================================================================

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
