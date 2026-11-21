-- UNARA EN VIVO Stage 4: per-meeting host and server-driven scheduled start.
-- The original meeting date/time remains in meeting JSON. A postponement is
-- stored separately as an instant, with an IANA timezone for local input.

create extension if not exists pg_cron with schema pg_catalog;

create table if not exists public.workspace_meeting_launch_state (
  workspace_id uuid not null,
  meeting_id text not null,
  host_user_id uuid references auth.users(id) on delete set null,
  scheduled_at timestamptz,
  time_zone text not null default 'America/Santiago',
  status text not null default 'disabled'
    check (status in ('disabled','scheduled','cancelled','started','completed')),
  started_event_id uuid,
  started_at timestamptz,
  started_by uuid references auth.users(id) on delete set null,
  rescheduled_from timestamptz,
  updated_at timestamptz not null default clock_timestamp(),
  updated_by uuid references auth.users(id) on delete set null,
  primary key (workspace_id, meeting_id),
  foreign key (workspace_id, meeting_id)
    references public.workspace_meetings(workspace_id, id) on delete cascade
);

alter table public.workspace_meeting_launch_state enable row level security;
drop policy if exists "Members can read meeting launch state" on public.workspace_meeting_launch_state;
create policy "Members can read meeting launch state"
  on public.workspace_meeting_launch_state for select to authenticated
  using (public.is_workspace_member(workspace_id));
revoke all on public.workspace_meeting_launch_state from public, anon, authenticated;
grant select on public.workspace_meeting_launch_state to authenticated;

-- The start transaction is shared by the scheduled worker and explicit start.
create or replace function public.start_workspace_meeting_once(
  target_workspace uuid, target_meeting text, event_kind text
) returns uuid
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  meeting_row public.workspace_meetings%rowtype;
  launch_row public.workspace_meeting_launch_state%rowtype;
  live_row public.workspace_meeting_live_state%rowtype;
  first_section_id text;
  start_event uuid;
  started_at_server timestamptz := clock_timestamp();
