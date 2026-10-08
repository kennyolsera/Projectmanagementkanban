-- =====================================================================
-- Project management Rev growth: initial Supabase schema
-- Source of truth for fields: src/data/seed.js, createTask()/createProject()
-- in src/actions/actions.js, and the share/team/view actions.
-- Every app field is mapped in .10x/specs/2026-10-08-supabase-data-model-design.md
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Enums (match src/core/constants.js exactly)
-- ---------------------------------------------------------------------
create type public.task_status     as enum ('backlog', 'todo', 'progress', 'review', 'done');
create type public.task_priority   as enum ('urgent', 'high', 'medium', 'low', 'none');
create type public.project_status  as enum ('planning', 'active', 'risk', 'hold', 'complete');
create type public.member_role     as enum ('Owner', 'Admin', 'Member', 'Guest');
create type public.member_status   as enum ('active', 'invited', 'deactivated');
create type public.project_access  as enum ('workspace', 'private');
create type public.project_perm    as enum ('view', 'comment', 'edit', 'full');   -- UI: Can view / Can comment / Can edit / Full access
create type public.notif_type      as enum ('mention', 'assign', 'comment', 'update');
create type public.view_layout     as enum ('list', 'board', 'table');
create type public.workspace_plan  as enum ('Free', 'Team', 'Business');

-- ---------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- profiles: one per auth user (personal prefs; was S.prefs, S.views, notifPrefs, recentSearches)
-- ---------------------------------------------------------------------
create table public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  full_name        text not null default '',
  title            text not null default '',
  color            text not null default '#5A67D8',
  timezone         text not null default 'UTC',
  prefs            jsonb not null default '{}'::jsonb,   -- theme, accent, side, density, weekStart, dateFmt, lang, tz, motion, home, openTasks
  view_settings    jsonb not null default '{}'::jsonb,   -- S.views: { "<viewKey>": {filters, sort, group, q, hidden, colW, showDone, mode} }
  notif_prefs      jsonb not null default '{}'::jsonb,   -- email_mention, email_assign, email_digest, email_comment, push_*, mention_all, assign_self
  recent_searches  text[] not null default '{}',
  sidebar_collapsed boolean not null default false,
  last_workspace_id uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create trigger profiles_updated before update on public.profiles for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- workspaces (was data.ws + data.workspaces)
-- ---------------------------------------------------------------------
create table public.workspaces (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) between 1 and 80),
  slug        text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),   -- ws.url
  color       text not null default '#1D1C1A',                                     -- ws.c
  plan        public.workspace_plan not null default 'Free',
  brand       boolean not null default false,
  created_by  uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger workspaces_updated before update on public.workspaces for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- teams (was data.teams / TEAMS_SEED)
-- ---------------------------------------------------------------------
create table public.teams (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces (id) on delete cascade,
  name          text not null check (length(trim(name)) between 1 and 60),
  description   text not null default '',
  icon          text not null default 'users',
  color         text not null default '#23918A',          -- team.c
  created_at    timestamptz not null default now(),
  unique (workspace_id, name)
);

