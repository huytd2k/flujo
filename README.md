# Flujo

> A lightweight, strongly typed image-generation workspace built around a pure functional core and disposable GPU workers.

Flujo is an image-generation client/server system designed for fast iteration with FLUX-family and similar image models while keeping GPU infrastructure ephemeral.

The core product loop is:

```text
prompt → generate → compare → tweak → generate again
```

The user should not need to understand containers, worker URLs, GPU lifecycle, provider APIs, model file layouts, or storage plumbing.

Flujo owns that complexity.

## Krea 2 RunPod worker

The v0.1 worker image and normal-Pod template live in [`worker/`](worker/README.md).
It bakes the tested Krea 2 Turbo FP8 model, Qwen3VL encoder, and VAE into the
container, verifies every artifact by SHA-256, and makes the models available
even when RunPod mounts a persistent `/workspace` volume. A GitHub Actions
workflow publishes the large amd64 image to GHCR; the accompanying script then
creates a private, non-serverless RunPod template referencing that image.

The gateway uses a session-provided or server-side `RUNPOD_API_KEY` with the
application-owned RunPod template `7d5q9pntz6` to provision a normal Pod on
demand, waits for ComfyUI, submits the bundled Krea 2 workflow,
and terminates the Pod manually or after 20 idle minutes. Completed image blobs
are copied into browser IndexedDB before teardown, so Library images do not
depend on disposable worker storage.

Flujo deploys as one container and one Pod-facing service. The Docker build
compiles Svelte and Gleam in separate stages, then places the frontend bundle
inside the small Erlang runtime image. The Gleam/Mist server serves both the
SPA and `/api/*` on port 4000; `docker compose up --build` publishes that single
service at `http://localhost:8080`.

## Local ComfyUI and phone access

Local ComfyUI is the default provider. The Compose stack builds a dedicated
`flujo-comfy:cu130` image containing CUDA 13, the exact PyTorch cu130 packages,
ComfyUI, and the SVDQuant custom node. It mounts the host's NVIDIA devices,
checkpoints, text encoders, VAE, LoRAs, and output directory; model weights are
not duplicated inside the image. This machine does not have NVIDIA Container
Toolkit registered with Docker, so Compose explicitly mounts GPU 0 and the
read-only driver 610 ABI libraries. If the host NVIDIA driver changes, update
those versioned library paths in `compose.yaml` (or install NVIDIA Container
Toolkit and replace them with `gpus: all`).

For running without Docker, the included launcher uses the tested combined environment (Python 3.11,
PyTorch `2.11.0+cu130`, CUDA 13.0, and `comfy_kitchen`), verifies that CUDA is
available, and starts the worker with the required custom node and 1 GB VRAM
reserve:

```sh
./scripts/start-local-comfy.sh
```

Override `FLUJO_COMFY_PYTHON` if that environment moves. The current default is
`/home/huytran/micromamba/envs/comfyenv/bin/python3.11`; the launcher refuses a
PyTorch build older than cu130 because it would disable the optimized W4A4 CUDA
backend. It binds only to `192.168.0.33` and permits CORS only from
`http://192.168.0.33:8080`; update `FLUJO_COMFY_LISTEN` and
`FLUJO_PHONE_ORIGIN` if the machine's LAN address changes.

Set `FLUJO_LAN_IP` and `FLUJO_PHONE_ORIGIN` in `.env`, then start both services
with `docker compose up --build -d` and open
`http://<this-machine-LAN-IP>:8080` on the phone. Docker connects to the same
private Compose hostname; generated images use the LAN-published port 8188.
Set `COMFYUI_PUBLIC_URL` when the public address differs from the LAN IP.
The local workflow uses
`Krea2-Turbo-SVDQuant-W4A4-rank256-actaware.safetensors`,
`bld_lora.safetensors`, the Qwen3VL encoder, and Qwen Image VAE. To restore the
cloud provider, set `FLUJO_PROVIDER=runpod` and provide `RUNPOD_API_KEY`.

---

## 1. Project goals

Flujo should:

- provide a clean image-generation UX on desktop and mobile;
- support disposable GPU workers on providers such as RunPod and Vast.ai;
- automatically provision a worker when generation is requested;
- automatically stop workers after an idle timeout;
- keep generation history, metadata, prompts, and images independent of worker lifetime;
- support multiple models, model profiles, LoRAs, image/reference inputs, batching, seeds, and advanced parameters;
- keep the business domain independent of HTTP, databases, cloud providers, storage providers, clocks, randomness, and frontend code;
- make invalid states difficult or impossible to represent;
- prefer immutable data transformation, pattern matching, algebraic data types, higher-order functions, and pure functions;
- optimize code for readability, explicit invariants, and mechanical correctness rather than cleverness.

The first version should be intentionally small.

---

## 2. Non-goals for v0.1

Do **not** implement these unless the project scope is explicitly changed:

- node-graph editing;
- ComfyUI compatibility as a core abstraction;
- video generation;
- LoRA training;
- marketplace features;
- collaborative/multi-user editing;
- arbitrary workflow graphs;
- inpainting/canvas editor;
- automatic model downloading;
- plugin systems;
- provider-specific concepts in the domain layer.