begin
  perform pg_advisory_xact_lock(hashtextextended(target_workspace::text||':'||target_meeting,0));
  select * into meeting_row from public.workspace_meetings
    where workspace_id=target_workspace and id=target_meeting for update;
  if not found then raise exception 'No encontramos esta reunión.'; end if;
  insert into public.workspace_meeting_launch_state(workspace_id,meeting_id)
    values(target_workspace,target_meeting) on conflict do nothing;
  select * into launch_row from public.workspace_meeting_launch_state
    where workspace_id=target_workspace and meeting_id=target_meeting for update;
  if event_kind<>'scheduled_start' and auth.uid() is not null
      and not (public.is_workspace_admin(target_workspace) or public.is_workspace_editor_or_above(target_workspace) or launch_row.host_user_id=auth.uid()) then
    raise exception 'No tienes permiso para iniciar esta reunión.';
  end if;
  if launch_row.status='started' then
    return launch_row.started_event_id;
  end if;
  if meeting_row.data->>'status'='En curso' then
    -- A pre-existing manual start is already official. Mark it observed so the
    -- scheduler will not repeatedly retry it, without resetting any clocks.
    start_event:=coalesce(launch_row.started_event_id,gen_random_uuid());
    update public.workspace_meeting_launch_state set status='started',started_event_id=start_event,
      started_at=coalesce(started_at,started_at_server),started_by=auth.uid(),updated_at=started_at_server,updated_by=auth.uid()
      where workspace_id=target_workspace and meeting_id=target_meeting;
    return start_event;
  end if;
  if meeting_row.data->>'status'='Finalizada' then
    raise exception 'Esta reunión ya está finalizada.';
  end if;
  if event_kind='scheduled_start' and launch_row.status<>'scheduled' then
    return null;
  end if;

  select section_data->>'id' into first_section_id
    from jsonb_array_elements(coalesce(meeting_row.data->'agenda'->'sections','[]'::jsonb))
      with ordinality as section_rows(section_data, section_order)
    order by section_order limit 1;
  if first_section_id is null and meeting_row.data->'agenda' is null
      and jsonb_array_length(coalesce(meeting_row.data->'songs','[]'::jsonb))>0 then
    first_section_id := 'legacy-repertoire';
  end if;

  insert into public.workspace_meeting_live_state(workspace_id,meeting_id)
    values(target_workspace,target_meeting) on conflict do nothing;
  select * into live_row from public.workspace_meeting_live_state
    where workspace_id=target_workspace and meeting_id=target_meeting for update;

  -- Never reset clocks that have already been initialized by an earlier live action.
  if not live_row.initial_clocks_started then
    update public.workspace_meeting_live_state set
      general_started_at=case when general_is_running then general_started_at else started_at_server end,
      general_is_running=true,
      current_section_id=coalesce(first_section_id,current_section_id),
      initial_clocks_started=true, updated_at=started_at_server, updated_by=auth.uid()
      where workspace_id=target_workspace and meeting_id=target_meeting;
    if first_section_id is not null then
      update public.workspace_meeting_section_timers set
        elapsed_seconds=elapsed_seconds+case when is_running and started_at is not null
          then greatest(0,floor(extract(epoch from (started_at_server-started_at)))::integer) else 0 end,
        started_at=null,is_running=false,updated_at=started_at_server,updated_by=auth.uid()
        where workspace_id=target_workspace and meeting_id=target_meeting
          and is_running and section_id<>first_section_id;
      insert into public.workspace_meeting_section_timers
        (workspace_id,meeting_id,section_id,elapsed_seconds,started_at,is_running,updated_at,updated_by)
        values(target_workspace,target_meeting,first_section_id,0,started_at_server,true,started_at_server,auth.uid())
        on conflict(workspace_id,meeting_id,section_id) do update set
          started_at=case when public.workspace_meeting_section_timers.is_running
            then public.workspace_meeting_section_timers.started_at else started_at_server end,
          is_running=true,updated_at=started_at_server,updated_by=auth.uid();
    end if;
  end if;

  start_event := coalesce(launch_row.started_event_id,gen_random_uuid());
  update public.workspace_meeting_launch_state set
    status='started',started_event_id=start_event,started_at=coalesce(started_at,started_at_server),
    started_by=auth.uid(),updated_at=started_at_server,updated_by=auth.uid()
    where workspace_id=target_workspace and meeting_id=target_meeting;
  update public.workspace_meetings set data=jsonb_set(data,'{status}',to_jsonb('En curso'::text),true)
    where workspace_id=target_workspace and id=target_meeting
      and coalesce(data->>'status','Preparación')<>'En curso';
  insert into public.workspace_meeting_history(workspace_id,meeting_id,actor_id,category,event_type,summary,details)
    values(target_workspace,target_meeting,auth.uid(),'live',event_kind,
      case when event_kind='scheduled_start' then 'La reunión comenzó según el horario programado.'
        when event_kind='host_start_now' then 'El Anfitrión inició la reunión antes del horario programado.'
        else 'La reunión comenzó antes del horario programado.' end,
      jsonb_build_object('started_event_id',start_event,'first_section_id',first_section_id,
        'scheduled_at',launch_row.scheduled_at,'started_at',started_at_server));
  return start_event;
end;
$$;
revoke all on function public.start_workspace_meeting_once(uuid,text,text) from public,anon,authenticated;

-- Keep Host-specific access narrow. Editor/Owner/Admin continue using the
-- original action RPC; this entry point only permits the assigned Host.
create or replace function public.manage_workspace_meeting_host_live_action(
  target_workspace uuid,target_meeting text,live_action text,target_section text default null
) returns void language plpgsql security definer set search_path=public,pg_temp
as $$
declare actor uuid:=auth.uid(); meeting_data jsonb; session_row public.workspace_meeting_live_state%rowtype;
  timer_row public.workspace_meeting_section_timers%rowtype; old_state jsonb; new_state jsonb;
  old_timer jsonb; new_timer jsonb; first_section_id text; valid_section boolean;
