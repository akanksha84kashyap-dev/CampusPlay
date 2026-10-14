import {identity,clients,json,safe,method,body} from './_shared.mjs';

export async function handler(event){
  try{
    const parts=event.path.split('/').filter(Boolean),action=parts.at(-1);
    if(event.httpMethod==='POST'&&['join','leave'].includes(action)){
      const {sb,user}=await identity(event),eventId=parts.at(-2);
      if(action==='leave'){
        const {error}=await sb.from('event_participants').delete().eq('event_id',eventId).eq('user_id',user.id);
        if(error)throw error;return json(200,{left:true});
      }
      const {data,error}=await sb.rpc('join_event',{p_event_id:eventId,p_user_id:user.id});
      if(error){if(error.code==='23505'||error.message?.includes('Already joined'))return json(409,{error:'You already joined this event.'});if(error.code==='P0001')return json(409,{error:error.message});throw error}
      return json(201,{joined:true,participant:data});
    }
    if(event.httpMethod==='GET'){
      const {data,error}=await clients().from('sports_events').select('id,title,sport,description,event_date,start_time,duration_minutes,skill_level,max_participants,team_size,facilities(name),profiles(display_name)').eq('status','open').gte('event_date',new Date().toISOString().slice(0,10)).order('event_date');
      if(error)throw error;return json(200,{events:data});
    }
    if(event.httpMethod==='POST'){
      const {sb,user}=await identity(event),b=body(event);
      if(!b.title||!b.sport||!b.facility_id||!b.date||!b.time||!b.max)return json(400,{error:'Title, sport, facility, date, time and max participants are required.'});
      if(new Date(b.date)<=new Date(new Date().toDateString()))return json(422,{error:'Events must be scheduled for a future date.'});
      const {data:facility,error:facilityError}=await sb.from('facilities').select('sport,supported_sports,capacity,opens_at,closes_at').eq('id',b.facility_id).single();
      if(facilityError)return json(404,{error:'Ground not found.'});
      const supported=facility.supported_sports||[];
      if(!(supported.includes(b.sport)||(supported.length===0&&facility.sport===b.sport)))return json(422,{error:'That activity is not available at the selected ground.'});
      if(Number(b.max)>facility.capacity)return json(422,{error:`This ground supports up to ${facility.capacity} participants.`});
      const [hour,minute]=String(b.time).split(':').map(Number),start=hour*60+minute,duration=Number(b.duration)||60;
      const hm=x=>{const [h,m]=String(x).split(':').map(Number);return h*60+m};
      const weekday=new Date(`${b.date}T12:00:00Z`).getUTCDay();
      const {data:hours}=await sb.from('facility_operating_hours').select('opens_at,closes_at,closed').eq('facility_id',b.facility_id).eq('weekday',weekday).maybeSingle();
      const opens=hours?.opens_at||facility.opens_at,closes=hours?.closes_at||facility.closes_at;
      if(hours?.closed||start<hm(opens)||start+duration>hm(closes))return json(422,{error:'Event time must fall within this ground’s opening hours.'});
      const {data,error}=await sb.from('sports_events').insert({organizer_id:user.id,title:b.title,sport:b.sport,facility_id:b.facility_id,event_date:b.date,start_time:b.time,duration_minutes:+b.duration||60,description:b.description,skill_level:(b.level||'All levels').toLowerCase(),max_participants:+b.max,team_size:+b.teamSize||2}).select().single();
      if(error)throw error;
      await sb.from('event_participants').insert({event_id:data.id,user_id:user.id});
      return json(201,{event:data});
    }
    return method(event,'GET','POST')||json(405,{error:'Method not allowed.'});
  }catch(e){return safe(e)}
}
