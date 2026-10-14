-- CampusPlay's three campus locations. Safe to run more than once.
insert into public.colleges(name,email_domains) values ('Northwood University',array['northwood.edu']),('Lakeside Institute',array['lakeside.edu']) on conflict(name) do nothing;

-- Convert the original demo cricket venue into the requested main ground when possible.
update public.facilities old set name='MS Ground'
where old.name='The Oval Cricket Ground' and not exists(select 1 from public.facilities current where current.name='MS Ground');
update public.facilities set sport='Cricket',supported_sports=array['Cricket','Volleyball','Basketball','Kabaddi','Kho-Kho','Badminton','Football','Hockey'],
 description='The main campus ground for cricket, volleyball, basketball, kabaddi, kho-kho, badminton, football and hockey.',
 location='Campus · Main sports ground',capacity=30,price_per_hour=0,amenities=array['Outdoor','Floodlights','Changing rooms'],opens_at='06:00',closes_at='22:00',active=true
where name='MS Ground';

-- Retire previous demo-only locations without deleting rows referenced by old bookings/events.
update public.facilities set active=false where name in ('Riverside Football Pitch','Founders Basketball Court','Smash Badminton Arena','Sunset Volleyball Court','Ace Tennis Courts');

insert into public.facilities(name,sport,supported_sports,description,location,capacity,price_per_hour,amenities,opens_at,closes_at)
select v.name,v.sport,v.supported_sports,v.description,v.location,v.capacity,0,v.amenities,v.opens,v.closes
from (values
 ('MS Ground','Cricket',array['Cricket','Volleyball','Basketball','Kabaddi','Kho-Kho','Badminton','Football','Hockey']::text[],'The main campus ground for cricket, volleyball, basketball, kabaddi, kho-kho, badminton, football and hockey.','Campus · Main sports ground',30,array['Outdoor','Floodlights','Changing rooms']::text[],'06:00'::time,'22:00'::time),
 ('TB Court','Table Tennis',array['Table Tennis']::text[],'Indoor table tennis court for practice, friendly rallies and campus tournaments.','Campus · Indoor court',4,array['Indoor','Table tennis tables','Lighting']::text[],'07:00'::time,'22:00'::time),
 ('ID Ground','Ludo',array['Ludo','Chess','Carrom','UNO','Music Chair']::text[],'Indoor recreation space for ludo, chess, carrom, UNO and music chair.','Campus · Indoor recreation hall',24,array['Indoor','Board games','Seating']::text[],'08:00'::time,'21:00'::time)
) as v(name,sport,supported_sports,description,location,capacity,amenities,opens,closes)
where not exists(select 1 from public.facilities f where f.name=v.name);

-- Ensure existing requested locations have current supported-sport data on reruns.
update public.facilities set supported_sports=array['Cricket','Volleyball','Basketball','Kabaddi','Kho-Kho','Badminton','Football','Hockey'] where name='MS Ground';
update public.facilities set supported_sports=array['Table Tennis'] where name='TB Court';
update public.facilities set supported_sports=array['Ludo','Chess','Carrom','UNO','Music Chair'] where name='ID Ground';

insert into public.facility_operating_hours(facility_id,weekday,opens_at,closes_at,closed)
select f.id,d,f.opens_at,f.closes_at,false from public.facilities f cross join generate_series(0,6) d where f.active=true
on conflict(facility_id,weekday) do update set opens_at=excluded.opens_at,closes_at=excluded.closes_at,closed=false;

-- Cancel sample events tied to retired demo venues; never create fake auth profiles.
update public.sports_events set status='cancelled' where facility_id in (select id from public.facilities where active=false) and title in ('Friday Night Football','Sunrise Smash Session','Campus Cricket Nets','Three-on-Three Hoops');
-- Optional safe sample events are associated with the first real signup and appear once per date.
insert into public.sports_events(organizer_id,facility_id,title,sport,description,event_date,start_time,duration_minutes,skill_level,max_participants,team_size)
select p.id,f.id,v.title,v.sport,v.description,current_date+v.day_offset,v.start_time,v.duration,v.skill,v.capacity,v.team
from (select id from public.profiles order by created_at limit 1) p
cross join (values
 ('Friday Night Football','Football','Friendly campus football under the lights.',2,'18:00'::time,90,'all levels',20,5,'MS Ground'),
 ('Table Tennis Rally','Table Tennis','Fast rallies and friendly competition.',1,'07:00'::time,60,'intermediate',4,2,'TB Court'),
 ('Kho-Kho Practice','Kho-Kho','Open practice and a relaxed campus game.',4,'16:30'::time,90,'all levels',24,12,'MS Ground'),
 ('Chess & Carrom Social','Chess','Board games and friendly campus matches.',3,'17:30'::time,75,'all levels',12,2,'ID Ground')
) as v(title,sport,description,day_offset,start_time,duration,skill,capacity,team,facility_name)
join public.facilities f on f.name=v.facility_name and f.active=true
where not exists(select 1 from public.sports_events e where e.organizer_id=p.id and e.title=v.title and e.event_date=current_date+v.day_offset);
insert into public.event_participants(event_id,user_id)
select e.id,e.organizer_id from public.sports_events e
where e.title in ('Friday Night Football','Table Tennis Rally','Kho-Kho Practice','Chess & Carrom Social')
on conflict(event_id,user_id) do nothing;
