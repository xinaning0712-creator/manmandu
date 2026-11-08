-- 慢慢讀車站：聖誕羽毛活動（2026-11 新增）
-- 在 Supabase 的 SQL Editor 整段貼上執行一次即可（重複執行也沒關係）

alter table public.settings add column if not exists xmas_early boolean not null default false;
alter table public.profiles
  add column if not exists xmas_min int not null default 0,   -- 活動期間累積的專心分鐘
  add column if not exists feathers int not null default 0,   -- 撿到的羽毛
  add column if not exists spent int not null default 0,      -- 換掉的羽毛
  add column if not exists items text[] not null default '{}',-- 換到的收藏
  add column if not exists wear text[] not null default '{}'; -- 正在戴的

-- 活動期間：台北時間 12/1–12/25，或站長提前開啟
create or replace function public.xmas_on() returns boolean
language sql security definer set search_path = public stable as $$
  select (to_char(now() at time zone 'Asia/Taipei','MM-DD') between '12-01' and '12-25')
      or coalesce((select xmas_early from public.settings where id = 1), false);
$$;

-- 累積分鐘：活動期間同時累積羽毛時數
create or replace function public.add_minutes(p_ym text, p_n int) returns int
language plpgsql security definer set search_path = public as $$
declare n int := greatest(1, least(p_n, 5)); t int; x boolean := public.xmas_on();
begin
  if p_ym !~ '^\d{4}-\d{2}$' then raise exception 'bad month'; end if;
  update public.profiles
     set total = total + n,
         months = jsonb_set(months, array[p_ym], to_jsonb(coalesce((months->>p_ym)::int, 0) + n)),
         xmas_min = xmas_min + case when x then n else 0 end,
         updated_at = now()
   where uid = auth.uid()
  returning total into t;
  if t is null then return null; end if;
  insert into public.station_stats (ym, minutes) values (p_ym, n)
  on conflict (ym) do update set minutes = public.station_stats.minutes + n;
  return t;
end $$;

-- 撿羽毛：每專心滿 1 小時可以撿 1 根
create or replace function public.collect_feather() returns int
language plpgsql security definer set search_path = public as $$
declare f int;
begin
  update public.profiles set feathers = feathers + 1
   where uid = auth.uid() and feathers < xmas_min / 60
  returning feathers into f;
  return f;
end $$;

-- 用羽毛換收藏
create or replace function public.redeem_item(p_item text) returns text[]
language plpgsql security definer set search_path = public as $$
declare cost int; it text[];
begin
  cost := case p_item when 'crown' then 6 when 'pearl' then 9 when 'wings' then 12 when 'snow' then 20 else null end;
  if cost is null then raise exception 'bad item'; end if;
  update public.profiles
     set spent = spent + cost, items = array_append(items, p_item), wear = array_append(array_remove(wear, p_item), p_item)
   where uid = auth.uid() and not (p_item = any(items)) and feathers - spent >= cost
  returning items into it;
  if it is null then raise exception 'not enough'; end if;
  return it;
end $$;

-- 換上／收起
create or replace function public.set_wear(p_wear text[]) returns text[]
language plpgsql security definer set search_path = public as $$
declare w text[];
begin
  update public.profiles
     set wear = coalesce(array(select x from unnest(p_wear) x where x = any(items)), '{}')
   where uid = auth.uid()
  returning wear into w;
  return w;
end $$;

-- 站長提前開啟（測試用）
create or replace function public.admin_set_xmas(p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not admin'; end if;
  update public.settings set xmas_early = coalesce(p_on, false) where id = 1;
end $$;

-- 換票卡時把收藏一起搬過去（profiles 整列搬家，已經包含）

-- 站長測試用：給自己幾小時的羽毛時數（只對站長自己有效）
create or replace function public.admin_test_feathers(p_n int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not admin'; end if;
  update public.profiles set xmas_min = xmas_min + greatest(0, least(p_n, 30)) * 60 where uid = auth.uid();
end $$;
