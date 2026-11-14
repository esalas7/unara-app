-- Workspace administrators are separate from worship-team roles.
alter table public.workspace_members
  add column if not exists is_admin boolean not null default false;

-- The workspace creator and existing worship leaders begin as administrators.
update public.workspace_members member
set is_admin = true
from public.workspaces workspace, public.profiles profile
where member.workspace_id = workspace.id
  and member.user_id = profile.id
  and (member.user_id = workspace.created_by or profile.role = 'Líder');

create or replace function public.is_workspace_admin(target_workspace uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.workspace_members
    where workspace_id = target_workspace and user_id = auth.uid() and is_admin
  );
$$;
revoke all on function public.is_workspace_admin(uuid) from public;
grant execute on function public.is_workspace_admin(uuid) to authenticated;

create or replace function public.set_workspace_admin(
  target_workspace uuid, target_user uuid, make_admin boolean
)
returns void language plpgsql security definer set search_path = public
as $$
declare
  workspace_creator uuid;
  target_role text;
  admin_count integer;
begin
  if auth.uid() is null or not public.is_workspace_admin(target_workspace) then
    raise exception 'Solo un administrador puede cambiar administradores.';
  end if;

  select created_by into workspace_creator from public.workspaces
    where id = target_workspace for update;
  if workspace_creator is null then raise exception 'No se encontró el espacio de trabajo.'; end if;

  select profile.role into target_role
  from public.workspace_members member
  join public.profiles profile on profile.id = member.user_id
  where member.workspace_id = target_workspace and member.user_id = target_user;
  if not found then raise exception 'Esa persona ya no pertenece al equipo.'; end if;

  if not make_admin and (target_user = workspace_creator or target_role = 'Líder') then
    raise exception 'El creador del espacio y los líderes deben conservar su administración.';
  end if;

  if not make_admin then
    select count(*) into admin_count from public.workspace_members
      where workspace_id = target_workspace and is_admin;
    if admin_count <= 1 and exists (
      select 1 from public.workspace_members
      where workspace_id = target_workspace and user_id = target_user and is_admin
    ) then raise exception 'El equipo debe conservar al menos un administrador.'; end if;
  end if;

  if make_admin then
    select count(*) into admin_count from public.workspace_members
      where workspace_id = target_workspace and is_admin;
    if admin_count >= 5 and not exists (
      select 1 from public.workspace_members
      where workspace_id = target_workspace and user_id = target_user and is_admin
    ) then raise exception 'El espacio ya tiene sus 5 administradores.'; end if;
  end if;

  update public.workspace_members set is_admin = make_admin
  where workspace_id = target_workspace and user_id = target_user;
end;
$$;
revoke all on function public.set_workspace_admin(uuid, uuid, boolean) from public;
grant execute on function public.set_workspace_admin(uuid, uuid, boolean) to authenticated;

-- Keep role and administrator status aligned for members who become leaders.
create or replace function public.protect_workspace_leader_role()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  team record;
  admin_count integer;
begin
  if new.role = 'Líder' and old.role is distinct from new.role then
    for team in
      select workspace_id, is_admin from public.workspace_members where user_id = new.id
    loop
      if not team.is_admin and auth.uid() = new.id then
        raise exception 'Solo un administrador puede asignar el cargo de líder.';
      end if;
      if not team.is_admin then
        perform 1 from public.workspaces where id = team.workspace_id for update;
        select count(*) into admin_count from public.workspace_members
          where workspace_id = team.workspace_id and is_admin;
        if admin_count >= 5 then raise exception 'El espacio ya tiene sus 5 administradores.'; end if;
        update public.workspace_members set is_admin = true
          where workspace_id = team.workspace_id and user_id = new.id;
      end if;
    end loop;
  end if;
  return new;
end;
$$;
drop trigger if exists protect_workspace_leader_role on public.profiles;
create trigger protect_workspace_leader_role
  after update of role on public.profiles
  for each row execute function public.protect_workspace_leader_role();

-- The creator is an administrator immediately; joining leaders are administrators too.
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
  insert into public.workspace_members(workspace_id, user_id, is_admin)
    values (new_workspace.id, auth.uid(), true);
  return query select new_workspace.id, new_workspace.name, new_workspace.invite_code;
end;
$$;

create or replace function public.join_workspace(code text)
returns table(id uuid, name text)
language plpgsql security definer set search_path = public
as $$
declare
  found_workspace public.workspaces;
  joining_role text;
  admin_count integer;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  select * into found_workspace from public.workspaces
    where invite_code = upper(trim(code)) for update;
  if found_workspace.id is null then raise exception 'El código no existe. Revísalo e intenta de nuevo.'; end if;
  select role into joining_role from public.profiles where id = auth.uid();
  if joining_role = 'Líder' then
    select count(*) into admin_count from public.workspace_members
      where workspace_id = found_workspace.id and is_admin;
    if admin_count >= 5 and not exists (
      select 1 from public.workspace_members where workspace_id = found_workspace.id and user_id = auth.uid()
    ) then raise exception 'El equipo ya tiene sus 5 administradores. Pide al creador que revise los cargos Líder.'; end if;
  end if;
  insert into public.workspace_members(workspace_id, user_id, is_admin)
    values (found_workspace.id, auth.uid(), joining_role = 'Líder') on conflict do nothing;
  return query select found_workspace.id, found_workspace.name;
end;
$$;

-- Members can still read meetings. Only workspace administrators can change them.
drop policy if exists "Team members can add meetings" on public.workspace_meetings;
drop policy if exists "Team members can edit meetings" on public.workspace_meetings;
drop policy if exists "Team members can remove meetings" on public.workspace_meetings;
create policy "Workspace admins can add meetings"
  on public.workspace_meetings for insert to authenticated
  with check (public.is_workspace_admin(workspace_id));
create policy "Workspace admins can edit meetings"
  on public.workspace_meetings for update to authenticated
  using (public.is_workspace_admin(workspace_id))
  with check (public.is_workspace_admin(workspace_id));
create policy "Workspace admins can remove meetings"
  on public.workspace_meetings for delete to authenticated
  using (public.is_workspace_admin(workspace_id));
