-- Log a chore for yesterday only. The day is chosen here, never by the client.
-- Coins are half, rounded down, at least 1 when the chore pays anything. No game bonus.
-- It stays pending even when the household does not require approval.
create function public.submit_late_completion(p_kid uuid, p_chore uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare k public.kids; ch public.chores; h public.households;
  cid uuid; yday date; dow smallint; wk date; used integer; pay integer;
begin
  if not public.is_kid_device(p_kid) then raise exception 'not allowed'; end if;
  select * into k from public.kids where id = p_kid;
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

revoke all on function public.submit_late_completion(uuid, uuid) from public, anon;
grant execute on function public.submit_late_completion(uuid, uuid) to authenticated;
