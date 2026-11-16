-- Shared live controls are stored separately from the meeting agenda so a
-- timer update never replaces another member's meeting edits.
create table if not exists public.workspace_meeting_live_state (
  workspace_id uuid not null,
  meeting_id text not null,
  current_section_id text,
  general_elapsed_seconds integer not null default 0 check (general_elapsed_seconds >= 0),
  general_started_at timestamptz,
  general_is_running boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  primary key (workspace_id, meeting_id),
  foreign key (workspace_id, meeting_id)
    references public.workspace_meetings(workspace_id, id) on delete cascade
);

create table if not exists public.workspace_meeting_section_timers (
  workspace_id uuid not null,
  meeting_id text not null,
  section_id text not null,
  elapsed_seconds integer not null default 0 check (elapsed_seconds >= 0),
  started_at timestamptz,
  is_running boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  primary key (workspace_id, meeting_id, section_id),
  foreign key (workspace_id, meeting_id)
    references public.workspace_meetings(workspace_id, id) on delete cascade
);

create table if not exists public.workspace_meeting_live_songs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  meeting_id text not null,
  section_id text not null,
  song_id text not null,
  after_item_id text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  foreign key (workspace_id, meeting_id)
    references public.workspace_meetings(workspace_id, id) on delete cascade,
  foreign key (workspace_id, song_id)
    references public.workspace_songs(workspace_id, id) on delete restrict
);

create index if not exists workspace_meeting_live_songs_order_idx
  on public.workspace_meeting_live_songs(workspace_id, meeting_id, section_id, created_at, id);

alter table public.workspace_meeting_live_state enable row level security;
alter table public.workspace_meeting_section_timers enable row level security;
alter table public.workspace_meeting_live_songs enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='workspace_meeting_live_state' and policyname='Members can read live meeting state') then
    create policy "Members can read live meeting state" on public.workspace_meeting_live_state
      for select to authenticated using (public.is_workspace_member(workspace_id));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='workspace_meeting_section_timers' and policyname='Members can read live section timers') then
    create policy "Members can read live section timers" on public.workspace_meeting_section_timers
      for select to authenticated using (public.is_workspace_member(workspace_id));
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='workspace_meeting_live_songs' and policyname='Members can read live meeting songs') then
    create policy "Members can read live meeting songs" on public.workspace_meeting_live_songs
      for select to authenticated using (public.is_workspace_member(workspace_id));
  end if;
end;
$$;

revoke all on public.workspace_meeting_live_state,
  public.workspace_meeting_section_timers,
  public.workspace_meeting_live_songs from public, anon, authenticated;
grant select on public.workspace_meeting_live_state,
  public.workspace_meeting_section_timers,
  public.workspace_meeting_live_songs to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'workspace_meeting_live_state') then
      execute 'alter publication supabase_realtime add table public.workspace_meeting_live_state';
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'workspace_meeting_section_timers') then
      execute 'alter publication supabase_realtime add table public.workspace_meeting_section_timers';
    end if;
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'workspace_meeting_live_songs') then
      execute 'alter publication supabase_realtime add table public.workspace_meeting_live_songs';
    end if;
  end if;
end;
$$;

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
  timer_row public.workspace_meeting_section_timers%rowtype;
  tick_seconds integer;
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

  insert into public.workspace_meeting_live_state (workspace_id, meeting_id)
  values (target_workspace, target_meeting) on conflict do nothing;
  select * into session_row from public.workspace_meeting_live_state
  where workspace_id = target_workspace and meeting_id = target_meeting for update;

  if live_action = 'general_start' then
    update public.workspace_meeting_live_state set
      general_started_at = case when general_is_running then general_started_at else now() end,
      general_is_running = true, updated_at = now(), updated_by = auth.uid()
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
      current_section_id = target_section, updated_at = now(), updated_by = auth.uid()
    where workspace_id = target_workspace and meeting_id = target_meeting;
    return;
  end if;

  select * into timer_row from public.workspace_meeting_section_timers
  where workspace_id = target_workspace and meeting_id = target_meeting and section_id = target_section;

  if live_action = 'section_start' then
    insert into public.workspace_meeting_section_timers
      (workspace_id, meeting_id, section_id, elapsed_seconds, started_at, is_running, updated_at, updated_by)
    values (target_workspace, target_meeting, target_section, 0, now(), true, now(), auth.uid())
    on conflict (workspace_id, meeting_id, section_id) do update set
      started_at = case when public.workspace_meeting_section_timers.is_running then public.workspace_meeting_section_timers.started_at else now() end,
      is_running = true, updated_at = now(), updated_by = auth.uid();
    update public.workspace_meeting_live_state set current_section_id = target_section, updated_at = now(), updated_by = auth.uid()
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