The domain should remain focused on:

```text
models
generation specifications
generation items
assets
workers
queues
policies
state transitions
```

---

# 3. Technology stack

## Backend

- **Gleam**
- Prefer Erlang/BEAM target unless a concrete deployment constraint requires otherwise.
- HTTP framework may be selected later.
- Domain code must not depend on the HTTP framework.

## Frontend

- **Svelte**
- TypeScript enabled.
- Strongly typed API client generated or derived from a single transport schema.
- Frontend state must remain separate from domain state.

## Persistence

Initial implementation may use SQLite or Postgres.

The domain layer must not depend on either.

## Image storage

Use an object-storage abstraction.

Potential adapters:

- Cloudflare R2
- S3-compatible storage
- local filesystem for development

## GPU providers

Provider adapters may include:

- RunPod
- Vast.ai
- local development worker

The domain must not know these provider names.

---

# 4. Architectural rule

Flujo uses a **Functional Core / Imperative Shell** architecture.

```text
                  PURE CORE

           Data → Functions → Data

                     │
                     │ Effect descriptions
                     ▼

                IMPURE SHELL

     HTTP / DB / GPU / Storage / Clock / RNG
```

The core:

- never performs I/O;
- never reads current time;
- never generates UUIDs;
- never generates random seeds;
- never calls cloud APIs;
- never writes files;
- never talks to a database;
- never reads environment variables.

The core receives facts and returns decisions.

External systems turn those decisions into effects.

---

# 5. Dependency direction

Dependencies flow inward.

```text
adapters
   │
   ▼
application
   │
   ▼
domain
```

Forbidden:

```text
domain → RunPod
domain → Vast
domain → SQL
domain → S3
domain → HTTP
domain → environment variables
```

The domain must compile and be testable without any infrastructure package.

---

# 6. Core design philosophy

## 6.1 Make illegal states unrepresentable

Do not model mutually dependent state with unrelated booleans and `Option` fields.

Bad:

```gleam
pub type Worker {
  Worker(
    running: Bool,
    worker_id: Option(String),
    model: Option(String),
    idle_since: Option(Int),
  )
}
```

Good:

```gleam
pub type WorkerState {
  Sleeping
  Provisioning(requested_at: Instant)
  Booting(worker: WorkerId, started_at: Instant)
  LoadingModel(worker: WorkerId, model: ModelRef, started_at: Instant)
  Ready(worker: WorkerId, model: ModelRef, idle_since: Instant)
  Executing(
    worker: WorkerId,
    model: ModelRef,
    items: NonEmpty(GenerationItemId),
  )
  Draining(
    worker: WorkerId,
    model: ModelRef,
    items: NonEmpty(GenerationItemId),
  )
  Stopping(worker: WorkerId)
  Broken(failure: WorkerFailure)
}
```

If the system is `Sleeping`, there is no worker ID.

If it is `Ready`, a worker ID, loaded model, and idle timestamp necessarily exist.

The type expresses the invariant.

---

## 6.2 Avoid primitive obsession

Bad:

```gleam
pub type Generation {
  Generation(
    id: String,
    prompt: String,
    width: Int,
    height: Int,
    count: Int,
    seed: Int,
  )
}
```

Preferred:

```gleam
pub type Generation {
  Generation(
    id: GenerationId,
    created_at: Instant,
    spec: GenerationSpec,
    items: NonEmpty(GenerationItem),
  )
}
```

Use opaque refined types for important values.

Examples:

```text
GenerationId
GenerationItemId
WorkerId
ModelId
ModelRevision
LoraId
AssetId

Prompt
Seed
ImageCount
PixelWidth
PixelHeight
ImageSize

LoraWeight
Guidance
StepCount
Progress

Instant
Duration
```

---

## 6.3 Smart constructors own validation

Example:

```gleam
pub opaque type Prompt {
  Prompt(String)
}

pub type PromptError {
  EmptyPrompt
  PromptTooLong(Int)
}

pub fn new(raw: String) -> Result(Prompt, PromptError)
```

Outside the module, callers must not be able to construct an invalid `Prompt`.

Apply this pattern to every value with invariants.

---

## 6.4 Store truth once

Never store data that can be derived reliably.

Do not store:

```text
generation.status
generation.image_count
generation.completed_count
worker.is_idle
```

when these values can be derived from canonical state.

This prevents contradictions.

Example:

```text
generation.status = Complete
item #3 = Running
```

must be impossible because `generation.status` should not exist as stored mutable state.

---

## 6.5 Prefer exhaustive pattern matching

For central domain ADTs, avoid catch-all cases.

Preferred:

```gleam
case state {
  Queued(..) -> ...
  Assigned(..) -> ...
  Running(..) -> ...
  Persisting(..) -> ...
  Succeeded(..) -> ...
  Failed(..) -> ...
  Cancelled(..) -> ...
}
```

Avoid:

```gleam
case state {
  Running(..) -> ...
  _ -> ...
}
```

unless the catch-all is mathematically intentional and future variants genuinely should behave identically.

