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
    from public.blocked_terms bt
    where position(lower(bt.term) in lower(normalized_content)) > 0
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

revoke all on function public.submit_room_comment(text, text) from public;
grant execute on function public.submit_room_comment(text, text) to authenticated;
