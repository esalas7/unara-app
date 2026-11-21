-- Stage 5. Persist the countdown identity separately from the clock display.
alter table public.workspace_meeting_launch_state
  add column countdown_for timestamptz,
  add column finished_at timestamptz,
  add column finished_by uuid references auth.users(id) on delete set null;
create index workspace_meeting_scheduled_time on public.workspace_meeting_launch_state(scheduled_at)
where status='scheduled';

create or replace function public.process_due_workspace_meeting_starts()
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare candidate record; current_launch public.workspace_meeting_launch_state%rowtype; starts integer:=0;
begin
  for candidate in select workspace_id, meeting_id from public.workspace_meeting_launch_state
    where status='scheduled' and scheduled_at<=clock_timestamp()+interval '60 seconds'
      and (scheduled_at<=clock_timestamp() or countdown_for is distinct from scheduled_at)
    order by scheduled_at,workspace_id,meeting_id limit 100
  loop
    perform pg_advisory_xact_lock(hashtextextended(candidate.workspace_id::text||':'||candidate.meeting_id,0));
    perform 1 from public.workspace_meetings where workspace_id=candidate.workspace_id and id=candidate.meeting_id for update;
    select * into current_launch from public.workspace_meeting_launch_state where workspace_id=candidate.workspace_id and meeting_id=candidate.meeting_id for update;
    if current_launch.status='scheduled' then
      if current_launch.scheduled_at<=clock_timestamp() then
        perform public.start_workspace_meeting_once(candidate.workspace_id,candidate.meeting_id,'scheduled_start');
        starts:=starts+1;
      elsif current_launch.scheduled_at<=clock_timestamp()+interval '60 seconds' then
        update public.workspace_meeting_launch_state set countdown_for=scheduled_at,updated_at=clock_timestamp()
        where workspace_id=candidate.workspace_id and meeting_id=candidate.meeting_id and countdown_for is distinct from scheduled_at;
      end if;
    end if;
  end loop;
  return starts;
end $$;

create function public.my_meeting_navigation(target_workspace uuid)
returns table(meeting_id text,event_key text,screen text) language sql stable security definer
set search_path=public,pg_temp as $$
  select l.meeting_id,
    case when l.status='started' then l.started_event_id::text else l.countdown_for::text end,
    case when l.status='started' then coalesce(m.data#>>'{agenda,sections,0,id}',
      case when m.data->'agenda' is null and jsonb_array_length(m.data->'songs')>0 then 'legacy-repertoire' end,'general') else 'general' end
  from public.workspace_meeting_launch_state l join public.workspace_meetings m on m.id=l.meeting_id and m.workspace_id=l.workspace_id
  where l.workspace_id=target_workspace and public.is_workspace_member(target_workspace)
    and (l.host_user_id=auth.uid() or exists(select 1 from public.workspace_meeting_assignments a where
      a.workspace_id=l.workspace_id and a.meeting_id=l.meeting_id and a.user_id=auth.uid()))
    and ((l.status='scheduled' and l.scheduled_at=l.countdown_for and l.scheduled_at>now() and l.scheduled_at<=now()+interval '60 seconds')
      or (l.status='started' and m.data->>'status'='En curso' and l.started_event_id is not null))
  order by case when l.status='started' then l.started_at else l.scheduled_at-interval '60 seconds' end desc,
    (l.status='started') desc,l.meeting_id
$$;
revoke all on function public.my_meeting_navigation(uuid) from public,anon;
grant execute on function public.my_meeting_navigation(uuid) to authenticated;
-- Keep fractional seconds across repeated whole-meeting pauses; the existing UI reads integer seconds.
alter table public.workspace_meeting_live_state add column pause_fraction numeric not null default 0;
alter table public.workspace_meeting_section_timers add column pause_fraction numeric not null default 0;

-- Only confirmed completion dates may participate in automatic pruning.
create table public.meeting_retention_log (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  meeting_id text not null, finished_at timestamptz not null, removed_at timestamptz not null default now(),
  primary key(workspace_id,meeting_id,removed_at)
);
alter table public.meeting_retention_log enable row level security;
revoke all on public.meeting_retention_log from public,anon,authenticated;

