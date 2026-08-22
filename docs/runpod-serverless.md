# RunPod Serverless setup

Flujo uses RunPod's official `worker-comfyui` request contract. The browser never receives the RunPod API key.

1. Create a RunPod Serverless endpoint from `runpod/worker-comfyui:5.8.6-flux1-dev` to verify the integration with FLUX.1 Dev.
2. For Krea 2, create a custom worker using RunPod ComfyUI-to-API. The worker must contain a ComfyUI release with Krea 2 nodes, the model files accepted under their upstream license, and the API-format workflow you tested in ComfyUI.
3. Configure scale-to-zero (`workersMin: 0`) and the desired RunPod idle timeout on the endpoint.
4. Copy `.env.example` to `.env` and set `RUNPOD_API_KEY` and `RUNPOD_ENDPOINT_ID`.
5. Run `docker compose up --build`, open `http://localhost:8080`, and paste the tested API workflow into Settings.

The workflow can contain `{{PROMPT}}`, `{{SEED}}`, `{{WIDTH}}`, and `{{HEIGHT}}` string placeholders. Flujo replaces them before submitting `{"input":{"workflow": ...}}` asynchronously. Job status and cancellation use RunPod's standard API.

Secrets must remain on the Gleam gateway. Do not put an API key into the Svelte application or browser storage.

