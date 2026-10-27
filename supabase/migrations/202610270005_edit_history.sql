-- Only payer-created entries can be edited. Original payment identity is immutable.
alter table public.expenses add column name text check (char_length(name) <= 100);
alter table public.expenses add column revision integer not null default 0;
create table public.expense_history (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null references public.expenses(id),
  group_id uuid not null references public.groups(id),
  actor_id uuid not null references public.profiles(id),
  request_id uuid not null,
  revision integer not null,
  changed_at timestamptz not null default now(),
  before_value jsonb,
  after_value jsonb not null,
  request_payload jsonb,
  unique(actor_id, request_id), unique(expense_id,revision)
);
alter table public.expense_history enable row level security;
revoke all on public.expense_history from anon,authenticated;
grant select on public.expense_history to authenticated;
create policy history_read on public.expense_history for select to authenticated using (public.is_member(group_id));
-- Existing rows become the baseline; no historical edits are invented.
insert into public.expense_history(expense_id,group_id,actor_id,request_id,revision,changed_at,after_value)
select id,group_id,payer_id,client_id,0,created_at,to_jsonb(e) from public.expenses e;
create function public.record_expense_creation() returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.expense_history(expense_id,group_id,actor_id,request_id,revision,changed_at,after_value)
  values(new.id,new.group_id,new.payer_id,new.client_id,0,new.created_at,to_jsonb(new));
  return new;
end $$;
revoke execute on function public.record_expense_creation() from public,anon,authenticated;
create trigger expense_creation_history after insert on public.expenses for each row execute function public.record_expense_creation();

create function public.edit_expense(p_id uuid,p_request_id uuid,p_expected_revision integer,
  p_amount_paise bigint,p_payer_share_paise bigint,p_recipient text,p_name text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare old_row public.expenses; new_row public.expenses; prior public.expense_history;
  payload jsonb := jsonb_build_object('id',p_id,'revision',p_expected_revision,'amount',p_amount_paise,
    'share',p_payer_share_paise,'recipient',nullif(trim(p_recipient),''),'name',nullif(trim(p_name),''));
begin
  select * into old_row from public.expenses where id=p_id for update;
  if not found or auth.uid() is null or old_row.payer_id<>auth.uid() or not public.is_member(old_row.group_id)
    then raise exception 'You can only edit your own entries.' using errcode='42501'; end if;
  if p_request_id is null then raise exception 'Missing edit request ID.' using errcode='22023'; end if;
  select * into prior from public.expense_history where actor_id=auth.uid() and request_id=p_request_id;
  if found then
    if prior.request_payload is distinct from payload then raise exception 'Request ID already used.' using errcode='22023'; end if;
    return jsonb_build_object('id',p_id,'revision',prior.revision,'duplicate',true);
  end if;
  if p_expected_revision is null or old_row.revision<>p_expected_revision
    then raise exception 'This entry changed. Close and reopen it before editing.' using errcode='40001'; end if;
  if p_amount_paise is null or p_amount_paise not between 1 and 1000000000
    or p_payer_share_paise is null or p_payer_share_paise not between 0 and p_amount_paise
    or (old_row.kind='repayment' and p_payer_share_paise<>0)
    or char_length(p_recipient)>100 or char_length(p_name)>100
    then raise exception 'Invalid expense fields.' using errcode='22023'; end if;
  update public.expenses set amount_paise=p_amount_paise,payer_share_paise=p_payer_share_paise,
    recipient=nullif(trim(p_recipient),''),name=nullif(trim(p_name),''),revision=revision+1
    where id=p_id returning * into new_row;
  insert into public.expense_history(expense_id,group_id,actor_id,request_id,revision,before_value,after_value,request_payload)
    values(p_id,old_row.group_id,auth.uid(),p_request_id,new_row.revision,to_jsonb(old_row),to_jsonb(new_row),payload);
  return jsonb_build_object('id',p_id,'revision',new_row.revision,'duplicate',false);
end $$;
revoke execute on function public.edit_expense(uuid,uuid,integer,bigint,bigint,text,text) from public,anon,authenticated;
grant execute on function public.edit_expense(uuid,uuid,integer,bigint,bigint,text,text) to authenticated;

create or replace function public.expense_detail(p_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  select to_jsonb(e)||jsonb_build_object('payer_name',p.display_name,'history',
    (select coalesce(jsonb_agg(to_jsonb(h)||jsonb_build_object('actor_name',a.display_name) order by h.revision desc),'[]'::jsonb)
     from public.expense_history h join public.profiles a on a.id=h.actor_id where h.expense_id=e.id)) into result
  from public.expenses e join public.profiles p on p.id=e.payer_id where e.id=p_id and public.is_member(e.group_id);
  if result is null then raise exception 'Expense not found or access denied.' using errcode='42501'; end if;
  return result;
end $$;

-- Default name preserves compatibility with older installed clients.
drop function public.log_expense(uuid,uuid,bigint,bigint,text,text,timestamptz,text,text,text);
create function public.log_expense(
  p_group_id uuid, p_client_id uuid, p_amount_paise bigint, p_payer_share_paise bigint,
  p_kind text, p_recipient text, p_occurred_at timestamptz,
  p_transaction_ref text, p_source text, p_fingerprint text, p_name text default null
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
    or p_source is null or p_source not in ('manual','com.google.android.apps.nbu.paisa.user','com.phonepe.app','net.one97.paytm','com.kotak811mobilebankingapp.instantsavingsupiscanandpayrecharge','in.org.npci.upiapp')
    or char_length(p_name)>100 or char_length(p_recipient)>100 or char_length(ref)>80
    or (p_fingerprint is not null and p_fingerprint !~ '^[a-f0-9]{64}$')
    then raise exception 'Invalid expense fields.' using errcode='22023'; end if;
  select (jsonb_populate_record(null::public.expenses,h.after_value)).* into saved from public.expense_history h where actor_id=u and request_id=p_client_id and revision=0;
  if found then
    if saved.group_id<>p_group_id or saved.amount_paise<>p_amount_paise or saved.payer_share_paise<>p_payer_share_paise
      or saved.kind<>p_kind or saved.recipient is distinct from nullif(trim(p_recipient),'')
      or saved.occurred_at<>p_occurred_at or saved.transaction_ref is distinct from ref
      or saved.name is distinct from nullif(trim(p_name),'') or saved.source<>p_source or saved.fingerprint is distinct from p_fingerprint
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
  insert into public.expenses(group_id,payer_id,client_id,amount_paise,payer_share_paise,kind,recipient,occurred_at,transaction_ref,source,fingerprint,name)
  values(p_group_id,u,p_client_id,p_amount_paise,p_payer_share_paise,p_kind,nullif(trim(p_recipient),''),p_occurred_at,ref,p_source,p_fingerprint,nullif(trim(p_name),''))
  returning * into saved;
  return jsonb_build_object('id',saved.id,'duplicate',false);
end $$;

revoke execute on function public.log_expense(uuid,uuid,bigint,bigint,text,text,timestamptz,text,text,text,text) from public,anon,authenticated;
grant execute on function public.log_expense(uuid,uuid,bigint,bigint,text,text,timestamptz,text,text,text,text) to authenticated;
