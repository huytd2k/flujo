export type Pod={id:string;name?:string;desiredStatus?:string;lastStatusChange?:string;costPerHr?:number;imageName?:string;machine?:{gpuDisplayName?:string};runtime?:{uptimeInSeconds?:number}};
export type PromptJob={prompt_id:string;number?:number;node_errors?:Record<string,unknown>};
export type ComfyImage={filename:string;subfolder:string;type:string};
export type ComfyHistory={status?:{completed?:boolean;status_str?:string};outputs?:Record<string,{images?:ComfyImage[]}>};
let runpodKey=sessionStorage.getItem('flujo.runpod.key')||'';
let imageBaseUrl='';
export function runPodSettings(){return {apiKey:runpodKey}}
export function setRunPodSettings(apiKey:string){runpodKey=apiKey.trim();if(runpodKey)sessionStorage.setItem('flujo.runpod.key',runpodKey);else sessionStorage.removeItem('flujo.runpod.key')}
async function json<T>(url:string,init:RequestInit={}):Promise<T>{const headers=new Headers(init.headers);if(runpodKey)headers.set('x-flujo-runpod-key',runpodKey);const response=await fetch(url,{...init,headers});const body=await response.json().catch(()=>({error:`HTTP ${response.status}`}));if(!response.ok)throw new Error(body.error||body.message||`HTTP ${response.status}`);return body as T}
export async function health(){const value=await json<{ok:boolean;configured:boolean;provider:string;imageBaseUrl?:string}>('/api/health');imageBaseUrl=value.imageBaseUrl||'';return value}
export const provision=()=>json<Pod>('/api/workers',{method:'POST'});
export const pods=()=>json<Pod[]|{pods?:Pod[]}>('/api/workers');
export const pod=(id:string)=>json<Pod>(`/api/workers/${encodeURIComponent(id)}`);
export const runtimeHealth=(id:string)=>json<{ready:boolean}>(`/api/workers/${encodeURIComponent(id)}/health`);
export const terminate=(id:string)=>json<unknown>(`/api/workers/${encodeURIComponent(id)}`,{method:'DELETE'});
export const submit=(podId:string,workflow:unknown)=>json<PromptJob>(`/api/workers/${encodeURIComponent(podId)}/generations`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({prompt:workflow,client_id:'flujo-v01'})});
export const history=(podId:string,promptId:string)=>json<Record<string,ComfyHistory>>(`/api/workers/${encodeURIComponent(podId)}/jobs/${encodeURIComponent(promptId)}`);
export const cancel=(podId:string,promptId:string)=>json<unknown>(`/api/workers/${encodeURIComponent(podId)}/jobs/${encodeURIComponent(promptId)}/cancel`,{method:'POST'});
export function imageUrl(podId:string,image:ComfyImage):string{const query=new URLSearchParams({filename:image.filename,subfolder:image.subfolder||'',type:image.type||'output'});if(imageBaseUrl){return `${imageBaseUrl}/view?${query}`}if(podId==='remote-comfy'){return `${location.protocol}//${location.hostname}:8188/view?${query}`}return `https://${podId}-8188.proxy.runpod.net/view?${query}`}
export function krea2Workflow(prompt:string,seed:number,width:number,height:number,provider='remote-comfy'){if(provider==='remote-comfy')return {
  '1':{class_type:'Krea2SVDQuantW4A4Loader',inputs:{model_name:'Krea2-Turbo-SVDQuant-W4A4-rank256-actaware.safetensors'}},
  '2':{class_type:'CLIPLoader',inputs:{clip_name:'qwen3vl_4b_fp8_scaled.safetensors',type:'krea2',device:'default'}},
  '3':{class_type:'VAELoader',inputs:{vae_name:'qwen_image_vae.safetensors'}},
  '4':{class_type:'Krea2SVDQuantLoraLoader',inputs:{lora_name:'bld_lora.safetensors',strength:1,adapters:'bypass (exact, slower)',model:['1',0]}},
  '5':{class_type:'CLIPTextEncode',inputs:{text:prompt,clip:['2',0]}},
  '6':{class_type:'ConditioningZeroOut',inputs:{conditioning:['5',0]}},
  '7':{class_type:'EmptySD3LatentImage',inputs:{width,height,batch_size:1}},
  '8':{class_type:'KSampler',inputs:{model:['4',0],seed,steps:8,cfg:1,sampler_name:'euler',scheduler:'simple',positive:['5',0],negative:['6',0],latent_image:['7',0],denoise:1}},
  '9':{class_type:'VAEDecode',inputs:{samples:['8',0],vae:['3',0]}},
  '10':{class_type:'SaveImage',inputs:{images:['9',0],filename_prefix:'flujo-krea2-svdquant'}},
};return {
  '1':{class_type:'UNETLoader',inputs:{unet_name:'krea2_turbo_fp8_scaled.safetensors',weight_dtype:'default'}},
  '2':{class_type:'CLIPLoader',inputs:{clip_name:'qwen3vl_4b_fp8_scaled.safetensors',type:'krea2'}},
  '3':{class_type:'VAELoader',inputs:{vae_name:'qwen_image_vae.safetensors'}},
  '4':{class_type:'CLIPTextEncode',inputs:{text:prompt,clip:['2',0]}},
  '5':{class_type:'ConditioningZeroOut',inputs:{conditioning:['4',0]}},
  '6':{class_type:'EmptyLatentImage',inputs:{width,height,batch_size:1}},
  '7':{class_type:'KSampler',inputs:{model:['1',0],seed,steps:8,cfg:1,sampler_name:'euler',scheduler:'simple',positive:['4',0],negative:['5',0],latent_image:['6',0],denoise:1}},
  '8':{class_type:'VAEDecode',inputs:{samples:['7',0],vae:['3',0]}},
  '9':{class_type:'SaveImage',inputs:{images:['8',0],filename_prefix:'flujo-krea2'}},
}}
