-- Boys' default shirt colour must be free, otherwise set_worn rejects every outfit save.
update public.shop_items set price = 0 where key = 'topc:sky';
