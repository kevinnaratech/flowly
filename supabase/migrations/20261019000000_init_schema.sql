-- =====================================================================
-- Finance Tracker: skema awal (Supabase / PostgreSQL)
-- Auth ditangani Supabase Auth (auth.users). Tabel di sini cuma data aplikasi.
-- Hanya untuk project BARU. Jangan dijalankan di project yang sudah berisi tabel ini.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. FUNCTIONS (helper umum)
-- ---------------------------------------------------------------------

-- Auto-update kolom updated_at
create function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Saat user baru daftar (email atau Google), bikin profile otomatis
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, name, avatar_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name',
             new.raw_user_meta_data->>'full_name',
             split_part(new.email, '@', 1)),
    coalesce(new.raw_user_meta_data->>'avatar_url',
             new.raw_user_meta_data->>'picture')
  );
  return new;
end;
$$;

-- Saldo awal wallet selalu = initial_balance (klien tidak bisa memalsukan)
create function public.init_wallet_balance()
returns trigger
language plpgsql
as $$
begin
  new.balance := new.initial_balance;
  return new;
end;
$$;

-- Validasi: wallet harus milik user yang sama dan belum dihapus
create function public.validate_and_snapshot_wallet()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted timestamptz;
begin
  select deleted_at into v_deleted
  from public.wallets
  where id = new.wallet_id and user_id = new.user_id;

  if not found then
    raise exception 'Wallet tidak ditemukan atau bukan milik user ini';
  end if;

  if v_deleted is not null
     and (tg_op = 'INSERT' or new.wallet_id is distinct from old.wallet_id) then
    raise exception 'Wallet sudah dihapus';
  end if;

  return new;
end;
$$;

-- Sesuaikan saldo wallet. Argumen trigger: '1' untuk income, '-1' untuk expense
create function public.adjust_wallet_balance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sign numeric := (tg_argv[0])::numeric;
begin
  if tg_op = 'INSERT' then
    update public.wallets
       set balance = balance + v_sign * new.amount
     where id = new.wallet_id;
    return new;
  elsif tg_op = 'UPDATE' then
    update public.wallets
       set balance = balance - v_sign * old.amount
     where id = old.wallet_id;
    update public.wallets
       set balance = balance + v_sign * new.amount
     where id = new.wallet_id;
    return new;
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- 2. TABLES
-- ---------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.wallets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  initial_balance numeric(14,2) not null default 0,
  balance numeric(14,2) not null default 0,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.income_categories (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null unique,
  icon text,
  color text,
  created_at timestamptz not null default now()
);

create table public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null unique,
  icon text,
  color text,
  created_at timestamptz not null default now()
);

