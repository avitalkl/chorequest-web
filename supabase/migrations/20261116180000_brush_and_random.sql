-- Replace emoji sudoku with sparkle brush, and allow a Random game on chores.
-- Chores that still say sudoku become brush. Old sudoku rows in game_events stay valid.
-- 'random' is only a chore setting. The kid app logs the game she actually played.
-- Paste this whole file. It is idempotent.

begin;

alter table public.chores drop constraint if exists chores_game_check;

update public.chores set game = 'brush' where game = 'sudoku';

alter table public.chores add constraint chores_game_check
  check (game in (
    'memory', 'bubbles', 'stars', 'critters', 'simon', 'count', 'none',
    'queens', 'tennis', 'bounce', 'scramble', 'slide', 'reflex', 'birds',
    'silver', 'brush', 'random'));

alter table public.game_events drop constraint if exists game_events_game_check;

alter table public.game_events add constraint game_events_game_check
  check (game in (
    'memory', 'bubbles', 'stars', 'critters', 'simon', 'count',
    'queens', 'tennis', 'flip', 'bounce', 'sudoku', 'scramble', 'slide', 'reflex', 'birds',
    'silver', 'brush'));

create or replace function public.log_game_event(p_kid uuid, p_game text, p_action text) returns void
language plpgsql security definer set search_path = '' as $$
declare k public.kids;
begin
  if p_action not in ('played', 'skipped', 'liked', 'disliked') then raise exception 'bad action'; end if;
  if p_game not in (
    'memory', 'bubbles', 'stars', 'critters', 'simon', 'count',
    'queens', 'tennis', 'flip', 'bounce', 'sudoku', 'scramble', 'slide', 'reflex', 'birds',
    'silver', 'brush'
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

commit;