-- ---------------------------------------------------------------------
-- members: a person inside a workspace (was data.members). user_id is null while invited.
-- ---------------------------------------------------------------------
create table public.members (
  id              uuid primary key default gen_random_uuid(),
  workspace_id    uuid not null references public.workspaces (id) on delete cascade,
  user_id         uuid references auth.users (id) on delete set null,
  name            text not null,
  email           text not null check (email ~* '^\S+@\S+\.\S+$'),
  role            public.member_role not null default 'Member',
  status          public.member_status not null default 'invited',
  team_id         uuid references public.teams (id) on delete set null,   -- '' / No team => null
  title           text not null default '',
  color           text not null default '#6B7280',                        -- member.c (avatar)
  timezone        text not null default '',                               -- member.tz (display city)
  last_active_at  timestamptz,                                            -- member.last (mins ago) is derived from this
  invited_by      uuid references public.members (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (workspace_id, email),
  unique (workspace_id, user_id)
);
create index members_user_idx on public.members (user_id);
create trigger members_updated before update on public.members for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- projects (was data.projects + data.projOrder)
-- ---------------------------------------------------------------------
create table public.projects (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces (id) on delete cascade,
  key           text not null check (key ~ '^[A-Z]{1,8}$'),               -- e.g. WEB
  name          text not null check (length(trim(name)) between 1 and 120),
  description   text not null default '',
  icon          text not null default 'folder',
  color         text not null default 'indigo'
                check (color in ('indigo','blue','violet','teal','rose','amber','green','slate')),
  status        public.project_status not null default 'planning',
  team_id       uuid references public.teams (id) on delete set null,
  lead_id       uuid references public.members (id) on delete set null,
  start_date    date,
  due_date      date,
  access        public.project_access not null default 'workspace',     -- seed `private: true` => 'private'
  task_seq      integer not null default 200,                           -- p.seq, next task number
  position      double precision not null default 0,                    -- projOrder (sidebar order)
  archived_at   timestamptz,
  created_by    uuid references public.members (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),                     -- p.last is derived from this
  unique (workspace_id, key),
  check (due_date is null or start_date is null or due_date >= start_date)
);
create index projects_ws_idx on public.projects (workspace_id, position);
create trigger projects_updated before update on public.projects for each row execute function public.set_updated_at();

-- project_members: p.members[] + p.perms{}
create table public.project_members (
  project_id  uuid not null references public.projects (id) on delete cascade,
  member_id   uuid not null references public.members (id) on delete cascade,
  permission  public.project_perm not null default 'edit',
  added_at    timestamptz not null default now(),
  primary key (project_id, member_id)
);
create index project_members_member_idx on public.project_members (member_id);

-- milestones: p.milestones[]
create table public.milestones (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid not null references public.projects (id) on delete cascade,
  name        text not null,
  date        date not null,
  created_at  timestamptz not null default now()
);
create index milestones_project_idx on public.milestones (project_id, date);

-- project_favorites: p.fav (per user, not global)
create table public.project_favorites (
  member_id   uuid not null references public.members (id) on delete cascade,
  project_id  uuid not null references public.projects (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (member_id, project_id)
);

-- ---------------------------------------------------------------------
-- tasks (was data.tasks)
-- ---------------------------------------------------------------------
create table public.tasks (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces (id) on delete cascade,
  project_id    uuid not null references public.projects (id) on delete cascade,
  key           text not null,                                          -- e.g. WEB-201 (set by trigger)
  title         text not null default 'Untitled' check (length(title) <= 500),
  description   text not null default '',                               -- t.desc (sanitised HTML)
  status        public.task_status not null default 'todo',
  prev_status   public.task_status,                                     -- t.prevStatus (undo complete)
  priority      public.task_priority not null default 'none',
  assignee_id   uuid references public.members (id) on delete set null,
  start_date    date,
  due_date      date,
  labels        text[] not null default '{}'
                check (labels <@ array['design','frontend','backend','research','content','bug','qa','growth']),
  estimate      text check (estimate is null or estimate ~ '^\d+(\.\d+)?\s?[hdw]$'),   -- '2d', '4h'
  recur         text check (recur is null or recur in ('Daily','Weekly','Every 2 weeks','Monthly')),
  position      double precision not null default 0,                    -- t.order
  completed_at  timestamptz,
  archived_at   timestamptz,
  archived      boolean generated always as (archived_at is not null) stored,
  created_by    uuid references public.members (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (project_id, key),
  check (due_date is null or start_date is null or due_date >= start_date)
);
create index tasks_project_idx  on public.tasks (project_id, status, position) where archived_at is null;
create index tasks_assignee_idx on public.tasks (assignee_id) where archived_at is null;
create index tasks_due_idx      on public.tasks (workspace_id, due_date) where archived_at is null and status <> 'done';
create index tasks_labels_idx   on public.tasks using gin (labels);
create trigger tasks_updated before update on public.tasks for each row execute function public.set_updated_at();

-- task key (PROJ-seq, same as nextKey(p)), workspace_id and completed_at bookkeeping
create or replace function public.tasks_before_write() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_ws   uuid;
  v_key  text;
  v_seq  integer;
begin
  select workspace_id, key into v_ws, v_key from public.projects where id = new.project_id;
  new.workspace_id := v_ws;
  if tg_op = 'INSERT' and coalesce(new.key, '') = '' then
    update public.projects set task_seq = task_seq + 1 where id = new.project_id returning task_seq into v_seq;
    new.key := v_key || '-' || v_seq;
  elsif tg_op = 'UPDATE' and new.project_id <> old.project_id then
    -- moving a task to another project gives it a key in that project (same as nextKey(p) in the app)
    update public.projects set task_seq = task_seq + 1 where id = new.project_id returning task_seq into v_seq;
    new.key := v_key || '-' || v_seq;
  end if;
  if new.status = 'done' and (tg_op = 'INSERT' or old.status <> 'done') then
    new.completed_at := coalesce(new.completed_at, now());
  elsif new.status <> 'done' then
    new.completed_at := null;
  end if;
  return new;
end $$;
create trigger tasks_before_write before insert or update on public.tasks
  for each row execute function public.tasks_before_write();

-- subtasks: t.subtasks[] {id, title, done}
create table public.subtasks (
  id          uuid primary key default gen_random_uuid(),
  task_id     uuid not null references public.tasks (id) on delete cascade,
  title       text not null check (length(trim(title)) between 1 and 300),
  done        boolean not null default false,
  position    double precision not null default 0,
  created_at  timestamptz not null default now()
);
create index subtasks_task_idx on public.subtasks (task_id, position);

-- task_dependencies: t.deps[] (this task is blocked by depends_on)
create table public.task_dependencies (
  task_id        uuid not null references public.tasks (id) on delete cascade,
  depends_on_id  uuid not null references public.tasks (id) on delete cascade,
  primary key (task_id, depends_on_id),
  check (task_id <> depends_on_id)
);

-- task_favorites: t.fav (per user)
create table public.task_favorites (
  member_id   uuid not null references public.members (id) on delete cascade,
  task_id     uuid not null references public.tasks (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (member_id, task_id)
);

-- ---------------------------------------------------------------------
-- comments + reactions (was data.comments, c.re = {emoji: [memberIds]})
-- ---------------------------------------------------------------------
create table public.comments (
  id          uuid primary key default gen_random_uuid(),
  task_id     uuid not null references public.tasks (id) on delete cascade,
  author_id   uuid references public.members (id) on delete set null,
  body        text not null check (length(trim(body)) between 1 and 10000),   -- c.text
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index comments_task_idx on public.comments (task_id, created_at);
create trigger comments_updated before update on public.comments for each row execute function public.set_updated_at();

create table public.comment_reactions (
  comment_id  uuid not null references public.comments (id) on delete cascade,
  member_id   uuid not null references public.members (id) on delete cascade,
  emoji       text not null check (length(emoji) between 1 and 16),
  created_at  timestamptz not null default now(),
  primary key (comment_id, member_id, emoji)
);

-- ---------------------------------------------------------------------
-- files: data.files AND t.attachments (an attachment is a file with task_id set)
-- binary content lives in Supabase Storage bucket `files` at storage_path
-- ---------------------------------------------------------------------
create table public.files (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces (id) on delete cascade,
  project_id    uuid not null references public.projects (id) on delete cascade,
  task_id       uuid references public.tasks (id) on delete set null,
  name          text not null,
  type          text not null default 'file'
                check (type in ('fig','pdf','zip','img','sheet','doc','code','video','file')),   -- fileType()
  size_bytes    bigint not null default 0 check (size_bytes >= 0),                                -- app shows fsize()
  storage_path  text unique,
  uploaded_by   uuid references public.members (id) on delete set null,
  created_at    timestamptz not null default now()
);
create index files_project_idx on public.files (project_id, created_at desc);
create index files_task_idx    on public.files (task_id) where task_id is not null;

-- ---------------------------------------------------------------------
-- calendar events (was data.events)
-- ---------------------------------------------------------------------
create table public.events (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces (id) on delete cascade,
  project_id    uuid references public.projects (id) on delete cascade,
  title         text not null,
  date          date not null,
  time          time,
  created_by    uuid references public.members (id) on delete set null,
  created_at    timestamptz not null default now()
);
create index events_ws_date_idx on public.events (workspace_id, date);

-- ---------------------------------------------------------------------
-- activity feed (was data.activity, written by logAct)
-- ---------------------------------------------------------------------
create table public.activity (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces (id) on delete cascade,
  actor_id      uuid references public.members (id) on delete set null,   -- a.by
  verb          text not null,                                           -- 'created', 'moved', 'completed', ...
  task_id       uuid references public.tasks (id) on delete cascade,
  project_id    uuid references public.projects (id) on delete cascade,
  extra         text not null default '',
  created_at    timestamptz not null default now()                       -- a.at
);
create index activity_ws_idx      on public.activity (workspace_id, created_at desc);
create index activity_project_idx on public.activity (project_id, created_at desc);
create index activity_task_idx    on public.activity (task_id, created_at desc);

-- ---------------------------------------------------------------------
-- notifications / inbox (was data.notifs; recipient was implicitly `me`)
-- ---------------------------------------------------------------------
create table public.notifications (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces (id) on delete cascade,
  recipient_id  uuid not null references public.members (id) on delete cascade,
  type          public.notif_type not null,
  actor_id      uuid references public.members (id) on delete set null,   -- n.by (null = system)
  task_id       uuid references public.tasks (id) on delete cascade,
  project_id    uuid references public.projects (id) on delete cascade,
  text          text not null,
  snippet       text not null default '',
  read          boolean not null default false,
  created_at    timestamptz not null default now()
);
create index notifications_recipient_idx on public.notifications (recipient_id, read, created_at desc);

-- ---------------------------------------------------------------------
-- saved views (was data.savedViews)
-- ---------------------------------------------------------------------
create table public.saved_views (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces (id) on delete cascade,
  project_id    uuid not null references public.projects (id) on delete cascade,
  owner_id      uuid references public.members (id) on delete set null,
  name          text not null default 'Untitled view',
  layout        public.view_layout not null default 'list',            -- sv.type
  filters       jsonb not null default '[]'::jsonb,                    -- [{f, op, v:[]}]
  created_at    timestamptz not null default now()
);

-- workspace_id on child rows is always derived from the project (cannot be spoofed)
create or replace function public.fill_workspace_from_project() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.project_id is not null then
    select workspace_id into new.workspace_id from public.projects where id = new.project_id;
  end if;
  return new;
end $$;
create trigger files_ws       before insert or update on public.files       for each row execute function public.fill_workspace_from_project();
create trigger events_ws      before insert or update on public.events      for each row execute function public.fill_workspace_from_project();
create trigger saved_views_ws before insert or update on public.saved_views for each row execute function public.fill_workspace_from_project();

-- =====================================================================
-- Access helpers (security definer so RLS policies can call them without recursion)
-- =====================================================================
create or replace function public.my_member_id(ws uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.members where workspace_id = ws and user_id = auth.uid() and status = 'active' limit 1
$$;

create or replace function public.is_ws_member(ws uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where workspace_id = ws and user_id = auth.uid() and status = 'active')
$$;

create or replace function public.ws_role(ws uuid) returns public.member_role
language sql stable security definer set search_path = public as $$
  select role from public.members where workspace_id = ws and user_id = auth.uid() and status = 'active' limit 1
$$;

create or replace function public.is_ws_admin(ws uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.ws_role(ws) in ('Owner', 'Admin'), false)
$$;

-- canSee(p) from the app: a workspace-access project is visible to every non-guest member;
-- a private project (and anything for Guests) only to its project members.
create or replace function public.can_see_project(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.projects p
    join public.members m on m.workspace_id = p.workspace_id and m.user_id = auth.uid() and m.status = 'active'
    where p.id = pid
      and (
        (p.access = 'workspace' and m.role <> 'Guest')
        or exists (select 1 from public.project_members pm where pm.project_id = p.id and pm.member_id = m.id)
      )
  )
$$;

-- returns the caller's effective permission on a project
create or replace function public.project_perm_of(pid uuid) returns public.project_perm
language sql stable security definer set search_path = public as $$
  select case
    when not public.can_see_project(pid) then null
    when m.role in ('Owner', 'Admin') then 'full'::public.project_perm
    when p.lead_id = m.id then 'full'::public.project_perm
    when pm.permission is not null then pm.permission
    when p.access = 'workspace' and m.role = 'Member' then 'edit'::public.project_perm
    else null
  end
  from public.projects p
  join public.members m on m.workspace_id = p.workspace_id and m.user_id = auth.uid() and m.status = 'active'
  left join public.project_members pm on pm.project_id = p.id and pm.member_id = m.id
  where p.id = pid
  limit 1
$$;

create or replace function public.can_edit_project(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.project_perm_of(pid) in ('edit', 'full'), false)
$$;

create or replace function public.can_comment_project(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.project_perm_of(pid) in ('comment', 'edit', 'full'), false)
$$;

create or replace function public.task_project(tid uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select project_id from public.tasks where id = tid
$$;

-- =====================================================================
-- Bootstrap triggers
-- =====================================================================
-- new auth user -> profile; claim any pending invites sent to the same email
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  update public.members
     set user_id = new.id, status = 'active'
   where lower(email) = lower(new.email) and user_id is null and status = 'invited';
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- creator of a workspace becomes its Owner
create or replace function public.handle_new_workspace() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_name  text;
  v_email text;
begin
  select coalesce(p.full_name, ''), u.email into v_name, v_email
  from auth.users u left join public.profiles p on p.id = u.id where u.id = auth.uid();
  if auth.uid() is not null then
    insert into public.members (workspace_id, user_id, name, email, role, status, last_active_at)
    values (new.id, auth.uid(), coalesce(nullif(v_name, ''), split_part(v_email, '@', 1)), v_email, 'Owner', 'active', now());
  end if;
  return new;
end $$;
create trigger on_workspace_created after insert on public.workspaces
  for each row execute function public.handle_new_workspace();

-- project creator + lead are added as project members (createProject: members = [me, lead])
create or replace function public.handle_new_project() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.created_by is not null then
    insert into public.project_members (project_id, member_id, permission) values (new.id, new.created_by, 'full') on conflict do nothing;
  end if;
  if new.lead_id is not null then
    insert into public.project_members (project_id, member_id, permission) values (new.id, new.lead_id, 'full') on conflict do nothing;
  end if;
  return new;
end $$;
create trigger on_project_created after insert on public.projects
  for each row execute function public.handle_new_project();

-- =====================================================================
-- Row Level Security
-- =====================================================================
alter table public.profiles          enable row level security;
alter table public.workspaces        enable row level security;
alter table public.teams             enable row level security;
alter table public.members           enable row level security;
alter table public.projects          enable row level security;
alter table public.project_members   enable row level security;
alter table public.milestones        enable row level security;
alter table public.project_favorites enable row level security;
alter table public.tasks             enable row level security;
alter table public.subtasks          enable row level security;
alter table public.task_dependencies enable row level security;
alter table public.task_favorites    enable row level security;
alter table public.comments          enable row level security;
alter table public.comment_reactions enable row level security;
alter table public.files             enable row level security;
alter table public.events            enable row level security;
alter table public.activity          enable row level security;
alter table public.notifications     enable row level security;
alter table public.saved_views       enable row level security;

-- profiles: own row only
create policy profiles_self on public.profiles for all
  using (id = auth.uid()) with check (id = auth.uid());

-- workspaces
create policy ws_select on public.workspaces for select using (public.is_ws_member(id));
create policy ws_insert on public.workspaces for insert with check (auth.uid() is not null and created_by = auth.uid());
create policy ws_update on public.workspaces for update using (public.is_ws_admin(id)) with check (public.is_ws_admin(id));
create policy ws_delete on public.workspaces for delete using (public.ws_role(id) = 'Owner');

-- teams
create policy teams_select on public.teams for select using (public.is_ws_member(workspace_id));
create policy teams_write  on public.teams for all
  using (public.is_ws_admin(workspace_id)) with check (public.is_ws_admin(workspace_id));

-- members: everyone in the workspace can see the roster; admins manage it; you can edit your own display fields
create policy members_select on public.members for select
  using (public.is_ws_member(workspace_id) or user_id = auth.uid());
create policy members_admin on public.members for all
  using (public.is_ws_admin(workspace_id)) with check (public.is_ws_admin(workspace_id));
create policy members_self_update on public.members for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());
-- non-admin Members may invite Guests when sharing a project (A.shareAdd)
create policy members_invite_guest on public.members for insert
  with check (public.ws_role(workspace_id) = 'Member' and role = 'Guest' and status = 'invited' and user_id is null);

-- projects
create policy projects_select on public.projects for select using (public.can_see_project(id));
create policy projects_insert on public.projects for insert
  with check (public.ws_role(workspace_id) in ('Owner', 'Admin', 'Member'));
create policy projects_update on public.projects for update
  using (public.can_edit_project(id)) with check (public.ws_role(workspace_id) is not null);
create policy projects_delete on public.projects for delete
  using (public.project_perm_of(id) = 'full');

-- project_members
create policy pm_select on public.project_members for select using (public.can_see_project(project_id));
create policy pm_write  on public.project_members for all
  using (public.project_perm_of(project_id) = 'full' or public.can_edit_project(project_id))
  with check (public.project_perm_of(project_id) = 'full' or public.can_edit_project(project_id));

-- milestones
create policy ms_select on public.milestones for select using (public.can_see_project(project_id));
create policy ms_write  on public.milestones for all
  using (public.can_edit_project(project_id)) with check (public.can_edit_project(project_id));

-- favourites: own rows, on things you can see
create policy pfav_self on public.project_favorites for all
  using (member_id in (select id from public.members where user_id = auth.uid()))
  with check (member_id in (select id from public.members where user_id = auth.uid()) and public.can_see_project(project_id));
create policy tfav_self on public.task_favorites for all
  using (member_id in (select id from public.members where user_id = auth.uid()))
  with check (member_id in (select id from public.members where user_id = auth.uid()) and public.can_see_project(public.task_project(task_id)));

-- tasks
create policy tasks_select on public.tasks for select using (public.can_see_project(project_id));
create policy tasks_insert on public.tasks for insert with check (public.can_edit_project(project_id));
create policy tasks_update on public.tasks for update
  using (public.can_edit_project(project_id)) with check (public.can_edit_project(project_id));
create policy tasks_delete on public.tasks for delete using (public.can_edit_project(project_id));

-- subtasks / dependencies follow their task
create policy sub_select on public.subtasks for select using (public.can_see_project(public.task_project(task_id)));
create policy sub_write  on public.subtasks for all
  using (public.can_edit_project(public.task_project(task_id)))
  with check (public.can_edit_project(public.task_project(task_id)));
create policy dep_select on public.task_dependencies for select using (public.can_see_project(public.task_project(task_id)));
create policy dep_write  on public.task_dependencies for all
  using (public.can_edit_project(public.task_project(task_id)))
  with check (public.can_edit_project(public.task_project(task_id)));

-- comments: commenters can post; authors edit/delete their own; admins/full can delete any
create policy com_select on public.comments for select using (public.can_see_project(public.task_project(task_id)));
create policy com_insert on public.comments for insert
  with check (public.can_comment_project(public.task_project(task_id))
              and author_id in (select id from public.members where user_id = auth.uid()));
create policy com_update on public.comments for update
  using (author_id in (select id from public.members where user_id = auth.uid()))
  with check (author_id in (select id from public.members where user_id = auth.uid()));
create policy com_delete on public.comments for delete
  using (author_id in (select id from public.members where user_id = auth.uid())
         or public.project_perm_of(public.task_project(task_id)) = 'full');

create policy react_select on public.comment_reactions for select
  using (exists (select 1 from public.comments c where c.id = comment_id and public.can_see_project(public.task_project(c.task_id))));
create policy react_self on public.comment_reactions for all
  using (member_id in (select id from public.members where user_id = auth.uid()))
  with check (member_id in (select id from public.members where user_id = auth.uid())
              and exists (select 1 from public.comments c where c.id = comment_id and public.can_comment_project(public.task_project(c.task_id))));

-- files
create policy files_select on public.files for select using (public.can_see_project(project_id));
create policy files_write  on public.files for all
  using (public.can_edit_project(project_id)) with check (public.can_edit_project(project_id));

-- events: project events follow the project; workspace-level events (no project) are visible to members
create policy events_select on public.events for select
  using (case when project_id is null then public.is_ws_member(workspace_id) else public.can_see_project(project_id) end);
create policy events_write on public.events for all
  using (case when project_id is null then public.is_ws_admin(workspace_id) else public.can_edit_project(project_id) end)
  with check (case when project_id is null then public.is_ws_admin(workspace_id) else public.can_edit_project(project_id) end);

-- activity: readable where the project is visible; append-only by the actor
create policy act_select on public.activity for select
  using (case when project_id is null then public.is_ws_member(workspace_id) else public.can_see_project(project_id) end);
create policy act_insert on public.activity for insert
  with check (public.is_ws_member(workspace_id) and actor_id = public.my_member_id(workspace_id));

-- notifications: recipient reads/updates/deletes; any workspace member may notify another member
create policy notif_own on public.notifications for select
  using (recipient_id in (select id from public.members where user_id = auth.uid()));
create policy notif_update on public.notifications for update
  using (recipient_id in (select id from public.members where user_id = auth.uid()))
  with check (recipient_id in (select id from public.members where user_id = auth.uid()));
create policy notif_delete on public.notifications for delete
  using (recipient_id in (select id from public.members where user_id = auth.uid()));
create policy notif_insert on public.notifications for insert
  with check (public.is_ws_member(workspace_id)
              and exists (select 1 from public.members r where r.id = recipient_id and r.workspace_id = notifications.workspace_id));

-- saved views
create policy sv_select on public.saved_views for select using (public.can_see_project(project_id));
create policy sv_write  on public.saved_views for all
  using (public.can_see_project(project_id)) with check (public.can_see_project(project_id));

-- =====================================================================
-- Storage: private bucket `files`, object path = <workspace_id>/<project_id>/<file_id>-<name>
-- =====================================================================
insert into storage.buckets (id, name, public) values ('files', 'files', false) on conflict (id) do nothing;

create policy "files read" on storage.objects for select
  using (bucket_id = 'files' and public.can_see_project(((storage.foldername(name))[2])::uuid));
create policy "files write" on storage.objects for insert
  with check (bucket_id = 'files' and public.can_edit_project(((storage.foldername(name))[2])::uuid));
create policy "files delete" on storage.objects for delete
  using (bucket_id = 'files' and public.can_edit_project(((storage.foldername(name))[2])::uuid));

-- =====================================================================
-- Realtime: stream changes for live multi-user boards
-- =====================================================================
alter publication supabase_realtime add table
  public.projects, public.project_members, public.tasks, public.subtasks, public.comments,
  public.comment_reactions, public.files, public.activity, public.notifications, public.members, public.teams;
