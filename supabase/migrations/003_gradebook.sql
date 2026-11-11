-- Weekly Assessment gradebook (teacher only): one JSON document per "<grade>|<semester>"
create table if not exists app.gradebook(book text primary key, data jsonb not null, updated_at timestamptz not null default now());
alter table app.gradebook enable row level security;
create or replace function public.portal_gb_get(p_token uuid, p_book text) returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform app.teacher(p_token); return (select jsonb_build_object('data', data, 'updated_at', updated_at) from app.gradebook where book = p_book); end $$;
create or replace function public.portal_gb_list(p_token uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform app.teacher(p_token); return coalesce((select jsonb_agg(jsonb_build_object('book', book, 'updated_at', updated_at)) from app.gradebook), '[]'::jsonb); end $$;
create or replace function public.portal_gb_save(p_token uuid, p_book text, p_data jsonb) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform app.teacher(p_token);
  if length(p_book) > 80 or pg_column_size(p_data) > 2000000 then return jsonb_build_object('error','too_large'); end if;
  insert into app.gradebook(book, data, updated_at) values (p_book, p_data, now()) on conflict (book) do update set data = excluded.data, updated_at = now();
  return jsonb_build_object('ok', true, 'at', now());
end $$;
revoke all on function public.portal_gb_get(uuid,text), public.portal_gb_list(uuid), public.portal_gb_save(uuid,text,jsonb) from public;
grant execute on function public.portal_gb_get(uuid,text), public.portal_gb_list(uuid), public.portal_gb_save(uuid,text,jsonb) to anon, authenticated, service_role;
