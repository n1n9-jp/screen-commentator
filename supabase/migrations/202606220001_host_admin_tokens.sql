create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.host_admin_tokens (
  token_hash text primary key,
  label text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.host_admin_tokens enable row level security;
revoke all on public.host_admin_tokens from anon, authenticated;

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

revoke all on function public.create_room(text) from public;
grant execute on function public.create_room(text) to anon, authenticated;
