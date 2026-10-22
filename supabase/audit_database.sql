with
exp_cols(t,c,nul) as (values
 ('profiles','id','NO'),('profiles','name','NO'),('profiles','avatar_url','YES'),('profiles','created_at','NO'),('profiles','updated_at','NO'),
 ('wallets','id','NO'),('wallets','user_id','NO'),('wallets','name','NO'),('wallets','initial_balance','NO'),('wallets','balance','NO'),('wallets','deleted_at','YES'),('wallets','created_at','NO'),('wallets','updated_at','NO'),
 ('income_categories','id','NO'),('income_categories','code','NO'),('income_categories','name','NO'),('income_categories','icon','YES'),('income_categories','color','YES'),('income_categories','created_at','NO'),
 ('expense_categories','id','NO'),('expense_categories','code','NO'),('expense_categories','name','NO'),('expense_categories','icon','YES'),('expense_categories','color','YES'),('expense_categories','created_at','NO'),
 ('incomes','id','NO'),('incomes','user_id','NO'),('incomes','wallet_id','NO'),('incomes','category_id','NO'),('incomes','amount','NO'),('incomes','note','YES'),('incomes','transaction_date','NO'),('incomes','created_at','NO'),('incomes','updated_at','NO'),
 ('expenses','id','NO'),('expenses','user_id','NO'),('expenses','wallet_id','NO'),('expenses','category_id','NO'),('expenses','amount','NO'),('expenses','note','YES'),('expenses','transaction_date','NO'),('expenses','created_at','NO'),('expenses','updated_at','NO'),
 ('planning','id','NO'),('planning','user_id','NO'),('planning','category_id','NO'),('planning','name','NO'),('planning','target_amount','NO'),('planning','collected_amount','NO'),('planning','target_date','NO'),('planning','monthly_allocation','YES'),('planning','status','YES'),('planning','created_at','NO'),('planning','updated_at','NO')
),
act_cols as (
 select c.table_name t, c.column_name c, c.is_nullable nul from information_schema.columns c
 join information_schema.tables tb on tb.table_schema=c.table_schema and tb.table_name=c.table_name
 where c.table_schema='public' and tb.table_type='BASE TABLE'
),
exp_pol(t,cmd) as (values
 ('profiles','SELECT'),('profiles','UPDATE'),
 ('wallets','SELECT'),('wallets','INSERT'),('wallets','UPDATE'),
 ('income_categories','SELECT'),('expense_categories','SELECT'),
 ('incomes','SELECT'),('incomes','INSERT'),('incomes','UPDATE'),
 ('expenses','SELECT'),('expenses','INSERT'),('expenses','UPDATE'),
 ('planning','SELECT'),('planning','INSERT'),('planning','UPDATE'),('planning','DELETE')
),
act_pol as (select tablename::text t, cmd from pg_policies where schemaname='public'),
exp_trg(t,f) as (values
 ('profiles','set_updated_at'),('wallets','set_updated_at'),('wallets','init_wallet_balance'),
 ('incomes','set_updated_at'),('incomes','validate_and_snapshot_wallet'),('incomes','adjust_wallet_balance'),
 ('expenses','set_updated_at'),('expenses','validate_and_snapshot_wallet'),('expenses','adjust_wallet_balance'),
 ('planning','set_updated_at'),('users','handle_new_user')
),
act_trg as (
 select distinct c.relname::text t, p.proname::text f
 from pg_trigger g join pg_class c on c.oid=g.tgrelid join pg_proc p on p.oid=g.tgfoid
 where not g.tgisinternal
),
exp_idx(i) as (values ('wallets_user_id_idx'),('incomes_user_date_idx'),('incomes_wallet_id_idx'),('expenses_user_date_idx'),('expenses_wallet_id_idx'),('planning_user_id_idx'))
select no, cek, status, detail from (
 select 1 no, 'Jumlah tabel public = 7' cek,
   case when n=7 then 'OK' else 'MASALAH' end status, n::text detail
   from (select count(*) n from information_schema.tables where table_schema='public' and table_type='BASE TABLE') s
 union all
 select 2, 'RLS aktif di semua tabel',
   case when coalesce(string_agg(relname,', '),'')='' then 'OK' else 'MASALAH' end,
   coalesce(nullif(string_agg(relname,', '),''),'semua aktif')
   from pg_class where relnamespace='public'::regnamespace and relkind='r' and not relrowsecurity
 union all
 select 3, 'Kolom yang hilang dibanding ERD',
   case when count(*)=0 then 'OK' else 'MASALAH' end,
   coalesce(nullif(string_agg(e.t||'.'||e.c,', '),''),'tidak ada')
   from exp_cols e left join act_cols a using (t,c) where a.c is null
 union all
 select 4, 'Kolom ekstra yang tidak ada di ERD',
   case when count(*)=0 then 'OK' else 'MASALAH' end,
   coalesce(nullif(string_agg(a.t||'.'||a.c,', '),''),'tidak ada')
   from act_cols a left join exp_cols e using (t,c) where e.c is null
 union all
 select 5, 'Wajib/boleh kosong (NULL) sesuai ERD',
   case when count(*)=0 then 'OK' else 'MASALAH' end,
   coalesce(nullif(string_agg(e.t||'.'||e.c||' (db='||a.nul||', erd='||e.nul||')',', '),''),'sesuai')
   from exp_cols e join act_cols a using (t,c) where a.nul<>e.nul
 union all
 select 6, 'Policy yang hilang',
   case when count(*)=0 then 'OK' else 'MASALAH' end,
   coalesce(nullif(string_agg(e.t||':'||e.cmd,', '),''),'tidak ada')
   from exp_pol e left join act_pol a using (t,cmd) where a.t is null
 union all
 select 7, 'Policy berlebih (misal delete yang seharusnya tidak ada)',
   case when count(*)=0 then 'OK' else 'MASALAH' end,
   coalesce(nullif(string_agg(a.t||':'||a.cmd,', '),''),'tidak ada')
   from act_pol a left join exp_pol e using (t,cmd) where e.t is null
 union all
 select 8, 'Trigger yang hilang',
   case when count(*)=0 then 'OK' else 'MASALAH' end,
   coalesce(nullif(string_agg(e.t||':'||e.f,', '),''),'tidak ada')
   from exp_trg e left join act_trg a using (t,f) where a.t is null
 union all
 select 9, 'Index yang hilang',
   case when count(*)=0 then 'OK' else 'MASALAH' end,
   coalesce(nullif(string_agg(e.i,', '),''),'tidak ada')
   from exp_idx e left join pg_indexes x on x.schemaname='public' and x.indexname=e.i where x.indexname is null
 union all
 select 10, 'FK wallet_id tidak cascade/set null',
   case when count(*) filter (where confdeltype in ('a','r'))=2 then 'OK' else 'MASALAH' end,
   string_agg(conrelid::regclass::text||'='||confdeltype::text,', ')
   from pg_constraint where contype='f' and confrelid='public.wallets'::regclass and conrelid in ('public.incomes'::regclass,'public.expenses'::regclass)
 union all
 select 11, 'Check amount > 0 di incomes, expenses, planning.target_amount',
   case when count(*)>=3 then 'OK' else 'MASALAH' end, count(*)::text||' constraint ditemukan'
   from pg_constraint where contype='c' and conrelid in ('public.incomes'::regclass,'public.expenses'::regclass,'public.planning'::regclass)
     and pg_get_constraintdef(oid) ~ '(amount|target_amount) > \(?0'
 union all
 select 12, 'code kategori unik',
   case when count(distinct tablename)=2 then 'OK' else 'MASALAH' end, count(distinct tablename)::text||' dari 2 tabel'
   from pg_indexes where schemaname='public' and tablename in ('income_categories','expense_categories')
     and indexdef ilike 'create unique index%(code)%'
 union all
 select 13, 'planning.status generated otomatis',
   case when max(is_generated)='ALWAYS' then 'OK' else 'MASALAH' end, coalesce(max(is_generated),'kolom tidak ada')
   from information_schema.columns where table_schema='public' and table_name='planning' and column_name='status'
 union all
 select 14, 'Klien tidak bisa ubah balance/initial_balance, cuma name dan deleted_at',
   case when not has_column_privilege('authenticated','public.wallets','balance','UPDATE')
         and not has_column_privilege('authenticated','public.wallets','initial_balance','UPDATE')
         and has_column_privilege('authenticated','public.wallets','name','UPDATE')
         and has_column_privilege('authenticated','public.wallets','deleted_at','UPDATE')
        then 'OK' else 'MASALAH' end,
   'balance='||has_column_privilege('authenticated','public.wallets','balance','UPDATE')::text||', name='||has_column_privilege('authenticated','public.wallets','name','UPDATE')::text
 union all
 select 15, 'Function security definer punya search_path',
   case when count(*)=0 then 'OK' else 'MASALAH' end,
   coalesce(nullif(string_agg(proname,', '),''),'semua aman')
   from pg_proc where pronamespace='public'::regnamespace and prosecdef
     and not coalesce(proconfig::text ilike '%search_path%', false)
 union all
 select 16, 'Isi kategori (income / expense)',
   case when (select count(*) from public.income_categories)>0 and (select count(*) from public.expense_categories)>0 then 'OK' else 'MASALAH' end,
   (select count(*) from public.income_categories)||' / '||(select count(*) from public.expense_categories)
 union all
 select 17, 'Sisa data tes (wallets/incomes/expenses/planning)',
   case when (select count(*) from public.wallets)+(select count(*) from public.incomes)+(select count(*) from public.expenses)+(select count(*) from public.planning)=0 then 'OK' else 'INFO' end,
   (select count(*) from public.wallets)||'/'||(select count(*) from public.incomes)||'/'||(select count(*) from public.expenses)||'/'||(select count(*) from public.planning)
 union all
 select 18, 'View history global ada dan memakai RLS pemanggil (security_invoker)',
   case when count(*) filter (where reloptions::text ilike '%security_invoker=true%')=1 then 'OK' else 'MASALAH' end,
   coalesce(max(relname)::text,'view transaction_history tidak ada')
   from pg_class where relnamespace='public'::regnamespace and relkind='v' and relname='transaction_history'
 union all
 select 19, 'Fungsi laporan dan total saldo ada (3 fungsi)',
   case when count(*)=3 then 'OK' else 'MASALAH' end, count(*)::text||' dari 3'
   from pg_proc where pronamespace='public'::regnamespace
     and proname in ('report_expense_by_category','report_monthly_summary','get_total_balance')
 union all
 select 20, 'View dan fungsi tertutup untuk anon (belum login)',
   case when not has_table_privilege('anon','public.transaction_history','SELECT')
         and not has_function_privilege('anon','public.get_total_balance()','EXECUTE')
        then 'OK' else 'MASALAH' end, 'anon ditolak'
) x order by no;