create table public.incomes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  wallet_id uuid not null references public.wallets(id),
  category_id uuid not null references public.income_categories(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  note text,
  transaction_date date not null default current_date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  wallet_id uuid not null references public.wallets(id),
  category_id uuid not null references public.expense_categories(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  note text,
  transaction_date date not null default current_date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.planning (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  category_id uuid not null references public.expense_categories(id) on delete restrict,
  name text not null,
  target_amount numeric(14,2) not null check (target_amount > 0),
  collected_amount numeric(14,2) not null default 0 check (collected_amount >= 0),
  target_date date not null,
  monthly_allocation numeric(14,2),
  status text generated always as (
    case when collected_amount >= target_amount then 'completed' else 'in_progress' end
  ) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Index untuk query yang sering dipakai (report, history, daftar per user)
create index wallets_user_id_idx on public.wallets(user_id);
create index incomes_user_date_idx on public.incomes(user_id, transaction_date);
create index incomes_wallet_id_idx on public.incomes(wallet_id);
create index expenses_user_date_idx on public.expenses(user_id, transaction_date);
create index expenses_wallet_id_idx on public.expenses(wallet_id);
create index planning_user_id_idx on public.planning(user_id);

-- ---------------------------------------------------------------------
-- 3. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.wallets enable row level security;
alter table public.income_categories enable row level security;
alter table public.expense_categories enable row level security;
alter table public.incomes enable row level security;
alter table public.expenses enable row level security;
alter table public.planning enable row level security;

-- profiles: lihat dan ubah milik sendiri. Insert via trigger, tidak ada delete.
create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);
create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- wallets: tanpa policy delete (hapus = soft delete lewat deleted_at)
create policy "wallets_select_own" on public.wallets
  for select using (auth.uid() = user_id);
create policy "wallets_insert_own" on public.wallets
  for insert with check (auth.uid() = user_id);
create policy "wallets_update_own" on public.wallets
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- kategori: semua boleh baca, tidak ada yang boleh ubah lewat aplikasi
create policy "income_categories_select_all" on public.income_categories
  for select using (true);
create policy "expense_categories_select_all" on public.expense_categories
  for select using (true);

-- incomes dan expenses: tanpa policy delete
create policy "incomes_select_own" on public.incomes
  for select using (auth.uid() = user_id);
create policy "incomes_insert_own" on public.incomes
  for insert with check (auth.uid() = user_id);
create policy "incomes_update_own" on public.incomes
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "expenses_select_own" on public.expenses
  for select using (auth.uid() = user_id);
create policy "expenses_insert_own" on public.expenses
  for insert with check (auth.uid() = user_id);
create policy "expenses_update_own" on public.expenses
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- planning: CRUD penuh milik sendiri
create policy "planning_select_own" on public.planning
  for select using (auth.uid() = user_id);
create policy "planning_insert_own" on public.planning
  for insert with check (auth.uid() = user_id);
create policy "planning_update_own" on public.planning
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "planning_delete_own" on public.planning
  for delete using (auth.uid() = user_id);

-- ---------------------------------------------------------------------
-- 4. GRANTS: klien cuma boleh ubah name dan deleted_at di wallets
--    (balance hanya berubah lewat trigger income/expense)
-- ---------------------------------------------------------------------

revoke update on public.wallets from authenticated;
grant update (name, deleted_at) on public.wallets to authenticated;

-- ---------------------------------------------------------------------
-- 5. TRIGGERS
-- ---------------------------------------------------------------------

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create trigger set_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();
create trigger set_wallets_updated_at
  before update on public.wallets
  for each row execute function public.set_updated_at();
create trigger set_incomes_updated_at
  before update on public.incomes
  for each row execute function public.set_updated_at();
create trigger set_expenses_updated_at
  before update on public.expenses
  for each row execute function public.set_updated_at();
create trigger set_planning_updated_at
  before update on public.planning
  for each row execute function public.set_updated_at();

create trigger wallets_init_balance
  before insert on public.wallets
  for each row execute function public.init_wallet_balance();

create trigger incomes_validate_wallet
  before insert or update on public.incomes
  for each row execute function public.validate_and_snapshot_wallet();
create trigger expenses_validate_wallet
  before insert or update on public.expenses
  for each row execute function public.validate_and_snapshot_wallet();

create trigger incomes_adjust_balance
  after insert or update on public.incomes
  for each row execute function public.adjust_wallet_balance('1');
create trigger expenses_adjust_balance
  after insert or update on public.expenses
  for each row execute function public.adjust_wallet_balance('-1');

-- ---------------------------------------------------------------------
-- 6. SEED: kategori (icon dan color diisi nanti sesuai desain UI)
-- ---------------------------------------------------------------------

insert into public.income_categories (code, name) values
  ('gaji', 'Gaji'),
  ('freelance', 'Freelance'),
  ('tabungan', 'Tabungan'),
  ('hadiah', 'Hadiah'),
  ('bisnis', 'Bisnis'),
  ('lainnya', 'Lainnya');

insert into public.expense_categories (code, name) values
  ('makanan', 'Makanan'),
  ('belanja', 'Belanja'),
  ('hiburan', 'Hiburan'),
  ('transportasi', 'Transportasi'),
  ('tagihan', 'Tagihan'),
  ('kesehatan', 'Kesehatan'),
  ('pendidikan', 'Pendidikan'),
  ('lainnya', 'Lainnya');
