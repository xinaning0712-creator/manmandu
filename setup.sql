-- 慢慢讀車站：Supabase 資料表與權限設定
-- 在 Supabase 的 SQL Editor 整段貼上執行一次即可

-- 個人票卡（每台裝置一個匿名身分，只能讀寫自己的）
create table if not exists public.profiles (
  uid uuid primary key default auth.uid() references auth.users on delete cascade,
  nick text not null check (char_length(nick) between 1 and 10),
  animal text not null,
  scarf text not null,
  total int not null default 0,
  months jsonb not null default '{}'::jsonb,
  code text unique not null default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)),
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "profile_select_own" on public.profiles;
drop policy if exists "profile_insert_own" on public.profiles;
drop policy if exists "profile_update_own" on public.profiles;
create policy "profile_select_own" on public.profiles for select using (uid = auth.uid());
create policy "profile_insert_own" on public.profiles for insert with check (uid = auth.uid() and total = 0);
create policy "profile_update_own" on public.profiles for update using (uid = auth.uid()) with check (uid = auth.uid());
revoke insert, update on public.profiles from anon, authenticated;
grant insert (uid, nick, animal, scarf) on public.profiles to authenticated;
grant update (nick, animal, scarf, updated_at) on public.profiles to authenticated;

-- 每月共讀里程（大家只看得到總和）
create table if not exists public.station_stats (
  ym text primary key,
  minutes int not null default 0
);
alter table public.station_stats enable row level security;
drop policy if exists "stats_read" on public.station_stats;
create policy "stats_read" on public.station_stats for select using (true);

-- 站長設定
create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  goal_hours int not null default 30,
  music_path text,
  music_name text
);
insert into public.settings (id) values (1) on conflict do nothing;
alter table public.settings enable row level security;
drop policy if exists "settings_read" on public.settings;
create policy "settings_read" on public.settings for select using (true);

-- 站長名單與站長密碼（不開放直接讀取）
create table if not exists public.admins (uid uuid primary key references auth.users on delete cascade);
alter table public.admins enable row level security;
create table if not exists public.secrets (id int primary key check (id = 1), pass_hash text not null);
alter table public.secrets enable row level security;

create or replace function public.is_admin() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.admins where uid = auth.uid());
$$;

-- 紙條牆
create table if not exists public.notes (
  id bigint generated always as identity primary key,
  uid uuid not null default auth.uid() references auth.users on delete cascade,
  nick text not null check (char_length(nick) between 1 and 10),
  text text not null check (char_length(text) between 1 and 60),
  color text not null default '#f3d9b8',
  at timestamptz not null default now()
);
alter table public.notes enable row level security;
drop policy if exists "notes_read" on public.notes;
drop policy if exists "notes_insert_own" on public.notes;
drop policy if exists "notes_delete" on public.notes;
create policy "notes_read" on public.notes for select using (true);
create policy "notes_insert_own" on public.notes for insert with check (uid = auth.uid());
create policy "notes_delete" on public.notes for delete using (uid = auth.uid() or public.is_admin());

-- 累積閱讀分鐘：同時加到個人票卡和本月里程（一次最多 5 分鐘）
create or replace function public.add_minutes(p_ym text, p_n int) returns int
language plpgsql security definer set search_path = public as $$
declare n int := greatest(1, least(p_n, 5)); t int;
begin
  if p_ym !~ '^\d{4}-\d{2}$' then raise exception 'bad month'; end if;
  update public.profiles
     set total = total + n,
         months = jsonb_set(months, array[p_ym], to_jsonb(coalesce((months->>p_ym)::int, 0) + n)),
         updated_at = now()
   where uid = auth.uid()
  returning total into t;
  if t is null then return null; end if;
  insert into public.station_stats (ym, minutes) values (p_ym, n)
  on conflict (ym) do update set minutes = public.station_stats.minutes + n;
  return t;
end $$;

-- 換裝置時用票卡碼找回紀錄
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
  if exists (select 1 from public.admins where uid = old) then
    insert into public.admins values (auth.uid()) on conflict do nothing;
  end if;
  return true;
end $$;

-- 站長登入（比對站長密碼）
create or replace function public.claim_admin(p_pass text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
begin
  if exists (select 1 from public.secrets where id = 1 and pass_hash = crypt(p_pass, pass_hash)) then
    insert into public.admins values (auth.uid()) on conflict do nothing;
    return true;
  end if;
  return false;
end $$;

create or replace function public.admin_set_goal(p_goal int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not admin'; end if;
  update public.settings set goal_hours = greatest(3, least(p_goal, 500)) where id = 1;
end $$;

create or replace function public.admin_set_music(p_path text, p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not admin'; end if;
  update public.settings set music_path = p_path, music_name = left(p_name, 40) where id = 1;
end $$;

-- 即時更新
do $$ begin
  begin alter publication supabase_realtime add table public.station_stats; exception when others then null; end;
  begin alter publication supabase_realtime add table public.settings; exception when others then null; end;
  begin alter publication supabase_realtime add table public.notes; exception when others then null; end;
end $$;

-- 背景音樂空間（大家都能聽，只有站長能上傳和刪除）
insert into storage.buckets (id, name, public) values ('music', 'music', true) on conflict (id) do nothing;
drop policy if exists "music_admin_insert" on storage.objects;
drop policy if exists "music_admin_delete" on storage.objects;
create policy "music_admin_insert" on storage.objects for insert to authenticated with check (bucket_id = 'music' and public.is_admin());
create policy "music_admin_delete" on storage.objects for delete to authenticated using (bucket_id = 'music' and public.is_admin());

-- 收緊權限（只能透過上面的函式寫入）
revoke insert, update, delete on public.station_stats, public.settings, public.admins, public.secrets from anon, authenticated;
revoke select on public.admins, public.secrets from anon, authenticated;
