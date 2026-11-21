alter table public.workspace_meeting_launch_state
  add column section_launch uuid,
  add column section_event uuid,
  add column section_id text,
  add column section_changed_at timestamptz;

create function public.record_live_section_navigation()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
  update public.workspace_meeting_launch_state
  set section_launch=started_event_id, section_event=gen_random_uuid(),
      section_id=new.current_section_id, section_changed_at=clock_timestamp()
  where workspace_id=new.workspace_id and meeting_id=new.meeting_id
    and status='started' and started_event_id is not null;
  return new;
end $$;
revoke all on function public.record_live_section_navigation() from public,anon,authenticated;
create trigger record_live_section_navigation after update of current_section_id
on public.workspace_meeting_live_state for each row
when (new.current_section_id is not null and old.current_section_id is distinct from new.current_section_id)
execute function public.record_live_section_navigation();

create or replace function public.my_meeting_navigation(target_workspace uuid)
returns table(meeting_id text,event_key text,screen text) language sql stable security definer
set search_path=public,pg_temp as $$
  select l.meeting_id,
    case when l.status='started' then coalesce(e.section_event::text,l.started_event_id::text) else l.countdown_for::text end,
    case when l.status='started' then coalesce(e.section_id,m.data#>>'{agenda,sections,0,id}',
      case when m.data->'agenda' is null and jsonb_array_length(m.data->'songs')>0 then 'legacy-repertoire' end,'general') else 'general' end
  from public.workspace_meeting_launch_state l join public.workspace_meetings m on m.id=l.meeting_id and m.workspace_id=l.workspace_id
  left join lateral (
    select l.section_event, l.section_id, l.section_changed_at where l.section_launch=l.started_event_id
  ) e on true
  where l.workspace_id=target_workspace and public.is_workspace_member(target_workspace)
    and (l.host_user_id=auth.uid() or exists(select 1 from public.workspace_meeting_assignments a where
      a.workspace_id=l.workspace_id and a.meeting_id=l.meeting_id and a.user_id=auth.uid()))
    and ((l.status='scheduled' and l.scheduled_at=l.countdown_for and l.scheduled_at>now() and l.scheduled_at<=now()+interval '60 seconds')
      or (l.status='started' and m.data->>'status'='En curso' and l.started_event_id is not null))
  order by case when l.status='started' then coalesce(e.section_changed_at,l.started_at) else l.scheduled_at-interval '60 seconds' end desc,
    (l.status='started') desc,l.meeting_id
$$;
revoke all on function public.my_meeting_navigation(uuid) from public,anon;
grant execute on function public.my_meeting_navigation(uuid) to authenticated;