Adding a new ADT variant should normally cause compile errors anywhere business logic must be reconsidered.

That is a feature.

---

# 7. Draft state vs domain state

This is one of the most important boundaries.

The frontend may contain incomplete or invalid state while the user edits a form.

Example:

```gleam
pub type GenerationDraft {
  GenerationDraft(
    prompt: String,
    model: Option(ModelId),
    width: Int,
    height: Int,
    image_count: Int,
    loras: List(DraftLora),
    seed: DraftSeed,
  )
}
```

This may temporarily contain:

```text
prompt = ""
model = None
width = 13
image_count = -2
LoRA weight = 9999
```

That is acceptable UI state.

It must never become domain state directly.

There is one explicit boundary:

```text
GenerationDraft
      │
      │ validate + resolve defaults
      ▼
Result(GenerationSpec, ValidationErrors)
```

Once a `GenerationSpec` exists, its invariants must already hold.

---

# 8. NonEmpty

Create a small `NonEmpty(a)` type.

```gleam
pub opaque type NonEmpty(a) {
  NonEmpty(head: a, tail: List(a))
}
```

Suggested operations:

```gleam
from_list
to_list
one
map
fold
length
append
contains
```

Use `NonEmpty` whenever emptiness is invalid.

Examples:

```gleam
ImageGuided(
  prompt: Prompt,
  images: NonEmpty(AssetId),
)

Executing(
  worker: WorkerId,
  model: ModelRef,
  items: NonEmpty(GenerationItemId),
)
```

Do not use `List(a)` followed by repeated empty checks when the domain says there must be at least one value.

---

# 9. Generation intent

Do not represent generation modes with booleans.

Bad:

```text
is_img2img
is_inpaint
has_reference
```

Use a sum type:

```gleam
pub type GenerationIntent {
  TextToImage(
    prompt: Prompt,
  )

  ImageGuided(
    prompt: Prompt,
    images: NonEmpty(AssetId),
  )
}
```

Future extension:

```gleam
Inpaint(...)
```

Adding a new intent should force relevant business logic to be revisited through exhaustive matching.

---

# 10. Models and model profiles

A model is not merely a filename.

A model profile defines what constitutes a valid request.

```gleam
pub type ModelProfile {
  ModelProfile(
    id: ModelId,
    revision: ModelRevision,
    name: String,
    kind: ModelKind,
    input_policy: InputPolicy,
    size_policy: SizePolicy,
    batch_policy: BatchPolicy,
    lora_policy: LoraPolicy,
  )
}
```

## Input policy

Bad:

```gleam
supports_images: Bool
max_images: Option(Int)
```

This permits contradictory state.

Preferred:

```gleam
pub type InputPolicy {
  TextOnly

  TextAndImages(
    max_images: PositiveInt,
  )
}
```

## LoRA policy

Bad:

```gleam
supports_lora: Bool
max_loras: Option(Int)
min_weight: Option(Float)
max_weight: Option(Float)
```

Preferred:

```gleam
pub type LoraPolicy {
  LoraUnsupported

  LoraSupported(
    max_count: PositiveInt,
    weight_range: WeightRange,
  )
}
```

The same principle should apply to every capability.

---

# 11. Image size

Width and height should not travel through the domain as independent arbitrary integers.

```gleam
pub opaque type ImageSize {
  ImageSize(
    width: PixelWidth,
    height: PixelHeight,
  )
}
```

A smart constructor may enforce:

```text
minimum width
minimum height
maximum width
maximum height
divisibility requirements
maximum pixel area
model-specific restrictions
```

The UI may expose:

```gleam
pub type SizeChoice {
  Square
  Portrait3x4
  Portrait2x3
  Landscape4x3
  Landscape16x9
  Custom(Int, Int)
}
```

Resolve the choice before creating `GenerationSpec`.

The canonical specification stores exact resolved dimensions.

---

# 12. LoRA stack

A valid LoRA stack should be represented by a type whose constructor enforces its invariants.

```gleam
pub opaque type LoraStack {
  LoraStack(List(SelectedLora))
}
```

Construction must enforce:

- no duplicate LoRAs;
- count does not exceed model policy;
- each LoRA is compatible with the selected model;
- each weight is valid;
- unsupported models receive an empty stack only.

Suggested API:

```gleam
pub fn new(
  selected: List(SelectedLora),
  model: ModelProfile,
) -> Result(LoraStack, LoraError)
```

After successful construction, business code should not need to re-check those conditions.

---

# 13. Model-specific inference parameters

Do not use:

```gleam
Dict(String, Dynamic)
```

for generation parameters.

Do not create a generic untyped settings map.

Use ADTs.

```gleam
pub type InferenceParams {
  FluxParams(FluxParameters)
  QwenImageParams(QwenParameters)
}
```

Example:

```gleam
pub type FluxParameters {
  FluxParameters(
    steps: StepCount,
    guidance: Guidance,
  )
}
```

The `GenerationSpec` constructor must guarantee that the selected parameter type is compatible with the selected model kind.

A mismatched model and parameter set must not produce a valid `GenerationSpec`.

