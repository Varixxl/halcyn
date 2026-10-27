-- Halcyn accounts: an end-to-end encrypted vault for the streaming services'
-- sign-ins, and the user's playlists. The server only ever holds vault
-- ciphertext; keys are made on the device (rust/src/account.rs).

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- One row per account. The random vault key is stored twice, wrapped by the
-- password-derived key and by the recovery key; both are opaque here.
create table public.vaults (
  user_id uuid primary key references auth.users (id) on delete cascade,
  kdf jsonb not null,
  key_by_password text not null check (length(key_by_password) <= 512),
  key_by_recovery text not null check (length(key_by_recovery) <= 512),
  -- A keyed hash of the vault key: lets a device notice its key is stale.
  key_id text not null check (length(key_id) <= 64),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One row per service, so a sign-in renewed on one device doesn't overwrite
-- another service's.
create table public.vault_items (
  user_id uuid not null references auth.users (id) on delete cascade,
  service text not null check (service ~ '^[a-z0-9_.-]{1,64}$'),
  ciphertext text not null check (length(ciphertext) <= 65536),
  updated_at timestamptz not null default now(),
  primary key (user_id, service)
);

-- Playlists, each entry carrying the song's tags so another device can find
-- its own copy. Deleting keeps a tombstone so other devices delete theirs.
create table public.playlists (
  user_id uuid not null references auth.users (id) on delete cascade,
  id uuid not null,
  name text not null check (length(name) <= 500),
  entries jsonb not null default '[]'::jsonb
    check (pg_column_size(entries) <= 4194304),
  deleted boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (user_id, id)
);

create trigger vaults_touch before update on public.vaults
  for each row execute function public.touch_updated_at();
create trigger vault_items_touch before update on public.vault_items
  for each row execute function public.touch_updated_at();
create trigger playlists_touch before update on public.playlists
  for each row execute function public.touch_updated_at();

alter table public.vaults enable row level security;
alter table public.vault_items enable row level security;
alter table public.playlists enable row level security;

revoke all on public.vaults, public.vault_items, public.playlists from anon;
grant select, insert, update, delete
  on public.vaults, public.vault_items, public.playlists to authenticated;

create policy "own vault" on public.vaults
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "own vault items" on public.vault_items
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "own playlists" on public.playlists
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

-- Lets a signed-in user delete their own account and, by cascade, its data.
create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
