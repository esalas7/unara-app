begin;

create table if not exists public.workspace_meeting_history (
  id bigint generated always as identity primary key,
  workspace_id uuid not null,
  meeting_id text not null,
  actor_id uuid not null references auth.users(id) on delete restrict,
  occurred_at timestamptz not null default now(),
  category text not null check (category in ('planning','publication','live')),
  event_type text not null,
  summary text not null,
  details jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object'),
  published_version bigint,
  foreign key (workspace_id, meeting_id)
    references public.workspace_meetings(workspace_id, id) on delete cascade
);

create index if not exists workspace_meeting_history_page_idx
  on public.workspace_meeting_history(workspace_id, meeting_id, occurred_at desc, id desc);
alter table public.workspace_meeting_history enable row level security;
drop policy if exists "Editors can read meeting history" on public.workspace_meeting_history;
create policy "Editors can read meeting history" on public.workspace_meeting_history
  for select to authenticated
  using (public.is_workspace_editor_or_above(workspace_id));
revoke all on public.workspace_meeting_history from public, anon, authenticated;
grant select on public.workspace_meeting_history to authenticated;

create or replace function public.get_workspace_meeting_history(target_workspace uuid, target_meeting text, before_id bigint default null, page_size integer default 30)
returns table(id bigint, actor_id uuid, actor_name text, occurred_at timestamptz, category text, event_type text, summary text, details jsonb, published_version bigint)
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null or not public.is_workspace_editor_or_above(target_workspace) then
    raise exception 'Solo Propietarios, Administradores y Editores pueden consultar el historial.';
  end if;
  if not exists (select 1 from public.workspace_meetings m where m.workspace_id=target_workspace and m.id=target_meeting) then
    raise exception 'No encontramos esta reunión.';
  end if;
  return query
    select h.id, h.actor_id, coalesce(p.full_name, 'Usuario del equipo'), h.occurred_at,
      h.category, h.event_type, h.summary, h.details, h.published_version
    from public.workspace_meeting_history h
    left join public.profiles p on p.id=h.actor_id
    where h.workspace_id=target_workspace and h.meeting_id=target_meeting
      and (before_id is null or h.id < before_id)
    order by h.id desc limit least(greatest(coalesce(page_size,30),1),50);
end;
$$;

-- Replace publication with an atomic wrapper: the existing permission, version,
-- assignment, notification, and draft cleanup logic remains authoritative.
do $$ begin
  if to_regprocedure('public.publish_workspace_meeting_draft_before_history(uuid,text,bigint,bigint)') is null then
    alter function public.publish_workspace_meeting_draft(uuid,text,bigint,bigint)
      rename to publish_workspace_meeting_draft_before_history;
  end if;
end $$;

create or replace function public.publish_workspace_meeting_draft(target_workspace uuid,target_meeting text,expected_revision bigint,expected_published_version bigint)
returns bigint language plpgsql security definer set search_path=public,pg_temp
as $$
declare old_data jsonb; new_data jsonb; old_assignments jsonb; new_assignments jsonb; changed_fields jsonb:='{}'::jsonb;
  field_name text; next_version bigint; details_data jsonb;
begin
  if auth.uid() is null or not public.is_workspace_editor_or_above(target_workspace) then raise exception 'No tienes permiso para publicar reuniones.'; end if;
  select data into old_data from public.workspace_meetings where workspace_id=target_workspace and id=target_meeting;
  select coalesce(jsonb_agg(jsonb_build_object('user_id',a.user_id,'function_name',a.function_name) order by a.user_id,a.function_name),'[]'::jsonb)
    into old_assignments from public.workspace_meeting_assignments a where a.workspace_id=target_workspace and a.meeting_id=target_meeting;
  next_version:=public.publish_workspace_meeting_draft_before_history(target_workspace,target_meeting,expected_revision,expected_published_version);
  select data into new_data from public.workspace_meetings where workspace_id=target_workspace and id=target_meeting;
  select coalesce(jsonb_agg(jsonb_build_object('user_id',a.user_id,'function_name',a.function_name) order by a.user_id,a.function_name),'[]'::jsonb)
    into new_assignments from public.workspace_meeting_assignments a where a.workspace_id=target_workspace and a.meeting_id=target_meeting;
  for field_name in select key from jsonb_object_keys(coalesce(old_data,'{}'::jsonb) || coalesce(new_data,'{}'::jsonb)) as keys(key)
    where (old_data->key) is distinct from (new_data->key) and key<>'status'
  loop changed_fields:=changed_fields || jsonb_build_object(field_name,jsonb_build_object('old',old_data->field_name,'new',new_data->field_name)); end loop;
  if old_assignments is distinct from new_assignments then
    changed_fields:=changed_fields || jsonb_build_object('assignments',jsonb_build_object('old',old_assignments,'new',new_assignments));
  end if;
  details_data:=jsonb_build_object('changes',changed_fields);
  if old_data is distinct from new_data or old_assignments is distinct from new_assignments then
    insert into public.workspace_meeting_history(workspace_id,meeting_id,actor_id,category,event_type,summary,details,published_version)
    values(target_workspace,target_meeting,auth.uid(),'planning','planning_published','Se publicaron cambios en la planificación.',details_data,next_version);
  end if;
  insert into public.workspace_meeting_history(workspace_id,meeting_id,actor_id,category,event_type,summary,details,published_version)
  values(target_workspace,target_meeting,auth.uid(),'publication','published','Se publicó la versión '||next_version||'.',details_data,next_version);
  return next_version;
end; $$;

