-- Match server validation to the Android notification-source allowlist.
alter table public.expenses drop constraint expenses_source_check;
alter table public.expenses add constraint expenses_source_check check (source in ('manual','com.google.android.apps.nbu.paisa.user','com.phonepe.app','net.one97.paytm','com.kotak811mobilebankingapp.instantsavingsupiscanandpayrecharge','in.org.npci.upiapp'));

create or replace function public.log_expense(
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
    or p_source is null or p_source not in ('manual','com.google.android.apps.nbu.paisa.user','com.phonepe.app','net.one97.paytm','com.kotak811mobilebankingapp.instantsavingsupiscanandpayrecharge','in.org.npci.upiapp')
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
