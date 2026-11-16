alter table public.workspace_meeting_live_state
  add column if not exists initial_clocks_started boolean not null default false;

-- Mark existing meetings as already initialized so the first click after this
-- migration never starts or resets another clock unexpectedly.
update public.workspace_meeting_live_state
set initial_clocks_started = true
where initial_clocks_started = false;

-- Keep the existing, permission-checked RPC as the implementation for each
-- individual action. The wrapper below only coordinates its first start.
do $$
begin
  if to_regprocedure('public.manage_workspace_meeting_live_action(uuid,text,text,text,text,text)') is not null
     and to_regprocedure('public.manage_workspace_meeting_live_action_before_clock_coordination(uuid,text,text,text,text,text)') is null then
    alter function public.manage_workspace_meeting_live_action(uuid, text, text, text, text, text)
      rename to manage_workspace_meeting_live_action_before_clock_coordination;
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
  first_section_id text;
begin
  if live_action is null or live_action not in ('general_start', 'section_start') then
    perform public.manage_workspace_meeting_live_action_before_clock_coordination(
      target_workspace, target_meeting, live_action, target_section, source_song, after_item
    );
    return;
  end if;

  select data into meeting_data from public.workspace_meetings
  where workspace_id = target_workspace and id = target_meeting;
  if meeting_data is null then
    -- Delegate the standard missing-meeting error and authorization checks.
    perform public.manage_workspace_meeting_live_action_before_clock_coordination(
      target_workspace, target_meeting, live_action, target_section, source_song, after_item
    );
    return;
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

  if session_row.initial_clocks_started then
    perform public.manage_workspace_meeting_live_action_before_clock_coordination(
      target_workspace, target_meeting, live_action, target_section, source_song, after_item
    );
    return;
  end if;

  if live_action = 'general_start' then
    perform public.manage_workspace_meeting_live_action_before_clock_coordination(
      target_workspace, target_meeting, 'general_start', null, null, null
    );
    if first_section_id is not null then
      perform public.manage_workspace_meeting_live_action_before_clock_coordination(
        target_workspace, target_meeting, 'section_start', first_section_id, null, null
      );
    end if;
  else
    perform public.manage_workspace_meeting_live_action_before_clock_coordination(
      target_workspace, target_meeting, 'section_start', target_section, null, null
    );
    if target_section = first_section_id then
      -- This is the automatic paired start caused by the permitted section
      -- action; admins-only manual general clock controls remain unchanged.
      update public.workspace_meeting_live_state set
        general_started_at = case when general_is_running then general_started_at else now() end,
        general_is_running = true, updated_at = now(), updated_by = auth.uid()
      where workspace_id = target_workspace and meeting_id = target_meeting;
    end if;
  end if;

  update public.workspace_meeting_live_state set initial_clocks_started = true
  where workspace_id = target_workspace and meeting_id = target_meeting;
end;
$$;

revoke all on function public.manage_workspace_meeting_live_action_before_clock_coordination(uuid, text, text, text, text, text)
  from public, anon, authenticated;
revoke all on function public.manage_workspace_meeting_live_action(uuid, text, text, text, text, text)
  from public, anon;
grant execute on function public.manage_workspace_meeting_live_action(uuid, text, text, text, text, text)
  to authenticated;
