begin;

-- Published meetings keep the same stable IDs used by live timers and songs.
-- Existing rows are already published, so the default version is 1.
alter table public.workspace_meetings
  add column if not exists published_version bigint not null default 1,
  add column if not exists published_at timestamptz not null default now();

create table if not exists public.workspace_meeting_drafts (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  meeting_id text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null check (jsonb_typeof(data) = 'object'),
  selected_assignments jsonb check (selected_assignments is null or jsonb_typeof(selected_assignments) = 'array'),
  revision bigint not null default 1 check (revision > 0),
  base_published_version bigint not null default 0 check (base_published_version >= 0),
  updated_at timestamptz not null default now(),
  primary key (workspace_id, meeting_id, user_id)
);

alter table public.workspace_meeting_drafts enable row level security;
drop policy if exists "Editors can read their own meeting drafts" on public.workspace_meeting_drafts;
create policy "Editors can read their own meeting drafts"
  on public.workspace_meeting_drafts for select to authenticated
  using (user_id = auth.uid() and public.is_workspace_editor_or_above(workspace_id));
revoke all on public.workspace_meeting_drafts from public, anon, authenticated;
grant select on public.workspace_meeting_drafts to authenticated;

-- Planning can only become visible through the version-checked publish RPC.
-- Preserve admin deletion, but do not allow direct client writes that bypass drafts.
drop policy if exists "Editors can add meetings" on public.workspace_meetings;
drop policy if exists "Editors can edit meetings" on public.workspace_meetings;
revoke insert, update on public.workspace_meetings from public, anon, authenticated;
grant select, delete on public.workspace_meetings to authenticated;
revoke all on function public.save_workspace_meeting(uuid, jsonb, jsonb) from public, anon, authenticated;

-- The onboarding flow may import this owner's pre-existing local meetings once
-- when a new workspace is created. It cannot be used for later edits.
create or replace function public.seed_workspace_meetings(target_workspace uuid, meeting_rows jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not exists (
    select 1 from public.workspaces w
    join public.workspace_members m on m.workspace_id=w.id and m.user_id=auth.uid()
    where w.id=target_workspace and w.created_by=auth.uid()
      and m.workspace_role='Propietario' and m.membership_status='active'
  ) then
    raise exception 'Solo quien crea el espacio puede importar reuniones iniciales.';
  end if;
  if meeting_rows is null or jsonb_typeof(meeting_rows) <> 'array' then
    raise exception 'La lista inicial de reuniones no es válida.';
  end if;
  insert into public.workspace_meetings(workspace_id,id,data)
  select target_workspace, nullif(btrim(item->>'id'), ''), item
  from jsonb_array_elements(meeting_rows) as rows(item)
  where nullif(btrim(item->>'id'), '') is not null
  on conflict (workspace_id,id) do nothing;
end;
$$;
revoke all on function public.seed_workspace_meetings(uuid,jsonb) from public, anon, authenticated;
grant execute on function public.seed_workspace_meetings(uuid,jsonb) to authenticated;

create table if not exists public.workspace_meeting_notifications (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  meeting_id text not null,
  recipient_id uuid not null,
  published_version bigint not null,
  meeting_title text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  unique (workspace_id, meeting_id, published_version, recipient_id),
  foreign key (workspace_id, meeting_id)
    references public.workspace_meetings(workspace_id, id) on delete cascade,
  foreign key (workspace_id, recipient_id)
    references public.workspace_members(workspace_id, user_id) on delete cascade
);

create index if not exists workspace_meeting_notifications_recipient_idx
  on public.workspace_meeting_notifications(recipient_id, created_at desc);
alter table public.workspace_meeting_notifications enable row level security;
drop policy if exists "Members can read their meeting notifications" on public.workspace_meeting_notifications;
create policy "Members can read their meeting notifications"
  on public.workspace_meeting_notifications for select to authenticated
  using (recipient_id = auth.uid() and public.is_workspace_member(workspace_id));
revoke all on public.workspace_meeting_notifications from public, anon, authenticated;
grant select on public.workspace_meeting_notifications to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'workspace_meeting_notifications') then
    execute 'alter publication supabase_realtime add table public.workspace_meeting_notifications';
  end if;
end;
$$;

