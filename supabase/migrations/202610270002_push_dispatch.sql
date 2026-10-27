-- Supabase-only extensions. Secret values are provisioned separately, never committed.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;
create extension if not exists supabase_vault with schema vault;

create function public.dispatch_push() returns void language plpgsql security definer set search_path = '' as $$
declare endpoint text; secret text;
begin
  select decrypted_secret into endpoint from vault.decrypted_secrets where name='push_function_url' limit 1;
  select decrypted_secret into secret from vault.decrypted_secrets where name='push_dispatch_secret' limit 1;
  if endpoint is null or secret is null then return; end if;
  perform net.http_post(url:=endpoint,
    headers:=jsonb_build_object('Content-Type','application/json','x-dispatch-secret',secret),
    body:='{}'::jsonb,timeout_milliseconds:=5000);
end $$;
create function public.wake_push() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists(select 1 from public.push_outbox where expense_id=new.id) then
    begin perform public.dispatch_push();
    exception when others then
      -- The durable outbox + cron recover failures without rolling back a payment log.
      raise warning 'Push wake-up failed; scheduled retry will recover.';
    end;
  end if;
  return new;
end $$;
-- Trigger names execute alphabetically: enqueue first, wake second.
create trigger expense_push_wake after insert on public.expenses for each row execute function public.wake_push();
revoke execute on function public.dispatch_push(),public.wake_push() from public,anon,authenticated;
select cron.schedule('two-tally-push-retry','* * * * *','select public.dispatch_push()');