begin
  if actor is null or not public.is_workspace_member(target_workspace) or live_action not in ('general_start','general_pause','general_reset','section_start','section_pause','section_reset') then
    raise exception 'La acción en vivo no es válida.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(target_workspace::text||':'||target_meeting,0));
  select data into meeting_data from public.workspace_meetings where workspace_id=target_workspace and id=target_meeting for update;
  if meeting_data is null then raise exception 'No encontramos esta reunión.'; end if;
  if not exists(select 1 from public.workspace_meeting_launch_state l where l.workspace_id=target_workspace
      and l.meeting_id=target_meeting and l.host_user_id=actor and l.status in ('scheduled','cancelled','started')) then
    raise exception 'Solo el Anfitrión de esta reunión puede usar estos controles.';
  end if;
  insert into public.workspace_meeting_live_state(workspace_id,meeting_id) values(target_workspace,target_meeting) on conflict do nothing;
  select * into session_row from public.workspace_meeting_live_state
    where workspace_id=target_workspace and meeting_id=target_meeting for update;
  select to_jsonb(s) into old_state from public.workspace_meeting_live_state s
    where s.workspace_id=target_workspace and s.meeting_id=target_meeting;
  select section_data->>'id' into first_section_id from jsonb_array_elements(coalesce(meeting_data->'agenda'->'sections','[]'::jsonb))
    with ordinality s(section_data,ord) order by ord limit 1;
  if first_section_id is null and meeting_data->'agenda' is null and jsonb_array_length(coalesce(meeting_data->'songs','[]'::jsonb))>0 then first_section_id:='legacy-repertoire'; end if;
  if live_action like 'section_%' then
    select exists(select 1 from jsonb_array_elements(coalesce(meeting_data->'agenda'->'sections','[]'::jsonb)) s(section_data)
      where section_data->>'id'=target_section)
      or (meeting_data->'agenda' is null and target_section='legacy-repertoire') into valid_section;
    if target_section is null or not coalesce(valid_section,false) then raise exception 'La sección ya no existe.'; end if;
    select to_jsonb(t) into old_timer from public.workspace_meeting_section_timers t
      where t.workspace_id=target_workspace and t.meeting_id=target_meeting and t.section_id=target_section;
  end if;

  if live_action='general_start' then
    if meeting_data->>'status'<>'En curso' then raise exception 'Inicia oficialmente la reunión antes de usar el cronómetro.'; end if;
    update public.workspace_meeting_live_state set general_started_at=case when general_is_running then general_started_at else clock_timestamp() end,
      general_is_running=true,updated_at=clock_timestamp(),updated_by=actor where workspace_id=target_workspace and meeting_id=target_meeting;
    if not session_row.initial_clocks_started then
      if first_section_id is not null then
        if session_row.current_section_id is not null and session_row.current_section_id<>first_section_id then
          update public.workspace_meeting_section_timers set elapsed_seconds=elapsed_seconds+case when is_running and started_at is not null then greatest(0,floor(extract(epoch from(clock_timestamp()-started_at)))::integer) else 0 end,
            started_at=null,is_running=false,updated_at=clock_timestamp(),updated_by=actor
            where workspace_id=target_workspace and meeting_id=target_meeting and section_id=session_row.current_section_id and is_running;
        end if;
        insert into public.workspace_meeting_section_timers(workspace_id,meeting_id,section_id,elapsed_seconds,started_at,is_running,updated_at,updated_by)
          values(target_workspace,target_meeting,first_section_id,0,clock_timestamp(),true,clock_timestamp(),actor)
          on conflict(workspace_id,meeting_id,section_id) do update set started_at=case when public.workspace_meeting_section_timers.is_running then public.workspace_meeting_section_timers.started_at else clock_timestamp() end,
            is_running=true,updated_at=clock_timestamp(),updated_by=actor;
      end if;
      update public.workspace_meeting_live_state set current_section_id=coalesce(first_section_id,current_section_id),initial_clocks_started=true
        where workspace_id=target_workspace and meeting_id=target_meeting;
    end if;
  elsif live_action='general_pause' then
    if meeting_data->>'status'<>'En curso' then raise exception 'La reunión todavía no ha comenzado.'; end if;
    update public.workspace_meeting_live_state set general_elapsed_seconds=general_elapsed_seconds+case when general_is_running and general_started_at is not null then greatest(0,floor(extract(epoch from(clock_timestamp()-general_started_at)))::integer) else 0 end,
      general_started_at=null,general_is_running=false,updated_at=clock_timestamp(),updated_by=actor where workspace_id=target_workspace and meeting_id=target_meeting;
  elsif live_action='general_reset' then
    if meeting_data->>'status'<>'En curso' then raise exception 'La reunión todavía no ha comenzado.'; end if;
    update public.workspace_meeting_live_state set general_elapsed_seconds=0,general_started_at=null,general_is_running=false,
      updated_at=clock_timestamp(),updated_by=actor where workspace_id=target_workspace and meeting_id=target_meeting;
  elsif live_action='section_start' and session_row.current_section_id is distinct from target_section then
    if meeting_data->>'status'<>'En curso' then raise exception 'Inicia oficialmente la reunión antes de controlar sus secciones.'; end if;
    if session_row.current_section_id is not null then
      update public.workspace_meeting_section_timers set elapsed_seconds=elapsed_seconds+case when is_running and started_at is not null then greatest(0,floor(extract(epoch from(clock_timestamp()-started_at)))::integer) else 0 end,
        started_at=null,is_running=false,updated_at=clock_timestamp(),updated_by=actor where workspace_id=target_workspace and meeting_id=target_meeting and section_id=session_row.current_section_id and is_running;
    end if;
    insert into public.workspace_meeting_section_timers(workspace_id,meeting_id,section_id,elapsed_seconds,started_at,is_running,updated_at,updated_by)
      values(target_workspace,target_meeting,target_section,0,clock_timestamp(),true,clock_timestamp(),actor)
      on conflict(workspace_id,meeting_id,section_id) do update set started_at=case when public.workspace_meeting_section_timers.is_running then public.workspace_meeting_section_timers.started_at else clock_timestamp() end,
        is_running=true,updated_at=clock_timestamp(),updated_by=actor;
    update public.workspace_meeting_live_state set current_section_id=target_section,updated_at=clock_timestamp(),updated_by=actor where workspace_id=target_workspace and meeting_id=target_meeting;
    if target_section=first_section_id and not session_row.initial_clocks_started then
      update public.workspace_meeting_live_state set general_started_at=case when general_is_running then general_started_at else clock_timestamp() end,
        general_is_running=true,initial_clocks_started=true where workspace_id=target_workspace and meeting_id=target_meeting;
    end if;
  elsif live_action='section_start' then
    if meeting_data->>'status'<>'En curso' then raise exception 'Inicia oficialmente la reunión antes de controlar sus secciones.'; end if;
    insert into public.workspace_meeting_section_timers(workspace_id,meeting_id,section_id,elapsed_seconds,started_at,is_running,updated_at,updated_by)
      values(target_workspace,target_meeting,target_section,0,clock_timestamp(),true,clock_timestamp(),actor)
      on conflict(workspace_id,meeting_id,section_id) do update set started_at=case when public.workspace_meeting_section_timers.is_running then public.workspace_meeting_section_timers.started_at else clock_timestamp() end,
        is_running=true,updated_at=clock_timestamp(),updated_by=actor;
    update public.workspace_meeting_live_state set current_section_id=target_section,updated_at=clock_timestamp(),updated_by=actor where workspace_id=target_workspace and meeting_id=target_meeting;
  elsif live_action='section_pause' then
    if meeting_data->>'status'<>'En curso' then raise exception 'La reunión todavía no ha comenzado.'; end if;
    update public.workspace_meeting_section_timers set elapsed_seconds=elapsed_seconds+case when is_running and started_at is not null then greatest(0,floor(extract(epoch from(clock_timestamp()-started_at)))::integer) else 0 end,
      started_at=null,is_running=false,updated_at=clock_timestamp(),updated_by=actor where workspace_id=target_workspace and meeting_id=target_meeting and section_id=target_section;
  elsif live_action='section_reset' then
    if meeting_data->>'status'<>'En curso' then raise exception 'La reunión todavía no ha comenzado.'; end if;
    update public.workspace_meeting_section_timers set elapsed_seconds=0,started_at=null,is_running=false,updated_at=clock_timestamp(),updated_by=actor
      where workspace_id=target_workspace and meeting_id=target_meeting and section_id=target_section;
  end if;
  select to_jsonb(s) into new_state from public.workspace_meeting_live_state s where s.workspace_id=target_workspace and s.meeting_id=target_meeting;
  if target_section is not null then select to_jsonb(t) into new_timer from public.workspace_meeting_section_timers t where t.workspace_id=target_workspace and t.meeting_id=target_meeting and t.section_id=target_section; end if;
  if (old_state-'updated_at'-'updated_by') is distinct from (new_state-'updated_at'-'updated_by')
      or (old_timer-'updated_at'-'updated_by') is distinct from (new_timer-'updated_at'-'updated_by') then
    insert into public.workspace_meeting_history(workspace_id,meeting_id,actor_id,category,event_type,summary,details)
      values(target_workspace,target_meeting,actor,'live',live_action,
        case when live_action like 'general_%' then 'El Anfitrión actualizó el cronómetro general.' else 'El Anfitrión actualizó el cronómetro de una sección.' end,
        jsonb_build_object('section_id',target_section,'old_state',old_state,'new_state',new_state,'old_timer',old_timer,'new_timer',new_timer));
  end if;
