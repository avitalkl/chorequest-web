alter table public.chores add column if not exists title_he text check (title_he is null or char_length(title_he) between 1 and 60);
alter table public.prizes add column if not exists title_he text check (title_he is null or char_length(title_he) between 1 and 60);
grant insert (title_he), update (title_he) on public.chores to authenticated;
grant insert (title_he), update (title_he) on public.prizes to authenticated;
