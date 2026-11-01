-- ChoreQuest web: households, kids (paired by QR + anonymous auth), chores, approvals, coin ledger, shop.
create extension if not exists pgcrypto with schema extensions;

create table public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'My family' check (char_length(name) between 1 and 40),
  require_approval boolean not null default true,
  timezone text not null default 'Asia/Jerusalem',
  created_at timestamptz not null default now()
);

create table public.household_members (
  household_id uuid not null references public.households on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  role text not null check (role in ('owner', 'admin')),
  created_at timestamptz not null default now(),
  primary key (household_id, user_id)
);
create index on public.household_members (user_id);

create table public.kids (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households on delete cascade,
  name text not null check (char_length(name) between 1 and 14),
  coins integer not null default 0 check (coins >= 0),
  worn jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index on public.kids (household_id);

create table public.kid_devices (
  kid_id uuid not null references public.kids on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  primary key (kid_id, user_id)
);
create index on public.kid_devices (user_id);

create table public.invites (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('kid', 'parent')),
  household_id uuid not null references public.households on delete cascade,
  kid_id uuid references public.kids on delete cascade,
  code_hash text not null unique,
  expires_at timestamptz not null,
  created_by uuid references auth.users on delete set null,
  created_at timestamptz not null default now(),
  check ((kind = 'kid') = (kid_id is not null))
);

create table public.chores (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households on delete cascade,
  kid_id uuid references public.kids on delete cascade,
  title text not null check (char_length(title) between 1 and 60),
  icon text not null default '⭐' check (char_length(icon) between 1 and 8),
  coins integer not null default 5 check (coins between 0 and 50),
  game text not null default 'memory'
    check (game in ('memory', 'bubbles', 'stars', 'critters', 'simon', 'count', 'none')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index on public.chores (household_id) where active;

create table public.completions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households on delete cascade,
  kid_id uuid not null references public.kids on delete cascade,
  chore_id uuid not null references public.chores,
  day date not null,
  base_coins integer not null check (base_coins between 0 and 50),
  bonus integer not null default 0 check (bonus between 0 and 20),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  reviewed_by uuid references auth.users on delete set null,
  reviewed_at timestamptz
);
create unique index completions_one_per_day on public.completions (chore_id, kid_id, day)
  where status in ('pending', 'approved');
create index on public.completions (household_id, status);
create index on public.completions (kid_id, day);

create table public.coin_ledger (
  id bigint generated always as identity primary key,
  household_id uuid not null references public.households on delete cascade,
  kid_id uuid not null references public.kids on delete cascade,
  amount integer not null check (amount <> 0),
  kind text not null check (kind in ('chore', 'purchase')),
  completion_id uuid unique references public.completions,
  item_key text,
  created_at timestamptz not null default now()
);
create index on public.coin_ledger (kid_id);

create table public.shop_items (
  key text primary key,
  price integer not null check (price >= 0)
);

create table public.kid_items (
  kid_id uuid not null references public.kids on delete cascade,
  item_key text not null references public.shop_items,
  created_at timestamptz not null default now(),
  primary key (kid_id, item_key)
);

-- Ledger rows are the only way coins move; the kids.coins check stops overspending atomically.
create function public.apply_ledger() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.kids set coins = coins + new.amount where id = new.kid_id;
  return new;
end $$;
create trigger coin_ledger_apply after insert on public.coin_ledger
  for each row execute function public.apply_ledger();

-- ---------- access helpers ----------
create function public.is_member(h uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.household_members m
    where m.household_id = h and m.user_id = (select auth.uid()))
$$;

create function public.is_kid_device(k uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.kid_devices d
    where d.kid_id = k and d.user_id = (select auth.uid()))
$$;

create function public.is_household_kid_device(h uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.kid_devices d join public.kids k on k.id = d.kid_id
    where k.household_id = h and d.user_id = (select auth.uid()))
$$;

create function public.is_parent_user() returns boolean
language sql stable set search_path = '' as $$
  select coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) = false
$$;

-- ---------- row level security ----------
alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.kids enable row level security;
alter table public.kid_devices enable row level security;
alter table public.invites enable row level security;
alter table public.chores enable row level security;
alter table public.completions enable row level security;
alter table public.coin_ledger enable row level security;
alter table public.shop_items enable row level security;
alter table public.kid_items enable row level security;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

grant select on public.households, public.household_members, public.kids, public.kid_devices,
  public.invites, public.chores, public.completions, public.coin_ledger, public.shop_items,
  public.kid_items to authenticated;
grant update (name, require_approval) on public.households to authenticated;
grant insert (household_id, name), update (name) on public.kids to authenticated;
grant delete on public.kids, public.kid_devices to authenticated;
grant insert (household_id, kid_id, title, icon, coins, game, active),
  update (kid_id, title, icon, coins, game, active) on public.chores to authenticated;

create policy households_select on public.households for select to authenticated
  using (public.is_member(id) or public.is_household_kid_device(id));
create policy households_update on public.households for update to authenticated
  using (public.is_member(id)) with check (public.is_member(id));