end;
$$;
revoke all on function public.manage_workspace_meeting_host_live_action(uuid,text,text,text) from public,anon;
grant execute on function public.manage_workspace_meeting_host_live_action(uuid,text,text,text) to authenticated;

create or replace function public.sync_workspace_meeting_launch_schedule()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
declare host_id uuid; tz text; local_start timestamp; instant timestamptz; previous public.workspace_meeting_launch_state%rowtype;
  schedule_changed boolean;
begin
  host_id:=nullif(new.data->>'host_user_id','')::uuid;
  tz:=coalesce(nullif(new.data->>'time_zone',''),'America/Santiago');
  if not exists(select 1 from pg_timezone_names where name=tz) then raise exception 'La zona horaria de la reunión no es válida.'; end if;
  if host_id is not null and not exists(select 1 from public.workspace_members m where m.workspace_id=new.workspace_id
      and m.user_id=host_id and m.membership_status='active') then raise exception 'El Anfitrión debe ser integrante activo del espacio.'; end if;
  if coalesce(new.data->>'date','') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' and coalesce(new.data->>'time','') ~ '^[0-9]{2}:[0-9]{2}(:[0-9]{2})?$' then
    local_start:=(new.data->>'date')::date+(new.data->>'time')::time;
    instant:=local_start at time zone tz;
  end if;
  select * into previous from public.workspace_meeting_launch_state where workspace_id=new.workspace_id and meeting_id=new.id for update;
  schedule_changed:=not found or previous.host_user_id is distinct from host_id or previous.time_zone is distinct from tz;
  if tg_op='UPDATE' and ((old.data->>'date') is distinct from (new.data->>'date') or (old.data->>'time') is distinct from (new.data->>'time')) then schedule_changed:=true; end if;
  insert into public.workspace_meeting_launch_state(workspace_id,meeting_id,host_user_id,scheduled_at,time_zone,status,updated_by)
    values(new.workspace_id,new.id,host_id,instant,tz,
      case when host_id is not null and instant is not null and new.data->>'status'='Preparación' then 'scheduled' else 'disabled' end,auth.uid())
    on conflict(workspace_id,meeting_id) do update set
      host_user_id=excluded.host_user_id,time_zone=excluded.time_zone,
      scheduled_at=case when schedule_changed then instant else public.workspace_meeting_launch_state.scheduled_at end,
      status=case when new.data->>'status'='Finalizada' then 'completed'
        when public.workspace_meeting_launch_state.status='started' then 'started'
        when schedule_changed then case when host_id is not null and instant is not null and new.data->>'status'='Preparación' then 'scheduled' else 'disabled' end
        else public.workspace_meeting_launch_state.status end,
      started_event_id=case when schedule_changed and public.workspace_meeting_launch_state.status<>'started' then null else public.workspace_meeting_launch_state.started_event_id end,
      started_at=case when schedule_changed and public.workspace_meeting_launch_state.status<>'started' then null else public.workspace_meeting_launch_state.started_at end,
      started_by=case when schedule_changed and public.workspace_meeting_launch_state.status<>'started' then null else public.workspace_meeting_launch_state.started_by end,
      updated_at=clock_timestamp(),updated_by=auth.uid();
  return new;
