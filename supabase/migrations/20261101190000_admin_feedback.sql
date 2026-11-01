-- Owner portal and parent feedback.
create table public.app_admins (email text primary key check (email = lower(email)));
alter table public.app_admins enable row level security;
insert into public.app_admins (email) values ('avital.klausner@gmail.com') on conflict do nothing;

create function public.is_app_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_parent_user()
    and exists (select 1 from public.app_admins a where a.email = lower((select auth.jwt()) ->> 'email'))
$$;

create table public.feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  household_id uuid references public.households on delete set null,
  email text,
  kind text not null default 'idea' check (kind in ('idea', 'bug', 'other')),
  message text not null check (char_length(message) between 1 and 2000),
  status text not null default 'new' check (status in ('new', 'done')),
  created_at timestamptz not null default now()
);
create index on public.feedback (created_at desc);
alter table public.feedback enable row level security;

create function public.send_feedback(p_message text, p_kind text default 'idea') returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := (select auth.uid()); h uuid;
begin
  if uid is null or not public.is_parent_user() then raise exception 'parents only'; end if;
  if char_length(btrim(coalesce(p_message, ''))) = 0 then raise exception 'empty'; end if;
  if (select count(*) from public.feedback where user_id = uid and created_at > now() - interval '1 day') >= 20 then
    raise exception 'too many';
  end if;
  select household_id into h from public.household_members where user_id = uid limit 1;
  insert into public.feedback (user_id, household_id, email, kind, message)
  values (uid, h, (select auth.jwt()) ->> 'email', case when p_kind in ('idea', 'bug', 'other') then p_kind else 'other' end, left(btrim(p_message), 2000));
end $$;

create function public.admin_set_feedback(p_id uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_app_admin() then raise exception 'not allowed'; end if;
  update public.feedback set status = case when p_status = 'done' then 'done' else 'new' end where id = p_id;
end $$;

create function public.admin_dashboard() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  if not public.is_app_admin() then raise exception 'not allowed'; end if;
  select jsonb_build_object(
    'totals', jsonb_build_object(
      'households', (select count(*) from public.households),
      'parents', (select count(distinct user_id) from public.household_members),
      'kids', (select count(*) from public.kids),
      'devices', (select count(*) from public.kid_devices),
      'chores', (select count(*) from public.chores),
      'prizes', (select count(*) from public.prizes),
      'completions', (select count(*) from public.completions where status = 'approved'),
      'new_households_7d', (select count(*) from public.households where created_at > now() - interval '7 days'),
      'active_households_7d', (select count(distinct household_id) from public.completions where created_at > now() - interval '7 days'),
      'completions_7d', (select count(*) from public.completions where status = 'approved' and created_at > now() - interval '7 days'),
      'feedback_new', (select count(*) from public.feedback where status = 'new')
    ),
    'top_chores', coalesce((select jsonb_agg(t) from (
      select min(c.title) as title, min(c.icon) as icon,
             count(distinct c.household_id) as families,
             coalesce(sum((select count(*) from public.completions x where x.chore_id = c.id and x.status = 'approved')), 0) as done
      from public.chores c group by lower(btrim(c.title))
      order by done desc, families desc limit 20) t), '[]'),
    'new_chores', coalesce((select jsonb_agg(t) from (
      select c.title, c.icon, c.coins, c.repeat, c.created_at, h.name as family
      from public.chores c join public.households h on h.id = c.household_id
      where c.created_at > h.created_at + interval '1 minute'
      order by c.created_at desc limit 30) t), '[]'),
    'prizes', coalesce((select jsonb_agg(t) from (
      select z.title, z.icon, z.cost, z.created_at, h.name as family,
             (select count(*) from public.prize_requests q where q.prize_id = z.id) as requests
      from public.prizes z join public.households h on h.id = z.household_id
      order by z.created_at desc limit 40) t), '[]'),
    'feedback', coalesce((select jsonb_agg(t) from (
      select f.id, f.kind, f.message, f.status, f.email, f.created_at, h.name as family
      from public.feedback f left join public.households h on h.id = f.household_id
      order by (f.status = 'new') desc, f.created_at desc limit 100) t), '[]')
  ) into r;
  return r;
end $$;

revoke all on function public.is_app_admin(), public.send_feedback(text, text), public.admin_set_feedback(uuid, text), public.admin_dashboard() from public, anon;
grant execute on function public.is_app_admin(), public.send_feedback(text, text), public.admin_set_feedback(uuid, text), public.admin_dashboard() to authenticated;
