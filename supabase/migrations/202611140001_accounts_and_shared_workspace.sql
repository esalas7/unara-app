-- UNARA accounts, private birthdays, shared worship-team data.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  role text not null default 'Músico'
    check (role in ('Líder', 'Músico', 'Sonido', 'Multimedia')),
  instruments text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.profile_birthdays (
  user_id uuid primary key references auth.users(id) on delete cascade,
  date_of_birth date not null
);

create table if not exists public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  invite_code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

create table if not exists public.workspace_songs (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  id text not null,
  data jsonb not null,
  primary key (workspace_id, id)
);

create table if not exists public.workspace_meetings (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  id text not null,
  data jsonb not null,
  primary key (workspace_id, id)
);

-- Keep shared lists current on other devices without a page reload.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'workspace_songs') then
      execute 'alter publication supabase_realtime add table public.workspace_songs';
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'workspace_meetings') then
      execute 'alter publication supabase_realtime add table public.workspace_meetings';
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'workspace_members') then
      execute 'alter publication supabase_realtime add table public.workspace_members';
    end if;
  end if;
end;
$$;

alter table public.profiles enable row level security;
alter table public.profile_birthdays enable row level security;
alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.workspace_songs enable row level security;
alter table public.workspace_meetings enable row level security;

-- A SECURITY DEFINER helper avoids recursive RLS policies on workspace_members.
create or replace function public.is_workspace_member(target_workspace uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.workspace_members
    where workspace_id = target_workspace and user_id = auth.uid()
  );
$$;
revoke all on function public.is_workspace_member(uuid) from public;
grant execute on function public.is_workspace_member(uuid) to authenticated;

create policy "Profiles are visible within your team"
  on public.profiles for select to authenticated
  using (
    id = auth.uid() or exists (
      select 1 from public.workspace_members theirs
      where theirs.user_id = profiles.id and public.is_workspace_member(theirs.workspace_id)
    )
  );
create policy "Users can create their own profile"
  on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "Users can update their own profile"
  on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "Birthdays are private to their owner"
  on public.profile_birthdays for select to authenticated using (user_id = auth.uid());
create policy "Users can create their own birthday"
  on public.profile_birthdays for insert to authenticated with check (user_id = auth.uid());
create policy "Users can update their own birthday"
  on public.profile_birthdays for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "Workspace members can read their workspace"
  on public.workspaces for select to authenticated
  using (public.is_workspace_member(id));
create policy "Workspace members are visible to the team"
  on public.workspace_members for select to authenticated
  using (public.is_workspace_member(workspace_id));

create policy "Team members can read songs"
  on public.workspace_songs for select to authenticated
  using (public.is_workspace_member(workspace_id));
create policy "Team members can add songs"
  on public.workspace_songs for insert to authenticated
  with check (public.is_workspace_member(workspace_id));
create policy "Team members can edit songs"
  on public.workspace_songs for update to authenticated
  using (public.is_workspace_member(workspace_id))
  with check (public.is_workspace_member(workspace_id));
create policy "Team members can remove songs"
  on public.workspace_songs for delete to authenticated
  using (public.is_workspace_member(workspace_id));

create policy "Team members can read meetings"
  on public.workspace_meetings for select to authenticated
  using (public.is_workspace_member(workspace_id));
create policy "Team members can add meetings"
  on public.workspace_meetings for insert to authenticated
  with check (public.is_workspace_member(workspace_id));
create policy "Team members can edit meetings"
  on public.workspace_meetings for update to authenticated
  using (public.is_workspace_member(workspace_id))
  with check (public.is_workspace_member(workspace_id));
create policy "Team members can remove meetings"
  on public.workspace_meetings for delete to authenticated
  using (public.is_workspace_member(workspace_id));

create or replace function public.create_workspace(workspace_name text)
returns table(id uuid, name text, invite_code text)
language plpgsql security definer set search_path = public
as $$
declare new_workspace public.workspaces;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  if length(trim(workspace_name)) < 2 then raise exception 'Escribe un nombre para el equipo.'; end if;
  insert into public.workspaces(name, created_by)
    values (trim(workspace_name), auth.uid()) returning * into new_workspace;
  insert into public.workspace_members(workspace_id, user_id)
    values (new_workspace.id, auth.uid());
  return query select new_workspace.id, new_workspace.name, new_workspace.invite_code;
end;
$$;

create or replace function public.join_workspace(code text)
returns table(id uuid, name text)
language plpgsql security definer set search_path = public
as $$
declare found_workspace public.workspaces;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  select * into found_workspace from public.workspaces
    where invite_code = upper(trim(code));
  if found_workspace.id is null then raise exception 'El código no existe. Revísalo e intenta de nuevo.'; end if;
  insert into public.workspace_members(workspace_id, user_id)
    values (found_workspace.id, auth.uid()) on conflict do nothing;
  return query select found_workspace.id, found_workspace.name;
end;
$$;

revoke all on function public.create_workspace(text) from public;
revoke all on function public.join_workspace(text) from public;
grant execute on function public.create_workspace(text) to authenticated;
grant execute on function public.join_workspace(text) to authenticated;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles(id, full_name, role)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'full_name', ''),
      coalesce(new.raw_user_meta_data->>'role', 'Músico')
    );
  if nullif(new.raw_user_meta_data->>'date_of_birth', '') is not null then
    insert into public.profile_birthdays(user_id, date_of_birth)
      values (new.id, (new.raw_user_meta_data->>'date_of_birth')::date);
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_unara on auth.users;
create trigger on_auth_user_created_unara
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

grant select, insert, update, delete on public.profiles to authenticated;
grant select, insert, update, delete on public.profile_birthdays to authenticated;
grant select on public.workspaces, public.workspace_members to authenticated;
grant select, insert, update, delete on public.workspace_songs, public.workspace_meetings to authenticated;