-- Keep the current coordinated-clock implementation intact and log one row for
-- each accepted user action rather than each internal paired clock update.
do $$ begin
  if to_regprocedure('public.manage_workspace_meeting_live_action_before_history(uuid,text,text,text,text,text)') is null then
    alter function public.manage_workspace_meeting_live_action(uuid,text,text,text,text,text)
      rename to manage_workspace_meeting_live_action_before_history;
  end if;
end $$;
create or replace function public.manage_workspace_meeting_live_action(target_workspace uuid,target_meeting text,live_action text,target_section text default null,source_song text default null,after_item text default null)
returns void language plpgsql security definer set search_path=public,pg_temp
as $$
declare old_state jsonb; new_state jsonb; old_timer jsonb; new_timer jsonb; song_row public.workspace_meeting_live_songs%rowtype; old_song_ids uuid[];
  event_summary text; event_details jsonb:='{}'::jsonb; should_log boolean:=false; section_name text;
begin
  perform pg_advisory_xact_lock(hashtextextended(target_workspace::text||':'||target_meeting,0));
  if live_action not in ('general_start','general_pause','general_reset','section_start','section_pause','section_reset','add_song') then
    raise exception 'La acción en vivo no es válida.';
  end if;
  select to_jsonb(s) into old_state from public.workspace_meeting_live_state s where s.workspace_id=target_workspace and s.meeting_id=target_meeting;
  if target_section is not null then
    select to_jsonb(t) into old_timer from public.workspace_meeting_section_timers t where t.workspace_id=target_workspace and t.meeting_id=target_meeting and t.section_id=target_section;
    select coalesce(section_data->>'type',target_section) into section_name
      from public.workspace_meetings m cross join lateral jsonb_array_elements(coalesce(m.data->'agenda'->'sections','[]'::jsonb)) s(section_data)
      where m.workspace_id=target_workspace and m.id=target_meeting and section_data->>'id'=target_section limit 1;
    section_name:=coalesce(section_name,target_section);
  end if;
  if live_action='add_song' then
    select coalesce(array_agg(s.id),array[]::uuid[]) into old_song_ids from public.workspace_meeting_live_songs s where s.workspace_id=target_workspace and s.meeting_id=target_meeting;
  end if;
  perform public.manage_workspace_meeting_live_action_before_history(target_workspace,target_meeting,live_action,target_section,source_song,after_item);
  select to_jsonb(s) into new_state from public.workspace_meeting_live_state s where s.workspace_id=target_workspace and s.meeting_id=target_meeting;
  if target_section is not null then select to_jsonb(t) into new_timer from public.workspace_meeting_section_timers t where t.workspace_id=target_workspace and t.meeting_id=target_meeting and t.section_id=target_section; end if;
  if live_action='add_song' then
    select * into song_row from public.workspace_meeting_live_songs s where s.workspace_id=target_workspace and s.meeting_id=target_meeting and s.section_id=target_section and s.song_id=source_song and not (s.id=any(old_song_ids)) order by created_at desc limit 1;
    event_summary:='Se agregó una canción adicional a '||coalesce(section_name,target_section)||'.';
    event_details:=jsonb_build_object('section_id',target_section,'song_id',source_song,'live_song_id',song_row.id,'after_item_id',after_item);
    should_log:=song_row.id is not null;
  elsif live_action like 'general_%' then
    should_log:=(old_state-'updated_at'-'updated_by') is distinct from (new_state-'updated_at'-'updated_by');
    event_summary:=case live_action when 'general_start' then 'Se inició el cronómetro general.' when 'general_pause' then 'Se pausó el cronómetro general.' else 'Se reinició el cronómetro general.' end;
    event_details:=jsonb_build_object('old',old_state,'new',new_state);
  else
    should_log:=(old_state-'updated_at'-'updated_by') is distinct from (new_state-'updated_at'-'updated_by')
      or (old_timer-'updated_at'-'updated_by') is distinct from (new_timer-'updated_at'-'updated_by');
    event_summary:=case live_action when 'section_start' then 'Se inició o reanudó el cronómetro de '||coalesce(section_name,target_section)||'.' when 'section_pause' then 'Se pausó el cronómetro de '||coalesce(section_name,target_section)||'.' else 'Se reinició el cronómetro de '||coalesce(section_name,target_section)||'.' end;
    event_details:=jsonb_build_object('section_id',target_section,'section',section_name,'old_state',old_state,'new_state',new_state,'old_timer',old_timer,'new_timer',new_timer);
  end if;
  if should_log then insert into public.workspace_meeting_history(workspace_id,meeting_id,actor_id,category,event_type,summary,details)
    values(target_workspace,target_meeting,auth.uid(),'live',live_action,event_summary,event_details); end if;
end; $$;

revoke all on function public.get_workspace_meeting_history(uuid,text,bigint,integer) from public,anon,authenticated;
grant execute on function public.get_workspace_meeting_history(uuid,text,bigint,integer) to authenticated;
revoke all on function public.publish_workspace_meeting_draft(uuid,text,bigint,bigint) from public,anon,authenticated;
grant execute on function public.publish_workspace_meeting_draft(uuid,text,bigint,bigint) to authenticated;
revoke all on function public.publish_workspace_meeting_draft_before_history(uuid,text,bigint,bigint) from public,anon,authenticated;
revoke all on function public.manage_workspace_meeting_live_action(uuid,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.manage_workspace_meeting_live_action(uuid,text,text,text,text,text) to authenticated;
revoke all on function public.manage_workspace_meeting_live_action_before_history(uuid,text,text,text,text,text) from public,anon,authenticated;

commit;
