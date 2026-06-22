create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  host_token_hash text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.comments (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null,
  email_hash text not null,
  content text not null check (char_length(content) between 1 and 80),
  created_at timestamptz not null default now()
);

create index if not exists comments_room_id_id_idx on public.comments(room_id, id);
create index if not exists comments_room_id_user_created_idx on public.comments(room_id, user_id, created_at desc);

create table if not exists public.blocked_terms (
  id bigint generated always as identity primary key,
  term text not null unique,
  created_at timestamptz not null default now(),
  check (char_length(trim(term)) > 0)
);

create table if not exists public.host_admin_tokens (
  token_hash text primary key,
  label text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.rooms enable row level security;
alter table public.comments enable row level security;
alter table public.blocked_terms enable row level security;
alter table public.host_admin_tokens enable row level security;

revoke all on public.rooms from anon, authenticated;
revoke all on public.comments from anon, authenticated;
revoke all on public.blocked_terms from anon, authenticated;
revoke all on public.host_admin_tokens from anon, authenticated;

create or replace function public.is_allowed_musabi_email(p_email text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  parts text[];
  domain text;
begin
  parts := string_to_array(lower(trim(coalesce(p_email, ''))), '@');

  if array_length(parts, 1) != 2 or parts[1] = '' or parts[2] = '' then
    return false;
  end if;

  domain := parts[2];
  return domain = 'musabi.ac.jp' or right(domain, length('.musabi.ac.jp')) = '.musabi.ac.jp';
end;
$$;

create or replace function public.normalize_comment_content(p_content text)
returns text
language sql
immutable
as $$
  select trim(regexp_replace(coalesce(p_content, ''), '[[:space:]]+', ' ', 'g'));
$$;

create or replace function public.hook_restrict_musabi_signup(event jsonb)
returns jsonb
language plpgsql
as $$
declare
  email text;
begin
  email := event -> 'user' ->> 'email';

  if public.is_allowed_musabi_email(email) then
    return '{}'::jsonb;
  end if;

  return jsonb_build_object(
    'error', jsonb_build_object(
      'http_code', 403,
      'message', 'Only musabi.ac.jp email addresses are allowed.'
    )
  );
end;
$$;

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

revoke all on function public.is_allowed_musabi_email(text) from public;
revoke all on function public.normalize_comment_content(text) from public;
revoke all on function public.hook_restrict_musabi_signup(jsonb) from public;
revoke all on function public.create_room(text) from public;
revoke all on function public.submit_room_comment(text, text) from public;
revoke all on function public.fetch_room_comments(text, text, bigint) from public;

grant usage on schema public to supabase_auth_admin;
grant execute on function public.is_allowed_musabi_email(text) to supabase_auth_admin;
grant execute on function public.hook_restrict_musabi_signup(jsonb) to supabase_auth_admin;
grant execute on function public.create_room(text) to anon, authenticated;
grant execute on function public.submit_room_comment(text, text) to authenticated;
grant execute on function public.fetch_room_comments(text, text, bigint) to anon, authenticated;
