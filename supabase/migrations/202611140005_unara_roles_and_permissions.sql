begin;

-- Separate worship-team functions from UNARA workspace permissions.
alter table public.workspace_members
  add column if not exists workspace_role text not null default 'Integrante',
  add column if not exists team_category text not null default 'Músico',
  add column if not exists team_functions text[] not null default '{}',
  add column if not exists other_function text not null default '',
  add column if not exists membership_status text not null default 'active';

alter table public.workspace_members drop constraint if exists workspace_members_workspace_role_check;
alter table public.workspace_members add constraint workspace_members_workspace_role_check
  check (workspace_role in ('Propietario','Administrador','Editor','Integrante'));
alter table public.workspace_members drop constraint if exists workspace_members_team_category_check;
alter table public.workspace_members add constraint workspace_members_team_category_check
  check (team_category in ('Músico','Multimedia'));
alter table public.workspace_members drop constraint if exists workspace_members_membership_status_check;
alter table public.workspace_members add constraint workspace_members_membership_status_check
  check (membership_status in ('active','pending'));

-- Preserve existing member and role data while translating the old single role field.
update public.workspace_members m
set workspace_role = case
      when w.created_by = m.user_id then 'Propietario'
      when m.is_admin then 'Administrador'
      else 'Integrante'
    end,
    team_category = case p.role when 'Sonido' then 'Multimedia' when 'Multimedia' then 'Multimedia' else 'Músico' end,
    team_functions = case
      when p.role = 'Líder' then array['Líder']::text[]
      when p.role = 'Sonido' then array['Sonido']::text[]
      else '{}'::text[]
    end,
    other_function = case when p.role = 'Músico' then coalesce(p.instruments,'') else '' end
from public.workspaces w, public.profiles p
where m.workspace_id = w.id and m.user_id = p.id;

create or replace function public.has_workspace_role(target_workspace uuid, allowed_roles text[])
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.workspace_members m
    where m.workspace_id = target_workspace and m.user_id = auth.uid()
      and m.workspace_role = any(allowed_roles) and m.membership_status='active'
  );
$$;
revoke all on function public.has_workspace_role(uuid,text[]) from public;
grant execute on function public.has_workspace_role(uuid,text[]) to authenticated;

create or replace function public.is_workspace_member(target_workspace uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.workspace_members m where m.workspace_id=target_workspace and m.user_id=auth.uid() and m.membership_status='active'); $$;
revoke all on function public.is_workspace_member(uuid) from public;
grant execute on function public.is_workspace_member(uuid) to authenticated;

