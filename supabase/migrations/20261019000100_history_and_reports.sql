-- =====================================================================
-- Finance Tracker: history global, laporan, dan total saldo
-- Jalankan SETELAH 20261019000000_init_schema.sql
-- Semua view/fungsi pakai hak akses pemanggil (RLS tetap berlaku),
-- jadi user hanya melihat data miliknya sendiri.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Default tanggal pakai zona waktu Indonesia (WIB)
--    Server Supabase memakai UTC, jadi current_date bisa mundur sehari
--    untuk input dini hari. Flutter tetap sebaiknya mengirim tanggal eksplisit.
-- ---------------------------------------------------------------------

alter table public.incomes
  alter column transaction_date set default ((now() at time zone 'Asia/Jakarta')::date);
alter table public.expenses
  alter column transaction_date set default ((now() at time zone 'Asia/Jakarta')::date);

-- ---------------------------------------------------------------------
-- 2. VIEW: history global (income + expense + saldo awal)
--    type: 'income' | 'expense' | 'initial_balance'
--    Saldo awal TIDAK dihitung sebagai income: ia hanya muncul sebagai baris
--    tersendiri di history, dan tidak ikut di fungsi laporan.
--    History wallet = filter wallet_id. Wallet terhapus tetap tampil
--    (wallet_deleted = true).
-- ---------------------------------------------------------------------

create view public.transaction_history
with (security_invoker = true) as
select
  i.id,
  i.user_id,
  i.wallet_id,
  w.name as wallet_name,
  (w.deleted_at is not null) as wallet_deleted,
  'income'::text as type,
  i.amount,
  i.amount as signed_amount,
  c.code as category_code,
  c.name as category_name,
  i.note,
  i.transaction_date,
  i.created_at
from public.incomes i
join public.wallets w on w.id = i.wallet_id
join public.income_categories c on c.id = i.category_id

union all

select
  e.id,
  e.user_id,
  e.wallet_id,
  w.name,
  (w.deleted_at is not null),
  'expense'::text,
  e.amount,
  -e.amount,
  c.code,
  c.name,
  e.note,
  e.transaction_date,
  e.created_at
from public.expenses e
join public.wallets w on w.id = e.wallet_id
join public.expense_categories c on c.id = e.category_id

union all

select
  w.id,
  w.user_id,
  w.id,
  w.name,
  (w.deleted_at is not null),
  'initial_balance'::text,
  w.initial_balance,
  w.initial_balance,
  null::text,
  null::text,
  null::text,
  (w.created_at at time zone 'Asia/Jakarta')::date,
  w.created_at
from public.wallets w
where w.initial_balance > 0;

revoke all on public.transaction_history from anon;
grant select on public.transaction_history to authenticated;

-- ---------------------------------------------------------------------
-- 3. FUNGSI LAPORAN
-- ---------------------------------------------------------------------

-- Pie chart: total expense per kategori dalam periode (p_to inklusif)
create function public.report_expense_by_category(p_from date, p_to date)
returns table (
  category_id uuid,
  category_code text,
  category_name text,
  total numeric,
  percentage numeric
)
language sql
stable
set search_path = public
as $$
  with t as (
    select c.id, c.code, c.name, sum(e.amount) as total
    from public.expenses e
    join public.expense_categories c on c.id = e.category_id
    where e.user_id = auth.uid()
      and e.transaction_date between p_from and p_to
    group by c.id, c.code, c.name
  )
  select id, code, name, total, round(total * 100 / sum(total) over (), 2)
  from t
  order by total desc;
$$;

-- Grafik income vs expense per bulan (bulan tanpa transaksi tetap tampil = 0)
-- Satuannya bulan penuh: bulan dari p_from sampai bulan p_to.
create function public.report_monthly_summary(p_from date, p_to date)
returns table (month date, income numeric, expense numeric)
language sql
stable
set search_path = public
as $$
  select
    m::date as month,
    coalesce((
      select sum(i.amount) from public.incomes i
      where i.user_id = auth.uid()
        and i.transaction_date >= m::date
        and i.transaction_date < (m + interval '1 month')::date
    ), 0) as income,
    coalesce((
      select sum(e.amount) from public.expenses e
      where e.user_id = auth.uid()
        and e.transaction_date >= m::date
        and e.transaction_date < (m + interval '1 month')::date
    ), 0) as expense
  from generate_series(
    date_trunc('month', p_from::timestamp),
    date_trunc('month', p_to::timestamp),
    interval '1 month'
  ) as m
  order by m;
$$;

-- Total saldo semua wallet aktif (yang dihapus tidak dihitung)
create function public.get_total_balance()
returns numeric
language sql
stable
set search_path = public
as $$
  select coalesce(sum(balance), 0)
  from public.wallets
  where user_id = auth.uid() and deleted_at is null;
$$;

revoke execute on function public.report_expense_by_category(date, date) from public, anon;
revoke execute on function public.report_monthly_summary(date, date) from public, anon;
revoke execute on function public.get_total_balance() from public, anon;
grant execute on function public.report_expense_by_category(date, date) to authenticated;
grant execute on function public.report_monthly_summary(date, date) to authenticated;
grant execute on function public.get_total_balance() to authenticated;