---

# 14. Canonical GenerationSpec

Target shape:

```gleam
pub opaque type GenerationSpec {
  GenerationSpec(
    model: ModelRef,
    intent: GenerationIntent,
    size: ImageSize,
    items: NonEmpty(GenerationItemSpec),
    loras: LoraStack,
    params: InferenceParams,
  )
}
```

Each image request becomes an item specification:

```gleam
pub type GenerationItemSpec {
  GenerationItemSpec(
    seed: Seed,
  )
}
```

Do **not** store a separate `count`.

If there are four items, the count is four.

```gleam
non_empty.length(spec.items)
```

This eliminates:

```text
count = 4
items.length = 3
```

as a representable state.

---

# 15. Randomness, IDs, and time

Randomness is an effect.

Clock access is an effect.

ID generation is an effect.

The domain must not do this:

```gleam
let seed = random.int(...)
let id = uuid.new()
let now = clock.now()
```

Instead, the shell creates those values and passes them into pure functions.

Example:

```gleam
pub fn create_generation(
  id: GenerationId,
  created_at: Instant,
  seeds: NonEmpty(Seed),
  request: ValidatedRequest,
) -> Generation
```

Same inputs must always produce the same output.

---

# 16. Generation and GenerationItem

A generation is a group of independent image items.

Example:

```text
Generation
├── GenerationItem
├── GenerationItem
├── GenerationItem
└── GenerationItem
```

Suggested type:

```gleam
pub type Generation {
  Generation(
    id: GenerationId,
    created_at: Instant,
    spec: GenerationSpec,
    items: NonEmpty(GenerationItem),
  )
}
```

Each item:

```gleam
pub type GenerationItem {
  GenerationItem(
    id: GenerationItemId,
    spec: GenerationItemSpec,
    state: ItemState,
  )
}
```

The generation specification is immutable after submission.

"Reuse settings" produces a new draft or new generation.

It never mutates historical generations.

---

# 17. Item state machine

Never model lifecycle using:

```gleam
status: String
worker_id: Option(WorkerId)
started_at: Option(Instant)
completed_at: Option(Instant)
asset: Option(AssetId)
error: Option(String)
```

Use an ADT.

```gleam
pub type ItemState {
  Queued(
    queued_at: Instant,
  )

  Assigned(
    worker: WorkerId,
    assigned_at: Instant,
  )

  Running(
    worker: WorkerId,
    started_at: Instant,
    progress: ProgressState,
  )

  Persisting(
    worker: WorkerId,
    rendered: RenderedImage,
  )

  Succeeded(
    asset: AssetId,
    completed_at: Instant,
  )

  Failed(
    failure: GenerationFailure,
    failed_at: Instant,
  )

  Cancelled(
    cancelled_at: Instant,
  )
}
```

Invariants:

- `Succeeded` always has an asset.
- `Failed` always has a failure.
- `Running` always has a worker.
- `Queued` cannot contain an output.
- terminal states do not contain active worker state.

---

# 18. Progress

Do not use `Option(Float)`.

Prefer:

```gleam
pub type ProgressState {
  ProgressUnknown
  ProgressKnown(Progress)
}
```

`Progress` should be an opaque type guaranteeing:

```text
0.0 <= value <= 1.0
```

---

# 19. Derived generation phase

Do not persist `Generation.status`.

Derive it from item state.

```gleam
pub type GenerationPhase {
  GenerationQueued

  GenerationRunning(
    complete: Int,
    total: PositiveInt,
  )

  GenerationComplete
  GenerationPartial
  GenerationFailed
  GenerationCancelled
}
```

Suggested API:

```gleam
pub fn phase(generation: Generation) -> GenerationPhase
```

Implementation should be a pure fold over items.

Example style:

```gleam
generation.items
|> non_empty.fold(summary.initial(), summary.add_item)
|> summary.to_phase()
```

No persisted value should be capable of disagreeing with item state.

---

# 20. Worker state machine

For v0.1, support one logical worker slot.

```gleam
pub type WorkerState {
  Sleeping

  Provisioning(
    requested_at: Instant,
  )

  Booting(
    worker: WorkerId,
    started_at: Instant,
  )

  LoadingModel(
    worker: WorkerId,
    model: ModelRef,
    started_at: Instant,
  )

  Ready(
    worker: WorkerId,
    model: ModelRef,
    idle_since: Instant,
  )

  Executing(
    worker: WorkerId,
    model: ModelRef,
    items: NonEmpty(GenerationItemId),
  )

  Draining(
    worker: WorkerId,
    model: ModelRef,
    items: NonEmpty(GenerationItemId),
  )

  Stopping(
    worker: WorkerId,
  )

  Broken(
    failure: WorkerFailure,
  )
}
```

`Draining` means:

> Current work may finish, but no new work may be assigned.

Do not represent this as:

```gleam
should_stop_after_current: Bool
```

The distinct state is clearer and safer.

---

# 21. Shutdown policy

```gleam
pub type ShutdownPolicy {
  NeverShutdown

  ShutdownAfterIdle(
    duration: Duration,
  )
}
```