create function public.control_meeting_lifecycle(target_workspace uuid,target_meeting text,operation text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare actor uuid:=auth.uid(); current_status text; next_status text; active_section text; moment timestamptz; victim record;
begin
  if actor is null or not public.is_workspace_member(target_workspace) then raise exception 'Acceso denegado'; end if;
  if operation='finish' then perform pg_advisory_xact_lock(hashtextextended('retention:'||target_workspace,0)); end if;
  perform pg_advisory_xact_lock(hashtextextended(target_workspace::text||':'||target_meeting,0));
  select data->>'status' into current_status from public.workspace_meetings
    where workspace_id=target_workspace and id=target_meeting for update;
  if not(coalesce(public.is_workspace_admin(target_workspace),false) or exists(
    select 1 from public.workspace_meeting_launch_state where workspace_id=target_workspace
    and meeting_id=target_meeting and host_user_id=actor)) then raise exception 'No tienes permiso para dirigir esta reunión'; end if;
  next_status:=case
    when operation='pause' and current_status='En curso' then 'Pausada'
    when operation='resume' and current_status='Pausada' then 'En curso'
    when operation='reset' and current_status in ('En curso','Pausada') then 'Preparación'
    when operation='finish' and current_status in ('En curso','Pausada') then 'Finalizada' end;
  if next_status is null then raise exception 'La reunión ya cambió de estado. Actualiza la vista.'; end if;
  select current_section_id into active_section from public.workspace_meeting_live_state
    where workspace_id=target_workspace and meeting_id=target_meeting for update;
  moment:=clock_timestamp();
  update public.workspace_meeting_live_state set
    general_elapsed_seconds=case when operation='reset' then 0 else general_elapsed_seconds+
      case when general_is_running then floor(greatest(0,extract(epoch from moment-general_started_at))+pause_fraction)::int else 0 end end,
    pause_fraction=case when operation='reset' then 0 when general_is_running then mod(greatest(0,extract(epoch from moment-general_started_at))+pause_fraction,1) else pause_fraction end,
    general_is_running=operation='resume', general_started_at=case when operation='resume' then moment end,
    initial_clocks_started=operation<>'reset',current_section_id=case when operation<>'reset' then active_section end,
    updated_at=moment,updated_by=actor where workspace_id=target_workspace and meeting_id=target_meeting;
  update public.workspace_meeting_section_timers set elapsed_seconds=case when operation='reset' then 0 else elapsed_seconds+
    case when is_running then floor(greatest(0,extract(epoch from moment-started_at))+pause_fraction)::int else 0 end end,
    pause_fraction=case when operation='reset' then 0 when is_running then mod(greatest(0,extract(epoch from moment-started_at))+pause_fraction,1) else pause_fraction end,
    is_running=(operation='resume' and section_id is not distinct from active_section),
    started_at=case when operation='resume' and section_id=active_section then moment end,
    updated_at=moment,updated_by=actor where workspace_id=target_workspace and meeting_id=target_meeting;
  update public.workspace_meeting_launch_state set status=case operation when 'reset' then 'cancelled' when 'finish' then 'completed' else 'started' end,
    countdown_for=null,started_event_id=case when operation<>'reset' then started_event_id end,
    started_at=case when operation<>'reset' then started_at end,
    finished_at=case when operation='finish' then moment end,finished_by=case when operation='finish' then actor end,
    updated_at=moment,updated_by=actor where workspace_id=target_workspace and meeting_id=target_meeting;
  perform set_config('unara.lifecycle',target_meeting,true);
  update public.workspace_meetings set data=jsonb_set(data,'{status}',to_jsonb(next_status))
    where workspace_id=target_workspace and id=target_meeting;
  perform set_config('unara.lifecycle','',true);
  insert into public.workspace_meeting_history(workspace_id,meeting_id,actor_id,category,event_type,summary,details)
    values(target_workspace,target_meeting,actor,'live','meeting_'||operation,
      case operation when 'pause' then 'Se pausó la reunión.' when 'resume' then 'Se reanudó la reunión.'
      when 'reset' then 'Se reinició la reunión.' else 'Se finalizó la reunión.' end,'{}');
  if operation='finish' and not exists(select 1 from public.workspace_meetings m left join public.workspace_meeting_launch_state l
    on l.workspace_id=m.workspace_id and l.meeting_id=m.id where m.workspace_id=target_workspace and m.data->>'status'='Finalizada' and l.finished_at is null) then
    for victim in select l.meeting_id,l.finished_at from public.workspace_meeting_launch_state l join public.workspace_meetings m
      on m.workspace_id=l.workspace_id and m.id=l.meeting_id where l.workspace_id=target_workspace and m.data->>'status'='Finalizada'
      order by l.finished_at desc,l.meeting_id offset 10 loop
      insert into public.meeting_retention_log(workspace_id,meeting_id,finished_at) values(target_workspace,victim.meeting_id,victim.finished_at);
      delete from public.workspace_meetings where workspace_id=target_workspace and id=victim.meeting_id;
    end loop;
  end if;
end $$;
revoke all on function public.control_meeting_lifecycle(uuid,text,text) from public,anon;
grant execute on function public.control_meeting_lifecycle(uuid,text,text) to authenticated;
revoke execute on function public.set_workspace_meeting_status(uuid,text,text) from public,anon,authenticated;
create or replace function public.protect_meeting_control_fields()
returns trigger language plpgsql security definer set search_path=public,pg_temp
as $$
declare launch_started boolean:=false; launch_actor uuid;
begin
  if tg_op='UPDATE' and old.data->>'status'='Finalizada' and new.data is distinct from old.data then raise exception 'La reunión ya está finalizada.'; end if;
  if tg_op='INSERT' then
    if coalesce(new.data->>'status','Preparación')<>'Preparación' and not public.is_workspace_admin(new.workspace_id) then
      raise exception 'Solo un administrador puede iniciar o finalizar reuniones.';
    end if;
    if (new.data ? 'assignments' or nullif(new.data->>'host_user_id','') is not null) and not public.is_workspace_admin(new.workspace_id) then
      raise exception 'Solo Propietarios y Administradores pueden designar al Anfitrión o asignar funciones.';
    end if;
    return new;
  end if;
  if new.data->>'status' is distinct from old.data->>'status' and current_setting('unara.lifecycle',true) is distinct from new.id then
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


alter function public.manage_workspace_meeting_live_action(uuid,text,text,text,text,text) rename to manage_workspace_meeting_live_action_stage4;
revoke all on function public.manage_workspace_meeting_live_action_stage4(uuid,text,text,text,text,text) from public,anon,authenticated;
create function public.manage_workspace_meeting_live_action(target_workspace uuid,target_meeting text,live_action text,target_section text default null,source_song text default null,after_item text default null)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(target_workspace::text||':'||target_meeting,0));
  if not exists(select 1 from public.workspace_meetings where workspace_id=target_workspace and id=target_meeting and data->>'status'='En curso') then
    raise exception 'La reunión debe estar en curso.';
  end if;
  perform public.manage_workspace_meeting_live_action_stage4(target_workspace,target_meeting,live_action,target_section,source_song,after_item);