create or replace function public.save_workspace_meeting_draft(
  target_workspace uuid,
  target_meeting text,
  meeting_data jsonb,
  selected_assignments jsonb,
  expected_revision bigint,
  expected_published_version bigint
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_version bigint;
  current_revision bigint;
  current_assignments jsonb;
  next_revision bigint;
begin
  if auth.uid() is null or not public.is_workspace_editor_or_above(target_workspace) then
    raise exception 'No tienes permiso para guardar borradores de reuniones.';
  end if;
  if meeting_data is null or jsonb_typeof(meeting_data) <> 'object'
     or nullif(btrim(meeting_data->>'id'), '') is distinct from target_meeting then
    raise exception 'La información del borrador no es válida.';
  end if;
  if selected_assignments is not null then
    if jsonb_typeof(selected_assignments) <> 'array' then
      raise exception 'Las asignaciones del borrador no son válidas.';
    end if;
    if not public.is_workspace_admin(target_workspace) then
      raise exception 'Solo Propietarios y Administradores pueden asignar funciones para una reunión.';
    end if;
    if exists (
      select 1
      from jsonb_to_recordset(selected_assignments) as item(user_id uuid, function_name text)
      where not exists (
        select 1 from public.workspace_members m
        where m.workspace_id = target_workspace and m.user_id = item.user_id
          and m.membership_status = 'active' and item.function_name = any(m.team_functions)
      )
    ) then
      raise exception 'Cada función debe estar registrada en el perfil activo de la persona.';
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(target_workspace::text || ':' || target_meeting || ':' || auth.uid()::text, 0));

  select coalesce(published_version, 0) into current_version
  from public.workspace_meetings
  where workspace_id = target_workspace and id = target_meeting;
  current_version := coalesce(current_version, 0);
  if current_version <> expected_published_version then
    raise exception 'La reunión publicada cambió mientras editabas. Conservamos tu copia; vuelve a cargar la versión más reciente antes de continuar.';
  end if;

  select d.revision, d.selected_assignments into current_revision, current_assignments
  from public.workspace_meeting_drafts as d
  where d.workspace_id = target_workspace and d.meeting_id = target_meeting and d.user_id = auth.uid()
  for update;

  if current_revision is null then
    if coalesce(expected_revision, 0) <> 0 then
      raise exception 'El borrador cambió en otro dispositivo. Conservamos tu copia local para que no pierdas tus cambios.';
    end if;
    next_revision := 1;
    current_assignments := selected_assignments;
    insert into public.workspace_meeting_drafts
      (workspace_id, meeting_id, user_id, data, selected_assignments, revision, base_published_version, updated_at)
    values
      (target_workspace, target_meeting, auth.uid(), meeting_data - 'status', current_assignments, next_revision, current_version, now());
  else
    if current_revision <> expected_revision then
      raise exception 'El borrador cambió en otro dispositivo. Conservamos tu copia local para que no pierdas tus cambios.';
    end if;
    next_revision := current_revision + 1;
    if selected_assignments is not null then current_assignments := selected_assignments; end if;
    update public.workspace_meeting_drafts
    set data = meeting_data - 'status', selected_assignments = current_assignments,
        revision = next_revision, updated_at = now()
    where workspace_id = target_workspace and meeting_id = target_meeting and user_id = auth.uid();
  end if;
  return next_revision;
end;
$$;

