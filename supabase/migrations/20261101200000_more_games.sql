alter table public.chores drop constraint if exists chores_game_check;
alter table public.chores add constraint chores_game_check
  check (game in ('memory', 'bubbles', 'stars', 'critters', 'simon', 'count', 'none',
    'queens', 'tennis', 'flip', 'sudoku', 'scramble', 'slide', 'reflex', 'birds'));
