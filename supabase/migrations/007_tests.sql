-- Assessments: teacher-made tests (from an uploaded Word/PDF with answer fields placed on the pages, or from a lesson's
-- question bank), assigned to a grade or chosen students, timed, auto-marked against the teacher's key (re-marked when
-- the key changes), with manual points for open questions.
create table if not exists app.tests (
  id bigserial primary key,
  title text not null,
  grade text not null,
  students text[],                    -- null = every student in the grade
  lesson text,                        -- lesson node id (optional)
  kind text not null default 'doc' check (kind in ('doc','bank')),
  opens_at timestamptz, due_at timestamptz,
  duration_min int,                   -- null = no time limit
  show text not null default 'submit' check (show in ('submit','due','never')),
  status text not null default 'draft' check (status in ('draft','published')),
  q jsonb not null default '[]',      -- questions without answers
  key jsonb not null default '{}',    -- answers, teacher only
  npages int not null default 0,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists app.test_pages (
  test_id bigint not null references app.tests(id) on delete cascade,
  n int not null, img text not null,
  primary key (test_id, n)
);
create table if not exists app.test_attempts (
  id bigserial primary key,
  test_id bigint not null references app.tests(id) on delete cascade,
  user_id text not null references app.users(id) on delete cascade,
  answers jsonb not null default '{}',
  overrides jsonb not null default '{}',
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  result jsonb,
  unique (test_id, user_id)
);
alter table app.tests enable row level security;
alter table app.test_pages enable row level security;
alter table app.test_attempts enable row level security;
revoke all on app.tests, app.test_pages, app.test_attempts from public, anon, authenticated;

create or replace function app.tnorm(x text) returns text language sql immutable set search_path to '' as $$
  select regexp_replace(regexp_replace(lower(trim(coalesce(x,''))), '\s+', ' ', 'g'), '[\s\.,;:!?]+$', '')
$$;

-- mark one attempt: q = questions, k = key, a = answers, o = teacher overrides {qid: points}
create or replace function app.mark_test(q jsonb, k jsonb, a jsonb, o jsonb) returns jsonb
language plpgsql immutable set search_path to '' as $$
declare e jsonb; id text; t text; pts numeric; kv jsonb; av jsonb; earned numeric; ok boolean;
  score numeric := 0; mx numeric := 0; pending int := 0; items jsonb := '{}'; n int; c int; i int; alt text; x numeric; kn numeric; tol numeric;
begin
  for e in select * from jsonb_array_elements(coalesce(q,'[]')) loop
    id := e->>'id'; t := e->>'t'; pts := coalesce((e->>'p')::numeric, 1); kv := k->id; av := a->id; earned := null; ok := null;
    if t = 'info' then continue; end if;
    mx := mx + pts;
    if o ? id then earned := least(pts, greatest(0, (o->>id)::numeric)); ok := earned >= pts;
    elsif kv is null or kv = 'null'::jsonb then earned := null;
    elsif t in ('tf','mcq') then ok := upper(coalesce(av #>> '{}','')) = upper(kv #>> '{}'); earned := case when ok then pts else 0 end;
    elsif t = 'blank' then
      ok := false;
      foreach alt in array string_to_array(kv #>> '{}', '|') loop
        if app.tnorm(alt) <> '' and app.tnorm(alt) = app.tnorm(av #>> '{}') then ok := true; end if;
      end loop;
      earned := case when ok then pts else 0 end;
    elsif t = 'num' then
      begin x := replace(trim(coalesce(av #>> '{}','')), ',', '.')::numeric; exception when others then x := null; end;
      kn := (kv->>'v')::numeric; tol := coalesce((kv->>'tol')::numeric, 0);
      ok := x is not null and abs(x - kn) <= greatest(abs(kn) * tol, 0.000001); earned := case when ok then pts else 0 end;
    elsif t = 'match' then
      n := jsonb_array_length(kv); c := 0;
      for i in 0 .. n - 1 loop
        if av is not null and jsonb_typeof(av) = 'array' and upper(coalesce(av->>i,'')) = upper(kv->>i) then c := c + 1; end if;
      end loop;
      earned := case when n > 0 then round(pts * c / n, 2) else 0 end; ok := c = n;
    else earned := null; -- open: teacher marks it
    end if;
    if earned is null then pending := pending + 1; else score := score + earned; end if;
    items := items || jsonb_build_object(id, jsonb_build_object('p', earned, 'ok', ok));
  end loop;
  return jsonb_build_object('score', score, 'max', mx, 'pending', pending, 'items', items);
end $$;

create or replace function app.test_open_for(t app.tests, v_uid text) returns boolean language sql stable set search_path to '' as $$
  select t.status = 'published' and exists (select 1 from app.users u where u.id = v_uid and u.grade = t.grade)
    and (t.students is null or v_uid = any(t.students) or right(v_uid, 4) = any(t.students))
$$;
create or replace function app.test_release(t app.tests, at app.test_attempts) returns boolean language sql stable set search_path to '' as $$
  select at.submitted_at is not null and (t.show = 'submit' or (t.show = 'due' and t.due_at is not null and now() > t.due_at))
$$;

create or replace function public.portal_tests(p_token uuid) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare v_uid text := app.uid(p_token); v_t boolean;
begin
  select is_teacher into v_t from app.users where id = v_uid;
  if v_t then
    return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title, 'grade', t.grade, 'students', t.students, 'lesson', t.lesson, 'kind', t.kind,
        'opens', t.opens_at, 'due', t.due_at, 'dur', t.duration_min, 'show', t.show, 'status', t.status, 'nq', jsonb_array_length(t.q), 'npages', t.npages, 'upd', t.updated_at,
        'nsub', (select count(*) from app.test_attempts a where a.test_id = t.id and a.submitted_at is not null),
        'nstart', (select count(*) from app.test_attempts a where a.test_id = t.id),
        'avg', (select round(avg(((a.result->>'score')::numeric) / nullif((a.result->>'max')::numeric, 0)) * 100, 1) from app.test_attempts a where a.test_id = t.id and a.submitted_at is not null))
      order by coalesce(t.opens_at, t.created_at) desc) from app.tests t), '[]'::jsonb);
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title, 'lesson', t.lesson, 'kind', t.kind, 'opens', t.opens_at, 'due', t.due_at,
      'dur', t.duration_min, 'show', t.show, 'nq', jsonb_array_length(t.q),
      'started', a.started_at, 'submitted', a.submitted_at,
      'result', case when a.id is not null and app.test_release(t, a) then a.result end)
    order by coalesce(t.due_at, t.opens_at, t.created_at) desc)
    from app.tests t left join app.test_attempts a on a.test_id = t.id and a.user_id = v_uid
    where app.test_open_for(t, v_uid)), '[]'::jsonb);
