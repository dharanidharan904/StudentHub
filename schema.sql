-- StudentHub schema. Run once in Supabase: SQL Editor > New query > paste > Run.
create extension if not exists pgcrypto;

create table app_settings(key text primary key, value text not null);
alter table app_settings enable row level security;  -- no policies: never readable from the browser
insert into app_settings values('staff_invite','CHANGE-ME-STAFF'),('admin_invite','CHANGE-ME-ADMIN');

create table profiles(
  id uuid primary key references auth.users on delete cascade,
  student_id text unique, full_name text not null, email text not null,
  phone text, notify boolean not null default false,
  role text not null default 'STUDENT' check (role in ('ADMIN','STAFF','STUDENT')),
  department text, year int check (year between 1 and 6), section text,
  is_active boolean not null default true, created_at timestamptz not null default now());

create table actions(
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title)>=3), description text not null,
  action_type text not null default 'OTHER', external_url text,
  deadline timestamptz not null,
  priority text not null default 'NORMAL' check (priority in ('LOW','NORMAL','MEDIUM','HIGH','URGENT')),
  status text not null default 'DRAFT' check (status in ('DRAFT','PUBLISHED','CLOSED','CANCELLED')),
  requires_verification boolean not null default false,
  target_department text, target_year int, target_section text,
  created_by uuid references profiles(id), last_reminder_at timestamptz,
  created_at timestamptz not null default now());

create table student_actions(
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references profiles(id) on delete cascade,
  action_id uuid not null references actions(id) on delete cascade,
  status text not null default 'PENDING' check (status in ('PENDING','OPENED','SUBMITTED','COMPLETED','VERIFICATION_PENDING')),
  assigned_at timestamptz not null default now(), submitted_at timestamptz, completed_at timestamptz,
  unique(student_id, action_id));

create table notifications(
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references profiles(id) on delete cascade,
  action_id uuid references actions(id) on delete cascade,
  title text, message text not null, notification_type text default 'SYSTEM',
  is_read boolean not null default false, created_at timestamptz not null default now());

create table sms_outbox(id uuid primary key default gen_random_uuid(), to_phone text not null, body text not null,
  sent boolean not null default false, created_at timestamptz not null default now());
alter table sms_outbox enable row level security;  -- only the server (service role) reads this

create table audit_logs(id uuid primary key default gen_random_uuid(), user_id uuid, action text, entity_type text, entity_id uuid,
  created_at timestamptz not null default now());
alter table audit_logs enable row level security;

create index on student_actions(student_id); create index on student_actions(action_id);
create index on actions(deadline); create index on actions(status); create index on profiles(department);
create index on notifications(student_id, created_at desc);

create or replace function my_role() returns text language sql stable security definer set search_path=public as
$$ select role from profiles where id=auth.uid() and is_active $$;

-- New sign-up: role comes from the server-checked invite code, never from the browser.
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare m jsonb := new.raw_user_meta_data; r text := coalesce(upper(m->>'role'),'STUDENT');
begin
  if r not in ('STUDENT','STAFF','ADMIN') then r := 'STUDENT'; end if;
  if r <> 'STUDENT' and coalesce(m->>'invite','') <> (select value from app_settings where key = lower(r)||'_invite') then
    raise exception 'Invalid invite code'; end if;
  insert into profiles(id,student_id,full_name,email,role,department,year,section)
  values(new.id, case when r='STUDENT' then upper(m->>'student_id') end, coalesce(m->>'full_name','User'), new.email, r,
         m->>'department', nullif(m->>'year','')::int, m->>'section');
  if r='STUDENT' then  -- catch up on actions published before they registered
    insert into student_actions(student_id,action_id)
    select new.id, a.id from actions a where a.status='PUBLISHED'
      and (a.target_department is null or a.target_department = m->>'department')
      and (a.target_year is null or a.target_year = nullif(m->>'year','')::int)
      and (a.target_section is null or a.target_section = m->>'section')
    on conflict do nothing;
  end if;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

-- Row level security
alter table profiles enable row level security; alter table actions enable row level security;
alter table student_actions enable row level security; alter table notifications enable row level security;

create policy profiles_read on profiles for select using (id=auth.uid() or my_role() in ('STAFF','ADMIN'));
create policy actions_read on actions for select using (my_role() in ('STAFF','ADMIN')
  or (status='PUBLISHED' and exists(select 1 from student_actions s where s.action_id=actions.id and s.student_id=auth.uid())));
