-- 慢慢讀車站：閱讀紀錄本（2026-11 新增）
create table if not exists public.readings (
  id bigint generated always as identity primary key,
  uid uuid not null default auth.uid() references auth.users on delete cascade,
  kind text not null check (kind in ('book','paper')),
  title text not null check (char_length(title) between 1 and 150),
  authors text check (char_length(authors) <= 100),
  year int check (year between 1800 and 2100),
  note text check (char_length(note) <= 50),
  tags text check (char_length(tags) <= 60),
  link text check (char_length(link) <= 400),
  created_at timestamptz not null default now()
);
alter table public.readings enable row level security;
drop policy if exists "readings_own_select" on public.readings;
drop policy if exists "readings_own_insert" on public.readings;
drop policy if exists "readings_own_update" on public.readings;
drop policy if exists "readings_own_delete" on public.readings;
create policy "readings_own_select" on public.readings for select using (uid = auth.uid());
create policy "readings_own_insert" on public.readings for insert with check (uid = auth.uid());
create policy "readings_own_update" on public.readings for update using (uid = auth.uid()) with check (uid = auth.uid());
create policy "readings_own_delete" on public.readings for delete using (uid = auth.uid());

-- 全車站本月數量（只回傳總數，看不到內容）
create or replace function public.station_read_counts(p_ym text) returns json
language sql security definer set search_path = public stable as $$
  select json_build_object('books', count(*) filter (where kind = 'book'), 'papers', count(*) filter (where kind = 'paper'))
  from public.readings where to_char(created_at at time zone 'Asia/Taipei', 'YYYY-MM') = p_ym;
$$;

-- 票卡碼找回時，一起搬移閱讀紀錄
create or replace function public.claim_ticket(p_code text) returns boolean
language plpgsql security definer set search_path = public as $$
declare old uuid;
begin
  select uid into old from public.profiles where code = upper(trim(p_code));
  if old is null then return false; end if;
  if old = auth.uid() then return true; end if;
  delete from public.profiles where uid = auth.uid();
  update public.profiles set uid = auth.uid() where uid = old;
  update public.notes set uid = auth.uid() where uid = old;
  update public.readings set uid = auth.uid() where uid = old;
  if exists (select 1 from public.admins where uid = old) then
    insert into public.admins values (auth.uid()) on conflict do nothing;
  end if;
  return true;
end $$;