end;
$$;
drop trigger if exists sync_workspace_meeting_launch_schedule on public.workspace_meetings;
create trigger sync_workspace_meeting_launch_schedule after insert or update of data on public.workspace_meetings
  for each row execute function public.sync_workspace_meeting_launch_schedule();

-- Preserve existing role checks while allowing only the assigned Host to start
-- the same meeting. The Host cannot change permanent roles or meeting content.
create or replace function public.protect_meeting_control_fields()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
declare launch_started boolean:=false; launch_actor uuid;
begin
  if tg_op='INSERT' then
    if coalesce(new.data->>'status','Preparación')<>'Preparación' and not public.is_workspace_admin(new.workspace_id) then
      raise exception 'Solo un administrador puede iniciar o finalizar reuniones.';
    end if;
    if (new.data ? 'assignments' or nullif(new.data->>'host_user_id','') is not null) and not public.is_workspace_admin(new.workspace_id) then
      raise exception 'Solo Propietarios y Administradores pueden designar al Anfitrión o asignar funciones.';
    end if;
    return new;
  end if;
  if new.data->>'status' is distinct from old.data->>'status' then
    select status='started',started_by into launch_started,launch_actor from public.workspace_meeting_launch_state
      where workspace_id=new.workspace_id and meeting_id=new.id;
    if not public.is_workspace_admin(new.workspace_id) and not (
      new.data->>'status'='En curso' and coalesce(launch_started,false)
      and (launch_actor is not distinct from auth.uid())
    ) then raise exception 'Solo un administrador o el Anfitrión asignado pueden iniciar la reunión.'; end if;
  end if;
  if new.data->'assignments' is distinct from old.data->'assignments' and not public.is_workspace_admin(new.workspace_id) then
    raise exception 'Solo un administrador puede asignar funciones para una reunión.';
  end if;
  if new.data->>'host_user_id' is distinct from old.data->>'host_user_id' and not public.is_workspace_admin(new.workspace_id) then
    raise exception 'Solo Propietarios y Administradores pueden designar al Anfitrión.';
  end if;
  return new;