create policy actions_insert on actions for insert with check (my_role() in ('STAFF','ADMIN') and created_by=auth.uid());
create policy actions_update on actions for update using (my_role()='ADMIN' or (my_role()='STAFF' and created_by=auth.uid()));
create policy actions_delete on actions for delete using (my_role()='ADMIN' or (my_role()='STAFF' and created_by=auth.uid()));
create policy sa_read on student_actions for select using (student_id=auth.uid() or my_role() in ('STAFF','ADMIN'));
create policy notif_read on notifications for select using (student_id=auth.uid());
create policy notif_update on notifications for update using (student_id=auth.uid()) with check (student_id=auth.uid());
revoke update on notifications from authenticated; grant update(is_read) on notifications to authenticated;
-- profiles, student_actions, sms_outbox and audit_logs have no write policies: changes go through the functions below.

create or replace function publish_action(p_id uuid) returns int language plpgsql security definer set search_path=public as $$
declare act actions; n int;
begin
  select * into act from actions where id=p_id;
  if act.id is null or not (my_role()='ADMIN' or (my_role()='STAFF' and act.created_by=auth.uid())) then raise exception 'Not allowed'; end if;
  update actions set status='PUBLISHED' where id=p_id;
  with ins as (
    insert into student_actions(student_id,action_id)
    select p.id,p_id from profiles p where p.role='STUDENT' and p.is_active
      and (act.target_department is null or p.department=act.target_department)
      and (act.target_year is null or p.year=act.target_year)
      and (act.target_section is null or p.section=act.target_section)
    on conflict do nothing returning student_id),
  nn as (insert into notifications(student_id,action_id,title,message,notification_type)
    select student_id,p_id,'New action','New action assigned: '||act.title,'NEW_ACTION' from ins returning 1),
  sm as (insert into sms_outbox(to_phone,body)
    select p.phone,'New action assigned: '||act.title from ins join profiles p on p.id=ins.student_id where p.notify and coalesce(p.phone,'')<>'' returning 1)
  select count(*) into n from ins;
  insert into audit_logs(user_id,action,entity_type,entity_id) values(auth.uid(),'ACTION_PUBLISHED','action',p_id);
  return n;
end $$;

create or replace function submit_action(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare v boolean;
begin
  select requires_verification into v from actions where id=p_id;
  update student_actions set status=case when v then 'VERIFICATION_PENDING' else 'COMPLETED' end,
    submitted_at=now(), completed_at=case when v then null else now() end
  where student_id=auth.uid() and action_id=p_id and status in ('PENDING','OPENED');
  if not found then raise exception 'Nothing to submit'; end if;
  insert into audit_logs(user_id,action,entity_type,entity_id) values(auth.uid(),'STUDENT_SUBMITTED','action',p_id);
end $$;

create or replace function send_reminder(p_id uuid) returns int language plpgsql security definer set search_path=public as $$
declare act actions; n int;
begin
  select * into act from actions where id=p_id;
  if act.id is null or not (my_role()='ADMIN' or (my_role()='STAFF' and act.created_by=auth.uid())) then raise exception 'Not allowed'; end if;
  if act.last_reminder_at > now() - interval '6 hours' then raise exception 'A reminder went out recently'; end if;
  with t as (select student_id from student_actions where action_id=p_id and status='PENDING'),
  nn as (insert into notifications(student_id,action_id,title,message,notification_type)
    select student_id,p_id,'Reminder','Reminder: '||act.title||' is due '||to_char(act.deadline at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),'REMINDER' from t returning 1),
  sm as (insert into sms_outbox(to_phone,body)
    select p.phone,'Reminder: '||act.title||' is due '||to_char(act.deadline at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM')
    from t join profiles p on p.id=t.student_id where p.notify and coalesce(p.phone,'')<>'' returning 1)
  select count(*) into n from t;
  update actions set last_reminder_at=now() where id=p_id;
  insert into audit_logs(user_id,action,entity_type,entity_id) values(auth.uid(),'REMINDER_SENT','action',p_id);
  return n;
end $$;

create or replace function update_prefs(p_phone text, p_notify boolean) returns void language plpgsql security definer set search_path=public as $$
begin
  if coalesce(p_phone,'')<>'' and p_phone !~ '^\+[1-9][0-9]{9,14}$' then raise exception 'Invalid phone number'; end if;
  update profiles set phone=p_phone, notify=p_notify where id=auth.uid();
end $$;

alter publication supabase_realtime add table actions, student_actions, notifications, profiles;