end $$;
revoke all on function public.manage_workspace_meeting_live_action(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.manage_workspace_meeting_live_action(uuid,text,text,text,text,text) to authenticated;

alter function public.manage_workspace_meeting_host_live_action(uuid,text,text,text) rename to manage_workspace_meeting_host_live_action_stage4;
revoke all on function public.manage_workspace_meeting_host_live_action_stage4(uuid,text,text,text) from public,anon,authenticated;
create function public.manage_workspace_meeting_host_live_action(target_workspace uuid,target_meeting text,live_action text,target_section text default null)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(target_workspace::text||':'||target_meeting,0));
  if not exists(select 1 from public.workspace_meetings where workspace_id=target_workspace and id=target_meeting and data->>'status'='En curso') then
    raise exception 'La reunión debe estar en curso.';
  end if;
  perform public.manage_workspace_meeting_host_live_action_stage4(target_workspace,target_meeting,live_action,target_section);
end $$;
revoke all on function public.manage_workspace_meeting_host_live_action(uuid,text,text,text) from public,anon;
grant execute on function public.manage_workspace_meeting_host_live_action(uuid,text,text,text) to authenticated;

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
    if launch_row.status='completed' or exists(select 1 from public.workspace_meetings where workspace_id=target_workspace and id=target_meeting and data->>'status' in ('Pausada','Finalizada')) then raise exception 'Esta reunión no se puede iniciar.'; end if;
    if not (public.is_workspace_admin(target_workspace) or public.is_workspace_editor_or_above(target_workspace) or launch_row.host_user_id is not distinct from actor) then raise exception 'No tienes permiso para iniciar esta reunión.'; end if;
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
