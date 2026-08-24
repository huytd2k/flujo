export type SchemaProperty = {
  type?: string;
  title?: string;
  description?: string;
  default?: unknown;
  minimum?: number;
  maximum?: number;
  multipleOf?: number;
  enum?: unknown[];
};
export type DependencyRequirement = {
  id: string;
  label: string;
  kind: "gpu" | "file";
  minimum?: number;
  path?: string;
  md5?: string;
};

export type DependencyIssue = {
  id: string;
  label: string;
  message: string;
};

export type DependencyReport = {
  ok: boolean;
  checks: Array<{
    id: string;
    label: string;
    status: "ok" | "warning" | "error";
    detail: string;
  }>;
  errors: DependencyIssue[];
  warnings: DependencyIssue[];
};


export type Runner = {
  id: string;
  name: string;
  image: string;
  dependencies: DependencyRequirement[];
  inputSchema: { required?: string[]; properties?: Record<string, SchemaProperty> };
};

export type RunnerInstance = {
  id: string;
  runnerId?: string;
  port?: string;
  status?: string;
};

export type OutputImage = { filename: string; subfolder?: string; type?: string };
type RunRecord = {
  status?: { status_str?: string };
  outputs?: Record<string, { images?: OutputImage[] }>;
};

const baseUrl = (import.meta.env.VITE_FLUJO_API_URL || "").replace(/\/$/, "");

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(`${baseUrl}${path}`, init);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    const reported = Array.isArray(body.errors)
      ? body.errors.map((error: unknown) => {
          if (!error || typeof error !== "object") return "";
          const label = "label" in error ? error.label : "";
          const message = "message" in error ? error.message : "";
          return [label, message]
            .filter((value): value is string => typeof value === "string")
            .join(": ");
        })
      : [];
    const rawNodes: unknown[] = Object.values(body.node_errors || {});
    const nodeErrors = rawNodes.flatMap((node) => {
      if (
        !node ||
        typeof node !== "object" ||
        !("errors" in node) ||
        !Array.isArray(node.errors)
      ) {
        return [];
      }
      return node.errors.map((error: unknown) => {
        if (!error || typeof error !== "object") return "";
        const details = "details" in error ? error.details : "";
        const message = "message" in error ? error.message : "";
        return typeof details === "string"
          ? details
          : typeof message === "string"
            ? message
            : "";
      });
    });
    const upstream =
      typeof body.error === "object"
        ? body.error?.message || body.error?.details
        : body.error;
    const message =
      [...reported, ...nodeErrors].filter(Boolean).join("\n") ||
      body.message ||
      upstream ||
      `Request failed (${response.status})`;
    throw new Error(String(message).replaceAll("_", " "));
  }
  return body as T;
}

const instancePath = (id: string) => `/api/runner-instances/${encodeURIComponent(id)}`;

export const api = {
  health: () => request<{ ok: boolean; configured: boolean }>("/api/health"),
  runners: () => request<Runner[]>("/api/runners"),
  instances: () => request<RunnerInstance[]>("/api/runner-instances"),
  instance: (id: string) => request<RunnerInstance>(instancePath(id)),
  spin: (runnerId: string) =>
    request<RunnerInstance>(`/api/runners/${encodeURIComponent(runnerId)}/instances`, { method: "POST" }),
  ready: (id: string) => request<{ ready: boolean }>(`${instancePath(id)}/health`),
  dependencies: (id: string) =>
    request<DependencyReport>(`${instancePath(id)}/dependencies`),
  stop: (id: string) =>
    request<void>(instancePath(id), { method: "DELETE" }),
  run: (id: string, workflow: unknown) =>
    request<{ prompt_id: string }>(`${instancePath(id)}/runs`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ prompt: workflow, client_id: "flujo-web" }),
    }),
  runStatus: (id: string, runId: string) =>
    request<Record<string, RunRecord>>(`${instancePath(id)}/runs/${encodeURIComponent(runId)}`),
  cancelRun: (id: string, runId: string) =>
    request<void>(`${instancePath(id)}/runs/${encodeURIComponent(runId)}/cancel`, { method: "POST" }),
};

export function imageUrl(instance: RunnerInstance, image: OutputImage): string {
  const query = new URLSearchParams({
    filename: image.filename,
    subfolder: image.subfolder || "",
    type: image.type || "output",
  });
  return `${baseUrl}${instancePath(instance.id)}/outputs?${query}`;
}

export function runnerWorkflow(inputs: Record<string, unknown>) {
  const loras = Array.isArray(inputs.loras) ? inputs.loras : [];
  const firstLora = loras[0] as { path?: string; weight?: number } | undefined;
  return {
    "1": { class_type: "Krea2SVDQuantW4A4Loader", inputs: { model_name: String(inputs.modelPath) } },
    "2": { class_type: "CLIPLoader", inputs: { clip_name: "qwen3vl_4b_fp8_scaled.safetensors", type: "krea2", device: "default" } },
    "3": { class_type: "VAELoader", inputs: { vae_name: "qwen_image_vae.safetensors" } },
    "4": { class_type: "Krea2SVDQuantLoraLoader", inputs: { lora_name: firstLora?.path || "bld_lora.safetensors", strength: firstLora?.weight ?? 1, adapters: "bypass (exact, slower)", model: ["1", 0] } },
    "5": { class_type: "CLIPTextEncode", inputs: { text: String(inputs.prompt || ""), clip: ["2", 0] } },
    "6": { class_type: "ConditioningZeroOut", inputs: { conditioning: ["5", 0] } },
    "7": { class_type: "EmptySD3LatentImage", inputs: { width: Number(inputs.width), height: Number(inputs.height), batch_size: 1 } },
    "8": { class_type: "KSampler", inputs: { model: ["4", 0], seed: Number(inputs.seed), steps: 8, cfg: 1, sampler_name: "euler", scheduler: "simple", positive: ["5", 0], negative: ["6", 0], latent_image: ["7", 0], denoise: 1 } },
    "9": { class_type: "VAEDecode", inputs: { samples: ["8", 0], vae: ["3", 0] } },
    "10": { class_type: "SaveImage", inputs: { images: ["9", 0], filename_prefix: "flujo-krea2" } },
  };
}