Only `Ready` workers may be idle.

Suggested pure function:

```gleam
pub fn idle_deadline(
  worker: WorkerState,
  policy: ShutdownPolicy,
) -> Option(Instant)
```

When an idle timer fires, the domain must re-check worker state.

If the worker has started executing a job since the timer was scheduled, the stale timer is ignored.

A timer firing is a fact.

It is not permission to blindly stop infrastructure.

---

# 22. Queue

For v0.1:

```gleam
pub opaque type GenerationQueue {
  GenerationQueue(List(GenerationItemId))
}
```

Rules:

- FIFO initially;
- no duplicate item IDs;
- completed items cannot remain queued;
- cancelled items cannot remain queued;
- one active item at a time initially;
- queue order is canonical state.

Potential future scheduling policy:

```gleam
pub type SchedulingPolicy {
  Fifo
  PreferLoadedModel
}
```

Do not prematurely implement advanced scheduling.

---

# 23. Messages

The pure core is driven by facts/commands.

Example:

```gleam
pub type Message {
  SubmitGeneration(SubmitGeneration)

  CancelGeneration(GenerationId)

  WorkerProvisioned(
    worker: WorkerId,
    at: Instant,
  )

  WorkerOnline(
    worker: WorkerId,
    at: Instant,
  )

  ModelLoaded(
    worker: WorkerId,
    model: ModelRef,
    at: Instant,
  )

  ItemStarted(
    item: GenerationItemId,
    at: Instant,
  )

  ItemProgressed(
    item: GenerationItemId,
    progress: Progress,
  )

  ItemRendered(
    item: GenerationItemId,
    image: RenderedImage,
  )

  AssetPersisted(
    item: GenerationItemId,
    asset: AssetId,
    at: Instant,
  )

  ItemFailed(
    item: GenerationItemId,
    failure: GenerationFailure,
    at: Instant,
  )

  IdleDeadlineReached(
    worker: WorkerId,
    at: Instant,
  )
}
```

Messages contain already-observed facts.

The domain decides what they mean.

---

# 24. Effects as data

The domain does not perform infrastructure operations.

It returns descriptions of required effects.

```gleam
pub type Effect {
  ProvisionWorker

  LoadModel(
    worker: WorkerId,
    model: ModelRef,
  )

  ExecuteItem(
    worker: WorkerId,
    generation: GenerationId,
    item: GenerationItemId,
    request: InferenceRequest,
  )

  CancelExecution(
    worker: WorkerId,
    item: GenerationItemId,
  )

  PersistImage(
    item: GenerationItemId,
    rendered: RenderedImage,
  )

  StopWorker(
    worker: WorkerId,
  )

  ScheduleIdleCheck(
    worker: WorkerId,
    at: Instant,
  )
}
```

These values perform no I/O.

The application shell interprets them.

---

# 25. Domain events

Effects describe what infrastructure should do.

Domain events describe what happened in the business domain.

Keep these concepts separate.

Example:

```gleam
pub type DomainEvent {
  GenerationSubmitted(GenerationId)
  WorkerProvisionRequested
  WorkerBecameReady(WorkerId)
  GenerationItemStarted(GenerationItemId)
  GenerationItemSucceeded(GenerationItemId, AssetId)
  GenerationItemFailed(GenerationItemId, GenerationFailure)
  WorkerShutdownRequested(WorkerId)
}
```

Events may later be useful for:

- persistence;
- auditing;
- WebSocket/SSE updates;
- analytics;
- debugging.

Do not force event sourcing in v0.1.

---

# 26. Central transition function

The core should converge on a single conceptual transition entry point.

```gleam
pub fn transition(
  state: State,
  message: Message,
) -> Result(Transition, DomainError)
```

```gleam
pub type Transition {
  Transition(
    state: State,
    effects: List(Effect),
    events: List(DomainEvent),
  )
}
```

Conceptual flow:

```text
HTTP / provider / timer
          │
          ▼
       Message
          │
          ▼
     transition()
          │
          ▼
┌──────────────────────┐
│ new state            │
│ effects              │
│ domain events        │
└──────────┬───────────┘
           │
           ▼
   effect interpreter
           │
           ▼
GPU / DB / S3 / timers
```

The transition function must remain deterministic and pure.

---

# 27. Example lifecycle

A complete v0.1 flow should be simulatable without any real infrastructure.

```text
submit 4 image items
       ↓
worker = Sleeping
       ↓
ProvisionWorker effect
       ↓
WorkerProvisioned
       ↓
WorkerOnline
       ↓
LoadModel effect
       ↓
ModelLoaded
       ↓
ExecuteItem #1
       ↓
ItemStarted
       ↓
ItemProgressed
       ↓
ItemRendered
       ↓
PersistImage effect
       ↓
AssetPersisted
       ↓
item #1 = Succeeded
       ↓
ExecuteItem #2
       ↓
...
       ↓
queue empty
       ↓
worker = Ready
       ↓
ScheduleIdleCheck
       ↓
IdleDeadlineReached
       ↓
StopWorker effect
       ↓
worker = Sleeping
```