create policy members_select on public.household_members for select to authenticated
  using (public.is_member(household_id));

create policy kids_select on public.kids for select to authenticated
  using (public.is_member(household_id) or public.is_kid_device(id));
create policy kids_insert on public.kids for insert to authenticated
  with check (public.is_member(household_id));
create policy kids_update on public.kids for update to authenticated
  using (public.is_member(household_id)) with check (public.is_member(household_id));
create policy kids_delete on public.kids for delete to authenticated
  using (public.is_member(household_id));

create policy devices_select on public.kid_devices for select to authenticated
  using (user_id = (select auth.uid()) or exists (
    select 1 from public.kids k where k.id = kid_id and public.is_member(k.household_id)));
create policy devices_delete on public.kid_devices for delete to authenticated
  using (exists (select 1 from public.kids k where k.id = kid_id and public.is_member(k.household_id)));

create policy invites_select on public.invites for select to authenticated
  using (public.is_member(household_id));

create policy chores_select on public.chores for select to authenticated
  using (public.is_member(household_id)
    or (active and public.is_household_kid_device(household_id)
        and (kid_id is null or public.is_kid_device(kid_id))));
create policy chores_insert on public.chores for insert to authenticated
  with check (public.is_member(household_id)
    and (kid_id is null or exists (select 1 from public.kids k where k.id = kid_id and k.household_id = chores.household_id)));
create policy chores_update on public.chores for update to authenticated
  using (public.is_member(household_id))
  with check (public.is_member(household_id)
    and (kid_id is null or exists (select 1 from public.kids k where k.id = kid_id and k.household_id = chores.household_id)));

create policy completions_select on public.completions for select to authenticated
  using (public.is_member(household_id) or public.is_kid_device(kid_id));
create policy ledger_select on public.coin_ledger for select to authenticated
  using (public.is_member(household_id) or public.is_kid_device(kid_id));
create policy shop_select on public.shop_items for select to authenticated using (true);
create policy kid_items_select on public.kid_items for select to authenticated
  using (public.is_kid_device(kid_id) or exists (
    select 1 from public.kids k where k.id = kid_id and public.is_member(k.household_id)));

-- ---------- parent functions ----------
create function public.create_household(p_name text default 'My family') returns uuid
language plpgsql security definer set search_path = '' as $$
declare uid uuid := (select auth.uid()); h uuid;
begin
  if uid is null or not public.is_parent_user() then raise exception 'parents only'; end if;
  select household_id into h from public.household_members where user_id = uid limit 1;
  if h is not null then return h; end if;
  insert into public.households (name) values (coalesce(nullif(btrim(p_name), ''), 'My family')) returning id into h;
  insert into public.household_members (household_id, user_id, role) values (h, uid, 'owner');
  insert into public.chores (household_id, title, icon, coins, game) values
    (h, 'Make the bed', '🛏️', 5, 'memory'), (h, 'Brush teeth', '🦷', 3, 'bubbles'),
    (h, 'Do homework', '📚', 10, 'count'), (h, 'Help with dishes', '🍽️', 6, 'critters'),
    (h, 'Read 20 minutes', '📖', 8, 'stars'), (h, 'Tidy my room', '🧸', 7, 'simon');
  return h;
end $$;

