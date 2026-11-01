create function public.admin_detail(p_kind text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  if not public.is_app_admin() then raise exception 'not allowed'; end if;
  if p_kind in ('households', 'new_households_7d', 'active_households_7d') then
    select coalesce(jsonb_agg(t), '[]') into r from (
      select '🏠' as icon, h.name as title,
        (select count(*) from public.household_members m where m.household_id = h.id) || ' parents · '
        || (select count(*) from public.kids k where k.household_id = h.id) || ' kids · '
        || (select count(*) from public.chores c where c.household_id = h.id) || ' chores · '
        || (select count(*) from public.completions x where x.household_id = h.id and x.status = 'approved') || ' done' as sub,
        h.created_at as at
      from public.households h
      where p_kind = 'households'
         or (p_kind = 'new_households_7d' and h.created_at > now() - interval '7 days')
         or (p_kind = 'active_households_7d' and exists (select 1 from public.completions x where x.household_id = h.id and x.created_at > now() - interval '7 days'))
      order by h.created_at desc limit 200) t;
  elsif p_kind = 'parents' then
    select coalesce(jsonb_agg(t), '[]') into r from (
      select '👤' as icon, coalesce(u.email, 'unknown') as title, h.name || ' · ' || m.role as sub, m.created_at as at
      from public.household_members m join public.households h on h.id = m.household_id
      left join auth.users u on u.id = m.user_id order by m.created_at desc limit 200) t;
  elsif p_kind = 'kids' then
    select coalesce(jsonb_agg(t), '[]') into r from (
      select '🧒' as icon, k.name as title, h.name || ' · ' || k.coins || ' coins' as sub, k.created_at as at
      from public.kids k join public.households h on h.id = k.household_id order by k.created_at desc limit 200) t;
  elsif p_kind = 'devices' then
    select coalesce(jsonb_agg(t), '[]') into r from (
      select '📱' as icon, k.name as title, h.name as sub, d.created_at as at
      from public.kid_devices d join public.kids k on k.id = d.kid_id join public.households h on h.id = k.household_id
      order by d.created_at desc limit 200) t;
  elsif p_kind = 'chores' then
    select coalesce(jsonb_agg(t), '[]') into r from (
      select c.icon, c.title, h.name || ' · ' || c.coins || ' coins' as sub, c.created_at as at
      from public.chores c join public.households h on h.id = c.household_id order by c.created_at desc limit 200) t;
  elsif p_kind = 'prizes' then
    select coalesce(jsonb_agg(t), '[]') into r from (
      select z.icon, z.title, h.name || ' · ' || z.cost || ' coins' as sub, z.created_at as at
      from public.prizes z join public.households h on h.id = z.household_id order by z.created_at desc limit 200) t;
  elsif p_kind in ('completions', 'completions_7d') then
    select coalesce(jsonb_agg(t), '[]') into r from (
      select c.icon, c.title, h.name || ' · ' || k.name || ' · +' || (x.base_coins + x.bonus) as sub, x.created_at as at
      from public.completions x join public.chores c on c.id = x.chore_id
      join public.kids k on k.id = x.kid_id join public.households h on h.id = x.household_id
      where x.status = 'approved' and (p_kind = 'completions' or x.created_at > now() - interval '7 days')
      order by x.created_at desc limit 200) t;
  else
    raise exception 'unknown kind';
  end if;
  return r;
end $$;

revoke all on function public.admin_detail(text) from public, anon;
grant execute on function public.admin_detail(text) to authenticated;