end $$;

create or replace function public.portal_test_get(p_token uuid, p_id bigint) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare v_uid text := app.uid(p_token); v_t boolean; t app.tests; a app.test_attempts;
begin
  select is_teacher into v_t from app.users where id = v_uid;
  select * into t from app.tests where id = p_id;
  if t.id is null then return jsonb_build_object('error','not_found'); end if;
  if v_t then return to_jsonb(t) - 'created_at'; end if;
  if not app.test_open_for(t, v_uid) then return jsonb_build_object('error','not_found'); end if;
  select * into a from app.test_attempts where test_id = t.id and user_id = v_uid;
  return jsonb_build_object('id', t.id, 'title', t.title, 'lesson', t.lesson, 'kind', t.kind, 'opens', t.opens_at, 'due', t.due_at, 'dur', t.duration_min,
    'show', t.show, 'q', t.q, 'npages', t.npages, 'now', now(),
    'attempt', case when a.id is null then null else jsonb_build_object('answers', a.answers, 'started', a.started_at, 'submitted', a.submitted_at,
      'result', case when app.test_release(t, a) then a.result end) end,
    'key', case when a.id is not null and app.test_release(t, a) then t.key end);
end $$;

create or replace function public.portal_test_page(p_token uuid, p_id bigint, p_n int) returns text
language plpgsql security definer set search_path to '' as $$
declare v_uid text := app.uid(p_token); v_t boolean; t app.tests;
begin
  select is_teacher into v_t from app.users where id = v_uid;
  select * into t from app.tests where id = p_id;
  if t.id is null or not (coalesce(v_t,false) or app.test_open_for(t, v_uid)) then return null; end if;
  return (select img from app.test_pages where test_id = p_id and n = p_n);
