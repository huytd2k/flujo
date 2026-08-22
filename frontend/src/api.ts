export type Pod={id:string;desiredStatus?:string;costPerHr?:number;machine?:{gpuDisplayName?:string}};
export type PromptJob={prompt_id:string;number?:number;node_errors?:Record<string,unknown>};
export type ComfyImage={filename:string;subfolder:string;type:string};
export type ComfyHistory={status?:{completed?:boolean;status_str?:string};outputs?:Record<string,{images?:ComfyImage[]}>};
async function json<T>(url:string,init?:RequestInit):Promise<T>{const response=await fetch(url,init);const body=await response.json().catch(()=>({error:`HTTP ${response.status}`}));if(!response.ok)throw new Error(body.error||body.message||`HTTP ${response.status}`);return body as T}
export const health=()=>json<{ok:boolean;configured:boolean;provider:string}>('/api/health');
export const provision=()=>json<Pod>('/api/workers',{method:'POST'});
export const runtimeHealth=(id:string)=>json<unknown>(`/api/workers/${encodeURIComponent(id)}/health`);
export const terminate=(id:string)=>json<unknown>(`/api/workers/${encodeURIComponent(id)}`,{method:'DELETE'});
export const submit=(podId:string,workflow:unknown)=>json<PromptJob>(`/api/workers/${encodeURIComponent(podId)}/generations`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({prompt:workflow,client_id:'flujo-v01'})});
export const history=(podId:string,promptId:string)=>json<Record<string,ComfyHistory>>(`/api/workers/${encodeURIComponent(podId)}/jobs/${encodeURIComponent(promptId)}`);
export const cancel=(podId:string,promptId:string)=>json<unknown>(`/api/workers/${encodeURIComponent(podId)}/jobs/${encodeURIComponent(promptId)}/cancel`,{method:'POST'});
export function imageUrl(podId:string,image:ComfyImage):string{const query=new URLSearchParams({filename:image.filename,subfolder:image.subfolder||'',type:image.type||'output'});return `https://${podId}-8188.proxy.runpod.net/view?${query}`}
export function krea2Workflow(prompt:string,seed:number,width:number,height:number){return {
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
