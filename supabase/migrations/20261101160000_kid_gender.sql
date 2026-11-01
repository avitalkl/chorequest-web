alter table public.kids add column gender text not null default 'girl' check (gender in ('girl', 'boy'));

grant insert (gender), update (gender) on public.kids to authenticated;

insert into public.shop_items (key, price) values
('style:short', 0),
('style:spiky', 8),
('style:messy', 10),
('bottom:joggers', 6),
('hat:cap', 12),
('hat:beanie', 14);
