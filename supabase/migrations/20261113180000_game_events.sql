-- How often a kid plays a chore game through, or skips it.
create table public.game_events (
  id bigint generated always as identity primary key,
  household_id uuid not null references public.households on delete cascade,
  kid_id uuid not null references public.kids on delete cascade,
  game text not null check (game in (
    'memory', 'bubbles', 'stars', 'critters', 'simon', 'count',
    'queens', 'tennis', 'flip', 'sudoku', 'scramble', 'slide', 'reflex', 'birds')),
  action text not null check (action in ('played', 'skipped', 'liked', 'disliked')),
  created_at timestamptz not null default now()
);
create index on public.game_events (household_id, created_at desc);

alter table public.game_events enable row level security;
revoke all on public.game_events from anon, authenticated;
grant select on public.game_events to authenticated;

create policy game_events_select on public.game_events for select to authenticated
  using (public.is_member(household_id));

create function public.log_game_event(p_kid uuid, p_game text, p_action text) returns void
language plpgsql security definer set search_path = '' as $$
declare k public.kids;
begin
  if p_action not in ('played', 'skipped', 'liked', 'disliked') then raise exception 'bad action'; end if;
  if p_game not in (
    'memory', 'bubbles', 'stars', 'critters', 'simon', 'count',
    'queens', 'tennis', 'flip', 'sudoku', 'scramble', 'slide', 'reflex', 'birds'
  ) then raise exception 'bad game'; end if;
  select * into k from public.kids where id = p_kid;
  if k.id is null then raise exception 'unknown kid'; end if;
  if not (public.is_kid_device(p_kid) or public.is_member(k.household_id)) then
    raise exception 'not allowed';
  end if;
  insert into public.game_events (household_id, kid_id, game, action)
  values (k.household_id, p_kid, p_game, p_action);
end $$;

revoke all on function public.log_game_event(uuid, text, text) from public, anon;
grant execute on function public.log_game_event(uuid, text, text) to authenticated;