create function public.create_kid_invite(p_kid uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare k public.kids; code text := encode(extensions.gen_random_bytes(16), 'hex');
begin
  select * into k from public.kids where id = p_kid;
  if k.id is null or not public.is_member(k.household_id) then raise exception 'not allowed'; end if;
  delete from public.invites where kid_id = p_kid;
  insert into public.invites (kind, household_id, kid_id, code_hash, expires_at, created_by)
  values ('kid', k.household_id, p_kid, encode(extensions.digest(code, 'sha256'), 'hex'),
          now() + interval '7 days', (select auth.uid()));
  return code;
end $$;

create function public.create_parent_invite() returns text
language plpgsql security definer set search_path = '' as $$
declare uid uuid := (select auth.uid()); h uuid; code text := encode(extensions.gen_random_bytes(16), 'hex');
begin
  select household_id into h from public.household_members where user_id = uid and role = 'owner' limit 1;
  if h is null then raise exception 'owners only'; end if;
  insert into public.invites (kind, household_id, code_hash, expires_at, created_by)
  values ('parent', h, encode(extensions.digest(code, 'sha256'), 'hex'), now() + interval '3 days', uid);
  return code;
end $$;

create function public.accept_parent_invite(p_code text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare uid uuid := (select auth.uid()); inv public.invites;
begin
  if uid is null or not public.is_parent_user() then raise exception 'parents only'; end if;
  select * into inv from public.invites
    where kind = 'parent' and code_hash = encode(extensions.digest(p_code, 'sha256'), 'hex') and expires_at > now();
  if inv.id is null then raise exception 'invalid or expired invite'; end if;
  insert into public.household_members (household_id, user_id, role)
    values (inv.household_id, uid, 'admin') on conflict do nothing;
  return inv.household_id;
end $$;

create function public.approve_completion(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.completions;
begin
  select * into c from public.completions where id = p_id for update;
  if c.id is null or not public.is_member(c.household_id) then raise exception 'not allowed'; end if;
  if c.status = 'approved' then return; end if;
  if c.status <> 'pending' then raise exception 'not pending'; end if;
  update public.completions set status = 'approved', reviewed_by = (select auth.uid()), reviewed_at = now() where id = p_id;
  if c.base_coins + c.bonus > 0 then
    insert into public.coin_ledger (household_id, kid_id, amount, kind, completion_id)
    values (c.household_id, c.kid_id, c.base_coins + c.bonus, 'chore', c.id) on conflict (completion_id) do nothing;
  end if;
end $$;

create function public.reject_completion(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.completions;
begin
  select * into c from public.completions where id = p_id for update;
  if c.id is null or not public.is_member(c.household_id) then raise exception 'not allowed'; end if;
  if c.status <> 'pending' then raise exception 'not pending'; end if;
  update public.completions set status = 'rejected', reviewed_by = (select auth.uid()), reviewed_at = now() where id = p_id;
end $$;

-- ---------- kid functions ----------
create function public.claim_kid_invite(p_code text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare uid uuid := (select auth.uid()); inv public.invites;
begin
  if uid is null then raise exception 'sign in first'; end if;
  select * into inv from public.invites
    where kind = 'kid' and code_hash = encode(extensions.digest(p_code, 'sha256'), 'hex') and expires_at > now();
  if inv.id is null then raise exception 'invalid or expired invite'; end if;
  insert into public.kid_devices (kid_id, user_id) values (inv.kid_id, uid) on conflict do nothing;
  return inv.kid_id;
end $$;

create function public.submit_completion(p_kid uuid, p_chore uuid, p_bonus integer default 0) returns uuid
language plpgsql security definer set search_path = '' as $$
declare k public.kids; ch public.chores; h public.households; cid uuid; today date; b integer;
begin
  if not public.is_kid_device(p_kid) then raise exception 'not allowed'; end if;
  select * into k from public.kids where id = p_kid;
  select * into ch from public.chores where id = p_chore and active;
  if ch.id is null or ch.household_id <> k.household_id or (ch.kid_id is not null and ch.kid_id <> p_kid) then
    raise exception 'unknown chore';
  end if;
  select * into h from public.households where id = k.household_id;
  today := (now() at time zone h.timezone)::date;
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

create function public.cancel_completion(p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.completions;
begin
  select * into c from public.completions where id = p_id for update;
  if c.id is null or not public.is_kid_device(c.kid_id) then raise exception 'not allowed'; end if;
  if c.status <> 'pending' then raise exception 'not pending'; end if;
  delete from public.completions where id = p_id;
end $$;

create function public.buy_item(p_kid uuid, p_item text) returns void
language plpgsql security definer set search_path = '' as $$
declare it public.shop_items; k public.kids;
begin
  if not public.is_kid_device(p_kid) then raise exception 'not allowed'; end if;
  select * into it from public.shop_items where key = p_item;
  if it.key is null then raise exception 'unknown item'; end if;
  select * into k from public.kids where id = p_kid for update;
  if exists (select 1 from public.kid_items where kid_id = p_kid and item_key = p_item) then return; end if;
  insert into public.kid_items (kid_id, item_key) values (p_kid, p_item);
  if it.price > 0 then
    insert into public.coin_ledger (household_id, kid_id, amount, kind, item_key)
    values (k.household_id, p_kid, -it.price, 'purchase', p_item);
  end if;
end $$;

create function public.set_worn(p_kid uuid, p_worn jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare e record;
begin
  if not public.is_kid_device(p_kid) then raise exception 'not allowed'; end if;
  if jsonb_typeof(p_worn) <> 'object' then raise exception 'bad outfit'; end if;
  for e in select key, value from jsonb_each_text(p_worn) loop
    if not exists (select 1 from public.shop_items s where s.key = e.key || ':' || e.value
        and (s.price = 0 or exists (select 1 from public.kid_items i where i.kid_id = p_kid and i.item_key = s.key))) then
      raise exception 'item not available: %:%', e.key, e.value;
    end if;
  end loop;
  update public.kids set worn = p_worn where id = p_kid;
end $$;

revoke all on all functions in schema public from public, anon, authenticated;

grant execute on function public.is_member(uuid), public.is_kid_device(uuid),
  public.is_household_kid_device(uuid), public.is_parent_user() to authenticated;
grant execute on function public.create_household(text), public.create_kid_invite(uuid),
  public.create_parent_invite(), public.accept_parent_invite(text), public.approve_completion(uuid),
  public.reject_completion(uuid), public.claim_kid_invite(text), public.submit_completion(uuid, uuid, integer),
  public.cancel_completion(uuid), public.buy_item(uuid, text), public.set_worn(uuid, jsonb) to authenticated;

alter publication supabase_realtime add table public.completions, public.kids, public.chores, public.kid_items;
