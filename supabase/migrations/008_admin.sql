-- Admin control panel: roles, roster management, site content (files, links, tools, courses, lesson settings) and site settings.
alter table app.users add column if not exists role text not null default 'student' check (role in ('student','teacher','admin'));
alter table app.users add column if not exists courses text[] not null default '{}';   -- teacher: course keys they manage ('*' = all)
alter table app.users add column if not exists classes text[] not null default '{}';   -- teacher: grades/classes they teach (empty = all)
update app.users set role = 'teacher' where is_teacher and role = 'student';
update app.users set role = 'admin', courses = '{*}' where id = '2395741818';

create table if not exists app.content(
  id bigserial primary key,
  kind text not null check (kind in ('file','link','tool','course','lesson','dash')),
  course text not null default 'bio',     -- course key
  target text not null default '',        -- node id (bio) or module/lesson id in a custom course
  section text not null default '',       -- section name on the page (Engage, Explore, ...)
  title text not null default '',
  data jsonb not null default '{}'::jsonb,
  teacher_only boolean not null default false,
  hidden boolean not null default false,
  sort int not null default 0,
  created_by text,
  updated_at timestamptz not null default now()
);
create index if not exists content_course_idx on app.content(course, target);
alter table app.content enable row level security;

create or replace function app.admin(p_token uuid) returns text language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  v := app.uid(p_token);
  if not exists(select 1 from app.users where id = v and role = 'admin') then raise exception 'not_admin' using errcode = 'P0001'; end if;
  return v;
end $$;
-- teacher who may edit a course (admin always may)
create or replace function app.can_edit(p_token uuid, p_course text) returns text language plpgsql security definer set search_path = '' as $$
declare v text; u app.users;
begin
  v := app.uid(p_token);
  select * into u from app.users where id = v;
  if u.role = 'admin' or (u.role = 'teacher' and ('*' = any(u.courses) or p_course = any(u.courses))) then return v; end if;
  raise exception 'not_allowed' using errcode = 'P0001';
end $$;
revoke all on function app.admin(uuid), app.can_edit(uuid, text) from public, anon, authenticated;

-- profile now carries role, courses and classes, and the site settings
create or replace function app.profile(p_id text) returns jsonb language sql security definer set search_path = '' as $$
  select u.payload
    || jsonb_build_object('role', u.role, 'crs', to_jsonb(u.courses), 'cls', to_jsonb(u.classes), 'site', coalesce((select v from app.settings where k = 'site'), '{}'::jsonb))
    || case when u.is_teacher then jsonb_build_object('td', (select v from app.settings where k = 'tdrive'))
            else jsonb_build_object('sl', (select v from app.settings where k = 'slinks')) end
  from app.users u where u.id = p_id
$$;

-- teachers see the students of their classes (admin, or a teacher with no classes set, sees everyone)
create or replace function public.portal_roster(p_token uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v text; c text[]; r text;
begin
  v := app.teacher(p_token);
  select classes, role into c, r from app.users where id = v;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'n', name, 'g', grade, 'locked', locked_until is not null and locked_until > now()) order by grade, name)
    from app.users where not is_teacher and (r = 'admin' or cardinality(c) = 0 or grade = any(c))), '[]'::jsonb);
end $$;

-- ===== roster management (admin) =====
create or replace function public.portal_admin_users(p_token uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform app.admin(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'n', name, 'g', grade, 'role', role, 'crs', to_jsonb(courses), 'cls', to_jsonb(classes),
    'locked', locked_until is not null and locked_until > now(), 'created', created_at,
    'last', (select max(updated_at) from app.lesson_state s where s.user_id = u.id)) order by role desc, grade, name) from app.users u), '[]'::jsonb);
end $$;