end;
$$;

-- Seed every published meeting but leave old meetings disabled unless an
-- administrator explicitly selected a Host and published it.
insert into public.workspace_meeting_launch_state(workspace_id,meeting_id,host_user_id,scheduled_at,time_zone,status)
select m.workspace_id,m.id,null,null,'America/Santiago','disabled' from public.workspace_meetings m
on conflict(workspace_id,meeting_id) do nothing;

create or replace function public.get_workspace_meeting_launch_state(target_workspace uuid,target_meeting text)
returns table(workspace_id uuid,meeting_id text,host_user_id uuid,scheduled_at timestamptz,time_zone text,status text,
  started_event_id uuid,started_at timestamptz,rescheduled_from timestamptz,server_now timestamptz)
language plpgsql security definer set search_path=public,pg_temp
as $$
begin
  if auth.uid() is null or not public.is_workspace_member(target_workspace) then raise exception 'No tienes acceso a esta reunión.'; end if;
  return query select l.workspace_id,l.meeting_id,l.host_user_id,l.scheduled_at,l.time_zone,l.status,l.started_event_id,l.started_at,l.rescheduled_from,clock_timestamp()
    from public.workspace_meeting_launch_state l where l.workspace_id=target_workspace and l.meeting_id=target_meeting;
end;
$$;
revoke all on function public.get_workspace_meeting_launch_state(uuid,text) from public,anon;
grant execute on function public.get_workspace_meeting_launch_state(uuid,text) to authenticated;

