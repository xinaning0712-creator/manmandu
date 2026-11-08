-- 慢慢讀車站：待辦清單（2026-11 新增）
create table if not exists public.todos (
  id bigint generated always as identity primary key,
  uid uuid not null default auth.uid() references auth.users on delete cascade,
  text text not null check (char_length(text) between 1 and 60),
  done boolean not null default false,
  done_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.todos enable row level security;
drop policy if exists "todos_own" on public.todos;
create policy "todos_own" on public.todos for all using (uid = auth.uid()) with check (uid = auth.uid());
create or replace function public.station_todo_done(p_ym text) returns int
language sql security definer set search_path = public stable as $$
  select count(*)::int from public.todos where done and to_char(done_at at time zone 'Asia/Taipei', 'YYYY-MM') = p_ym;
$$;