create or replace function public.portal_admin_user_save(p_token uuid, p_id text, p_name text, p_grade text, p_role text, p_courses text[], p_classes text[], p_new boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me text; np text; tpl jsonb;
begin
  me := app.admin(p_token);
  if p_id !~ '^\d{10}$' then return jsonb_build_object('error','bad_id'); end if;
  if coalesce(trim(p_name),'') = '' then return jsonb_build_object('error','no_name'); end if;
  if p_role not in ('student','teacher','admin') then return jsonb_build_object('error','bad_role'); end if;
  if p_id = me and p_role <> 'admin' then return jsonb_build_object('error','self_role'); end if;
  if p_new then
    if exists(select 1 from app.users where id = p_id) then return jsonb_build_object('error','exists'); end if;
    np := lpad((floor(random()*1000000))::int::text, 6, '0');
    select payload->'l' into tpl from app.users where id = me;
    insert into app.users(id, name, grade, is_teacher, pin_hash, payload, role, courses, classes)
    values (p_id, trim(p_name), case when p_role = 'student' then p_grade else 'Teacher' end, p_role <> 'student', extensions.crypt(np, extensions.gen_salt('bf', 8)),
      case when p_role = 'student' then jsonb_build_object('n', trim(p_name), 'g', p_grade)
           else jsonb_build_object('n', trim(p_name), 'g', 'Teacher', 't', 1, 'c', array_to_string(p_classes, ' · '), 'l', coalesce(tpl, '[]'::jsonb)) end,
      p_role, coalesce(p_courses, '{}'), coalesce(p_classes, '{}'));
    return jsonb_build_object('ok', true, 'pin', np);
  end if;
  update app.users set name = trim(p_name), grade = case when p_role = 'student' then p_grade else 'Teacher' end, role = p_role, is_teacher = p_role <> 'student',
    courses = coalesce(p_courses, '{}'), classes = coalesce(p_classes, '{}'),
    payload = case when p_role = 'student' then (payload - 't' - 'l' - 'c') || jsonb_build_object('n', trim(p_name), 'g', p_grade)
                   else payload || jsonb_build_object('n', trim(p_name), 'g', 'Teacher', 't', 1, 'c', array_to_string(p_classes, ' · '))
                        || case when payload ? 'l' then '{}'::jsonb else jsonb_build_object('l', coalesce((select payload->'l' from app.users where id = me), '[]'::jsonb)) end end
  where id = p_id;
  if not found then return jsonb_build_object('error','not_found'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.portal_admin_user_delete(p_token uuid, p_id text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare me text;
begin
  me := app.admin(p_token);
  if p_id = me then return jsonb_build_object('error','self'); end if;
  delete from app.users where id = p_id;
  return jsonb_build_object('ok', found);
end $$;

-- admin can reset anyone's PIN (teachers included); teachers keep the student-only reset
create or replace function public.portal_admin_reset_pin(p_token uuid, p_id text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare np text;
begin
  perform app.admin(p_token);
  np := lpad((floor(random()*1000000))::int::text, 6, '0');
  update app.users set pin_hash = extensions.crypt(np, extensions.gen_salt('bf', 8)), failed = 0, locked_until = null where id = p_id;
  if not found then return jsonb_build_object('error','not_found'); end if;
  return jsonb_build_object('pin', np);
end $$;

-- bulk import: rows = [{id, n, g}] students; returns the new PINs
create or replace function public.portal_admin_import(p_token uuid, p_rows jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
declare r jsonb; np text; out jsonb := '[]'::jsonb;
begin
  perform app.admin(p_token);
  for r in select * from jsonb_array_elements(p_rows) loop
    if (r->>'id') !~ '^\d{10}$' or coalesce(trim(r->>'n'),'') = '' then out := out || jsonb_build_object('id', r->>'id', 'error', 'bad_row'); continue; end if;
    if exists(select 1 from app.users where id = r->>'id') then out := out || jsonb_build_object('id', r->>'id', 'n', r->>'n', 'error', 'exists'); continue; end if;
    np := lpad((floor(random()*1000000))::int::text, 6, '0');
    insert into app.users(id, name, grade, is_teacher, pin_hash, payload, role)
    values (r->>'id', trim(r->>'n'), r->>'g', false, extensions.crypt(np, extensions.gen_salt('bf', 8)), jsonb_build_object('n', trim(r->>'n'), 'g', r->>'g'), 'student');
    out := out || jsonb_build_object('id', r->>'id', 'n', r->>'n', 'g', r->>'g', 'pin', np);
  end loop;
  return out;
end $$;

-- ===== site content =====
create or replace function public.portal_content(p_token uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v text; t boolean;
begin
  v := app.uid(p_token);
  select is_teacher into t from app.users where id = v;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'course', course, 'target', target, 'section', section, 'title', title, 'data', data,
      'teacher', teacher_only, 'hidden', hidden, 'sort', sort, 'upd', updated_at) order by sort, id)
    from app.content where t or (not teacher_only and not hidden)), '[]'::jsonb);
end $$;

create or replace function public.portal_content_save(p_token uuid, p_item jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v text; nid bigint; crs text := coalesce(p_item->>'course','bio');
begin
  v := app.can_edit(p_token, crs);
  if (p_item->>'kind') = 'course' or (p_item->>'kind') = 'dash' then perform app.admin(p_token); end if;
  if p_item ? 'id' and (p_item->>'id') is not null then
    update app.content set kind = p_item->>'kind', course = crs, target = coalesce(p_item->>'target',''), section = coalesce(p_item->>'section',''),
      title = coalesce(p_item->>'title',''), data = coalesce(p_item->'data','{}'::jsonb), teacher_only = coalesce((p_item->>'teacher')::boolean,false),
      hidden = coalesce((p_item->>'hidden')::boolean,false), sort = coalesce((p_item->>'sort')::int,0), updated_at = now()
    where id = (p_item->>'id')::bigint returning id into nid;
  else
    insert into app.content(kind, course, target, section, title, data, teacher_only, hidden, sort, created_by)
    values (p_item->>'kind', crs, coalesce(p_item->>'target',''), coalesce(p_item->>'section',''), coalesce(p_item->>'title',''), coalesce(p_item->'data','{}'::jsonb),
      coalesce((p_item->>'teacher')::boolean,false), coalesce((p_item->>'hidden')::boolean,false), coalesce((p_item->>'sort')::int,0), v) returning id into nid;
  end if;
  return jsonb_build_object('ok', true, 'id', nid);
end $$;

create or replace function public.portal_content_delete(p_token uuid, p_id bigint) returns jsonb language plpgsql security definer set search_path = '' as $$
declare crs text;
begin
  select course into crs from app.content where id = p_id;
  if crs is null then return jsonb_build_object('error','not_found'); end if;
  perform app.can_edit(p_token, crs);
  delete from app.content where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ===== site settings + health =====
create or replace function public.portal_site_save(p_token uuid, p_site jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform app.admin(p_token);
  insert into app.settings(k, v) values ('site', p_site) on conflict (k) do update set v = excluded.v;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.portal_admin_stats(p_token uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform app.admin(p_token);
  return jsonb_build_object(
    'students', (select count(*) from app.users where role = 'student'),
    'teachers', (select count(*) from app.users where role <> 'student'),
    'grades', (select jsonb_object_agg(g, n) from (select grade g, count(*) n from app.users where role = 'student' group by grade) x),
    'active_today', (select count(distinct user_id) from app.lesson_state where updated_at > now() - interval '1 day'),
    'active_week', (select count(distinct user_id) from app.lesson_state where updated_at > now() - interval '7 days'),
    'sessions_now', (select count(*) from app.sessions where expires_at > now()),
    'lesson_saves', (select count(*) from app.lesson_state),
    'submissions', (select count(*) from app.submissions),
    'to_review', (select count(*) from app.submissions where reviewed_at is null),
    'tests', (select count(*) from app.tests),
    'attempts', (select count(*) from app.test_attempts),
    'content', (select count(*) from app.content),
    'locked', (select count(*) from app.users where locked_until > now()),
    'ai_today', (select coalesce(sum(n),0) from app.ai_usage where day = current_date),
    'db_size_mb', round(pg_database_size(current_database()) / 1048576.0, 1),
    'files_mb', (select round(coalesce(sum((metadata->>'size')::bigint),0) / 1048576.0, 1) from storage.objects where bucket_id = 'site-files'),
    'by_lesson', (select jsonb_object_agg(lesson, n) from (select lesson, count(*) n from app.lesson_state group by lesson) y));
end $$;

grant execute on function public.portal_admin_users(uuid), public.portal_admin_user_save(uuid,text,text,text,text,text[],text[],boolean), public.portal_admin_user_delete(uuid,text),
  public.portal_admin_reset_pin(uuid,text), public.portal_admin_import(uuid,jsonb), public.portal_content(uuid), public.portal_content_save(uuid,jsonb),
  public.portal_content_delete(uuid,bigint), public.portal_site_save(uuid,jsonb), public.portal_admin_stats(uuid) to anon, authenticated;

-- public bucket for uploaded files (paths are random; uploads only through the 'upload' edge function, which checks the session)
insert into storage.buckets(id, name, public, file_size_limit) values ('site-files', 'site-files', true, 52428800) on conflict (id) do nothing;
