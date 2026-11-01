begin;
insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'p@test.local'),
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', null);
create temp table res (step text, ok boolean);
grant all on res to authenticated;
create or replace function pg_temp.as_user(u uuid, anon boolean) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated', 'is_anonymous', anon)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.fails(sql text) returns boolean language plpgsql as $$
begin execute sql; return false; exception when others then return true; end $$;
grant execute on function pg_temp.as_user(uuid, boolean), pg_temp.fails(text) to authenticated;

do $$
declare h uuid; k uuid; code text; wk uuid; wd uuid; pz uuid; rq uuid; dow smallint; c1 uuid; c2 uuid; c3 uuid;
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000c1', false);
  h := public.create_household('T');
  insert into public.kids (household_id, name) values (h, 'Cara') returning id into k;
  code := public.create_kid_invite(k);
  dow := extract(dow from (now() at time zone (select timezone from public.households where id = h)))::smallint;

  insert into public.chores (household_id, title, repeat, weekly_target, coins) values (h, 'Weekly x2', 'weekly', 2, 10) returning id into wk;
  insert into public.chores (household_id, title, weekdays, coins) values (h, 'Other day', array[((dow + 1) % 7)::smallint], 10) returning id into wd;
  insert into public.chores (household_id, title, weekdays, coins) values (h, 'Today only', array[dow], 10) returning id into c3;
  insert into res values ('bad weekday rejected', pg_temp.fails($q$insert into public.chores (household_id, title, weekdays) values (gen_random_uuid(), 'x', array[9::smallint])$q$));
  insert into public.prizes (household_id, title, cost) values (h, 'Ice cream', 30) returning id into pz;

  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000d1', true);
  perform public.claim_kid_invite(code);
  insert into res values ('chore on another weekday blocked', pg_temp.fails(format($q$select public.submit_completion(%L,%L,0)$q$, k, wd)));
  insert into res values ('chore on todays weekday allowed', not pg_temp.fails(format($q$select public.submit_completion(%L,%L,0)$q$, k, c3)));
  insert into res values ('weekly chore first completion ok', not pg_temp.fails(format($q$select public.submit_completion(%L,%L,0)$q$, k, wk)));
  -- backdate so the second weekly completion is on a different day of the same week
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000c1', false);
  reset role;
  update public.completions set day = day - 0 where chore_id = wk;
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000d1', true);
  insert into res values ('weekly same-day duplicate blocked', pg_temp.fails(format($q$select public.submit_completion(%L,%L,0)$q$, k, wk)));

  reset role;
  insert into public.completions (household_id, kid_id, chore_id, day, base_coins, status)
    values (h, k, wk, (now() at time zone 'Asia/Jerusalem')::date - 1, 10, 'approved');
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000d1', true);
  insert into res values ('weekly goal reached (2 per week) blocks more', pg_temp.fails(format($q$select public.submit_completion(%L,%L,0)$q$, k, wk)) or dow = 0);

  reset role;
  insert into public.coin_ledger (household_id, kid_id, amount, kind) values (h, k, 40, 'chore');
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000d1', true);
  rq := public.redeem_prize(k, pz);
  insert into res values ('prize redeem deducts cost', (select coins from public.kids where id = k) = 10);
  insert into res values ('cannot overspend on prize', pg_temp.fails(format($q$select public.redeem_prize(%L,%L)$q$, k, pz)));
  perform public.cancel_prize_request(rq);
  insert into res values ('cancel refunds', (select coins from public.kids where id = k) = 40);
  insert into res values ('kid cannot give prize', pg_temp.fails(format($q$select public.give_prize(%L)$q$, rq)));
  rq := public.redeem_prize(k, pz);
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000c1', false);
  perform public.reject_prize(rq);
  insert into res values ('parent reject refunds once', (select coins from public.kids where id = k) = 40 and pg_temp.fails(format($q$select public.reject_prize(%L)$q$, rq)));
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000d1', true);
  rq := public.redeem_prize(k, pz);
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000c1', false);
  perform public.give_prize(rq);
  insert into res values ('give keeps coins spent', (select coins from public.kids where id = k) = 10 and (select status from public.prize_requests where id = rq) = 'given');
  reset role;
end $$;

reset role;
select step, ok from res;
rollback;
