-- CampusPlay schema. Apply in the Supabase SQL editor or with Supabase CLI.
create extension if not exists pgcrypto;
create extension if not exists btree_gist;

create table if not exists public.colleges (
 id uuid primary key default gen_random_uuid(), name text not null unique,
 email_domains text[] not null default '{}', created_at timestamptz not null default now()
);
create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 college_id uuid references public.colleges(id), display_name text not null,
 college_email text not null unique, preferred_sports text[] not null default '{}',
 skill_level text not null default 'beginner' check(skill_level in ('beginner','intermediate','advanced')),
 availability jsonb not null default '[]', preferred_team_size int check(preferred_team_size between 1 and 50),
 discoverable boolean not null default true, is_admin boolean not null default false,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.facilities (
 id uuid primary key default gen_random_uuid(), name text not null, sport text not null,
 supported_sports text[] not null default '{}',
 description text not null default '', location text not null, capacity int not null check(capacity>0),
 price_per_hour numeric(9,2) check(price_per_hour>=0), amenities text[] not null default '{}',
 opens_at time not null default '06:00', closes_at time not null default '22:00',
 active boolean not null default true, created_at timestamptz not null default now(),
 check(opens_at<closes_at)
);
alter table public.facilities add column if not exists supported_sports text[] not null default '{}';
create table if not exists public.facility_operating_hours (
 id uuid primary key default gen_random_uuid(), facility_id uuid not null references public.facilities on delete cascade,
 weekday smallint not null check(weekday between 0 and 6), opens_at time not null, closes_at time not null,
 closed boolean not null default false, unique(facility_id,weekday), check(opens_at<closes_at)
);
create table if not exists public.facility_closures (
 id uuid primary key default gen_random_uuid(), facility_id uuid not null references public.facilities on delete cascade,
 starts_at timestamptz not null, ends_at timestamptz not null, reason text not null default '',
 check(starts_at<ends_at)
);
create table if not exists public.facility_managers (
 facility_id uuid not null references public.facilities on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 created_at timestamptz not null default now(), primary key(facility_id,user_id)
);
create table if not exists public.bookings (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id),
 facility_id uuid not null references public.facilities(id), booking_date date not null,
 start_time time not null, duration_minutes int not null check(duration_minutes between 30 and 240),
 team_size int not null check(team_size>0), sport text not null default 'unspecified', status text not null default 'confirmed' check(status in ('confirmed','cancelled')),
 reference text not null unique default ('CP-'||upper(substr(encode(gen_random_bytes(5),'hex'),1,8))),
 cancelled_at timestamptz, created_at timestamptz not null default now(),
 -- Local campus wall-clock time is intentional: bookings are scheduled against local
 -- facility opening hours, so keep the generated expression timezone-independent.
 slot tsrange generated always as (tsrange(booking_date+start_time, booking_date+start_time+duration_minutes*interval '1 minute','[)')) stored
);
alter table public.bookings add column if not exists sport text not null default 'unspecified';
-- Exclusion constraint serializes overlapping active reservations, including concurrent requests.
alter table public.bookings drop constraint if exists bookings_no_overlap;
alter table public.bookings add constraint bookings_no_overlap exclude using gist (facility_id with =, slot with &&) where(status='confirmed');
create index if not exists bookings_user_date_idx on public.bookings(user_id,booking_date);
create index if not exists bookings_facility_date_idx on public.bookings(facility_id,booking_date) where status='confirmed';
create table if not exists public.sports_events (
 id uuid primary key default gen_random_uuid(), organizer_id uuid not null references public.profiles(id),
 facility_id uuid not null references public.facilities(id), title text not null check(length(title) between 3 and 70),
 sport text not null, description text not null default '', event_date date not null,
 start_time time not null, duration_minutes int not null check(duration_minutes between 30 and 240),
 skill_level text not null default 'all levels', max_participants int not null check(max_participants between 2 and 50),
 team_size int not null check(team_size between 1 and 50), status text not null default 'open' check(status in ('open','cancelled','complete')),
 created_at timestamptz not null default now(), check(event_date>=current_date)
);
create index if not exists events_date_sport_idx on public.sports_events(event_date,sport) where status='open';
create table if not exists public.event_participants (
 event_id uuid not null references public.sports_events(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 joined_at timestamptz not null default now(), primary key(event_id,user_id)
);
create table if not exists public.match_requests (
 id uuid primary key default gen_random_uuid(), from_user uuid not null references public.profiles(id),
 to_user uuid not null references public.profiles(id), sport text not null,
 message text not null default '', status text not null default 'pending' check(status in ('pending','accepted','declined')),
 created_at timestamptz not null default now(), unique(from_user,to_user,sport), check(from_user<>to_user)
);
create table if not exists public.reports (
 id uuid primary key default gen_random_uuid(), reporter_id uuid references public.profiles(id),
 subject_type text not null check(subject_type in ('profile','event','facility')),
 subject_id uuid not null, reason text not null, status text not null default 'open' check(status in ('open','reviewing','resolved')),
 created_at timestamptz not null default now()
);

-- Create a profile after auth signup; the client cannot set admin status through this trigger.
create or replace function public.create_profile_for_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.profiles(id,display_name,college_email)
 values(new.id,coalesce(new.raw_user_meta_data->>'display_name',split_part(new.email,'@',1)),new.email)
 on conflict(id) do nothing;
 return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.create_profile_for_new_user();

-- Availability is derived from facility hours, closures and confirmed reservations.
create or replace function public.get_facility_availability(p_facility_id uuid,p_date date)
returns table(slot_start time, slot_end time, available boolean) language plpgsql stable security definer set search_path=public as $$
declare f facilities%rowtype; t time; day_open time; day_close time; is_closed boolean; booked boolean;
begin
 select * into f from facilities where id=p_facility_id and active=true;
 if not found then raise exception 'Facility unavailable'; end if;
 select oh.opens_at,oh.closes_at,oh.closed into day_open,day_close,is_closed from facility_operating_hours oh where oh.facility_id=p_facility_id and oh.weekday=extract(dow from p_date);
 day_open:=coalesce(day_open,f.opens_at);day_close:=coalesce(day_close,f.closes_at);
 if coalesce(is_closed,false) then return; end if;
 t:=day_open;
 while t+interval '1 hour'<=day_close loop
  select exists(select 1 from bookings b where b.facility_id=p_facility_id and b.booking_date=p_date and b.status='confirmed' and tsrange(p_date+t,p_date+t+interval '1 hour','[)') && b.slot) into booked;
  if not exists(select 1 from facility_closures c where c.facility_id=p_facility_id and tsrange(p_date+t,p_date+t+interval '1 hour','[)') && tsrange(c.starts_at at time zone 'UTC',c.ends_at at time zone 'UTC','[)')) then
   slot_start:=t;slot_end:=t+interval '1 hour';available:=not booked;return next;
  end if;
  t:=t+interval '1 hour';
 end loop;
end $$;

-- Atomic event join prevents two final seats from being taken at once.
create or replace function public.join_event(p_event_id uuid,p_user_id uuid) returns uuid language plpgsql security definer set search_path=public as $$
declare uid uuid:=p_user_id; ev sports_events%rowtype; count_joined int;
begin
 if uid is null then raise exception 'Sign in required'; end if;
 select * into ev from sports_events where id=p_event_id for update;
 if not found or ev.status<>'open' or ev.event_date<current_date then raise exception 'Event is no longer open'; end if;
 if exists(select 1 from event_participants where event_id=p_event_id and user_id=uid) then raise exception 'Already joined'; end if;
 select count(*) into count_joined from event_participants where event_id=p_event_id;
 if count_joined>=ev.max_participants then raise exception 'Event is full'; end if;
 insert into event_participants(event_id,user_id) values(p_event_id,uid);return p_event_id;
end $$;

-- Authenticated server function uses the service key only after verifying the user's JWT.
drop function if exists public.create_booking(uuid,uuid,date,time,integer,integer);
create or replace function public.create_booking(p_user_id uuid,p_facility_id uuid,p_sport text,p_date date,p_start_time time,p_duration_minutes int,p_team_size int)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=p_user_id; f facilities%rowtype; result bookings%rowtype; finish_at time; day_open time; day_close time;
begin
 if uid is null then raise exception 'Sign in required'; end if;
 if p_date<current_date then raise exception 'Booking date cannot be in the past'; end if;
 if p_duration_minutes<30 or p_duration_minutes>240 or p_team_size<1 then raise exception 'Invalid duration or team size'; end if;
 select * into f from facilities where id=p_facility_id and active=true for update;
 if not found then raise exception 'Facility is unavailable'; end if;
 if not (p_sport=any(f.supported_sports) or (cardinality(f.supported_sports)=0 and p_sport=f.sport)) then raise exception 'This activity is not available at the selected ground'; end if;
 if p_team_size>f.capacity then raise exception 'Team exceeds facility capacity'; end if;
 select opens_at,closes_at into day_open,day_close from facility_operating_hours where facility_id=f.id and weekday=extract(dow from p_date) and closed=false;
 day_open:=coalesce(day_open,f.opens_at);day_close:=coalesce(day_close,f.closes_at);finish_at:=p_start_time+(p_duration_minutes||' minutes')::interval;
 if p_start_time<day_open or finish_at>day_close then raise exception 'Time is outside operating hours'; end if;
 if p_date=current_date and p_start_time<=localtime then raise exception 'Booking time must be in the future'; end if;
 if exists(select 1 from facility_operating_hours where facility_id=f.id and weekday=extract(dow from p_date) and closed=true) then raise exception 'Facility is closed that day';end if;
 if exists(select 1 from facility_closures c where c.facility_id=f.id and tsrange(p_date+p_start_time,p_date+finish_at,'[)') && tsrange(c.starts_at at time zone 'UTC',c.ends_at at time zone 'UTC','[)')) then raise exception 'Facility is closed for that time';end if;
 insert into bookings(user_id,facility_id,sport,booking_date,start_time,duration_minutes,team_size) values(uid,f.id,p_sport,p_date,p_start_time,p_duration_minutes,p_team_size) returning * into result;
 return jsonb_build_object('id',result.id,'facility_id',result.facility_id,'sport',result.sport,'date',result.booking_date,'time',result.start_time,'duration',result.duration_minutes,'teamSize',result.team_size,'status',result.status,'reference',result.reference);
end $$;

alter table colleges enable row level security;
alter table profiles enable row level security;
alter table facilities enable row level security;
alter table facility_operating_hours enable row level security;
alter table facility_closures enable row level security;
alter table facility_managers enable row level security;
alter table bookings enable row level security;
alter table sports_events enable row level security;
alter table event_participants enable row level security;
alter table match_requests enable row level security;
alter table reports enable row level security;

drop policy if exists "colleges readable" on colleges;
drop policy if exists "profile owner reads own row" on profiles;
drop policy if exists "profile owner update" on profiles;
drop policy if exists "facilities publicly readable" on facilities;
drop policy if exists "hours readable" on facility_operating_hours;
drop policy if exists "closures readable" on facility_closures;
drop policy if exists "managers read own assignments" on facility_managers;
drop policy if exists "bookings owner reads" on bookings;
drop policy if exists "events open readable" on sports_events;
drop policy if exists "event participants readable" on event_participants;
drop policy if exists "match requests visible to parties" on match_requests;
drop policy if exists "requester creates match request" on match_requests;
drop policy if exists "recipient responds to request" on match_requests;
drop policy if exists "reporter sees own reports" on reports;
drop policy if exists "signed in user submits report" on reports;
create policy "colleges readable" on colleges for select using(true);
-- Raw profile rows contain email addresses. Public matching uses the server function's
-- explicit safe-field projection; direct table reads are limited to the signed-in owner.
create policy "profile owner reads own row" on profiles for select using(id=auth.uid());
create policy "profile owner update" on profiles for update using(id=auth.uid()) with check(id=auth.uid());
create or replace function public.prevent_profile_privilege_change() returns trigger language plpgsql security definer set search_path=public as $$
begin if new.is_admin is distinct from old.is_admin then raise exception 'Administrator role is managed by database operators'; end if; return new; end $$;
drop trigger if exists protect_profile_privileges on public.profiles;
create trigger protect_profile_privileges before update on public.profiles for each row execute procedure public.prevent_profile_privilege_change();
create policy "facilities publicly readable" on facilities for select using(active=true or exists(select 1 from profiles where id=auth.uid() and is_admin));
create policy "hours readable" on facility_operating_hours for select using(true);
create policy "closures readable" on facility_closures for select using(true);
create policy "managers read own assignments" on facility_managers for select using(user_id=auth.uid() or exists(select 1 from profiles where id=auth.uid() and is_admin));
create policy "bookings owner reads" on bookings for select using(user_id=auth.uid() or exists(select 1 from facility_managers fm where fm.facility_id=bookings.facility_id and fm.user_id=auth.uid()) or exists(select 1 from profiles where id=auth.uid() and is_admin));
create policy "events open readable" on sports_events for select using(status='open' or organizer_id=auth.uid());
create policy "event participants readable" on event_participants for select using(user_id=auth.uid() or exists(select 1 from sports_events e where e.id=event_id and e.status='open'));
create policy "match requests visible to parties" on match_requests for select using(from_user=auth.uid() or to_user=auth.uid());
create policy "requester creates match request" on match_requests for insert with check(from_user=auth.uid());
create policy "recipient responds to request" on match_requests for update using(to_user=auth.uid()) with check(to_user=auth.uid());
create policy "reporter sees own reports" on reports for select using(reporter_id=auth.uid() or exists(select 1 from profiles where id=auth.uid() and is_admin));
create policy "signed in user submits report" on reports for insert with check(reporter_id=auth.uid());

revoke all on function public.create_booking(uuid,uuid,text,date,time,integer,integer) from public;
grant execute on function public.create_booking(uuid,uuid,text,date,time,integer,integer) to service_role;
revoke all on function public.join_event(uuid,uuid) from public;
grant execute on function public.join_event(uuid,uuid) to service_role;
grant execute on function public.get_facility_availability(uuid,date) to anon,authenticated;
