-- RLS scenario test (run against a local DB after the migration, as superuser). Uses auth.users inserts and request.jwt.claim.sub to impersonate users.
\set ON_ERROR_STOP 1
insert into auth.users(id,email,raw_user_meta_data) values
 ('00000000-0000-0000-0000-00000000000a','owner@x.com','{"full_name":"Olivia Owner"}'),
 ('00000000-0000-0000-0000-00000000000b','member@x.com','{}'),
 ('00000000-0000-0000-0000-00000000000c','guest@x.com','{}'),
 ('00000000-0000-0000-0000-00000000000d','outsider@x.com','{}');
select 'profiles created', count(*) from profiles;

-- act as owner
set role authenticated; select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
insert into workspaces(id,name,slug,created_by) values ('11111111-1111-1111-1111-111111111111','Rev growth','rev-growth','00000000-0000-0000-0000-00000000000a');
select 'owner member row', role, status, name from members;
insert into members(workspace_id,name,email,role,status) values
 ('11111111-1111-1111-1111-111111111111','Mia Member','member@x.com','Member','invited'),
 ('11111111-1111-1111-1111-111111111111','Gus Guest','guest@x.com','Guest','invited');
reset role;
-- invited users sign up later -> claim; simulate by re-running claim logic
update members m set user_id=u.id, status='active' from auth.users u where lower(u.email)=lower(m.email) and m.user_id is null;
set role authenticated; select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
insert into projects(id,workspace_id,key,name,created_by,lead_id) values
 ('22222222-2222-2222-2222-222222222221','11111111-1111-1111-1111-111111111111','WEB','Website', (select id from members where role='Owner'),(select id from members where role='Owner')),
 ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','CP','Customer Portal',(select id from members where role='Owner'),(select id from members where role='Owner'));
update projects set access='private' where key='CP';
insert into tasks(project_id,title,status) values ('22222222-2222-2222-2222-222222222221','Wireframes','todo'),('22222222-2222-2222-2222-222222222221','Copy','done'),('22222222-2222-2222-2222-222222222222','Billing','todo');
select 'task keys', key, status, completed_at is not null as completed, workspace_id is not null as ws_filled from tasks order by key;
-- share WEB with guest as "comment"
insert into project_members(project_id,member_id,permission) values ('22222222-2222-2222-2222-222222222221',(select id from members where email='guest@x.com'),'comment');

-- member: sees WEB not CP, can edit tasks
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000b',false);
select 'member sees projects', string_agg(key, ',' order by key) from projects;
select 'member sees tasks', count(*) from tasks;
update tasks set status='review' where title='Wireframes';
select 'member edited', status from tasks where title='Wireframes';

-- guest: sees only WEB, cannot edit, can comment
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000c',false);
select 'guest sees projects', string_agg(key, ',') from projects;
update tasks set title='hacked' where title='Wireframes';
select 'guest edit blocked (still Wireframes)', count(*) from tasks where title='Wireframes';
insert into comments(task_id,author_id,body) values ((select id from tasks where title='Wireframes'),(select id from members where user_id=auth.uid()),'Looks good');
select 'guest commented', count(*) from comments;

-- outsider sees nothing
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000d',false);
select 'outsider sees', (select count(*) from workspaces) ws, (select count(*) from projects) p, (select count(*) from tasks) t, (select count(*) from members) m;
do $$ begin
  begin insert into tasks(project_id,title) values ('22222222-2222-2222-2222-222222222221','x'); raise notice 'FAIL outsider inserted';
  exception when insufficient_privilege then raise notice 'outsider insert blocked'; end;
end $$;

-- owner: private project visible because owner is project member; move task to CP re-keys
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000a',false);
select 'owner sees projects', string_agg(key, ',' order by key) from projects;
update tasks set project_id='22222222-2222-2222-2222-222222222222' where title='Copy';
update tasks set status='todo' where title='Copy';
select 'moved task', key, completed_at is null as reopened from tasks where title='Copy';