end $$;

create or replace function public.portal_test_save(p_token uuid, p_id bigint, p_meta jsonb, p_q jsonb, p_key jsonb) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare v_id bigint := p_id; v_n int;
begin
  perform app.teacher(p_token);
  if pg_column_size(p_q) > 600000 or pg_column_size(p_key) > 300000 then return jsonb_build_object('error','too_large'); end if;
  if v_id is null then
    insert into app.tests(title, grade, students, lesson, kind, opens_at, due_at, duration_min, show, status, q, key, npages)
    values (p_meta->>'title', p_meta->>'grade', case when jsonb_typeof(p_meta->'students') = 'array' then array(select jsonb_array_elements_text(p_meta->'students')) end,
      nullif(p_meta->>'lesson',''), coalesce(p_meta->>'kind','doc'), nullif(p_meta->>'opens','')::timestamptz, nullif(p_meta->>'due','')::timestamptz,
      nullif(p_meta->>'dur','')::int, coalesce(p_meta->>'show','submit'), coalesce(p_meta->>'status','draft'), p_q, p_key, coalesce((p_meta->>'npages')::int, 0))
    returning id into v_id;
  else
    update app.tests set title = p_meta->>'title', grade = p_meta->>'grade',
      students = case when jsonb_typeof(p_meta->'students') = 'array' then array(select jsonb_array_elements_text(p_meta->'students')) end,
      lesson = nullif(p_meta->>'lesson',''), kind = coalesce(p_meta->>'kind','doc'), opens_at = nullif(p_meta->>'opens','')::timestamptz,
      due_at = nullif(p_meta->>'due','')::timestamptz, duration_min = nullif(p_meta->>'dur','')::int, show = coalesce(p_meta->>'show','submit'),
      status = coalesce(p_meta->>'status','draft'), q = p_q, key = p_key, npages = coalesce((p_meta->>'npages')::int, npages), updated_at = now()
    where id = v_id;
    -- re-mark every submitted attempt against the (possibly changed) key
    update app.test_attempts set result = app.mark_test(p_q, p_key, answers, overrides) where test_id = v_id and submitted_at is not null;
  end if;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.portal_test_page_save(p_token uuid, p_id bigint, p_n int, p_img text) returns jsonb
language plpgsql security definer set search_path to '' as $$
begin
  perform app.teacher(p_token);
  if length(p_img) > 3000000 then return jsonb_build_object('error','too_large'); end if;
  if p_img is null then delete from app.test_pages where test_id = p_id and n >= p_n; return jsonb_build_object('ok', true); end if;
  insert into app.test_pages(test_id, n, img) values (p_id, p_n, p_img) on conflict (test_id, n) do update set img = excluded.img;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.portal_test_delete(p_token uuid, p_id bigint) returns jsonb
language plpgsql security definer set search_path to '' as $$
begin perform app.teacher(p_token); delete from app.tests where id = p_id; return jsonb_build_object('ok', true); end $$;

create or replace function public.portal_test_start(p_token uuid, p_id bigint) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare v_uid text := app.uid(p_token); t app.tests; a app.test_attempts;
begin
  select * into t from app.tests where id = p_id;
  if t.id is null or not app.test_open_for(t, v_uid) then return jsonb_build_object('error','not_found'); end if;
  select * into a from app.test_attempts where test_id = p_id and user_id = v_uid;
  if a.id is null then
    if t.opens_at is not null and now() < t.opens_at then return jsonb_build_object('error','not_open'); end if;
    if t.due_at is not null and now() > t.due_at then return jsonb_build_object('error','closed'); end if;
    insert into app.test_attempts(test_id, user_id) values (p_id, v_uid) returning * into a;
  end if;
  return jsonb_build_object('ok', true, 'started', a.started_at, 'submitted', a.submitted_at, 'answers', a.answers, 'now', now());
end $$;

