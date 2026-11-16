create or replace function public.save_workspace_meeting(
  target_workspace uuid,
  meeting_data jsonb,
  selected_assignments jsonb default null
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  target_meeting text;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión para guardar una reunión.';
  end if;

  if not public.is_workspace_editor_or_above(target_workspace) then
    raise exception 'No tienes permiso para crear o editar reuniones en este equipo.';
  end if;

  if meeting_data is null or jsonb_typeof(meeting_data) <> 'object' then
    raise exception 'La información de la reunión no es válida.';
  end if;

  target_meeting := nullif(btrim(meeting_data->>'id'), '');
  if target_meeting is null then
    raise exception 'La reunión necesita un identificador.';
  end if;

  if selected_assignments is not null then
    if jsonb_typeof(selected_assignments) <> 'array' then
      raise exception 'Las asignaciones de la reunión no son válidas.';
    end if;
    if not public.is_workspace_admin(target_workspace) then
      raise exception 'Solo un Propietario o Administrador puede asignar funciones para una reunión.';
    end if;
  end if;

  insert into public.workspace_meetings (workspace_id, id, data)
  values (target_workspace, target_meeting, meeting_data)
  on conflict (workspace_id, id) do update
    set data = excluded.data;

  -- A null argument means an Editor is saving the meeting without changing
  -- administrator-managed assignments. An empty array removes all assignments.
  if selected_assignments is null then
    return;
  end if;

  insert into public.workspace_meeting_assignments (workspace_id, meeting_id, user_id, function_name)
  select target_workspace, target_meeting, item.user_id, item.function_name
  from jsonb_to_recordset(selected_assignments) as item(user_id uuid, function_name text)
  on conflict (workspace_id, meeting_id, user_id, function_name) do nothing;

  delete from public.workspace_meeting_assignments as current_assignment
  where current_assignment.workspace_id = target_workspace
    and current_assignment.meeting_id = target_meeting
    and not exists (
      select 1
      from jsonb_to_recordset(selected_assignments) as item(user_id uuid, function_name text)
      where item.user_id = current_assignment.user_id
        and item.function_name = current_assignment.function_name
    );
end;
$$;

revoke all on function public.save_workspace_meeting(uuid, jsonb, jsonb) from public;
grant execute on function public.save_workspace_meeting(uuid, jsonb, jsonb) to authenticated;
