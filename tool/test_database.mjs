import { PGlite } from '@electric-sql/pglite';
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
const db = new PGlite();
await db.exec([
  "create role anon nologin;",
  "create role authenticated nologin;",
  "create role service_role nologin bypassrls;",
  "create schema auth;",
  "create table auth.users(id uuid primary key, raw_user_meta_data jsonb default '{}'::jsonb);",
  "create function auth.uid() returns uuid language sql stable as $f$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $f$;",
  "grant usage on schema auth to anon,authenticated,service_role;",
  "grant execute on function auth.uid() to anon,authenticated,service_role;",
  "create publication supabase_realtime;"
].join('\n'));
await db.exec(await readFile(new URL('../supabase/migrations/202610270001_ledger.sql',import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../supabase/migrations/202610270003_google_profile.sql',import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../supabase/migrations/202610270004_kotak_bhim_sources.sql',import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../supabase/migrations/202610270005_edit_history.sql',import.meta.url),'utf8'));
let count=0;
const check=(name,fn)=>Promise.resolve().then(fn).then(()=>{count++;console.log('PASS '+name);});
const ids=[randomUUID(),randomUUID(),randomUUID(),randomUUID()];
for(let i=0;i<ids.length;i++) await db.query('insert into auth.users values($1,$2)',[ids[i],{display_name:['Asha','Riya','Outsider','Fourth'][i]}]);
async function as(user,fn,role='authenticated'){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user??'']);
  await db.exec('set role '+role);
  try{return await fn();}finally{await db.exec('reset role');}
}
const rpc=async(name,args=[],casts=[])=>{
  const params=args.map((_,i)=>'$'+(i+1)+(casts[i]?'::'+casts[i]:'')).join(',');
  return (await db.query('select public.'+name+'('+params+') as value',args)).rows[0].value;
};
let group,invite,expense;
await check('account profile trigger and group creation',async()=>{
  group=await as(ids[0],()=>rpc('create_group',['Everyday']));
  assert.ok(group.id);invite=await as(ids[0],()=>rpc('create_invite'));
  assert.match(invite.code,/^[A-F0-9]{32}$/);
});
await check('invite rotation invalidates prior code',async()=>{
  const old=invite.code;invite=await as(ids[0],()=>rpc('create_invite'));
  await assert.rejects(as(ids[1],()=>rpc('join_group',[old])),/invitation/i);
});
const occurred=new Date().toISOString();
const payload=(id=randomUUID(),amount=35000,share=17500,kind='expense',ref=null,fingerprint=null)=>[
  group.id,id,amount,share,kind,'Cafe',occurred,ref,'manual',fingerprint];
const casts=['uuid','uuid','bigint','bigint','text','text','timestamptz','text','text','text'];
const log=(args,user=ids[0])=>as(user,()=>rpc('log_expense',args,casts));
await check('cannot log before second member joins',async()=>{
  await assert.rejects(log(payload()),/Connect your friend/);
  assert.equal((await as(ids[1],()=>rpc('join_group',[invite.code]))).id,group.id);
});
await check('single-use invite and maximum two members',async()=>{
  await assert.rejects(as(ids[2],()=>rpc('join_group',[invite.code])),/invitation/i);
  await assert.rejects(as(ids[0],()=>rpc('create_group',['Second'])),/already/);
  await assert.rejects(as(ids[0],()=>rpc('create_invite')),/two friends/);
});
await check('outsider and anonymous users cannot read or write ledger',async()=>{
  await assert.rejects(log(payload(),ids[2]),/denied/i);
  const outsider=await as(ids[2],()=>db.query('select * from public.group_members'));
  assert.equal(outsider.rows.length,0);
  await assert.rejects(as(null,()=>rpc('ledger_snapshot'), 'anon'),/permission denied/i);
  await assert.rejects(as(ids[0],()=>db.query("insert into public.expenses default values")),/permission denied/i);
});
const deviceA=randomUUID(),deviceB=randomUUID(),deviceC=randomUUID();
for(const [i,device] of [deviceA,deviceB,deviceC].entries()){
  await as(ids[i],()=>rpc('register_device',[device,'token-'+ids[i]]));
}
const first=payload();
await check('commits expense with payer derived from authenticated user',async()=>{
  expense=await log(first);assert.equal(expense.duplicate,false);
  const detail=await as(ids[1],()=>rpc('expense_detail',[expense.id],['uuid']));
  assert.equal(detail.payer_id,ids[0]);assert.equal(detail.amount_paise,35000);
});
await check('exact retry creates neither a duplicate expense nor duplicate push',async()=>{
  const retry=await log(first);assert.equal(retry.id,expense.id);assert.equal(retry.duplicate,true);
  const rows=(await db.query('select * from public.push_outbox')).rows;
  assert.equal(rows.length,1);assert.equal(rows[0].recipient_id,ids[1]);assert.equal(rows[0].device_id,deviceB);
  assert.equal((await db.query('select count(*)::int as n from public.expenses')).rows[0].n,1);
});
await check('changed idempotency payload rejected',async()=>{
  const changed=[...first];changed[2]=999;
  await assert.rejects(log(changed),/Invalid expense|request ID/);
  changed[2]=35001;await assert.rejects(log(changed),/request ID/);
});
await check('validates negative amounts, shares, nulls, future date and source',async()=>{
  for(const args of [payload(undefined,-1,0),payload(undefined,100,101),payload(undefined,100,-1),
    payload(undefined,100,1,'repayment'),payload(undefined,null,0),payload(undefined,100,null)]){
    await assert.rejects(log(args),/Invalid expense/);
  }
  const future=payload();future[6]='2099-01-01T00:00:00Z';await assert.rejects(log(future),/Invalid expense/);
  const invalid=payload();invalid[8]='untrusted';await assert.rejects(log(invalid),/Invalid expense/);
});
await check('RLS protects saved data, profiles and details from outsider',async()=>{
  assert.equal((await as(ids[2],()=>db.query('select * from public.expenses'))).rows.length,0);
  assert.equal((await as(ids[2],()=>db.query('select * from public.profiles'))).rows.length,1);
  await assert.rejects(as(ids[2],()=>rpc('expense_detail',[expense.id],['uuid'])),/denied/);
  assert.equal((await as(ids[1],()=>db.query('select * from public.expenses'))).rows.length,1);
});
await check('custom split followed by repayment settles both balances',async()=>{
  await log(payload(undefined,10000,3000),ids[1]);
  let snap=await as(ids[0],()=>rpc('ledger_snapshot'));
  assert.equal(snap.members.find(m=>m.id===ids[0]).balance,10500);
  await log(payload(undefined,10500,0,'repayment'),ids[1]);
  snap=await as(ids[0],()=>rpc('ledger_snapshot'));
  assert.equal(snap.members.find(m=>m.id===ids[0]).balance,0);
  assert.equal(snap.members.find(m=>m.id===ids[1]).balance,0);
  assert.equal(snap.month.total,45000);assert.equal(snap.month.count,2);
  assert.equal(snap.members.find(m=>m.id===ids[0]).share,24500);
});
await check('transaction reference and fingerprint dedupe across request IDs',async()=>{
  const reference='123456789012', fingerprint='a'.repeat(64);
  const saved=await log(payload(undefined,101,51,'expense',reference,fingerprint));
  const repeated=await log(payload(undefined,101,51,'expense',reference,fingerprint));
  assert.equal(saved.id,repeated.id);assert.equal(repeated.duplicate,true);
  await assert.rejects(log(payload(undefined,102,51,'expense',reference,fingerprint)),/different amount/);
  await assert.rejects(log(payload(undefined,101,50,'expense',reference,fingerprint)),/different amount or split/);
});
await check('push claims are service-only, leased and completed idempotently',async()=>{
  await assert.rejects(as(ids[0],()=>rpc('claim_push',[20])),/permission denied/i);
  const batch=await as(null,()=>rpc('claim_push',[20]),'service_role');
  assert.ok(batch.items.length>=1);
  const again=await as(null,()=>rpc('claim_push',[20]),'service_role');assert.equal(again.items.length,0);
  const item=batch.items[0];
  await as(null,()=>rpc('finish_push',[item.id,randomUUID(),'sent',null],['uuid','uuid','text','text']),'service_role');
  assert.equal((await db.query('select state from public.push_outbox where id=$1',[item.id])).rows[0].state,'pending');
  await as(null,()=>rpc('finish_push',[item.id,item.lease_id,'sent',null],['uuid','uuid','text','text']),'service_role');
  assert.equal((await db.query('select state from public.push_outbox where id=$1',[item.id])).rows[0].state,'sent');
});
await check('database queue and tokens are inaccessible to mobile users',async()=>{
  await assert.rejects(as(ids[0],()=>db.query('select * from public.push_outbox')),/permission denied/i);
  await assert.rejects(as(ids[0],()=>db.query('select * from public.devices')),/permission denied/i);
  await assert.rejects(as(ids[0],()=>db.query('select * from public.invitations')),/permission denied/i);
});
await check('all Android payment sources persist and retry without duplicate friend pushes',async()=>{
  const parser = await readFile(new URL('../android/app/src/main/java/com/twotally/two_tally/PaymentParser.java',import.meta.url),'utf8');
  const sources = [...new Set([...parser.matchAll(/"((?:com\.|net\.|in\.)[a-zA-Z0-9_.]+)"/g)].map(m=>m[1]))];
  assert.equal(sources.length,5);
  for (const source of sources) {
    const args=payload(undefined,10000,5000);
    args[5]='TEST RECIPIENT'; args[8]=source; // Notification has no transaction reference.
    const saved=await log(args);
    assert.equal(saved.duplicate,false,source);
    const retried=await log(args);
    assert.equal(retried.id,saved.id); assert.equal(retried.duplicate,true);
    const row=(await db.query('select source,amount_paise,payer_share_paise,transaction_ref from public.expenses where id=$1',[saved.id])).rows[0];
    assert.equal(row.source,source); assert.equal(row.amount_paise,10000); assert.equal(row.payer_share_paise,5000);
    assert.equal(row.transaction_ref,null);
    const pushes=(await db.query('select recipient_id from public.push_outbox where expense_id=$1',[saved.id])).rows;
    assert.deepEqual(pushes,[{recipient_id:ids[1]}]);
  }
  const invalid=payload(); invalid[8]='com.unsupported.bank';
  await assert.rejects(log(invalid),/Invalid expense/);
});
const editCasts=['uuid','uuid','integer','bigint','bigint','text','text'];
const editId=randomUUID();
const editArgs=[expense.id,editId,0,40000,20000,'Cafe','Food'];
await check('only creator can edit; no direct writes or audit tampering', async()=>{
  for (const user of [ids[1],ids[2]]) await assert.rejects(as(user,()=>rpc('edit_expense',editArgs,editCasts)),/own entries/);
  await assert.rejects(as(null,()=>rpc('edit_expense',editArgs,editCasts),'anon'),/permission denied/);
  for (const sql of ["update public.expenses set name='tampered'",'delete from public.expense_history',"insert into public.expense_history default values"])
    await assert.rejects(as(ids[0],()=>db.exec(sql)),/permission denied/);
});
await check('creator edits atomically with before/after history and updated totals',async()=>{
  const before=await as(ids[0],()=>rpc('ledger_snapshot'));
  const result=await as(ids[0],()=>rpc('edit_expense',editArgs,editCasts));
  assert.equal(result.revision,1);
  const row=await as(ids[1],()=>rpc('expense_detail',[expense.id],['uuid']));
  assert.equal(row.name,'Food'); assert.equal(row.amount_paise,40000); assert.equal(row.payer_id,ids[0]);
  assert.equal(row.history.length,2); assert.equal(row.history[0].before_value.amount_paise,35000);
  assert.equal(row.history[0].after_value.name,'Food'); assert.equal(row.history[0].actor_id,ids[0]);
  const after=await as(ids[0],()=>rpc('ledger_snapshot'));
  assert.equal(after.month.total-before.month.total,5000);
  assert.equal(after.members.find(m=>m.id===ids[0]).balance-before.members.find(m=>m.id===ids[0]).balance,2500);
  assert.equal((await as(ids[2],()=>db.query('select * from public.expense_history'))).rows.length,0);
});
await check('edit retry and original creation retry remain idempotent after edits',async()=>{
  assert.equal((await as(ids[0],()=>rpc('edit_expense',editArgs,editCasts))).duplicate,true);
  assert.equal((await log(first)).id,expense.id);
  const altered=[...editArgs];altered[6]='Different';
  await assert.rejects(as(ids[0],()=>rpc('edit_expense',altered,editCasts)),/Request ID/);
  const stale=[...editArgs];stale[1]=randomUUID();
  await assert.rejects(as(ids[0],()=>rpc('edit_expense',stale,editCasts)),/entry changed/);
  assert.equal((await db.query('select count(*)::int n from public.expense_history where expense_id=$1',[expense.id])).rows[0].n,2);
});
await check('names can be set on create and cleared later; invalid edits rejected',async()=>{
  const args=[...payload(), 'Groceries'];
  const saved=await as(ids[0],()=>rpc('log_expense',args,[...casts,'text']));
  assert.equal((await as(ids[0],()=>rpc('expense_detail',[saved.id],['uuid']))).name,'Groceries');
  const update=[saved.id,randomUUID(),0,35000,17500,'Cafe','  '];
  await as(ids[0],()=>rpc('edit_expense',update,editCasts));
  assert.equal((await as(ids[0],()=>rpc('expense_detail',[saved.id],['uuid']))).name,null);
  for (const [index,value] of [[3,-1],[4,999999],[6,'x'.repeat(101)],[5,'x'.repeat(101)],[3,null],[2,null]]) {
    const invalid=[...update];invalid[1]=randomUUID();invalid[2]=1;invalid[index]=value;
    await assert.rejects(as(ids[0],()=>rpc('edit_expense',invalid,editCasts)),/Invalid expense|entry changed/);
  }
});
await db.close();
console.log(count+' database integration checks passed (PGlite/PostgreSQL).');
