alter table public.workspace_meeting_live_state
  add column if not exists initial_clocks_started boolean not null default false;

-- Existing meetings keep their current timer behavior after this migration.
update public.workspace_meeting_live_state
set initial_clocks_started = true
where initial_clocks_started = false;

create or replace function public.manage_workspace_meeting_live_action(
  target_workspace uuid,
  target_meeting text,
  live_action text,
  target_section text default null,
  source_song text default null,
  after_item text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  meeting_data jsonb;
  session_row public.workspace_meeting_live_state%rowtype;
  first_section_id text;
  valid_section boolean;
  valid_anchor boolean;
begin
  if auth.uid() is null then
    raise exception 'Debes iniciar sesión para usar los controles de la reunión.';
  end if;

  select data into meeting_data from public.workspace_meetings
  where workspace_id = target_workspace and id = target_meeting;
  if meeting_data is null then
    raise exception 'No encontramos esta reunión.';
  end if;

  if live_action in ('general_start', 'general_pause', 'general_reset') then
    if not public.is_workspace_admin(target_workspace) then
      raise exception 'Solo Propietarios y Administradores pueden controlar el cronómetro general.';
    end if;
  elsif live_action in ('section_start', 'section_pause', 'section_reset', 'add_song') then
    if not public.is_workspace_editor_or_above(target_workspace) then
      raise exception 'Tu rol no puede modificar los controles en vivo de esta reunión.';
    end if;
  else
    raise exception 'La acción en vivo no es válida.';
  end if;

  if live_action = 'add_song' then
    if target_section is null or source_song is null then
      raise exception 'Selecciona una sección y una canción.';
    end if;

    select exists (
      select 1 from jsonb_array_elements(coalesce(meeting_data->'agenda'->'sections', '[]'::jsonb)) as section(section_data)
      where section_data->>'id' = target_section
    ) or (meeting_data->'agenda' is null and target_section = 'legacy-repertoire')
    into valid_section;
    if not coalesce(valid_section, false) then
      raise exception 'La sección seleccionada ya no existe en esta reunión.';
    end if;

    if not exists (select 1 from public.workspace_songs where workspace_id = target_workspace and id = source_song) then
      raise exception 'La canción seleccionada ya no está en el repertorio.';
    end if;

    if after_item is not null then
      select exists (
        select 1
        from jsonb_array_elements(coalesce(meeting_data->'agenda'->'sections', '[]'::jsonb)) as section(section_data)
        cross join lateral jsonb_array_elements(coalesce(section_data->'items', '[]'::jsonb)) as item(item_data)
        where section_data->>'id' = target_section and item_data->>'id' = after_item
      ) or exists (
        select 1 from public.workspace_meeting_live_songs
        where workspace_id = target_workspace and meeting_id = target_meeting
          and section_id = target_section and id::text = after_item
      ) into valid_anchor;
      if not coalesce(valid_anchor, false) then
        raise exception 'La posición seleccionada ya no está disponible.';
      end if;
    end if;

    insert into public.workspace_meeting_live_songs
      (workspace_id, meeting_id, section_id, song_id, after_item_id, created_by)
    values (target_workspace, target_meeting, target_section, source_song, after_item, auth.uid());
    return;
  end if;

  if target_section is not null then
    select exists (
      select 1 from jsonb_array_elements(coalesce(meeting_data->'agenda'->'sections', '[]'::jsonb)) as section(section_data)
      where section_data->>'id' = target_section
    ) or (meeting_data->'agenda' is null and target_section = 'legacy-repertoire')
    into valid_section;
    if not coalesce(valid_section, false) then
      raise exception 'La sección seleccionada ya no existe en esta reunión.';
    end if;
  end if;

  select section_data->>'id' into first_section_id
  from jsonb_array_elements(coalesce(meeting_data->'agenda'->'sections', '[]'::jsonb))
    with ordinality as sections(section_data, section_order)
  order by section_order limit 1;
  if first_section_id is null and meeting_data->'agenda' is null
     and jsonb_array_length(coalesce(meeting_data->'songs', '[]'::jsonb)) > 0 then
    first_section_id := 'legacy-repertoire';
  end if;

  insert into public.workspace_meeting_live_state (workspace_id, meeting_id)
  values (target_workspace, target_meeting) on conflict do nothing;
  select * into session_row from public.workspace_meeting_live_state
  where workspace_id = target_workspace and meeting_id = target_meeting for update;

  if live_action = 'general_start' then
    if not session_row.initial_clocks_started and first_section_id is not null then
      insert into public.workspace_meeting_section_timers
        (workspace_id, meeting_id, section_id, elapsed_seconds, started_at, is_running, updated_at, updated_by)
      values (target_workspace, target_meeting, first_section_id, 0, now(), true, now(), auth.uid())
      on conflict (workspace_id, meeting_id, section_id) do update set
        started_at = case when public.workspace_meeting_section_timers.is_running then public.workspace_meeting_section_timers.started_at else now() end,
        is_running = true, updated_at = now(), updated_by = auth.uid();
    end if;

    update public.workspace_meeting_live_state set
      general_started_at = case when general_is_running then general_started_at else now() end,
      general_is_running = true,
      current_section_id = case when not session_row.initial_clocks_started and first_section_id is not null then first_section_id else current_section_id end,
      initial_clocks_started = true, updated_at = now(), updated_by = auth.uid()
    where workspace_id = target_workspace and meeting_id = target_meeting;
    return;
  elsif live_action = 'general_pause' then
    update public.workspace_meeting_live_state set
      general_elapsed_seconds = general_elapsed_seconds + case when general_is_running and general_started_at is not null then greatest(0, floor(extract(epoch from (now() - general_started_at)))::integer) else 0 end,
      general_started_at = null, general_is_running = false, updated_at = now(), updated_by = auth.uid()
    where workspace_id = target_workspace and meeting_id = target_meeting;
    return;
  elsif live_action = 'general_reset' then
    update public.workspace_meeting_live_state set
      general_elapsed_seconds = 0, general_started_at = null, general_is_running = false,
      updated_at = now(), updated_by = auth.uid()
    where workspace_id = target_workspace and meeting_id = target_meeting;
    return;
  end if;

  if live_action = 'section_start' and not session_row.initial_clocks_started
     and target_section = first_section_id then
    update public.workspace_meeting_live_state set
      general_started_at = case when general_is_running then general_started_at else now() end,
      general_is_running = true, initial_clocks_started = true,
      updated_at = now(), updated_by = auth.uid()
    where workspace_id = target_workspace and meeting_id = target_meeting;
  elsif live_action = 'section_start' and not session_row.initial_clocks_started then
    update public.workspace_meeting_live_state set initial_clocks_started = true,
      updated_at = now(), updated_by = auth.uid()
    where workspace_id = target_workspace and meeting_id = target_meeting;
  end if;

  if live_action = 'section_start' and session_row.current_section_id is distinct from target_section then
    if session_row.current_section_id is not null then
      update public.workspace_meeting_section_timers set
        elapsed_seconds = elapsed_seconds + case when is_running and started_at is not null then greatest(0, floor(extract(epoch from (now() - started_at)))::integer) else 0 end,
        started_at = null, is_running = false, updated_at = now(), updated_by = auth.uid()
      where workspace_id = target_workspace and meeting_id = target_meeting
        and section_id = session_row.current_section_id and is_running;
    end if;

    insert into public.workspace_meeting_section_timers
      (workspace_id, meeting_id, section_id, elapsed_seconds, started_at, is_running, updated_at, updated_by)
    values (target_workspace, target_meeting, target_section, 0, now(), true, now(), auth.uid())
    on conflict (workspace_id, meeting_id, section_id) do update set
      started_at = case when public.workspace_meeting_section_timers.is_running then public.workspace_meeting_section_timers.started_at else now() end,
      is_running = true, updated_at = now(), updated_by = auth.uid();

    update public.workspace_meeting_live_state set
      current_section_id = target_section, initial_clocks_started = true,
      updated_at = now(), updated_by = auth.uid()
    where workspace_id = target_workspace and meeting_id = target_meeting;
    return;
  end if;

  if live_action = 'section_start' then
    insert into public.workspace_meeting_section_timers
      (workspace_id, meeting_id, section_id, elapsed_seconds, started_at, is_running, updated_at, updated_by)
    values (target_workspace, target_meeting, target_section, 0, now(), true, now(), auth.uid())
    on conflict (workspace_id, meeting_id, section_id) do update set
      started_at = case when public.workspace_meeting_section_timers.is_running then public.workspace_meeting_section_timers.started_at else now() end,
      is_running = true, updated_at = now(), updated_by = auth.uid();
    update public.workspace_meeting_live_state set current_section_id = target_section,
      initial_clocks_started = true, updated_at = now(), updated_by = auth.uid()
    where workspace_id = target_workspace and meeting_id = target_meeting;
  elsif live_action = 'section_pause' then
    update public.workspace_meeting_section_timers set
      elapsed_seconds = elapsed_seconds + case when is_running and started_at is not null then greatest(0, floor(extract(epoch from (now() - started_at)))::integer) else 0 end,
      started_at = null, is_running = false, updated_at = now(), updated_by = auth.uid()
    where workspace_id = target_workspace and meeting_id = target_meeting and section_id = target_section;
    update public.workspace_meeting_live_state set updated_at = now(), updated_by = auth.uid()
    where workspace_id = target_workspace and meeting_id = target_meeting;
  elsif live_action = 'section_reset' then
    update public.workspace_meeting_section_timers set
      elapsed_seconds = 0, started_at = null, is_running = false, updated_at = now(), updated_by = auth.uid()
    where workspace_id = target_workspace and meeting_id = target_meeting and section_id = target_section;
    update public.workspace_meeting_live_state set updated_at = now(), updated_by = auth.uid()
    where workspace_id = target_workspace and meeting_id = target_meeting;
  end if;
end;
$$;

revoke all on function public.manage_workspace_meeting_live_action(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.manage_workspace_meeting_live_action(uuid, text, text, text, text, text) to authenticated;
