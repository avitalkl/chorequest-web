-- Silverware sort. Adds the game id only. No chore is switched over.
-- Drop each check before adding the wider one, so this runs in one go.

alter table public.chores drop constraint if exists chores_game_check;

alter table public.chores add constraint chores_game_check
  check (game in (
    'memory', 'bubbles', 'stars', 'critters', 'simon', 'count', 'none',
    'queens', 'tennis', 'bounce', 'sudoku', 'scramble', 'slide', 'reflex', 'birds',
    'silver'));

alter table public.game_events drop constraint if exists game_events_game_check;

alter table public.game_events add constraint game_events_game_check
  check (game in (
    'memory', 'bubbles', 'stars', 'critters', 'simon', 'count',
    'queens', 'tennis', 'flip', 'bounce', 'sudoku', 'scramble', 'slide', 'reflex', 'birds',
    'silver'));

create or replace function public.log_game_event(p_kid uuid, p_game text, p_action text) returns void
language plpgsql security definer set search_path = '' as $$
declare k public.kids;
begin
  if p_action not in ('played', 'skipped', 'liked', 'disliked') then raise exception 'bad action'; end if;
  if p_game not in (
    'memory', 'bubbles', 'stars', 'critters', 'simon', 'count',
    'queens', 'tennis', 'flip', 'bounce', 'sudoku', 'scramble', 'slide', 'reflex', 'birds',
    'silver'
  ) then raise exception 'bad game'; end if;
  select * into k from public.kids where id = p_kid;
  if k.id is null then raise exception 'unknown kid'; end if;
  if not (public.is_kid_device(p_kid) or public.is_member(k.household_id)) then
    raise exception 'not allowed';
  end if;
  insert into public.game_events (household_id, kid_id, game, action)
  values (k.household_id, p_kid, p_game, p_action);
end $$;

-- Optional. Uncomment to point a dishes chore at this game.
-- Or leave it and pick "Silverware sort" / "מיון סכו״ם" on the chore in the app.
-- update public.chores
--   set game = 'silver'
--   where active
--     and (title ilike '%dish%' or coalesce(title_he, '') like '%כלים%');
