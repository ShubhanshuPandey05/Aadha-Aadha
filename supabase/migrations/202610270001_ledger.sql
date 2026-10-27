-- Core schema. Money is integer paise. One permanent, two-person group per account.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 60)
);
create table public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
create table public.group_members (
  group_id uuid not null references public.groups(id),
  user_id uuid not null unique references public.profiles(id),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create table public.invitations (
  group_id uuid primary key references public.groups(id),
  code_hash text not null unique,
  expires_at timestamptz not null,
  used_at timestamptz
);
create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id),
  payer_id uuid not null references public.profiles(id),
  client_id uuid not null,
  amount_paise bigint not null check (amount_paise between 1 and 1000000000),
  payer_share_paise bigint not null check (payer_share_paise >= 0 and payer_share_paise <= amount_paise),
  kind text not null check (kind in ('expense','repayment')),
  recipient text check (char_length(recipient) <= 100),
  occurred_at timestamptz not null,
  transaction_ref text check (char_length(transaction_ref) <= 80),
  source text not null check (source in ('manual','com.google.android.apps.nbu.paisa.user','com.phonepe.app','net.one97.paytm')),
  fingerprint text check (fingerprint ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default now(),
  unique (payer_id, client_id),
  foreign key (group_id, payer_id) references public.group_members(group_id, user_id),
  check (kind <> 'repayment' or payer_share_paise = 0)
);
create unique index expense_fingerprint on public.expenses(payer_id, fingerprint) where fingerprint is not null;
create unique index expense_reference on public.expenses(payer_id, transaction_ref) where transaction_ref is not null;
create index expense_group_time on public.expenses(group_id, occurred_at desc);
create table public.devices (
  id uuid primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  token text not null unique check (char_length(token) between 20 and 4096),
  updated_at timestamptz not null default now()
);
-- One delivery per expense/device; never readable by mobile users.
create table public.push_outbox (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null references public.expenses(id),
  recipient_id uuid not null references public.profiles(id),
  device_id uuid not null references public.devices(id) on delete cascade,
  state text not null default 'pending' check (state in ('pending','sent','dead')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  lease_until timestamptz,
  lease_id uuid,
  sent_at timestamptz,
  last_error text,
  unique (expense_id, device_id)
);
create index push_due on public.push_outbox(next_attempt_at) where state = 'pending';

create function public.on_auth_user() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id, display_name)
  values (new.id, left(coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''), 'Friend'),60));
  return new;
end $$;
create trigger create_profile after insert on auth.users for each row execute function public.on_auth_user();
insert into public.profiles(id,display_name)
select id,left(coalesce(nullif(trim(raw_user_meta_data->>'display_name'),''),'Friend'),60) from auth.users
on conflict(id) do nothing;

create function public.is_member(p_group uuid) returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.group_members where group_id=p_group and user_id=auth.uid())
$$;
create function public.shares_group(p_user uuid) returns boolean language sql stable security definer set search_path = '' as $$
  select p_user=auth.uid() or exists(
    select 1 from public.group_members a join public.group_members b on a.group_id=b.group_id
    where a.user_id=auth.uid() and b.user_id=p_user)
$$;

alter table public.profiles enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.invitations enable row level security;
alter table public.expenses enable row level security;
alter table public.devices enable row level security;
alter table public.push_outbox enable row level security;
create policy profiles_read on public.profiles for select to authenticated using (public.shares_group(id));
create policy groups_read on public.groups for select to authenticated using (public.is_member(id));
create policy members_read on public.group_members for select to authenticated using (public.is_member(group_id));
create policy expenses_read on public.expenses for select to authenticated using (public.is_member(group_id));
-- No write policies: all client writes go through validated SECURITY DEFINER RPCs.
revoke all on public.profiles, public.groups, public.group_members, public.invitations, public.expenses, public.devices, public.push_outbox from anon, authenticated;
grant select on public.profiles, public.groups, public.group_members, public.expenses to authenticated;

