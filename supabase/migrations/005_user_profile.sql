-- My Profile: email, mobile and photo are editable by the user; name and national ID are not
alter table app.users add column if not exists email text, add column if not exists mobile text, add column if not exists photo text;
create or replace function public.portal_profile_get(p_token uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v text;
begin v := app.uid(p_token);
  return (select jsonb_build_object('id', id, 'name', name, 'grade', grade, 'teacher', is_teacher, 'email', email, 'mobile', mobile, 'photo', photo) from app.users where id = v); end $$;
create or replace function public.portal_profile_save(p_token uuid, p_email text, p_mobile text, p_photo text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v text; e text := nullif(trim(coalesce(p_email,'')),''); m text := nullif(regexp_replace(coalesce(p_mobile,''),'[\s-]','','g'),'');
begin
  v := app.uid(p_token);
  if e is not null and (length(e) > 120 or e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then return jsonb_build_object('error','email'); end if;
  if m is not null and m !~ '^\+?[0-9]{8,15}$' then return jsonb_build_object('error','mobile'); end if;
  if p_photo is not null and p_photo <> '' and (length(p_photo) > 300000 or p_photo !~ '^data:image/(jpeg|png|webp);base64,') then return jsonb_build_object('error','photo'); end if;
  update app.users set email = e, mobile = m, photo = nullif(p_photo,'') where id = v;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.portal_profile_get(uuid), public.portal_profile_save(uuid,text,text,text) from public;
grant execute on function public.portal_profile_get(uuid), public.portal_profile_save(uuid,text,text,text) to anon, authenticated, service_role;
