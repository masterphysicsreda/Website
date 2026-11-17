-- 010: 3D avatar per user (applied 2026-11-17)
alter table app.users add column if not exists avatar jsonb;
-- public.portal_avatar_get(p_token uuid) -> jsonb   (own avatar)
-- public.portal_avatar_save(p_token uuid, p_avatar jsonb) -> {ok}|{error}  (max ~320 KB, image must be a data:image jpeg/png/webp URL)