create or replace function public.is_workspace_admin(target_workspace uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select public.has_workspace_role(target_workspace, array['Propietario','Administrador']); $$;
revoke all on function public.is_workspace_admin(uuid) from public;
grant execute on function public.is_workspace_admin(uuid) to authenticated;

create or replace function public.is_workspace_editor_or_above(target_workspace uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select public.has_workspace_role(target_workspace, array['Propietario','Administrador','Editor']); $$;
revoke all on function public.is_workspace_editor_or_above(uuid) from public;
grant execute on function public.is_workspace_editor_or_above(uuid) to authenticated;

-- No client may directly edit membership or privilege columns.
drop policy if exists "Workspace members are visible to the team" on public.workspace_members;
create policy "Workspace members are visible to the team" on public.workspace_members
  for select to authenticated using (user_id=auth.uid() or public.is_workspace_member(workspace_id) or public.is_workspace_admin(workspace_id));

drop policy if exists "Team members can view profile photos" on storage.objects;
create policy "Team members can view profile photos" on storage.objects for select to authenticated
  using (bucket_id='profile-photos' and (
    (storage.foldername(name))[1]=auth.uid()::text or exists(
      select 1 from public.workspace_members own_member
      join public.workspace_members photo_owner on photo_owner.workspace_id=own_member.workspace_id
      where own_member.user_id=auth.uid() and photo_owner.user_id::text=(storage.foldername(name))[1]
        and public.is_workspace_member(own_member.workspace_id)
    )
  ));
drop policy if exists "Workspace owners can update workspace" on public.workspaces;
create policy "Workspace owners can update workspace" on public.workspaces
  for update to authenticated using (public.has_workspace_role(id,array['Propietario']))
  with check (public.has_workspace_role(id,array['Propietario']));
drop policy if exists "Workspace creator can delete workspace" on public.workspaces;
create policy "Workspace creator can delete workspace" on public.workspaces
  for delete to authenticated using (created_by=auth.uid());
revoke select on public.workspaces from authenticated;
grant select(id,name,created_by,created_at) on public.workspaces to authenticated;
grant update(name), delete on public.workspaces to authenticated;

drop policy if exists "Team members can add songs" on public.workspace_songs;
drop policy if exists "Team members can edit songs" on public.workspace_songs;
drop policy if exists "Team members can remove songs" on public.workspace_songs;
drop policy if exists "Editors can add songs" on public.workspace_songs;
drop policy if exists "Editors can edit songs" on public.workspace_songs;
drop policy if exists "Editors can remove songs" on public.workspace_songs;
create policy "Editors can add songs" on public.workspace_songs for insert to authenticated
  with check (public.is_workspace_editor_or_above(workspace_id));
create policy "Editors can edit songs" on public.workspace_songs for update to authenticated
  using (public.is_workspace_editor_or_above(workspace_id)) with check (public.is_workspace_editor_or_above(workspace_id));
create policy "Editors can remove songs" on public.workspace_songs for delete to authenticated
  using (public.is_workspace_editor_or_above(workspace_id));

drop policy if exists "Team members can add meetings" on public.workspace_meetings;
drop policy if exists "Workspace admins can add meetings" on public.workspace_meetings;
drop policy if exists "Workspace admins can edit meetings" on public.workspace_meetings;
drop policy if exists "Workspace admins can remove meetings" on public.workspace_meetings;
drop policy if exists "Editors can add meetings" on public.workspace_meetings;
drop policy if exists "Editors can edit meetings" on public.workspace_meetings;
drop policy if exists "Admins can remove meetings" on public.workspace_meetings;
create policy "Editors can add meetings" on public.workspace_meetings for insert to authenticated
  with check (public.is_workspace_editor_or_above(workspace_id));
create policy "Editors can edit meetings" on public.workspace_meetings for update to authenticated
  using (public.is_workspace_editor_or_above(workspace_id)) with check (public.is_workspace_editor_or_above(workspace_id));
create policy "Admins can remove meetings" on public.workspace_meetings for delete to authenticated
  using (public.is_workspace_admin(workspace_id));

-- Keep meeting control (start/finish and member assignments) administrator-only,
-- even if a client calls Supabase directly.
create or replace function public.protect_meeting_control_fields()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if coalesce(new.data->>'status','Preparación') <> 'Preparación'
      and not public.is_workspace_admin(new.workspace_id) then
      raise exception 'Solo un administrador puede iniciar o finalizar reuniones.';
    end if;
    if new.data ? 'assignments' and not public.is_workspace_admin(new.workspace_id) then
      raise exception 'Solo un administrador puede asignar funciones para una reunión.';
    end if;
    return new;
  end if;
  if new.data->>'status' is distinct from old.data->>'status'
     and not public.is_workspace_admin(new.workspace_id) then
    raise exception 'Solo un administrador puede iniciar o finalizar reuniones.';
  end if;
  if new.data->'assignments' is distinct from old.data->'assignments'
     and not public.is_workspace_admin(new.workspace_id) then
    raise exception 'Solo un administrador puede asignar funciones para una reunión.';
  end if;
  return new;
end;
$$;
drop trigger if exists protect_meeting_control_fields on public.workspace_meetings;
create trigger protect_meeting_control_fields before insert or update on public.workspace_meetings
for each row execute function public.protect_meeting_control_fields();

-- Per-meeting assignment records have their own administrator-only write rules.
create table if not exists public.workspace_meeting_assignments (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  meeting_id text not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  function_name text not null,
  instrument text not null default '',
  primary key (workspace_id, meeting_id, user_id, function_name),
  foreign key (workspace_id,meeting_id) references public.workspace_meetings(workspace_id,id) on delete cascade,
  foreign key (workspace_id,user_id) references public.workspace_members(workspace_id,user_id) on delete cascade
);
alter table public.workspace_meeting_assignments enable row level security;
drop policy if exists "Members can read meeting assignments" on public.workspace_meeting_assignments;
create policy "Members can read meeting assignments" on public.workspace_meeting_assignments
  for select to authenticated using (public.is_workspace_member(workspace_id));
drop policy if exists "Admins can add meeting assignments" on public.workspace_meeting_assignments;
create policy "Admins can add meeting assignments" on public.workspace_meeting_assignments
  for insert to authenticated with check (public.is_workspace_admin(workspace_id) and exists(select 1 from public.workspace_members m where m.workspace_id=workspace_meeting_assignments.workspace_id and m.user_id=workspace_meeting_assignments.user_id and m.membership_status='active'));
drop policy if exists "Admins can edit meeting assignments" on public.workspace_meeting_assignments;
create policy "Admins can edit meeting assignments" on public.workspace_meeting_assignments
  for update to authenticated using (public.is_workspace_admin(workspace_id)) with check (public.is_workspace_admin(workspace_id) and exists(select 1 from public.workspace_members m where m.workspace_id=workspace_meeting_assignments.workspace_id and m.user_id=workspace_meeting_assignments.user_id and m.membership_status='active'));
drop policy if exists "Admins can remove meeting assignments" on public.workspace_meeting_assignments;
create policy "Admins can remove meeting assignments" on public.workspace_meeting_assignments
  for delete to authenticated using (public.is_workspace_admin(workspace_id));
grant select, insert, update, delete on public.workspace_meeting_assignments to authenticated;

create or replace function public.validate_meeting_assignment()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if not exists(select 1 from public.workspace_members m where m.workspace_id=new.workspace_id and m.user_id=new.user_id
    and m.membership_status='active' and new.function_name=any(m.team_functions)) then
    raise exception 'La función debe estar asignada a esa persona dentro del equipo.';
  end if;
  return new;
end;
$$;
drop trigger if exists validate_meeting_assignment on public.workspace_meeting_assignments;
create trigger validate_meeting_assignment before insert or update on public.workspace_meeting_assignments
for each row execute function public.validate_meeting_assignment();

create or replace function public.get_workspace_invite_code(target_workspace uuid)
returns text language plpgsql stable security definer set search_path = public
as $$
declare result text;
begin
  if not public.is_workspace_admin(target_workspace) then raise exception 'Solo un administrador puede compartir el código de invitación.'; end if;
  select invite_code into result from public.workspaces where id=target_workspace;
  if result is null then raise exception 'No se encontró el espacio de trabajo.'; end if;
  return result;
end;
$$;
revoke all on function public.get_workspace_invite_code(uuid) from public;
grant execute on function public.get_workspace_invite_code(uuid) to authenticated;

create or replace function public.manage_workspace_member(
  target_workspace uuid, target_user uuid, new_team_category text,
  new_team_functions text[], new_other_function text, new_workspace_role text
)
returns void language plpgsql security definer set search_path = public
as $$
declare
  caller_role text;
  creator_id uuid;
  current_role text;
  role_count integer;
  music_options text[] := array['Líder','Director','Voz','Guitarra Eléctrica','Guitarra Acústica','Piano','Bajo','Batería','Violín','Viola','Saxofón','Otro'];
  media_options text[] := array['Líder','Sonido','Proyección'];
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  select m.workspace_role into caller_role from public.workspace_members m where m.workspace_id=target_workspace and m.user_id=auth.uid();
  if caller_role is null or caller_role not in ('Propietario','Administrador') then raise exception 'No tienes permiso para editar integrantes.'; end if;
  select w.created_by into creator_id from public.workspaces w where w.id=target_workspace for update;
  select m.workspace_role into current_role from public.workspace_members m where m.workspace_id=target_workspace and m.user_id=target_user and m.membership_status='active';
  if not found then raise exception 'Esa persona ya no pertenece al equipo.'; end if;
  if new_team_category not in ('Músico','Multimedia') then raise exception 'Selecciona Músico o Multimedia.'; end if;
  if new_workspace_role not in ('Propietario','Administrador','Editor','Integrante') then raise exception 'Selecciona un rol válido de UNARA.'; end if;
  if exists (select 1 from unnest(coalesce(new_team_functions,'{}')) as selected(function_name) where not (function_name=any(case when new_team_category='Músico' then music_options else media_options end))) then
    raise exception 'Una de las funciones no corresponde al cargo elegido.';
  end if;
  if 'Otro'=any(coalesce(new_team_functions,'{}')) and nullif(trim(new_other_function),'') is null then raise exception 'Especifica la función marcada como Otro.'; end if;
  if caller_role='Administrador' then
    if current_role='Propietario' and new_workspace_role is distinct from current_role then raise exception 'Un administrador no puede cambiar el rol de un propietario.'; end if;
    if new_workspace_role is distinct from current_role and new_workspace_role not in ('Editor','Integrante') then raise exception 'Un administrador solo puede asignar Editor o Integrante.'; end if;
  elsif target_user=creator_id and new_workspace_role<>'Propietario' then
    raise exception 'No se puede cambiar el rol del creador original.';
  elsif caller_role='Propietario' and auth.uid()<>creator_id and target_user<>creator_id and new_workspace_role='Propietario' and current_role<>'Propietario' then
    raise exception 'Solo el creador original puede designar a otro propietario.';
  end if;
  if new_workspace_role='Propietario' then
    if current_role is distinct from 'Propietario' then
      if caller_role<>'Propietario' or (target_user<>creator_id and auth.uid()<>creator_id) then raise exception 'Solo el creador puede nombrar otro propietario.'; end if;
      select count(*) into role_count from public.workspace_members m where m.workspace_id=target_workspace and m.workspace_role='Propietario' and m.user_id<>target_user;
      if role_count>=2 then raise exception 'El espacio ya tiene el máximo de 2 propietarios.'; end if;
    end if;
  elsif new_workspace_role='Administrador' then
    if current_role is distinct from 'Administrador' then
      if caller_role<>'Propietario' then raise exception 'Solo un propietario puede nombrar administradores.'; end if;
      select count(*) into role_count from public.workspace_members m where m.workspace_id=target_workspace and m.workspace_role='Administrador' and m.user_id<>target_user;
      if role_count>=4 then raise exception 'El espacio ya tiene el máximo de 4 administradores.'; end if;
    end if;
  end if;
  update public.workspace_members set team_category=new_team_category, team_functions=coalesce(new_team_functions,'{}'),
    other_function=coalesce(trim(new_other_function),''), workspace_role=new_workspace_role,
    is_admin=(new_workspace_role in ('Propietario','Administrador'))
  where workspace_id=target_workspace and user_id=target_user;
end;
$$;
revoke all on function public.manage_workspace_member(uuid,uuid,text,text[],text,text) from public;
grant execute on function public.manage_workspace_member(uuid,uuid,text,text[],text,text) to authenticated;

create or replace function public.remove_workspace_member(target_workspace uuid, target_user uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare caller_role text; creator_id uuid; target_role text; remaining_owners integer;
begin
  select m.workspace_role into caller_role from public.workspace_members m where m.workspace_id=target_workspace and m.user_id=auth.uid();
  if caller_role is null or caller_role not in ('Propietario','Administrador') then raise exception 'No tienes permiso para quitar integrantes.'; end if;
  select w.created_by into creator_id from public.workspaces w where w.id=target_workspace for update;
  select m.workspace_role into target_role from public.workspace_members m where m.workspace_id=target_workspace and m.user_id=target_user;
  if not found then return; end if;
  if target_user=creator_id then raise exception 'No se puede quitar al creador del espacio.'; end if;
  if caller_role='Administrador' and target_role in ('Propietario','Administrador') then raise exception 'Un administrador solo puede quitar integrantes y editores.'; end if;
  if caller_role='Propietario' and target_role='Propietario' and auth.uid()<>creator_id then raise exception 'Solo el creador original puede quitar a otro propietario.'; end if;
  if target_role='Propietario' then
    select count(*) into remaining_owners from public.workspace_members m where m.workspace_id=target_workspace and m.workspace_role='Propietario' and m.user_id<>target_user;
    if remaining_owners<1 then raise exception 'El espacio debe conservar al menos un propietario.'; end if;
  end if;
  delete from public.workspace_members where workspace_id=target_workspace and user_id=target_user;
end;
$$;
revoke all on function public.remove_workspace_member(uuid,uuid) from public;
grant execute on function public.remove_workspace_member(uuid,uuid) to authenticated;

create or replace function public.transfer_workspace_ownership(target_workspace uuid, new_owner uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare creator_id uuid;
begin
  select w.created_by into creator_id from public.workspaces w where w.id=target_workspace for update;
  if auth.uid() is null or auth.uid()<>creator_id then raise exception 'Solo el creador original puede transferir la propiedad.'; end if;
  if not exists(select 1 from public.workspace_members m where m.workspace_id=target_workspace and m.user_id=new_owner and m.membership_status='active') then raise exception 'La persona elegida debe pertenecer al equipo.'; end if;
  if new_owner=auth.uid() then raise exception 'Elige a otra persona para transferir la propiedad.'; end if;
  update public.workspace_members set workspace_role='Editor',is_admin=false
    where workspace_id=target_workspace and workspace_role='Propietario' and user_id not in (auth.uid(),new_owner);
  update public.workspace_members set workspace_role='Propietario',is_admin=true where workspace_id=target_workspace and user_id in (auth.uid(),new_owner);
  update public.workspaces set created_by=new_owner where id=target_workspace;
end;
$$;
revoke all on function public.transfer_workspace_ownership(uuid,uuid) from public;
grant execute on function public.transfer_workspace_ownership(uuid,uuid) to authenticated;

create or replace function public.create_workspace(workspace_name text)
returns table(id uuid, name text, invite_code text)
language plpgsql security definer set search_path = public
as $$
declare new_workspace public.workspaces;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  if length(trim(workspace_name)) < 2 then raise exception 'Escribe un nombre para el equipo.'; end if;
  insert into public.workspaces(name,created_by) values(trim(workspace_name),auth.uid()) returning * into new_workspace;
  insert into public.workspace_members(workspace_id,user_id,workspace_role,team_category,is_admin)
    values(new_workspace.id,auth.uid(),'Propietario','Músico',true);
  return query select new_workspace.id,new_workspace.name,new_workspace.invite_code;
end;
$$;

create or replace function public.join_workspace(code text)
returns table(id uuid,name text)
language plpgsql security definer set search_path = public
as $$
declare found_workspace public.workspaces;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  select workspace.* into found_workspace from public.workspaces workspace where workspace.invite_code=upper(trim(code)) for update;
  if found_workspace.id is null then raise exception 'El código no existe. Revísalo e intenta de nuevo.'; end if;
  insert into public.workspace_members(workspace_id,user_id,workspace_role,team_category,is_admin,membership_status)
    values(found_workspace.id,auth.uid(),'Integrante','Músico',false,'pending') on conflict do nothing;
  return query select found_workspace.id,found_workspace.name;
end;
$$;

revoke all on function public.create_workspace(text) from public;
revoke all on function public.join_workspace(text) from public;
grant execute on function public.create_workspace(text) to authenticated;
grant execute on function public.join_workspace(text) to authenticated;

create or replace function public.review_workspace_member(target_workspace uuid,target_user uuid,approve boolean)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_workspace_admin(target_workspace) then raise exception 'Solo un administrador puede aceptar integrantes.'; end if;
  if not exists(select 1 from public.workspace_members m where m.workspace_id=target_workspace and m.user_id=target_user and m.membership_status='pending') then
    raise exception 'La solicitud ya no está pendiente.';
  end if;
  if approve then
    update public.workspace_members set membership_status='active' where workspace_id=target_workspace and user_id=target_user;
  else
    delete from public.workspace_members where workspace_id=target_workspace and user_id=target_user;
  end if;
end;
$$;
revoke all on function public.review_workspace_member(uuid,uuid,boolean) from public;
grant execute on function public.review_workspace_member(uuid,uuid,boolean) to authenticated;

drop trigger if exists protect_workspace_leader_role on public.profiles;
drop function if exists public.protect_workspace_leader_role();
drop function if exists public.set_workspace_admin(uuid,uuid,boolean);

notify pgrst, 'reload schema';
commit;

