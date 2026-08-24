# Flujo

Flujo is a schema-driven image runner studio. The product loop is intentionally small:

```text
list runners → choose runner → spin runner → render its schema → run → inspect output
```

The Svelte frontend does not know about infrastructure providers. It reads runner definitions from the API, builds controls from each runner's JSON input schema, spins the selected runner on demand, and submits runs to that runner instance.

## Development

Install frontend dependencies, set `FLUJO_MODELS_DIR` to a ComfyUI models
directory, then run the backend and Vite together:

```sh
npm --prefix frontend install
make runner-build
make dev
```

The API listens on `http://localhost:4000`; Vite listens on `http://localhost:5173` and proxies `/api` during development.

Build and check the project with:

```sh
gleam test
npm --prefix frontend run check
npm --prefix frontend run build
```

## API

- `GET /api/health` — backend readiness.
- `GET /api/runners` — runner definitions, schemas, and dependency requirements.
- `POST /api/runners/{runnerId}/instances` — spin a runner.
- `GET /api/runner-instances` — list active runner instances.
- `GET /api/runner-instances/{instanceId}` — resolve an instance and its output port.
- `GET /api/runner-instances/{instanceId}/health` — runner readiness.
- `GET /api/runner-instances/{instanceId}/dependencies` — complete post-spin GPU, file, and MD5 report.
- `GET /api/runner-instances/{instanceId}/outputs` — proxy generated image bytes through Flujo.
- `POST /api/runner-instances/{instanceId}/runs` — submit a run.
- `GET /api/runner-instances/{instanceId}/runs/{runId}` — inspect run status and outputs.
- `POST /api/runner-instances/{instanceId}/runs/{runId}/cancel` — cancel a run.
- `DELETE /api/runner-instances/{instanceId}` — stop a runner instance.

Dependencies are checked once, immediately after a runner is spun. Missing
dependencies report every failure; an MD5 mismatch is a non-blocking warning.

## Structure

- `src/flujo/domain` — pure generation, model, value, queue, and transition types.
- `src/flujo/application/server.gleam` — HTTP transport.
- `src/flujo/adapters` — Docker and ComfyUI runner adapters.
- `frontend` — Svelte runner studio.
- `runner` — publishable Krea 2 ComfyUI runner image.
- `api/openapi.yaml` — public runner API contract.
