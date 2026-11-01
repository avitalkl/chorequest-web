begin;
insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'p1@test.local'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'p2@test.local'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', null);
create temp table res (step text, ok boolean, info text);
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
declare h uuid; k uuid; code text; chore uuid; cid uuid; pcode text;
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000a1', false);
  h := public.create_household('Test family');
  insert into res values ('household+6 default chores', (select count(*) from public.chores where household_id = h) = 6, null);
  insert into public.kids (household_id, name) values (h, 'Cara') returning id into k;
  code := public.create_kid_invite(k);
  select id into chore from public.chores where household_id = h and title = 'Do homework';

  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000b1', true);
  insert into res values ('kid cannot see kid before claim', (select count(*) from public.kids) = 0, null);
  insert into res values ('bad code rejected', pg_temp.fails($q$select public.claim_kid_invite('nope')$q$), null);
  perform public.claim_kid_invite(code);
  insert into res values ('kid sees own kid + 6 chores', (select count(*) from public.kids) = 1 and (select count(*) from public.chores) = 6, null);
  insert into res values ('kid cannot create household', pg_temp.fails($q$select public.create_household('x')$q$), null);
  insert into res values ('kid cannot edit coins', pg_temp.fails(format($q$update public.kids set coins = 999 where id = %L$q$, k)), null);
  update public.kids set name = 'Hacked' where id = k;
  insert into res values ('kid cannot rename (rls hides rows)', (select name from public.kids where id = k) = 'Cara', null);
  insert into res values ('kid cannot write ledger', pg_temp.fails(format($q$insert into public.coin_ledger (household_id,kid_id,amount,kind) values (%L,%L,100,'chore')$q$, h, k)), null);
  cid := public.submit_completion(k, chore, 99);
  insert into res values ('completion pending, bonus capped at 20', (select status = 'pending' and bonus = 20 from public.completions where id = cid), null);
  insert into res values ('double submit same day blocked', pg_temp.fails(format($q$select public.submit_completion(%L,%L,0)$q$, k, chore)), null);
  insert into res values ('kid cannot approve', pg_temp.fails(format($q$select public.approve_completion(%L)$q$, cid)), null);
  insert into res values ('no coins before approval', (select coins from public.kids where id = k) = 0, null);

  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000a2', false);
  insert into res values ('stranger parent sees nothing', (select count(*) from public.kids) = 0 and (select count(*) from public.completions) = 0, null);
  insert into res values ('stranger cannot approve', pg_temp.fails(format($q$select public.approve_completion(%L)$q$, cid)), null);

  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000a1', false);
  pcode := public.create_parent_invite();
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000a2', false);
  perform public.accept_parent_invite(pcode);
  insert into res values ('co-parent joined and sees kid', (select count(*) from public.kids) = 1, null);
  perform public.approve_completion(cid);
  perform public.approve_completion(cid);
  insert into res values ('approve idempotent: paid once (10+20)', (select coins from public.kids where id = k) = 30 and (select count(*) from public.coin_ledger) = 1, null);

  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000b1', true);
  insert into res values ('kid cannot buy more than balance', pg_temp.fails($q$select public.buy_item((select id from public.kids limit 1), 'hair:rainbow')$q$), null);
  perform public.buy_item(k, 'hair:blonde');
  insert into res values ('purchase deducts price (30-8)', (select coins from public.kids where id = k) = 22, null);
  perform public.buy_item(k, 'hair:blonde');
  insert into res values ('repeat purchase free/no-op', (select coins from public.kids where id = k) = 22, null);
  perform public.set_worn(k, '{"hair":"blonde","style":"long"}'::jsonb);
  insert into res values ('wear owned item ok', (select worn ->> 'hair' from public.kids where id = k) = 'blonde', null);
  insert into res values ('cannot wear unowned item', pg_temp.fails(format($q$select public.set_worn(%L, '{"hair":"rainbow"}'::jsonb)$q$, k)), null);
end $$;
select * from res;
rollback;
