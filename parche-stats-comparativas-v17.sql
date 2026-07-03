-- V17 · Stats comparativas de progresión de puntos
-- Refuerza la lectura necesaria para comparar progresión con otros usuarios.
-- Regla: cada usuario ve sus propios pronósticos siempre; los de otros usuarios solo
-- cuando el partido ya empezó/fue cerrado, o si el usuario es administrador.

alter table public.predictions enable row level security;

drop policy if exists p_pred_sel on public.predictions;
create policy p_pred_sel on public.predictions
for select
using (
  auth.uid() = user_id
  or public.match_started(match_id)
  or public.is_admin()
);

-- Verificación rápida: debe devolver la política p_pred_sel activa.
select
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual
from pg_policies
where schemaname = 'public'
  and tablename = 'predictions'
  and policyname = 'p_pred_sel';
