-- Security hardening for SECURITY DEFINER RPCs.
-- Paste this whole file in the SQL editor. It is idempotent.
-- Signed-in users (the authenticated role) keep EXECUTE, including a kid's
-- anonymous session. The logged-out anon role and PUBLIC do not.
-- Function signatures and success results for a normal caller stay the same.

begin;

-- A parent invite is one use. The first new parent still joins and gets the
-- household id back. Someone who is already in that household does not burn
-- the link. A second new parent finds the link gone.
create or replace function public.accept_parent_invite(p_code text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare uid uuid := (select auth.uid()); inv public.invites;
begin
  if uid is null or not public.is_parent_user() then raise exception 'parents only'; end if;
  select * into inv from public.invites
    where kind = 'parent'
      and code_hash = encode(extensions.digest(p_code, 'sha256'), 'hex')
      and expires_at > now()
    for update;
  if inv.id is null then raise exception 'invalid or expired invite'; end if;
  insert into public.household_members (household_id, user_id, role)
    values (inv.household_id, uid, 'admin')
    on conflict do nothing;
  if found then
    delete from public.invites where id = inv.id;
  end if;
  return inv.household_id;
end $$;

-- Hold the kid row so two overlapping submits cannot both pass a weekly cap.
create or replace function public.submit_completion(p_kid uuid, p_chore uuid, p_bonus integer default 0) returns uuid
language plpgsql security definer set search_path = '' as $$
declare k public.kids; ch public.chores; h public.households; cid uuid; today date; b integer;
  wk date; used integer;
begin
  if not public.is_kid_device(p_kid) then raise exception 'not allowed'; end if;
  select * into k from public.kids where id = p_kid for update;
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

create or replace function public.submit_late_completion(p_kid uuid, p_chore uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare k public.kids; ch public.chores; h public.households;
  cid uuid; yday date; dow smallint; wk date; used integer; pay integer;
begin
  if not public.is_kid_device(p_kid) then raise exception 'not allowed'; end if;
  select * into k from public.kids where id = p_kid for update;
  select * into ch from public.chores where id = p_chore and active;
  if ch.id is null or ch.household_id <> k.household_id or (ch.kid_id is not null and ch.kid_id <> p_kid) then
    raise exception 'unknown chore';
  end if;
  select * into h from public.households where id = k.household_id;
  yday := (now() at time zone h.timezone)::date - 1;
  dow := extract(dow from yday)::smallint;
  if ch.repeat = 'daily' and ch.weekdays is not null and not (dow = any (ch.weekdays)) then
    raise exception 'not scheduled yesterday';
  end if;
  if ch.repeat = 'weekly' then
    wk := yday - extract(dow from yday)::int;
    select count(*) into used from public.completions
      where chore_id = ch.id and kid_id = p_kid and day >= wk and day <= yday
        and status in ('pending', 'approved');
    if used >= ch.weekly_target then raise exception 'weekly goal reached'; end if;
  end if;
  if exists (select 1 from public.completions
      where chore_id = ch.id and kid_id = p_kid and day = yday
        and status in ('pending', 'approved')) then
    raise exception 'already done';
  end if;
  pay := case when ch.coins > 0 then greatest(1, ch.coins / 2) else 0 end;
  begin
    insert into public.completions (household_id, kid_id, chore_id, day, base_coins, bonus, status)
    values (k.household_id, p_kid, ch.id, yday, pay, 0, 'pending')
    returning id into cid;
  exception when unique_violation then
    raise exception 'already done';
  end;
  return cid;
end $$;

revoke all on function
  public.accept_parent_invite(text),
  public.admin_dashboard(),
  public.admin_detail(text),
  public.admin_set_feedback(uuid, text),
  public.approve_completion(uuid),
  public.buy_item(uuid, text),
  public.cancel_completion(uuid),
  public.cancel_prize_request(uuid),
  public.claim_kid_invite(text),
  public.create_household(text),
  public.create_kid_invite(uuid),
  public.create_parent_invite(),
  public.give_prize(uuid),
  public.is_app_admin(),
  public.is_household_kid_device(uuid),
  public.is_kid_device(uuid),
  public.is_member(uuid),
  public.log_game_event(uuid, text, text),
  public.redeem_prize(uuid, uuid),
  public.reject_completion(uuid),
  public.reject_prize(uuid),
  public.send_feedback(text, text),
  public.set_worn(uuid, jsonb),
  public.submit_completion(uuid, uuid, integer),
  public.submit_late_completion(uuid, uuid)
from public, anon, authenticated;

grant execute on function
  public.accept_parent_invite(text),
  public.admin_dashboard(),
  public.admin_detail(text),
  public.admin_set_feedback(uuid, text),
  public.approve_completion(uuid),
  public.buy_item(uuid, text),
  public.cancel_completion(uuid),
  public.cancel_prize_request(uuid),
  public.claim_kid_invite(text),
  public.create_household(text),
  public.create_kid_invite(uuid),
  public.create_parent_invite(),
  public.give_prize(uuid),
  public.is_app_admin(),
  public.is_household_kid_device(uuid),
  public.is_kid_device(uuid),
  public.is_member(uuid),
  public.log_game_event(uuid, text, text),
  public.redeem_prize(uuid, uuid),
  public.reject_completion(uuid),
  public.reject_prize(uuid),
  public.send_feedback(text, text),
  public.set_worn(uuid, jsonb),
  public.submit_completion(uuid, uuid, integer),
  public.submit_late_completion(uuid, uuid)
to authenticated;

commit;