create or replace function public.publish_workspace_meeting_draft(
  target_workspace uuid,
  target_meeting text,
  expected_revision bigint,
  expected_published_version bigint
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  draft_row public.workspace_meeting_drafts%rowtype;
  published_row public.workspace_meetings%rowtype;
  current_version bigint;
  next_version bigint;
  next_data jsonb;
  assignment_data jsonb;
  current_assignment_data jsonb;
  changed boolean;
begin
  if auth.uid() is null or not public.is_workspace_editor_or_above(target_workspace) then
    raise exception 'No tienes permiso para publicar reuniones.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(target_workspace::text || ':' || target_meeting || ':' || auth.uid()::text, 0));
  select * into draft_row from public.workspace_meeting_drafts
  where workspace_id = target_workspace and meeting_id = target_meeting and user_id = auth.uid()
  for update;
  if not found then raise exception 'No encontramos un borrador guardado para publicar.'; end if;
  if draft_row.revision <> expected_revision then
    raise exception 'El borrador cambió en otro dispositivo. Vuelve a cargarlo antes de publicar.';
  end if;

  select * into published_row from public.workspace_meetings
  where workspace_id = target_workspace and id = target_meeting
  for update;
  current_version := coalesce(published_row.published_version, 0);
  if current_version <> expected_published_version or draft_row.base_published_version <> current_version then
    raise exception 'La reunión fue publicada por otra persona mientras editabas. Tu borrador se conservó; carga la versión publicada para continuar.';
  end if;
  if draft_row.selected_assignments is not null and not public.is_workspace_admin(target_workspace) then
    raise exception 'Solo Propietarios y Administradores pueden publicar asignaciones de funciones.';
  end if;
  if draft_row.selected_assignments is not null and exists (
    select 1
    from jsonb_to_recordset(draft_row.selected_assignments) as item(user_id uuid, function_name text)
    where not exists (
      select 1 from public.workspace_members m
      where m.workspace_id=target_workspace and m.user_id=item.user_id
        and m.membership_status='active' and item.function_name = any(m.team_functions)
    )
  ) then
    raise exception 'Una función asignada ya no está registrada para una persona activa.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('user_id', a.user_id, 'function_name', a.function_name) order by a.user_id, a.function_name), '[]'::jsonb)
  into current_assignment_data
  from public.workspace_meeting_assignments a
  where a.workspace_id = target_workspace and a.meeting_id = target_meeting;
  assignment_data := coalesce(draft_row.selected_assignments, current_assignment_data);

  next_data := draft_row.data || jsonb_build_object('status', coalesce(published_row.data->>'status', 'Preparación'));
  changed := published_row.id is null
    or (published_row.data - 'status') is distinct from (next_data - 'status')
    or (draft_row.selected_assignments is not null and current_assignment_data is distinct from assignment_data);
  next_version := current_version + 1;

  insert into public.workspace_meetings (workspace_id, id, data, published_version, published_at)
  values (target_workspace, target_meeting, next_data, next_version, now())
  on conflict (workspace_id, id) do update
    set data = excluded.data, published_version = excluded.published_version, published_at = excluded.published_at;

  if draft_row.selected_assignments is not null then
    if not public.is_workspace_admin(target_workspace) then
      raise exception 'Solo Propietarios y Administradores pueden publicar asignaciones de funciones.';
    end if;
    insert into public.workspace_meeting_assignments (workspace_id, meeting_id, user_id, function_name)
    select target_workspace, target_meeting, item.user_id, item.function_name
    from jsonb_to_recordset(draft_row.selected_assignments) as item(user_id uuid, function_name text)
    on conflict (workspace_id, meeting_id, user_id, function_name) do nothing;
    delete from public.workspace_meeting_assignments a
    where a.workspace_id = target_workspace and a.meeting_id = target_meeting
      and not exists (
        select 1 from jsonb_to_recordset(draft_row.selected_assignments) as item(user_id uuid, function_name text)
        where item.user_id = a.user_id and item.function_name = a.function_name
      );
  end if;

  if changed then
    insert into public.workspace_meeting_notifications
      (workspace_id, meeting_id, recipient_id, published_version, meeting_title)
    select target_workspace, target_meeting, m.user_id, next_version, coalesce(next_data->>'title', 'Reunión')
    from public.workspace_members m
    where m.workspace_id = target_workspace and m.membership_status = 'active' and m.user_id <> auth.uid()
    on conflict (workspace_id, meeting_id, published_version, recipient_id) do nothing;
  end if;

  delete from public.workspace_meeting_drafts
  where workspace_id = target_workspace and meeting_id = target_meeting and user_id = auth.uid();
  return next_version;
end;
$$;

create or replace function public.discard_workspace_meeting_draft(target_workspace uuid, target_meeting text)
returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.is_workspace_editor_or_above(target_workspace) then
    raise exception 'No tienes permiso para descartar este borrador.';
  end if;
  delete from public.workspace_meeting_drafts
  where workspace_id = target_workspace and meeting_id = target_meeting and user_id = auth.uid();
end;
$$;

create or replace function public.set_workspace_meeting_status(target_workspace uuid, target_meeting text, new_status text)
returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.is_workspace_admin(target_workspace) then
    raise exception 'Solo Propietarios y Administradores pueden cambiar el estado de una reunión.';
  end if;
  if new_status not in ('Preparación', 'En curso', 'Finalizada') then
    raise exception 'El estado de la reunión no es válido.';
  end if;
  update public.workspace_meetings
  set data = jsonb_set(data, '{status}', to_jsonb(new_status), true)
  where workspace_id = target_workspace and id = target_meeting;
  if not found then raise exception 'No encontramos la reunión publicada.'; end if;
end;
$$;

create or replace function public.mark_workspace_meeting_notification_read(target_notification uuid)
returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión.'; end if;
  update public.workspace_meeting_notifications
  set read_at = coalesce(read_at, now())
  where id = target_notification and recipient_id = auth.uid()
    and public.is_workspace_member(workspace_id);
end;
$$;

revoke all on function public.save_workspace_meeting_draft(uuid, text, jsonb, jsonb, bigint, bigint) from public, anon, authenticated;
revoke all on function public.publish_workspace_meeting_draft(uuid, text, bigint, bigint) from public, anon, authenticated;
revoke all on function public.discard_workspace_meeting_draft(uuid, text) from public, anon, authenticated;
revoke all on function public.set_workspace_meeting_status(uuid, text, text) from public, anon, authenticated;
revoke all on function public.mark_workspace_meeting_notification_read(uuid) from public, anon, authenticated;
grant execute on function public.save_workspace_meeting_draft(uuid, text, jsonb, jsonb, bigint, bigint) to authenticated;
grant execute on function public.publish_workspace_meeting_draft(uuid, text, bigint, bigint) to authenticated;
grant execute on function public.discard_workspace_meeting_draft(uuid, text) to authenticated;
grant execute on function public.set_workspace_meeting_status(uuid, text, text) to authenticated;
grant execute on function public.mark_workspace_meeting_notification_read(uuid) to authenticated;

commit;
