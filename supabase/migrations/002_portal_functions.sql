-- Internal helpers (not callable from the website)
create or replace function app.uid(p_token uuid) returns text language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  select user_id into v from app.sessions where token = p_token and expires_at > now();
  if v is null then raise exception 'session_expired' using errcode = 'P0001'; end if;
  return v;
end $$;
create or replace function app.teacher(p_token uuid) returns text language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  v := app.uid(p_token);
  if not exists(select 1 from app.users where id = v and is_teacher) then raise exception 'not_teacher' using errcode = 'P0001'; end if;
  return v;
end $$;
create or replace function app.profile(p_id text) returns jsonb language sql security definer set search_path = '' as $$
  select u.payload || case when u.is_teacher then '{}'::jsonb else jsonb_build_object('sl', (select v from app.settings where k = 'slinks')) end
  from app.users u where u.id = p_id
$$;
revoke all on function app.uid(uuid), app.teacher(uuid), app.profile(text) from public, anon, authenticated;

-- Login with ID + PIN (5 wrong PINs lock the account for 10 minutes)
create or replace function public.portal_login(p_id text, p_pin text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare u app.users; t uuid;
begin
  select * into u from app.users where id = p_id;
  if u.id is null then perform pg_sleep(0.4); return jsonb_build_object('error','not_found'); end if;
  if u.locked_until is not null and u.locked_until > now() then return jsonb_build_object('error','locked','until',u.locked_until); end if;
  if u.pin_hash <> extensions.crypt(coalesce(p_pin,''), u.pin_hash) then
    update app.users set failed = failed + 1, locked_until = case when failed + 1 >= 5 then now() + interval '10 minutes' else null end where id = p_id;
    perform pg_sleep(0.4);
    return jsonb_build_object('error','bad_pin');
  end if;
  update app.users set failed = 0, locked_until = null where id = p_id;
  delete from app.sessions where expires_at < now();
  insert into app.sessions(user_id) values (p_id) returning token into t;
  return jsonb_build_object('token', t, 'id', u.id, 'user', app.profile(u.id));
end $$;
create or replace function public.portal_me(p_token uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v text;
begin v := app.uid(p_token); return jsonb_build_object('id', v, 'user', app.profile(v)); end $$;
create or replace function public.portal_logout(p_token uuid) returns void language sql security definer set search_path = '' as $$ delete from app.sessions where token = p_token $$;
create or replace function public.portal_change_pin(p_token uuid, p_old text, p_new text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  v := app.uid(p_token);
  if p_new !~ '^\d{6}$' then return jsonb_build_object('error','pin_format'); end if;
  if not exists(select 1 from app.users where id = v and pin_hash = extensions.crypt(p_old, pin_hash)) then return jsonb_build_object('error','bad_pin'); end if;
  update app.users set pin_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 8)) where id = v;
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.portal_reset_pin(p_token uuid, p_id text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare np text;
begin
  perform app.teacher(p_token);
  np := lpad((floor(random()*1000000))::int::text, 6, '0');
  update app.users set pin_hash = extensions.crypt(np, extensions.gen_salt('bf', 8)), failed = 0, locked_until = null where id = p_id and not is_teacher;
  if not found then return jsonb_build_object('error','not_found'); end if;
  return jsonb_build_object('pin', np);
end $$;

-- Lesson progress (each student reads/writes only their own)
create or replace function public.portal_lessons(p_token uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v text;
begin v := app.uid(p_token); return coalesce((select jsonb_object_agg(lesson, state) from app.lesson_state where user_id = v), '{}'::jsonb); end $$;
create or replace function public.portal_save_lesson(p_token uuid, p_lesson text, p_state jsonb, p_summary jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  v := app.uid(p_token);
  if exists(select 1 from app.users where id = v and is_teacher) then return jsonb_build_object('ok', false, 'teacher', true); end if;
  if length(p_lesson) > 60 or pg_column_size(p_state) > 400000 or pg_column_size(p_summary) > 20000 then return jsonb_build_object('error','too_large'); end if;
  insert into app.lesson_state(user_id, lesson, state, summary, updated_at) values (v, p_lesson, p_state, p_summary, now())
  on conflict (user_id, lesson) do update set state = excluded.state, summary = excluded.summary, updated_at = now();
  return jsonb_build_object('ok', true, 'at', now());
end $$;

-- Teacher only
create or replace function public.portal_class_results(p_token uuid, p_lesson text default null) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform app.teacher(p_token);
  return coalesce((select jsonb_agg(ls.summary || jsonb_build_object('n', u.name, 'g', u.grade, 'i', right(u.id,4), 'l', ls.lesson, 'upd', ls.updated_at) order by u.grade, u.name)
    from app.lesson_state ls join app.users u on u.id = ls.user_id
    where ls.summary is not null and (p_lesson is null or ls.lesson = p_lesson)), '[]'::jsonb);
end $$;
create or replace function public.portal_roster(p_token uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform app.teacher(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'n', name, 'g', grade, 'locked', locked_until is not null and locked_until > now()) order by grade, name) from app.users where not is_teacher), '[]'::jsonb);
end $$;

-- Calendar (everyone reads public events; only the teacher saves; private events only for the teacher)
create or replace function public.portal_events(p_token uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v text; t boolean;
begin
  v := app.uid(p_token);
  select is_teacher into t from app.users where id = v;
  return jsonb_build_object(
    'pub', coalesce((select jsonb_agg(data order by data->>'date', data->>'time') from app.events where not priv), '[]'::jsonb),
    'priv', case when t then coalesce((select jsonb_agg(data order by data->>'date', data->>'time') from app.events where priv), '[]'::jsonb) else null end);
end $$;
create or replace function public.portal_save_events(p_token uuid, p_pub jsonb, p_priv jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform app.teacher(p_token);
  if jsonb_typeof(p_pub) <> 'array' or jsonb_typeof(coalesce(p_priv,'[]'::jsonb)) <> 'array' then return jsonb_build_object('error','format'); end if;
  delete from app.events where true;
  insert into app.events(id, priv, data) select coalesce(e->>'id', gen_random_uuid()::text), false, e from jsonb_array_elements(p_pub) e on conflict (id) do nothing;
  insert into app.events(id, priv, data) select coalesce(e->>'id', gen_random_uuid()::text), true, e from jsonb_array_elements(coalesce(p_priv,'[]'::jsonb)) e on conflict (id) do nothing;
  return jsonb_build_object('ok', true);
end $$;

-- Notes
create or replace function public.portal_notes(p_token uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v text;
begin v := app.uid(p_token); return coalesce((select jsonb_object_agg(lesson, data) from app.notes where user_id = v), '{}'::jsonb); end $$;
create or replace function public.portal_save_notes(p_token uuid, p_lesson text, p_data jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  v := app.uid(p_token);
  if pg_column_size(p_data) > 3000000 then return jsonb_build_object('error','too_large'); end if;
  insert into app.notes(user_id, lesson, data, updated_at) values (v, p_lesson, p_data, now())
  on conflict (user_id, lesson) do update set data = excluded.data, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- AI marking allowance: 120 calls per student per day
create or replace function public.portal_ai_allow(p_token uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v text; n int;
begin
  v := app.uid(p_token);
  insert into app.ai_usage(user_id, day, n) values (v, current_date, 1)
  on conflict (user_id, day) do update set n = app.ai_usage.n + 1 returning app.ai_usage.n into n;
  return jsonb_build_object('ok', n <= 120, 'n', n);
end $$;

revoke all on all functions in schema public from public;
grant execute on function public.portal_login(text,text), public.portal_me(uuid), public.portal_logout(uuid), public.portal_change_pin(uuid,text,text),
  public.portal_reset_pin(uuid,text), public.portal_lessons(uuid), public.portal_save_lesson(uuid,text,jsonb,jsonb), public.portal_class_results(uuid,text),
  public.portal_roster(uuid), public.portal_events(uuid), public.portal_save_events(uuid,jsonb,jsonb), public.portal_notes(uuid), public.portal_save_notes(uuid,text,jsonb),
  public.portal_ai_allow(uuid) to anon, authenticated, service_role;