This scenario must be testable in-memory with zero I/O.

---

# 28. Validation errors vs domain errors

These are different concepts.

## ValidationError

Expected problems in user-provided data.

Examples:

```gleam
pub type ValidationError {
  PromptEmpty
  PromptTooLong(Int)
  ModelMissing
  InvalidImageSize
  TooManyImages
  UnsupportedInputMode
  LoraWeightOutOfRange
  TooManyLoras
}
```

Form validation should ideally accumulate multiple errors.

```gleam
pub opaque type ValidationErrors {
  ValidationErrors(NonEmpty(ValidationError))
}
```

Suggested API:

```gleam
pub fn validate_submission(...)
  -> Result(GenerationSpec, ValidationErrors)
```

## DomainError

An invalid operation attempted against valid domain state.

Examples:

```gleam
pub type DomainError {
  UnknownModel(ModelId)

  InvalidTransition(
    item: GenerationItemId,
    operation: Operation,
  )

  GenerationAlreadyFinished(GenerationId)

  ModelDoesNotSupportInput(ModelId)

  ModelDoesNotSupportLora(ModelId)

  LoraIncompatible(
    lora: LoraId,
    model: ModelId,
  )

  WorkerNotAvailable

  WorkerMismatch(
    expected: WorkerId,
    actual: WorkerId,
  )
}
```

Never encode domain errors as ad-hoc strings.

---

# 29. Canonical invariants

The following invariants should be enforced from the first implementation.

| Invariant | Encoding |
|---|---|
| Submitted generation always has a model | `GenerationSpec` contains `ModelRef` |
| Prompt is valid | opaque `Prompt` |
| Batch is non-empty | `NonEmpty(GenerationItem)` |
| Every item has a seed | `GenerationItemSpec(seed)` |
| Dimensions are valid | opaque `ImageSize` |
| LoRA weights are valid | opaque `LoraWeight` |
| LoRAs contain no duplicates | opaque `LoraStack` |
| LoRAs are compatible with model | validated `LoraStack` |
| Inference params match model | validated opaque `GenerationSpec` |
| Succeeded item always has asset | `Succeeded(asset, ...)` |
| Failed item always has failure | `Failed(failure, ...)` |
| Running item always has worker | `Running(worker, ...)` |
| Sleeping worker has no worker ID | `Sleeping` |
| Ready worker has loaded model | `Ready(worker, model, ...)` |
| Executing worker has work | `NonEmpty(GenerationItemId)` |
| Generation phase cannot contradict item states | phase is derived |
| Historical config is immutable | immutable `GenerationSpec` |
| Idle timeout cannot kill executing worker | transition only stops valid idle state |
| Terminal item cannot accidentally restart | explicit state transition rules |
| Randomness is deterministic from core perspective | seeds supplied from shell |
| Time is deterministic from core perspective | timestamps supplied from shell |

---

# 30. Functional programming rules

Prefer code that reads as transformation.

```text
take data
transform data
fold data
pattern match state
return new data
```

Prefer pipelines such as:

```gleam
generation.items
|> non_empty.map(item.progress)
|> non_empty.fold(summary.initial(), summary.add)
|> summary.phase
```

Prefer pure functions and higher-order functions when they make domain transformations clearer.

Avoid:

- hidden mutation;
- global state;
- service objects that mutate each other;
- large manager classes;
- generic dictionaries carrying business data;
- "god" modules;
- stringly typed enums;
- implicit nullable state.

Functional style is a means to make behavior explicit, not a contest to maximize abstraction.

---

# 31. Suggested Gleam module structure

```text
src/flujo/

  domain/
    id.gleam
    non_empty.gleam

    prompt.gleam
    seed.gleam
    time.gleam
    progress.gleam
    image_size.gleam

    model.gleam
    model_policy.gleam

    lora.gleam

    generation/
      spec.gleam
      item.gleam
      phase.gleam
      validation.gleam

    worker/
      state.gleam
      policy.gleam

    queue.gleam
    scheduler.gleam

    message.gleam
    effect.gleam
    event.gleam
    state.gleam
    transition.gleam

  application/
    command_handler.gleam
    effect_interpreter.gleam

  adapters/
    http/
    persistence/
    provider/
      runpod/
      vast/
      local/
    storage/
      s3/
      local/
```

Module boundaries may evolve.

Dependency direction may not.

---

# 32. Svelte boundary

Do not share internal Gleam domain types directly with the frontend.

Use an explicit transport projection.

```text
Gleam Domain
     ↓
DTO projection
     ↓
typed API
     ↓
Svelte
```

The frontend should receive only what it needs.

Example domain state:

```gleam
Running(
  worker: WorkerId,
  started_at: Instant,
  progress: ProgressState,
)
```

Possible frontend view:

```ts
type GenerationItemView =
  | {
      state: "queued";
    }
  | {
      state: "running";
      progress: number | null;
    }
  | {
      state: "complete";
      imageUrl: string;
    }
  | {
      state: "failed";
      message: string;
    };
```

The frontend does not need `WorkerId` to render a generation card.

Do not leak implementation details casually.