create function public.create_group(p_name text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare g uuid; u uuid := auth.uid();
begin
  if u is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  perform 1 from public.profiles where id=u for update;
  if exists(select 1 from public.group_members where user_id=u) then raise exception 'You already have a group.'; end if;
  if p_name is null or char_length(trim(p_name)) not between 1 and 60 then raise exception 'Enter a group name (1–60 characters).'; end if;
  insert into public.groups(name, created_by) values(trim(p_name),u) returning id into g;
  insert into public.group_members values(g,u,now());
  return jsonb_build_object('id',g);
end $$;

create function public.create_invite() returns jsonb language plpgsql security definer set search_path = '' as $$
declare g uuid; code text; expiry timestamptz := now()+interval '48 hours';
begin
  select group_id into g from public.group_members where user_id=auth.uid();
  if g is null then raise exception 'Create a group first.' using errcode='42501'; end if;
  perform 1 from public.groups where id=g for update;
  if (select count(*) from public.group_members where group_id=g) <> 1 then raise exception 'This group already has two friends.'; end if;
  code := upper(replace(gen_random_uuid()::text,'-',''));
  insert into public.invitations(group_id,code_hash,expires_at,used_at)
  values(g,encode(sha256(convert_to(code,'UTF8')),'hex'),expiry,null)
  on conflict(group_id) do update set code_hash=excluded.code_hash,expires_at=excluded.expires_at,used_at=null;
  return jsonb_build_object('code',code,'expires_at',expiry);
end $$;

create function public.join_group(p_code text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare g uuid; u uuid := auth.uid(); code text := upper(replace(trim(p_code),'-',''));
begin
  if u is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  perform 1 from public.profiles where id=u for update;
  if exists(select 1 from public.group_members where user_id=u) then raise exception 'You already have a group.'; end if;
  if code is null or code !~ '^[A-F0-9]{32}$' then raise exception 'Invalid or expired invitation.'; end if;
  select group_id into g from public.invitations where code_hash=encode(sha256(convert_to(code,'UTF8')),'hex');
  if g is null then raise exception 'Invalid or expired invitation.'; end if;
  -- Group lock serializes joining, invite rotation and expense validation.
  perform 1 from public.groups where id=g for update;
  if not exists(select 1 from public.invitations where group_id=g
    and code_hash=encode(sha256(convert_to(code,'UTF8')),'hex') and expires_at>now() and used_at is null)
    or (select count(*) from public.group_members where group_id=g) <> 1
    then raise exception 'Invalid, expired, or already used invitation.'; end if;
  insert into public.group_members values(g,u,now());
  update public.invitations set used_at=now() where group_id=g;
  return jsonb_build_object('id',g);
end $$;

create function public.log_expense(
  p_group_id uuid, p_client_id uuid, p_amount_paise bigint, p_payer_share_paise bigint,
  p_kind text, p_recipient text, p_occurred_at timestamptz,
  p_transaction_ref text, p_source text, p_fingerprint text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); saved public.expenses; ref text := nullif(upper(trim(p_transaction_ref)),'');
begin
  if u is null or not public.is_member(p_group_id) then raise exception 'Group access denied.' using errcode='42501'; end if;
  perform 1 from public.groups where id=p_group_id for update;
  if (select count(*) from public.group_members where group_id=p_group_id) <> 2 then raise exception 'Connect your friend before logging expenses.'; end if;
  if p_amount_paise is null or p_amount_paise not between 1 and 1000000000
    or p_payer_share_paise is null or p_payer_share_paise not between 0 and p_amount_paise
    or p_kind is null or p_kind not in ('expense','repayment')
    or (p_kind='repayment' and p_payer_share_paise<>0)
    or p_client_id is null or p_occurred_at is null or p_occurred_at>now()+interval '5 minutes'
    or p_source is null or p_source not in ('manual','com.google.android.apps.nbu.paisa.user','com.phonepe.app','net.one97.paytm')
    or char_length(p_recipient)>100 or char_length(ref)>80
    or (p_fingerprint is not null and p_fingerprint !~ '^[a-f0-9]{64}$')
    then raise exception 'Invalid expense fields.' using errcode='22023'; end if;
  select * into saved from public.expenses where payer_id=u and client_id=p_client_id;
  if found then
    if saved.group_id<>p_group_id or saved.amount_paise<>p_amount_paise or saved.payer_share_paise<>p_payer_share_paise
      or saved.kind<>p_kind or saved.recipient is distinct from nullif(trim(p_recipient),'')
      or saved.occurred_at<>p_occurred_at or saved.transaction_ref is distinct from ref
      or saved.source<>p_source or saved.fingerprint is distinct from p_fingerprint
      then raise exception 'This request ID has already been used for a different expense.' using errcode='22023'; end if;
    return jsonb_build_object('id',saved.id,'duplicate',true);
  end if;
  select * into saved from public.expenses where payer_id=u and
    ((p_fingerprint is not null and fingerprint=p_fingerprint) or (ref is not null and transaction_ref=ref)) limit 1;
  if found then
    if saved.amount_paise<>p_amount_paise or saved.payer_share_paise<>p_payer_share_paise
      or saved.kind<>p_kind or saved.group_id<>p_group_id
      then raise exception 'This payment is already logged with a different amount or split. Review the ledger.'; end if;
    return jsonb_build_object('id',saved.id,'duplicate',true);
  end if;
  insert into public.expenses(group_id,payer_id,client_id,amount_paise,payer_share_paise,kind,recipient,occurred_at,transaction_ref,source,fingerprint)
  values(p_group_id,u,p_client_id,p_amount_paise,p_payer_share_paise,p_kind,nullif(trim(p_recipient),''),p_occurred_at,ref,p_source,p_fingerprint)
  returning * into saved;
  return jsonb_build_object('id',saved.id,'duplicate',false);
end $$;

create function public.register_device(p_device_id uuid,p_token text) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  if p_device_id is null or p_token is null or char_length(p_token) not between 20 and 4096 then raise exception 'Invalid device registration.'; end if;
  -- A random installation ID may be transferred on explicit account switch.
  delete from public.push_outbox where device_id=p_device_id and recipient_id<>auth.uid();
  delete from public.devices where token=p_token and id<>p_device_id;
  insert into public.devices(id,user_id,token) values(p_device_id,auth.uid(),p_token)
  on conflict(id) do update set user_id=excluded.user_id,token=excluded.token,updated_at=now();
  return '{}'::jsonb;
end $$;
create function public.unregister_device(p_device_id uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  delete from public.devices where id=p_device_id and user_id=auth.uid();
  return '{}'::jsonb;
end $$;

create function public.enqueue_push() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.push_outbox(expense_id,recipient_id,device_id)
  select new.id,m.user_id,d.id from public.group_members m join public.devices d on d.user_id=m.user_id
  where m.group_id=new.group_id and m.user_id<>new.payer_id
  on conflict do nothing;
  return new;
end $$;
create trigger expense_push after insert on public.expenses for each row execute function public.enqueue_push();

create function public.ledger_snapshot() returns jsonb language plpgsql security definer set search_path = '' as $$
declare g uuid; result jsonb;
  month_start timestamptz := date_trunc('month',now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  month_end timestamptz := (date_trunc('month',now() at time zone 'Asia/Kolkata') + interval '1 month') at time zone 'Asia/Kolkata';
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  select group_id into g from public.group_members where user_id=auth.uid();
  if g is null then return jsonb_build_object('group',null,'members','[]'::jsonb,'expenses','[]'::jsonb); end if;
  select jsonb_build_object(
    'group',jsonb_build_object('id',id,'name',name,'ready',(select count(*)=2 from public.group_members where group_id=g)),
    'members',(select jsonb_agg(jsonb_build_object('id',m.user_id,'name',p.display_name,
      'contributed',coalesce((select sum(e.amount_paise) from public.expenses e where e.group_id=g and e.kind='expense' and e.payer_id=m.user_id),0),
      'share',coalesce((select sum(case when e.payer_id=m.user_id then e.payer_share_paise else e.amount_paise-e.payer_share_paise end) from public.expenses e where e.group_id=g and e.kind='expense'),0),
      'balance',coalesce((select sum(case
        when e.kind='repayment' then case when e.payer_id=m.user_id then e.amount_paise else -e.amount_paise end
        when e.payer_id=m.user_id then e.amount_paise-e.payer_share_paise else -(e.amount_paise-e.payer_share_paise) end)
        from public.expenses e where e.group_id=g),0)
      ) order by m.joined_at,m.user_id) from public.group_members m join public.profiles p on p.id=m.user_id where m.group_id=g),
    'month',jsonb_build_object('start',month_start,
      'total',coalesce((select sum(amount_paise) from public.expenses where group_id=g and kind='expense' and occurred_at>=month_start and occurred_at<month_end),0),
      'count',(select count(*) from public.expenses where group_id=g and kind='expense' and occurred_at>=month_start and occurred_at<month_end)),
    'expenses',coalesce((select jsonb_agg(to_jsonb(e) order by e.occurred_at desc) from
      (select * from public.expenses where group_id=g order by occurred_at desc,id desc limit 100) e),'[]'::jsonb)
  ) into result from public.groups where id=g;
  return result;
end $$;
create function public.expense_detail(p_id uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
  select to_jsonb(e)||jsonb_build_object('payer_name',p.display_name) into result
  from public.expenses e join public.profiles p on p.id=e.payer_id where e.id=p_id and public.is_member(e.group_id);
  if result is null then raise exception 'Expense not found or access denied.' using errcode='42501'; end if;
  return result;
end $$;

-- Service-only, leased delivery RPCs. A crash may cause an FCM resend; clients dedupe by expense UUID.
create function public.claim_push(p_limit integer default 20) returns jsonb language plpgsql security definer set search_path = '' as $$
declare results jsonb;
begin
  with selected as (
    select id from public.push_outbox where state='pending' and next_attempt_at<=now()
      and (lease_until is null or lease_until<now()) order by next_attempt_at
      for update skip locked limit least(greatest(p_limit,1),50)
  ), claimed as (
    update public.push_outbox o set lease_until=now()+interval '5 minutes',lease_id=gen_random_uuid(),attempts=attempts+1
    from selected s where o.id=s.id returning o.*
  )
  select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'lease_id',c.lease_id,'expense_id',e.id,
    'recipient_id',c.recipient_id,'token',d.token,'attempts',c.attempts,'amount_paise',e.amount_paise,
    'kind',e.kind,'payer_name',p.display_name)), '[]'::jsonb) into results
  from claimed c join public.expenses e on e.id=c.expense_id
  join public.profiles p on p.id=e.payer_id join public.devices d on d.id=c.device_id and d.user_id=c.recipient_id;
  return jsonb_build_object('items',results);
end $$;
create function public.finish_push(p_id uuid,p_lease_id uuid,p_result text,p_error text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if p_result not in ('sent','retry','dead') then raise exception 'Invalid result'; end if;
  update public.push_outbox set
    state=case when p_result='retry' then 'pending' else p_result end,
    sent_at=case when p_result='sent' then now() else null end,
    next_attempt_at=now()+make_interval(secs=>least(3600,30*power(2,least(attempts,7)))::int),
    lease_until=null,lease_id=null,last_error=left(p_error,200)
  where id=p_id and lease_id=p_lease_id and state='pending';
  return '{}'::jsonb;
end $$;

revoke execute on function public.on_auth_user(),public.is_member(uuid),public.shares_group(uuid),
  public.create_group(text),public.create_invite(),public.join_group(text),
  public.log_expense(uuid,uuid,bigint,bigint,text,text,timestamptz,text,text,text),
  public.register_device(uuid,text),public.unregister_device(uuid),public.enqueue_push(),
  public.ledger_snapshot(),public.expense_detail(uuid),public.claim_push(integer),
  public.finish_push(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.is_member(uuid),public.shares_group(uuid),public.create_group(text),
  public.create_invite(),public.join_group(text),public.log_expense(uuid,uuid,bigint,bigint,text,text,timestamptz,text,text,text),
  public.register_device(uuid,text),public.unregister_device(uuid),public.ledger_snapshot(),public.expense_detail(uuid) to authenticated;
grant execute on function public.claim_push(integer),public.finish_push(uuid,uuid,text,text) to service_role;
-- Realtime still applies SELECT RLS for every subscriber.
alter publication supabase_realtime add table public.expenses,public.group_members;
