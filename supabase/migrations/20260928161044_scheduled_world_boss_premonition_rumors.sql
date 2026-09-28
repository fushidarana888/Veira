-- Synced from live Supabase migration 20260928161044 (scheduled_world_boss_premonition_rumors)

update public.world_rumors set weight=10,rumor_kind='ambient' where related_event_slug is null;
insert into public.world_rumors(slug,title,body,min_level,enabled,starts_at,ends_at,weight,rumor_kind,related_event_slug)
 values('leviathan_sign_1','Соль на северном ветру','Рыбаки говорят, что море стало солонее обычного, а по ночам под водой слышен скрип, похожий на движение огромного киля.',1,true,'2026-10-17T15:00:00Z'::timestamptz,'2026-10-25T15:00:00Z'::timestamptz,50,'premonition','world_2026_10_22_salt_leviathan')
 on conflict(slug) do update set title=excluded.title,body=excluded.body,enabled=true,starts_at=excluded.starts_at,ends_at=excluded.ends_at,weight=excluded.weight,rumor_kind=excluded.rumor_kind,related_event_slug=excluded.related_event_slug;
insert into public.world_rumors(slug,title,body,min_level,enabled,starts_at,ends_at,weight,rumor_kind,related_event_slug)
 values('leviathan_sign_2','Пустые сети','В нескольких прибрежных поселениях сети поднимают целыми, но совершенно пустыми. Даже мелкая рыба ушла от берега.',1,true,'2026-10-17T15:00:00Z'::timestamptz,'2026-10-25T15:00:00Z'::timestamptz,50,'premonition','world_2026_10_22_salt_leviathan')
 on conflict(slug) do update set title=excluded.title,body=excluded.body,enabled=true,starts_at=excluded.starts_at,ends_at=excluded.ends_at,weight=excluded.weight,rumor_kind=excluded.rumor_kind,related_event_slug=excluded.related_event_slug;
insert into public.world_rumors(slug,title,body,min_level,enabled,starts_at,ends_at,weight,rumor_kind,related_event_slug)
 values('leviathan_sign_3','След на глубине','С дозорных башен видели длинную белую линию под северной водой. Она двигалась против течения.',1,true,'2026-10-18T15:00:00Z'::timestamptz,'2026-10-26T15:00:00Z'::timestamptz,50,'premonition','world_2026_10_22_salt_leviathan')
 on conflict(slug) do update set title=excluded.title,body=excluded.body,enabled=true,starts_at=excluded.starts_at,ends_at=excluded.ends_at,weight=excluded.weight,rumor_kind=excluded.rumor_kind,related_event_slug=excluded.related_event_slug;
insert into public.world_rumors(slug,title,body,min_level,enabled,starts_at,ends_at,weight,rumor_kind,related_event_slug)
 values('aster_sign_1','Неправильные звёзды','Астрономы спорят: несколько звёзд за одну ночь сместились так, будто небо повернулось вокруг неизвестной оси.',1,true,'2026-11-14T15:00:00Z'::timestamptz,'2026-11-22T15:00:00Z'::timestamptz,50,'premonition','world_2026_11_19_aster')
 on conflict(slug) do update set title=excluded.title,body=excluded.body,enabled=true,starts_at=excluded.starts_at,ends_at=excluded.ends_at,weight=excluded.weight,rumor_kind=excluded.rumor_kind,related_event_slug=excluded.related_event_slug;
insert into public.world_rumors(slug,title,body,min_level,enabled,starts_at,ends_at,weight,rumor_kind,related_event_slug)
 values('aster_sign_2','Тени без облаков','На равнинах появились длинные движущиеся тени, хотя небо совершенно чистое.',1,true,'2026-11-14T15:00:00Z'::timestamptz,'2026-11-22T15:00:00Z'::timestamptz,50,'premonition','world_2026_11_19_aster')
 on conflict(slug) do update set title=excluded.title,body=excluded.body,enabled=true,starts_at=excluded.starts_at,ends_at=excluded.ends_at,weight=excluded.weight,rumor_kind=excluded.rumor_kind,related_event_slug=excluded.related_event_slug;
insert into public.world_rumors(slug,title,body,min_level,enabled,starts_at,ends_at,weight,rumor_kind,related_event_slug)
 values('aster_sign_3','Шум над облаками','Ночью над горами слышен низкий гул. Птицы покидают верхние перевалы.',1,true,'2026-11-15T15:00:00Z'::timestamptz,'2026-11-23T15:00:00Z'::timestamptz,50,'premonition','world_2026_11_19_aster')
 on conflict(slug) do update set title=excluded.title,body=excluded.body,enabled=true,starts_at=excluded.starts_at,ends_at=excluded.ends_at,weight=excluded.weight,rumor_kind=excluded.rumor_kind,related_event_slug=excluded.related_event_slug;
insert into public.world_rumors(slug,title,body,min_level,enabled,starts_at,ends_at,weight,rumor_kind,related_event_slug)
 values('gravity_sign_1','Камни падают вверх','В горах нашли осыпь, часть которой застыла на деревьях снизу вверх. Никто не понимает, как камни туда попали.',1,true,'2026-12-12T15:00:00Z'::timestamptz,'2026-12-20T15:00:00Z'::timestamptz,50,'premonition','world_2026_12_17_gravity_dragon')
 on conflict(slug) do update set title=excluded.title,body=excluded.body,enabled=true,starts_at=excluded.starts_at,ends_at=excluded.ends_at,weight=excluded.weight,rumor_kind=excluded.rumor_kind,related_event_slug=excluded.related_event_slug;
insert into public.world_rumors(slug,title,body,min_level,enabled,starts_at,ends_at,weight,rumor_kind,related_event_slug)
 values('gravity_sign_2','Тяжёлый горизонт','Путники жалуются, что на некоторых дорогах шаг внезапно становится вдвое тяжелее, а через сотню метров всё проходит.',1,true,'2026-12-12T15:00:00Z'::timestamptz,'2026-12-20T15:00:00Z'::timestamptz,50,'premonition','world_2026_12_17_gravity_dragon')
 on conflict(slug) do update set title=excluded.title,body=excluded.body,enabled=true,starts_at=excluded.starts_at,ends_at=excluded.ends_at,weight=excluded.weight,rumor_kind=excluded.rumor_kind,related_event_slug=excluded.related_event_slug;
insert into public.world_rumors(slug,title,body,min_level,enabled,starts_at,ends_at,weight,rumor_kind,related_event_slug)
 values('gravity_sign_3','Трещина без края','Над дальними вершинами появилась тонкая чёрная линия. Днём её почти не видно, ночью вокруг неё искажаются звёзды.',1,true,'2026-12-13T15:00:00Z'::timestamptz,'2026-12-21T15:00:00Z'::timestamptz,50,'premonition','world_2026_12_17_gravity_dragon')
 on conflict(slug) do update set title=excluded.title,body=excluded.body,enabled=true,starts_at=excluded.starts_at,ends_at=excluded.ends_at,weight=excluded.weight,rumor_kind=excluded.rumor_kind,related_event_slug=excluded.related_event_slug;
create index if not exists world_rumors_active_window_idx on public.world_rumors(enabled,starts_at,ends_at);
