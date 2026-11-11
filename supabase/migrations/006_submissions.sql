-- Student work submissions: students submit a snapshot of a lesson activity; the teacher reviews it
-- with typed feedback, a mark and pen (Apple Pencil / stylus) annotations; the student sees the review.
create table if not exists app.submissions (
  id bigserial primary key,
  user_id text not null references app.users(id) on delete cascade,
  lesson text not null,            -- lesson key, e.g. M24L3
  part text not null,              -- launch | lab | sims | practice | flash | check
  title text not null,
  data jsonb not null,             -- structured snapshot (plain text blocks, rendered safely)
  score numeric, max numeric,      -- automatic score at submission time
  version int not null default 1,
  submitted_at timestamptz not null default now(),
  status text not null default 'submitted' check (status in ('submitted','reviewed')),
  feedback text, mark numeric, mark_max numeric,
  ink jsonb,                       -- teacher pen strokes in snapshot coordinates
  reviewed_at timestamptz,
  unique (user_id, lesson, part)
);
create index if not exists submissions_status_idx on app.submissions(status, submitted_at desc);
alter table app.submissions enable row level security;
revoke all on app.submissions from public, anon, authenticated;

-- student: submit or resubmit
create or replace function public.portal_submit(p_token uuid, p_lesson text, p_part text, p_title text, p_data jsonb, p_score numeric, p_max numeric)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_uid text := app.uid(p_token); v_row app.submissions;
begin
  if p_part not in ('launch','lab','sims','practice','flash','check') or length(p_lesson) > 40 or length(p_title) > 200 then
    return jsonb_build_object('error','bad_input'); end if;
  if pg_column_size(p_data) > 400000 then return jsonb_build_object('error','too_large'); end if;
  insert into app.submissions(user_id, lesson, part, title, data, score, max)
  values (v_uid, p_lesson, p_part, p_title, p_data, p_score, p_max)
  on conflict (user_id, lesson, part) do update set title = excluded.title, data = excluded.data, score = excluded.score, max = excluded.max,
    version = app.submissions.version + 1, submitted_at = now(), status = 'submitted'
  returning * into v_row;
  return jsonb_build_object('ok', true, 'id', v_row.id, 'version', v_row.version, 'at', v_row.submitted_at);
end $$;

-- student: own submissions (no snapshot / ink, for lists)
create or replace function public.portal_my_subs(p_token uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_uid text := app.uid(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'lesson', s.lesson, 'part', s.part, 'title', s.title, 'score', s.score, 'max', s.max,
      'version', s.version, 'at', s.submitted_at, 'status', s.status,
      'feedback', case when s.reviewed_at is not null then s.feedback end, 'mark', case when s.reviewed_at is not null then s.mark end,
      'mark_max', s.mark_max, 'rat', s.reviewed_at, 'ink', s.ink is not null) order by s.submitted_at desc)
    from app.submissions s where s.user_id = v_uid), '[]'::jsonb);
end $$;

-- teacher: all submissions (no snapshot / ink)
create or replace function public.portal_subs(p_token uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  perform app.teacher(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'lesson', s.lesson, 'part', s.part, 'title', s.title, 'score', s.score, 'max', s.max,
      'version', s.version, 'at', s.submitted_at, 'status', s.status, 'feedback', s.feedback, 'mark', s.mark, 'mark_max', s.mark_max, 'rat', s.reviewed_at,
      'n', u.name, 'g', u.grade, 'i', right(u.id, 4)) order by s.submitted_at desc)
    from app.submissions s join app.users u on u.id = s.user_id), '[]'::jsonb);
end $$;

-- owner or teacher: one submission with snapshot and ink
create or replace function public.portal_sub_get(p_token uuid, p_id bigint)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_uid text := app.uid(p_token); v_t boolean; v jsonb;
begin
  select is_teacher into v_t from app.users where id = v_uid;
  select jsonb_build_object('id', s.id, 'lesson', s.lesson, 'part', s.part, 'title', s.title, 'data', s.data, 'score', s.score, 'max', s.max,
      'version', s.version, 'at', s.submitted_at, 'status', s.status,
      'feedback', case when v_t or s.reviewed_at is not null then s.feedback end, 'mark', case when v_t or s.reviewed_at is not null then s.mark end,
      'mark_max', s.mark_max, 'ink', case when v_t or s.reviewed_at is not null then s.ink end, 'rat', s.reviewed_at,
      'n', u.name, 'g', u.grade, 'i', right(u.id, 4))
    into v from app.submissions s join app.users u on u.id = s.user_id
    where s.id = p_id and (s.user_id = v_uid or coalesce(v_t, false));
  if v is null then return jsonb_build_object('error','not_found'); end if;
  return v;
end $$;

-- teacher: save review (feedback, mark, pen strokes) and return it to the student
create or replace function public.portal_sub_review(p_token uuid, p_id bigint, p_feedback text, p_mark numeric, p_mark_max numeric, p_ink jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  perform app.teacher(p_token);
  if length(coalesce(p_feedback,'')) > 4000 or pg_column_size(p_ink) > 900000 then return jsonb_build_object('error','too_large'); end if;
  update app.submissions set feedback = nullif(trim(p_feedback),''), mark = p_mark, mark_max = p_mark_max, ink = p_ink,
    status = 'reviewed', reviewed_at = now() where id = p_id;
  if not found then return jsonb_build_object('error','not_found'); end if;
  return jsonb_build_object('ok', true, 'at', now());
end $$;

revoke all on function public.portal_submit(uuid,text,text,text,jsonb,numeric,numeric), public.portal_my_subs(uuid), public.portal_subs(uuid),
  public.portal_sub_get(uuid,bigint), public.portal_sub_review(uuid,bigint,text,numeric,numeric,jsonb) from public;
grant execute on function public.portal_submit(uuid,text,text,text,jsonb,numeric,numeric), public.portal_my_subs(uuid), public.portal_subs(uuid),
  public.portal_sub_get(uuid,bigint), public.portal_sub_review(uuid,bigint,text,numeric,numeric,jsonb) to anon, authenticated, service_role;
