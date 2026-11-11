-- Teacher-only Google Drive links (answer keys, planners, teacher slides) are stored in app.settings('tdrive')
-- and returned only in the teacher's profile. The values are set directly in the database, not in this repository.
create or replace function app.profile(p_id text) returns jsonb language sql security definer set search_path = '' as $$
  select u.payload || case when u.is_teacher then jsonb_build_object('td', (select v from app.settings where k = 'tdrive'))
                           else jsonb_build_object('sl', (select v from app.settings where k = 'slinks')) end
  from app.users u where u.id = p_id
$$;
revoke all on function app.profile(text) from public, anon, authenticated;
