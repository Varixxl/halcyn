-- What a phone is playing, for the user's computer to show on Discord (a phone
-- has no Discord app to tell). One row per account: the device playing last.

create table public.now_playing (
  user_id uuid primary key references auth.users (id) on delete cascade,
  device text not null check (length(device) <= 200),
  track jsonb check (pg_column_size(track) <= 16384),
  playing boolean not null default false,
  started_at timestamptz,
  updated_at timestamptz not null default now()
);

create trigger now_playing_touch before update on public.now_playing
  for each row execute function public.touch_updated_at();

alter table public.now_playing enable row level security;
revoke all on public.now_playing from anon;
grant select, insert, update, delete on public.now_playing to authenticated;

create policy "own now playing" on public.now_playing
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- The computer hears about changes as they happen.
alter publication supabase_realtime add table public.now_playing;
