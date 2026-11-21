-- Isolated PostgreSQL test harness only. Never run against production.
BEGIN;
do $$
declare owner_id uuid:=gen_random_uuid(); host uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();ws uuid:=gen_random_uuid(); other_ws uuid:=gen_random_uuid(); mid text; outcome text;
begin
insert into auth.users(id) values(owner_id),(host),(outsider);
perform set_config('test.actor',owner_id::text,true);
insert into workspaces(id,name,created_by) values(ws,'test',owner_id),(other_ws,'other',owner_id);
insert into workspace_members(workspace_id,user_id,workspace_role) values(ws,owner_id,'Propietario'),(ws,host,'Integrante'),(ws,outsider,'Editor'),(other_ws,owner_id,'Propietario');
insert into workspace_songs values(ws,'keep','{}');
for i in 1..11 loop
mid:='test-'||i;
perform set_config('test.actor',owner_id::text,true);
insert into workspace_meetings(workspace_id,id,data) values(ws,mid,jsonb_build_object('id',mid,'status','Preparación','host_user_id',host,'date','2030-02-10','time','12:00','songs','[]'::jsonb,'agenda','{"sections":[{"id":"first","type":"adoracion","items":[]}]}'::jsonb));
update workspace_meeting_launch_state set scheduled_at=now()+interval '30 seconds' where workspace_id=ws and meeting_id=mid;
perform process_due_workspace_meeting_starts();
perform set_config('test.actor',host::text,true);
assert exists(select 1 from my_meeting_navigation(ws) where meeting_id=mid and screen='general');
perform set_config('test.actor',outsider::text,true);
assert not exists(select 1 from my_meeting_navigation(ws) where meeting_id=mid);
begin perform control_meeting_lifecycle(ws,mid,'finish');raise exception 'editor unexpectedly authorized';exception when others then if sqlerrm not like 'No tienes permiso%' then raise;end if;end;
perform set_config('test.actor',host::text,true);
if i%2=0 then
update workspace_meeting_launch_state set scheduled_at=now()-interval '2 seconds' where workspace_id=ws and meeting_id=mid;
perform set_config('test.actor','',true);perform process_due_workspace_meeting_starts();perform set_config('test.actor',host::text,true);
else perform manage_workspace_meeting_launch_action(ws,mid,'start_now');end if;
assert exists(select 1 from my_meeting_navigation(ws) where meeting_id=mid and screen='first');
perform control_meeting_lifecycle(ws,mid,'pause');
assert not exists(select 1 from workspace_meeting_section_timers where workspace_id=ws and meeting_id=mid and is_running);
perform control_meeting_lifecycle(ws,mid,'resume');
perform control_meeting_lifecycle(ws,mid,'pause');
perform control_meeting_lifecycle(ws,mid,'reset');
perform process_due_workspace_meeting_starts();
assert (select data->>'status' from workspace_meetings where workspace_id=ws and id=mid)='Preparación';
perform manage_workspace_meeting_launch_action(ws,mid,'start_now');
if i%2=0 then perform control_meeting_lifecycle(ws,mid,'pause');end if;
perform control_meeting_lifecycle(ws,mid,'finish');
begin perform control_meeting_lifecycle(ws,mid,'finish');raise exception 'duplicate finish';exception when others then if sqlerrm not like 'La reunión ya cambió%' then raise;end if;end;
end loop;
assert (select count(*) from workspace_meetings where workspace_id=ws)=10;
assert not exists(select 1 from workspace_meetings where workspace_id=ws and id='test-1');
assert exists(select 1 from meeting_retention_log where workspace_id=ws and meeting_id='test-1');
assert exists(select 1 from workspace_songs where workspace_id=ws and id='keep');
end $$;

ROLLBACK;