create or replace function public.manage_workspace_meeting_launch_action(
  target_workspace uuid,target_meeting text,launch_action text,new_local_date text default null,new_local_time text default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp
as $$
declare actor uuid:=auth.uid(); launch_row public.workspace_meeting_launch_state%rowtype; target_instant timestamptz; event_id uuid;
begin
  if actor is null or not public.is_workspace_member(target_workspace) then raise exception 'Debes pertenecer a este espacio de trabajo.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(target_workspace::text||':'||target_meeting,0));
  select * into launch_row from public.workspace_meeting_launch_state where workspace_id=target_workspace and meeting_id=target_meeting;
  if not found then raise exception 'No encontramos la programación de esta reunión.'; end if;
  if launch_action='start_now' then
    if not (public.is_workspace_admin(target_workspace) or public.is_workspace_editor_or_above(target_workspace) or launch_row.host_user_id=actor) then raise exception 'No tienes permiso para iniciar esta reunión.'; end if;
    return public.start_workspace_meeting_once(target_workspace,target_meeting,case when launch_row.host_user_id=actor and not public.is_workspace_admin(target_workspace) then 'host_start_now' else 'authorized_start_now' end);
  elsif launch_action='cancel' then
    select * into launch_row from public.workspace_meeting_launch_state where workspace_id=target_workspace and meeting_id=target_meeting for update;
    if not public.is_workspace_admin(target_workspace) and launch_row.host_user_id is distinct from actor then raise exception 'Solo Propietarios, Administradores o el Anfitrión asignado pueden controlar el inicio.'; end if;
    if launch_row.status<>'scheduled' or launch_row.scheduled_at is null or launch_row.scheduled_at<=clock_timestamp() then raise exception 'El inicio ya comenzó o no está programado.'; end if;
    update public.workspace_meeting_launch_state set status='cancelled',updated_at=clock_timestamp(),updated_by=actor where workspace_id=target_workspace and meeting_id=target_meeting;
    insert into public.workspace_meeting_history(workspace_id,meeting_id,actor_id,category,event_type,summary,details)
      values(target_workspace,target_meeting,actor,'live','scheduled_start_cancelled','Se canceló el inicio automático de la reunión.',jsonb_build_object('scheduled_at',launch_row.scheduled_at));
    return null;
  elsif launch_action='postpone' then
    select * into launch_row from public.workspace_meeting_launch_state where workspace_id=target_workspace and meeting_id=target_meeting for update;
    if not public.is_workspace_admin(target_workspace) and launch_row.host_user_id is distinct from actor then raise exception 'Solo Propietarios, Administradores o el Anfitrión asignado pueden controlar el inicio.'; end if;
    if launch_row.status not in ('scheduled','cancelled') then raise exception 'Esta reunión no tiene un inicio que se pueda posponer.'; end if;
    if coalesce(new_local_date,'') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or coalesce(new_local_time,'') !~ '^[0-9]{2}:[0-9]{2}(:[0-9]{2})?$' then raise exception 'Indica una nueva fecha y hora válidas.'; end if;
    target_instant:=((new_local_date::date)+(new_local_time::time)) at time zone launch_row.time_zone;
    if target_instant<=clock_timestamp() then raise exception 'La nueva hora debe estar en el futuro.'; end if;
    update public.workspace_meeting_launch_state set rescheduled_from=coalesce(rescheduled_from,scheduled_at),scheduled_at=target_instant,
      status='scheduled',updated_at=clock_timestamp(),updated_by=actor where workspace_id=target_workspace and meeting_id=target_meeting;
    insert into public.workspace_meeting_history(workspace_id,meeting_id,actor_id,category,event_type,summary,details)
      values(target_workspace,target_meeting,actor,'live','scheduled_start_postponed','Se pospuso el inicio automático de la reunión.',jsonb_build_object('old_scheduled_at',launch_row.scheduled_at,'new_scheduled_at',target_instant,'time_zone',launch_row.time_zone));
    return null;
  else raise exception 'La acción de inicio no es válida.';
  end if;
end;
$$;
revoke all on function public.manage_workspace_meeting_launch_action(uuid,text,text,text,text) from public,anon;
grant execute on function public.manage_workspace_meeting_launch_action(uuid,text,text,text,text) to authenticated;

-- Worker entry point: only pg_cron (scheduled as the migration owner) executes
-- it. Row locks/advisory locks make concurrent ticks and manual starts safe.
create or replace function public.process_due_workspace_meeting_starts()
returns integer language plpgsql security definer set search_path=public,pg_temp
as $$
declare due record; started_count integer:=0;
begin
  for due in select workspace_id,meeting_id from public.workspace_meeting_launch_state
    where status='scheduled' and scheduled_at<=clock_timestamp() order by scheduled_at limit 100
  loop
    if public.start_workspace_meeting_once(due.workspace_id,due.meeting_id,'scheduled_start') is not null then started_count:=started_count+1; end if;
  end loop;
  return started_count;
end;
$$;
revoke all on function public.process_due_workspace_meeting_starts() from public,anon,authenticated;

-- Null actor identifies a trusted system event, not a user-supplied identity.
alter table public.workspace_meeting_history alter column actor_id drop not null;
create or replace function public.get_workspace_meeting_history(target_workspace uuid,target_meeting text,before_id bigint default null,page_size integer default 30)
returns table(id bigint,actor_id uuid,actor_name text,occurred_at timestamptz,category text,event_type text,summary text,details jsonb,published_version bigint)
language plpgsql security definer set search_path=public,pg_temp
as $$
begin
  if auth.uid() is null or not public.is_workspace_editor_or_above(target_workspace) then raise exception 'Solo Propietarios, Administradores y Editores pueden consultar el historial.'; end if;
  if not exists(select 1 from public.workspace_meetings m where m.workspace_id=target_workspace and m.id=target_meeting) then raise exception 'No encontramos esta reunión.'; end if;
  return query select h.id,h.actor_id,case when h.actor_id is null then 'UNARA (inicio programado)' else coalesce(p.full_name,'Usuario del equipo') end,
    h.occurred_at,h.category,h.event_type,h.summary,h.details,h.published_version from public.workspace_meeting_history h
    left join public.profiles p on p.id=h.actor_id where h.workspace_id=target_workspace and h.meeting_id=target_meeting
    and (before_id is null or h.id<before_id) order by h.id desc limit least(greatest(coalesce(page_size,30),1),50);
end;
$$;
revoke all on function public.get_workspace_meeting_history(uuid,text,bigint,integer) from public,anon,authenticated;
grant execute on function public.get_workspace_meeting_history(uuid,text,bigint,integer) to authenticated;

-- A one-second database job means the start does not depend on an open browser.
do $$
declare existing_job bigint;
begin
  select jobid into existing_job from cron.job where jobname='unara-meeting-scheduled-starts';
  if existing_job is not null then perform cron.unschedule(existing_job); end if;
  perform cron.schedule('unara-meeting-scheduled-starts','1 seconds','select public.process_due_workspace_meeting_starts();');
end;
$$;

do $$ begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime')
    and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='workspace_meeting_launch_state') then
    alter publication supabase_realtime add table public.workspace_meeting_launch_state;
  end if;
end $$;