create or replace function public.portal_test_answer(p_token uuid, p_id bigint, p_answers jsonb, p_final boolean) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare v_uid text := app.uid(p_token); t app.tests; a app.test_attempts; v_end timestamptz; v_final boolean := p_final;
begin
  select * into t from app.tests where id = p_id;
  select * into a from app.test_attempts where test_id = p_id and user_id = v_uid;
  if t.id is null or a.id is null then return jsonb_build_object('error','not_started'); end if;
  if a.submitted_at is not null then return jsonb_build_object('error','already_submitted'); end if;
  if pg_column_size(p_answers) > 200000 then return jsonb_build_object('error','too_large'); end if;
  v_end := least(case when t.duration_min is not null then a.started_at + make_interval(mins => t.duration_min) end, t.due_at);
  if v_end is not null and now() > v_end + interval '2 minutes' then v_final := true; end if;
  update app.test_attempts set answers = p_answers,
    submitted_at = case when v_final then now() end,
    result = case when v_final then app.mark_test(t.q, t.key, p_answers, overrides) end
  where id = a.id returning * into a;
  return jsonb_build_object('ok', true, 'submitted', a.submitted_at,
    'result', case when app.test_release(t, a) then a.result end, 'key', case when app.test_release(t, a) then t.key end);
end $$;

create or replace function public.portal_test_results(p_token uuid, p_id bigint) returns jsonb
language plpgsql security definer set search_path to '' as $$
begin
  perform app.teacher(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'uid', a.user_id, 'n', u.name, 'g', u.grade, 'i', right(u.id, 4), 'started', a.started_at,
      'submitted', a.submitted_at, 'answers', a.answers, 'overrides', a.overrides, 'result', a.result) order by u.name)
    from app.test_attempts a join app.users u on u.id = a.user_id where a.test_id = p_id), '[]'::jsonb);
end $$;

create or replace function public.portal_test_override(p_token uuid, p_attempt bigint, p_overrides jsonb) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare a app.test_attempts; t app.tests;
begin
  perform app.teacher(p_token);
  select * into a from app.test_attempts where id = p_attempt;
  select * into t from app.tests where id = a.test_id;
  update app.test_attempts set overrides = coalesce(p_overrides, '{}'),
    result = case when submitted_at is not null then app.mark_test(t.q, t.key, answers, coalesce(p_overrides, '{}')) end
  where id = p_attempt returning * into a;
  return jsonb_build_object('ok', true, 'result', a.result);
end $$;

-- teacher: submit a student's attempt now (e.g. the student left without submitting)
create or replace function public.portal_test_force_submit(p_token uuid, p_attempt bigint) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare a app.test_attempts; t app.tests;
begin
  perform app.teacher(p_token);
  select * into a from app.test_attempts where id = p_attempt;
  select * into t from app.tests where id = a.test_id;
  update app.test_attempts set submitted_at = coalesce(submitted_at, now()), result = app.mark_test(t.q, t.key, answers, overrides) where id = p_attempt;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.portal_tests(uuid), public.portal_test_get(uuid,bigint), public.portal_test_page(uuid,bigint,int),
  public.portal_test_save(uuid,bigint,jsonb,jsonb,jsonb), public.portal_test_page_save(uuid,bigint,int,text), public.portal_test_delete(uuid,bigint),
  public.portal_test_start(uuid,bigint), public.portal_test_answer(uuid,bigint,jsonb,boolean), public.portal_test_results(uuid,bigint),
  public.portal_test_override(uuid,bigint,jsonb), public.portal_test_force_submit(uuid,bigint) from public;
grant execute on function public.portal_tests(uuid), public.portal_test_get(uuid,bigint), public.portal_test_page(uuid,bigint,int),
  public.portal_test_save(uuid,bigint,jsonb,jsonb,jsonb), public.portal_test_page_save(uuid,bigint,int,text), public.portal_test_delete(uuid,bigint),
  public.portal_test_start(uuid,bigint), public.portal_test_answer(uuid,bigint,jsonb,boolean), public.portal_test_results(uuid,bigint),
  public.portal_test_override(uuid,bigint,jsonb), public.portal_test_force_submit(uuid,bigint) to anon, authenticated, service_role;
