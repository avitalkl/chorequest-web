-- More avatar items (hair, clothes, hats, pets, places).
insert into public.shop_items (key, price) values
('hair:silver', 15), ('hair:darkblonde', 0), ('hair:green', 20),
('style:buzz', 0), ('style:sidepart', 4), ('style:mohawk', 14), ('style:afro', 18),
('eyes:gray', 0), ('eyes:amber', 5),
('mouth:smirk', 5), ('mouth:tongue', 8),
('face:bandaid', 5), ('face:warpaint', 8),
('top:sweatshirt', 14), ('top:jacket', 18), ('top:cape', 25), ('top:jersey', 12), ('top:polo', 8),
('bottom:cargo', 8), ('bottom:longshorts', 8),
('shoes:redsneak', 5), ('shoes:greensneak', 5), ('shoes:blacksneak', 6), ('shoes:blackboot', 12),
('hat:snow', 16), ('hat:cowboy', 20), ('hat:tophat', 22), ('hat:knight', 26), ('hat:wizard', 28),
('acc:headphones', 20), ('acc:bowtie', 12), ('acc:scarf', 14),
('pet:turtle', 25), ('pet:frog', 20), ('pet:fox', 30), ('pet:penguin', 30), ('pet:panda', 35),
('pet:lion', 40), ('pet:dino', 40), ('pet:shark', 45), ('pet:dragon', 50),
('bg:soccer', 15), ('bg:snow', 18), ('bg:city', 18), ('bg:castle', 25), ('bg:underwater', 28)
on conflict (key) do update set price = excluded.price;
