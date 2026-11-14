-- Qualify column names to avoid ambiguity with the RETURNS TABLE output columns.
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

  select workspace.* into found_workspace
  from public.workspaces as workspace
  where workspace.invite_code = upper(trim(code))
  for update;
  if found_workspace.id is null then raise exception 'El código no existe. Revísalo e intenta de nuevo.'; end if;

  select profile.role into joining_role
  from public.profiles as profile
  where profile.id = auth.uid();

  if joining_role = 'Líder' then
    select count(*) into admin_count from public.workspace_members
      where workspace_id = found_workspace.id and is_admin;
    if admin_count >= 5 and not exists (
      select 1 from public.workspace_members
      where workspace_id = found_workspace.id and user_id = auth.uid()
    ) then raise exception 'El equipo ya tiene sus 5 administradores. Pide al creador que revise los cargos Líder.'; end if;
  end if;

  insert into public.workspace_members(workspace_id, user_id, is_admin)
    values (found_workspace.id, auth.uid(), joining_role = 'Líder')
    on conflict do nothing;
  return query select found_workspace.id, found_workspace.name;
end;
$$;