---

# 33. API contract

Maintain one transport contract as source of truth.

OpenAPI is a reasonable choice.

Conceptual flow:

```text
api/openapi.yaml
       │
       ├────────► Gleam transport types
       │
       └────────► TypeScript types/client
```

Important:

```text
OpenAPI types ≠ domain types
```

Transport objects exist to cross process boundaries.

Domain objects exist to encode business invariants.

Map explicitly between them.

Never generate the domain model from OpenAPI.

---

# 34. Frontend UX architecture

Primary destinations for v0.1:

```text
Create
Library
Settings
```

Do not create top-level destinations for every backend concept.

The main creation loop is:

```text
prompt
  ↓
generate
  ↓
compare
  ↓
reuse settings / variation
  ↓
generate again
```

Infrastructure is secondary.

Worker state should be exposed as small status information:

```text
Sleeping
Starting
Loading model
Ready
Generating
Stopping
```

The normal user flow should never require:

```text
start pod
copy URL
connect backend
load model manually
stop pod
```

---

# 35. v0.1 product feature set

Implement:

- text-to-image;
- reference/image input;
- model selection;
- model profiles;
- LoRA selection and weights;
- aspect ratios;
- custom image size;
- batch generation;
- seed handling;
- advanced model parameters;
- persistent generation history;
- generation metadata;
- reuse settings;
- variation/new-seed action;
- favorites;
- image download;
- generation queue;
- cancellation;
- automatic GPU provision;
- automatic model load;
- automatic idle shutdown;
- worker status;
- persistent image storage;
- desktop UI;
- mobile UI;
- minimal authentication;
- one logical worker slot.

Do not expand scope until this loop is stable.

---

# 36. Persistence rules

Persistence adapters store domain-relevant canonical state.

Do not let the database schema become the domain model.

Rules:

1. Domain types own invariants.
2. Persistence decoding must return `Result`.
3. Invalid persisted data is an explicit error.
4. Do not silently coerce corrupt records into valid values.
5. Historical `GenerationSpec` records are immutable.
6. Persist exact model revision/config needed for reproducibility.
7. Persist exact seeds for every generated item.
8. Persist generated asset metadata independently of temporary worker state.
9. Provider-specific runtime identifiers may be persisted in adapter/application records, but they must not contaminate core generation types.

---

# 37. Testing strategy

The pure core should carry most business test coverage.

## Unit tests

Test smart constructors.

Examples:

```text
Prompt rejects empty input.
ImageCount rejects zero.
Progress rejects values outside 0..1.
LoraWeight respects allowed bounds.
ImageSize respects model constraints.
```

## State transition tests

Test every legal lifecycle transition.

Examples:

```text
Queued → Assigned
Assigned → Running
Running → Persisting
Persisting → Succeeded
Running → Failed
Queued → Cancelled
```

Test invalid transitions explicitly.

Examples:

```text
Succeeded → Running = error
Failed → Persisting = error
Cancelled → Assigned = error
```

## Scenario tests

Run complete workflows through `transition`.

Example:

```text
Sleeping
+ SubmitGeneration
→ ProvisionWorker effect

WorkerOnline
→ LoadModel effect

ModelLoaded
→ ExecuteItem effect

ItemRendered
→ PersistImage effect

AssetPersisted
→ Succeeded

queue empty
→ idle timer

idle deadline
→ StopWorker effect
```

## Property-style tests

Where practical, test invariants rather than examples.

Examples:

- generation phase is `Complete` iff every item succeeded;
- terminal generation items are never schedulable;
- queue never contains duplicates after any public queue operation;
- constructing `LoraStack` never yields more than policy maximum;
- no public constructor can produce invalid `Progress`;
- idle shutdown never produces `StopWorker` while state is `Executing`.

---

# 38. AI implementation agent rules

Any AI agent working on this repository must follow these rules.

## Architecture

1. Do not introduce I/O into `domain/`.
2. Do not import provider, HTTP, database, storage, environment, clock, or randomness modules into `domain/`.
3. Keep domain functions deterministic.
4. Keep dependencies pointing inward.
5. Do not bypass smart constructors.
6. Do not expose opaque constructors merely to make implementation easier.

## Type design

7. Prefer ADTs over correlated booleans.
8. Prefer refined opaque types over raw `String`, `Int`, and `Float` for business values.
9. Prefer `NonEmpty(a)` when emptiness is invalid.
10. Do not use `Option` to encode mutually exclusive lifecycle states when an ADT is more accurate.
11. Do not use strings as enum/status values inside the domain.
12. Do not use `Dict(String, Dynamic)` for model-specific business configuration.
13. Do not duplicate derived state.
14. Do not persist a value merely because it is convenient if it can be derived safely.

## Pattern matching

15. Prefer exhaustive matches for important domain ADTs.
16. Do not add `_ ->` to silence compiler errors after adding a new variant.
17. When a new variant causes compiler failures, review each call site intentionally.

## Mutation and effects

18. Prefer immutable transformations.
19. Model external operations as effect values.
20. External callbacks become typed messages before entering the core.
21. Generate timestamps, UUIDs, and random seeds outside the core and pass them in.

