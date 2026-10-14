import { createClient } from '@supabase/supabase-js';

export const json=(statusCode,body)=>({statusCode,headers:{'content-type':'application/json','cache-control':'no-store'},body:JSON.stringify(body)});
export const bad=(message,statusCode=400)=>json(statusCode,{error:message});
export function clients(){const url=process.env.SUPABASE_URL,key=process.env.SUPABASE_SERVICE_ROLE_KEY;if(!url||!key)throw new Error('Server is not configured.');return createClient(url,key,{auth:{persistSession:false}})}
export async function identity(event,required=true){const token=event.headers.authorization?.replace(/^Bearer\s+/i,'');if(!token){if(required)throw Object.assign(new Error('Sign in required.'),{statusCode:401});return null}const sb=clients();const {data,error}=await sb.auth.getUser(token);if(error||!data.user)throw Object.assign(new Error('Your session is invalid or expired.'),{statusCode:401});return {sb,user:data.user}}
export const safe=(e)=>json(e.statusCode||500,{error:e.statusCode?e.message:'Request could not be completed.'});
export const method=(event,...allowed)=>allowed.includes(event.httpMethod)?null:json(405,{error:'Method not allowed.'});
export const body=(event)=>{try{return JSON.parse(event.body||'{}')}catch{throw Object.assign(new Error('Request body must be valid JSON.'),{statusCode:400})}};
export const idParam=(event)=>event.path.split('/').filter(Boolean).at(-1);
