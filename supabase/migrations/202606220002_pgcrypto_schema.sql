create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create or replace function public.create_room(p_admin_token text)
returns table(room_code text, host_token text)
language plpgsql
security definer
set search_path = public
as $$
declare
  generated_code text;
  generated_host_token text;
begin
  if not exists (
    select 1
    from public.host_admin_tokens
    where token_hash = encode(extensions.digest(coalesce(p_admin_token, ''), 'sha256'), 'hex')
      and is_active = true
  ) then
    raise exception 'invalid admin token' using errcode = '28000';
  end if;

  loop
    generated_code := upper(substr(encode(extensions.gen_random_bytes(4), 'hex'), 1, 6));
    exit when not exists (select 1 from public.rooms where code = generated_code);
  end loop;

  generated_host_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into public.rooms(code, host_token_hash)
  values (generated_code, encode(extensions.digest(generated_host_token, 'sha256'), 'hex'));

  room_code := generated_code;
  host_token := generated_host_token;
  return next;
end;
$$;

create or replace function public.submit_room_comment(p_room_code text, p_content text)
returns table(id bigint, content text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  target_room public.rooms%rowtype;
  caller_id uuid;
  caller_email text;
  normalized_content text;
  inserted_id bigint;
  inserted_content text;
  inserted_created_at timestamptz;
begin
  caller_id := auth.uid();
  caller_email := auth.jwt() ->> 'email';

  if caller_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  if not public.is_allowed_musabi_email(caller_email) then
    raise exception 'email domain is not allowed' using errcode = '28000';
  end if;

  select *
  into target_room
  from public.rooms
  where code = upper(trim(p_room_code))
    and is_active = true;

  if target_room.id is null then
    raise exception 'room not found' using errcode = '22023';
  end if;

  normalized_content := public.normalize_comment_content(p_content);

  if char_length(normalized_content) < 1 or char_length(normalized_content) > 80 then
    raise exception 'comment must be 1-80 characters' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.blocked_terms
    where position(lower(term) in lower(normalized_content)) > 0
  ) then
    raise exception 'comment contains a blocked term' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.comments c
    where c.room_id = target_room.id
      and c.user_id = caller_id
      and c.created_at > now() - interval '5 seconds'
  ) then
    raise exception 'please wait before posting again' using errcode = '22023';
  end if;

  if (
    select count(*)
    from public.comments c
    where c.room_id = target_room.id
      and c.user_id = caller_id
      and c.created_at > now() - interval '1 minute'
  ) >= 10 then
    raise exception 'posting rate limit exceeded' using errcode = '22023';
  end if;

  insert into public.comments as inserted_comment(room_id, user_id, email_hash, content)
  values (
    target_room.id,
    caller_id,
    encode(extensions.digest(lower(caller_email), 'sha256'), 'hex'),
    normalized_content
  )
  returning inserted_comment.id, inserted_comment.content, inserted_comment.created_at
  into inserted_id, inserted_content, inserted_created_at;

  id := inserted_id;
  content := inserted_content;
  created_at := inserted_created_at;

  return next;
end;
$$;

create or replace function public.fetch_room_comments(
  p_room_code text,
  p_host_token text,
  p_after_id bigint default 0
)
returns table(id bigint, content text, created_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  target_room public.rooms%rowtype;
begin
  select *
  into target_room
  from public.rooms
  where code = upper(trim(p_room_code))
    and is_active = true;

  if target_room.id is null then
    raise exception 'room not found' using errcode = '22023';
  end if;

  if encode(extensions.digest(coalesce(p_host_token, ''), 'sha256'), 'hex') <> target_room.host_token_hash then
    raise exception 'invalid host token' using errcode = '28000';
  end if;

  return query
  select c.id, c.content, c.created_at
  from public.comments c
  where c.room_id = target_room.id
    and c.id > coalesce(p_after_id, 0)
  order by c.id asc
  limit 50;
end;
$$;

revoke all on function public.create_room(text) from public;
revoke all on function public.submit_room_comment(text, text) from public;
revoke all on function public.fetch_room_comments(text, text, bigint) from public;

grant execute on function public.create_room(text) to anon, authenticated;
grant execute on function public.submit_room_comment(text, text) to authenticated;
grant execute on function public.fetch_room_comments(text, text, bigint) to anon, authenticated;
