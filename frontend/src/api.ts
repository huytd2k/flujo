export type RunPodJob={id:string;status?:'IN_QUEUE'|'IN_PROGRESS'|'COMPLETED'|'FAILED'|'CANCELLED'|'TIMED_OUT';output?:unknown;error?:string};
async function json<T>(url:string,init?:RequestInit):Promise<T>{const r=await fetch(url,init);const body=await r.json().catch(()=>({error:`HTTP ${r.status}`}));if(!r.ok)throw new Error(body.error||body.message||`HTTP ${r.status}`);return body as T}
export const health=()=>json<{ok:boolean;configured:boolean;provider:string}>('/api/health');
export const submit=(workflow:unknown)=>json<RunPodJob>('/api/generations',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({input:{workflow}})});
export const status=(id:string)=>json<RunPodJob>(`/api/jobs/${encodeURIComponent(id)}`);
export const cancel=(id:string)=>json<RunPodJob>(`/api/jobs/${encodeURIComponent(id)}/cancel`,{method:'POST'});
