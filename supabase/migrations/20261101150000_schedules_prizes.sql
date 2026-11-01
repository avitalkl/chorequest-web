-- Chore schedules (daily / weekly, optional weekdays) and real-world prizes.

alter table public.chores
  add column repeat text not null default 'daily' check (repeat in ('daily', 'weekly')),
  add column weekdays smallint[] check (weekdays <@ array[0,1,2,3,4,5,6]::smallint[] and cardinality(weekdays) > 0),
  add column weekly_target smallint not null default 1 check (weekly_target between 1 and 7);

grant insert (repeat, weekdays, weekly_target), update (repeat, weekdays, weekly_target)
  on public.chores to authenticated;

create table public.prizes (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households on delete cascade,
  title text not null check (char_length(title) between 1 and 60),
  icon text not null default '🎁' check (char_length(icon) between 1 and 8),
  cost integer not null default 50 check (cost between 1 and 5000),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index on public.prizes (household_id) where active;

create table public.prize_requests (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households on delete cascade,
  kid_id uuid not null references public.kids on delete cascade,
  prize_id uuid not null references public.prizes,
  cost integer not null check (cost > 0),
  status text not null default 'pending' check (status in ('pending', 'given', 'rejected', 'cancelled')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index on public.prize_requests (household_id, status);
create index on public.prize_requests (kid_id);

alter table public.coin_ledger drop constraint coin_ledger_kind_check;
alter table public.coin_ledger add constraint coin_ledger_kind_check
  check (kind in ('chore', 'purchase', 'prize', 'refund'));
alter table public.coin_ledger add column prize_request_id uuid references public.prize_requests;
create unique index coin_ledger_refund_once on public.coin_ledger (prize_request_id) where kind = 'refund';

alter table public.prizes enable row level security;
alter table public.prize_requests enable row level security;
revoke all on public.prizes, public.prize_requests from anon, authenticated;
grant select on public.prizes, public.prize_requests to authenticated;
grant insert (household_id, title, icon, cost, active), update (title, icon, cost, active)
  on public.prizes to authenticated;

create policy prizes_select on public.prizes for select to authenticated
  using (public.is_member(household_id) or (active and public.is_household_kid_device(household_id)));
create policy prizes_insert on public.prizes for insert to authenticated
  with check (public.is_member(household_id));
create policy prizes_update on public.prizes for update to authenticated
  using (public.is_member(household_id)) with check (public.is_member(household_id));
create policy prize_requests_select on public.prize_requests for select to authenticated
  using (public.is_member(household_id) or public.is_kid_device(kid_id));

-- Weekdays use 0 = Sunday .. 6 = Saturday; the week starts on Sunday.
create or replace function public.submit_completion(p_kid uuid, p_chore uuid, p_bonus integer default 0) returns uuid
language plpgsql security definer set search_path = '' as $$
declare k public.kids; ch public.chores; h public.households; cid uuid; today date; b integer;
  wk date; used integer;
begin
  if not public.is_kid_device(p_kid) then raise exception 'not allowed'; end if;
  select * into k from public.kids where id = p_kid;
  select * into ch from public.chores where id = p_chore and active;
  if ch.id is null or ch.household_id <> k.household_id or (ch.kid_id is not null and ch.kid_id <> p_kid) then
    raise exception 'unknown chore';
  end if;
  select * into h from public.households where id = k.household_id;
  today := (now() at time zone h.timezone)::date;
  if ch.weekdays is not null and not (extract(dow from today)::smallint = any (ch.weekdays)) then
    raise exception 'not scheduled today';
  end if;
  if ch.repeat = 'weekly' then
    wk := today - extract(dow from today)::int;
    select count(*) into used from public.completions
      where chore_id = ch.id and kid_id = p_kid and day >= wk and status in ('pending', 'approved');
    if used >= ch.weekly_target then raise exception 'weekly goal reached'; end if;
  end if;
  b := greatest(0, least(coalesce(p_bonus, 0), 20));
  insert into public.completions (household_id, kid_id, chore_id, day, base_coins, bonus, status)
  values (k.household_id, p_kid, ch.id, today, ch.coins, b, 'pending') returning id into cid;
  if not h.require_approval then
    update public.completions set status = 'approved', reviewed_at = now() where id = cid;
    if ch.coins + b > 0 then
      insert into public.coin_ledger (household_id, kid_id, amount, kind, completion_id)
      values (k.household_id, p_kid, ch.coins + b, 'chore', cid);
    end if;
  end if;
  return cid;
end $$;

create function public.redeem_prize(p_kid uuid, p_prize uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare k public.kids; pz public.prizes; rid uuid;
begin
  if not public.is_kid_device(p_kid) then raise exception 'not allowed'; end if;
  select * into k from public.kids where id = p_kid for update;
  select * into pz from public.prizes where id = p_prize and active;
  if pz.id is null or pz.household_id <> k.household_id then raise exception 'unknown prize'; end if;
  insert into public.prize_requests (household_id, kid_id, prize_id, cost)
  values (k.household_id, p_kid, pz.id, pz.cost) returning id into rid;
  insert into public.coin_ledger (household_id, kid_id, amount, kind, prize_request_id)
  values (k.household_id, p_kid, -pz.cost, 'prize', rid);
  return rid;
end $$;

create function public.cancel_prize_request(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.prize_requests;
begin
  select * into r from public.prize_requests where id = p_id for update;
  if r.id is null or not public.is_kid_device(r.kid_id) then raise exception 'not allowed'; end if;
  if r.status <> 'pending' then raise exception 'not pending'; end if;
  update public.prize_requests set status = 'cancelled', resolved_at = now() where id = p_id;
  insert into public.coin_ledger (household_id, kid_id, amount, kind, prize_request_id)
  values (r.household_id, r.kid_id, r.cost, 'refund', r.id);
end $$;

create function public.give_prize(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.prize_requests;
begin
  select * into r from public.prize_requests where id = p_id for update;
  if r.id is null or not public.is_member(r.household_id) then raise exception 'not allowed'; end if;
  if r.status = 'given' then return; end if;
  if r.status <> 'pending' then raise exception 'not pending'; end if;
  update public.prize_requests set status = 'given', resolved_at = now() where id = p_id;
end $$;

create function public.reject_prize(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.prize_requests;
begin
  select * into r from public.prize_requests where id = p_id for update;
  if r.id is null or not public.is_member(r.household_id) then raise exception 'not allowed'; end if;
  if r.status <> 'pending' then raise exception 'not pending'; end if;
  update public.prize_requests set status = 'rejected', resolved_at = now() where id = p_id;
  insert into public.coin_ledger (household_id, kid_id, amount, kind, prize_request_id)
  values (r.household_id, r.kid_id, r.cost, 'refund', r.id);
end $$;

revoke all on function public.redeem_prize(uuid, uuid), public.cancel_prize_request(uuid),
  public.give_prize(uuid), public.reject_prize(uuid) from public, anon;
grant execute on function public.redeem_prize(uuid, uuid), public.cancel_prize_request(uuid),
  public.give_prize(uuid), public.reject_prize(uuid) to authenticated;