## Error handling

22. Use typed errors.
23. Do not use string exceptions for domain failures.
24. Distinguish user validation errors from invalid domain operations.
25. Do not silently ignore impossible states.
26. Do not silently coerce invalid persistence data.

## Scope

27. Do not introduce node-graph abstractions in v0.1.
28. Do not build speculative generalized plugin systems.
29. Do not add multi-worker scheduling until single-worker behavior is stable.
30. Do not expose cloud-provider details in generation-domain types.
31. Do not implement features listed as non-goals without explicit scope change.

## Code quality

32. Prefer small modules with a single domain responsibility.
33. Prefer named transformations over deeply nested anonymous logic.
34. Use pipelines and HOFs when they improve readability.
35. Do not create abstractions before two or more concrete uses justify them.
36. Keep comments focused on **why an invariant or rule exists**, not on restating code.
37. Every public domain constructor/function should make invalid use difficult.
38. A compiler error after a domain-model change is often desirable. Do not immediately design around it.

## Tests

39. New domain behavior requires tests.
40. Every new state transition requires tests for both legal and illegal transitions.
41. Every new refined type requires constructor-boundary tests.
42. Every bug caused by a previously representable invalid state should result in either:
    - a stronger type/invariant that prevents that state, or
    - a regression test proving the transition cannot recur.

---

# 39. Implementation order

Build in this order.

## Phase 1: domain primitives

Implement:

```text
NonEmpty
IDs
Prompt
Seed
Instant
Duration
Progress
PositiveInt
ImageSize
LoraWeight
```

Add tests.

## Phase 2: model capabilities

Implement:

```text
ModelKind
ModelProfile
InputPolicy
SizePolicy
BatchPolicy
LoraPolicy
InferenceParams
```

Add compatibility tests.

## Phase 3: generation specification

Implement:

```text
GenerationIntent
LoraStack
GenerationItemSpec
GenerationSpec
validation
```

Ensure invalid generation requests cannot cross this boundary.

## Phase 4: generation lifecycle

Implement:

```text
Generation
GenerationItem
ItemState
GenerationPhase
```

Implement derived phase calculations.

## Phase 5: worker and queue

Implement:

```text
WorkerState
ShutdownPolicy
GenerationQueue
SchedulingPolicy(Fifo only initially)
```

## Phase 6: transition engine

Implement:

```text
State
Message
Effect
DomainEvent
Transition
transition()
```

Create a pure in-memory simulation.

## Phase 7: scenario tests

Prove the complete lifecycle works with no I/O.

Only after this phase should infrastructure integration begin.

## Phase 8: application shell

Implement effect interpretation interfaces.

## Phase 9: local adapters

Implement:

```text
local inference fake
local storage
in-memory persistence
fake clock/controlled timestamps
```

Use these for development.

## Phase 10: HTTP/API

Add transport DTOs and typed frontend client.

## Phase 11: provider adapters

Add one provider first.

Recommended:

```text
RunPod OR Vast
```

Do not implement both simultaneously unless needed for a real requirement.

## Phase 12: Svelte UI

Build the product loop:

```text
Create
→ generation progress
→ results
→ reuse settings
→ generate again
```

Then add Library and Settings.

---

# 40. Definition of done for the pure core

The pure-core milestone is complete when a test can execute this entire scenario:

```text
Given:
  a valid model profile
  a valid generation draft
  four supplied seeds
  a sleeping worker
  FIFO scheduling
  20-minute idle shutdown

When:
  the generation is submitted

Then:
  four generation items exist
  each has a deterministic seed
  the worker is provisioned
  the model is loaded
  items execute sequentially
  each rendered output is persisted
  all four items succeed
  generation phase derives as Complete
  worker becomes Ready
  idle timer is scheduled
  stale timers cannot kill active work
  valid idle deadline produces StopWorker
  worker eventually returns to Sleeping
```

This must require:

```text
zero network calls
zero database calls
zero filesystem calls
zero environment access
zero real clocks
zero random generators
```

If that scenario is difficult to test, the architecture has drifted.

---

# 41. Design review checklist

Before merging domain changes, ask:

```text
Can this invalid state be made impossible by the type?

Is this stored field actually derivable?

Does this Option exist because the model is weak?

Would an ADT express these cases more precisely?

Does this function perform an effect that should be returned as data?

Does domain code now know something about infrastructure?

Would adding a new state variant force us to reconsider all relevant behavior?

Can this behavior be tested without I/O?

Is there exactly one canonical source of truth?

Are transport concerns leaking into the domain?
```

If the answer exposes a weaker model, fix the model before adding more conditionals.

---

# 42. Guiding principle

The purpose of Flujo's architecture is not to maximize type-system cleverness.

It is to move correctness from:

```text
"developers must remember this rule"
```

to:

```text
"the program cannot construct the invalid state"
```

Prefer:

```text
compiler
types
constructors
pattern matching
pure functions
```

over:

```text
comments
conventions
runtime checks scattered everywhere
hope
```

The core should become boringly predictable.

That is success.
