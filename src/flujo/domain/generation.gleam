import flujo/domain/image_size.{type ImageSize}
import flujo/domain/model.{
  type InferenceParams, type LoraProfile, type ModelProfile, type ModelRef,
  type WeightRange,
}
import flujo/domain/non_empty.{type NonEmpty}
import flujo/domain/value.{
  type AssetId, type GenerationId, type GenerationItemId, type Instant,
  type LoraId, type LoraWeight, type ModelId, type PositiveInt, type Progress,
  type Prompt, type Seed, type WorkerId,
}
import gleam/bool
import gleam/list
import gleam/result

pub type GenerationIntent {
  TextToImage(prompt: Prompt)
  ImageGuided(prompt: Prompt, images: NonEmpty(AssetId))
}

pub type SelectedLora {
  SelectedLora(id: LoraId, weight: LoraWeight)
}

pub opaque type LoraStack {
  LoraStack(List(SelectedLora))
}

pub type LoraError {
  LoraUnsupported
  TooManyLoras
  DuplicateLora
  LoraIncompatible
  WeightOutOfRange
}

pub fn lora_stack(
  selected: List(SelectedLora),
  available: List(LoraProfile),
  model: ModelProfile,
) -> Result(LoraStack, LoraError) {
  let selected_count = list.length(selected)
  case model.lora_policy, selected {
    model.LoraUnsupported, [] -> Ok(LoraStack([]))
    model.LoraUnsupported, _ -> Error(LoraUnsupported)
    model.LoraSupported(max_count, range), _ ->
      case selected_count > value.positive_int_value(max_count) {
        True -> Error(TooManyLoras)
        False -> validate_loras(selected, available, model.ref.id, range, [])
      }
  }
}

fn validate_loras(
  selected: List(SelectedLora),
  available: List(LoraProfile),
  model_id: ModelId,
  range: WeightRange,
  seen: List(LoraId),
) -> Result(LoraStack, LoraError) {
  case selected {
    [] -> Ok(LoraStack([]))
    [SelectedLora(id, weight), ..rest] -> {
      use <- bool.guard(list.contains(seen, id), Error(DuplicateLora))
      use <- bool.guard(!weight_allowed(weight, range), Error(WeightOutOfRange))
      use <- bool.guard(
        !compatible(id, model_id, available),
        Error(LoraIncompatible),
      )
      validate_loras(rest, available, model_id, range, [id, ..seen])
      |> result.map(fn(stack) {
        LoraStack([SelectedLora(id, weight), ..loras(stack)])
      })
    }
  }
}

fn weight_allowed(weight: LoraWeight, range: WeightRange) -> Bool {
  let model.WeightRange(min, max) = range
  let raw = value.lora_weight_value(weight)
  raw >=. min && raw <=. max
}

fn compatible(
  id: LoraId,
  model_id: ModelId,
  profiles: List(LoraProfile),
) -> Bool {
  profiles
  |> list.any(fn(profile) {
    profile.id == id && list.contains(profile.compatible_models, model_id)
  })
}

pub fn loras(stack: LoraStack) -> List(SelectedLora) {
  let LoraStack(values) = stack
  values
}

pub type GenerationItemSpec {
  GenerationItemSpec(seed: Seed)
}

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

pub type SpecError {
  InputNotSupported
  TooManyInputImages
  BatchTooLarge
  ParameterMismatch
}

pub fn spec(
  profile: ModelProfile,
  intent: GenerationIntent,
  size: ImageSize,
  items: NonEmpty(GenerationItemSpec),
  loras: LoraStack,
  params: InferenceParams,
) -> Result(GenerationSpec, SpecError) {
  use _ <- result.try(validate_intent(profile, intent))
  use <- bool.guard(
    non_empty.length(items)
      > value.positive_int_value(profile.batch_policy.max_count),
    Error(BatchTooLarge),
  )
  use <- bool.guard(
    !model.params_match(profile.kind, params),
    Error(ParameterMismatch),
  )
  Ok(GenerationSpec(profile.ref, intent, size, items, loras, params))
}

fn validate_intent(
  profile: ModelProfile,
  intent: GenerationIntent,
) -> Result(Nil, SpecError) {
  case profile.input_policy, intent {
    model.TextOnly, TextToImage(_) -> Ok(Nil)
    model.TextOnly, ImageGuided(_, _) -> Error(InputNotSupported)
    model.TextAndImages(_), TextToImage(_) -> Ok(Nil)
    model.TextAndImages(max), ImageGuided(_, images) ->
      case non_empty.length(images) > value.positive_int_value(max) {
        True -> Error(TooManyInputImages)
        False -> Ok(Nil)
      }
  }
}

pub fn spec_model(specification: GenerationSpec) -> ModelRef {
  specification.model
}

pub fn item_specs(
  specification: GenerationSpec,
) -> NonEmpty(GenerationItemSpec) {
  specification.items
}

pub type ProgressState {
  ProgressUnknown
  ProgressKnown(Progress)
}

pub type GenerationFailure {
  GenerationFailure(code: String)
}

pub type RenderedImage {
  RenderedImage(reference: String)
}

pub type ItemState {
  Queued(queued_at: Instant)
  Assigned(worker: WorkerId, assigned_at: Instant)
  Running(worker: WorkerId, started_at: Instant, progress: ProgressState)
  Persisting(worker: WorkerId, rendered: RenderedImage)
  Succeeded(asset: AssetId, completed_at: Instant)
  Failed(failure: GenerationFailure, failed_at: Instant)
  Cancelled(cancelled_at: Instant)
}

pub type GenerationItem {
  GenerationItem(
    id: GenerationItemId,
    spec: GenerationItemSpec,
    state: ItemState,
  )
}

pub type Generation {
  Generation(
    id: GenerationId,
    created_at: Instant,
    spec: GenerationSpec,
    items: NonEmpty(GenerationItem),
  )
}

pub type GenerationPhase {
  GenerationQueued
  GenerationRunning(complete: Int, total: PositiveInt)
  GenerationComplete
  GenerationPartial
  GenerationFailed
  GenerationCancelled
}

type Summary {
  Summary(
    total: Int,
    queued: Int,
    active: Int,
    succeeded: Int,
    failed: Int,
    cancelled: Int,
  )
}

pub fn phase(generation: Generation) -> GenerationPhase {
  let summary =
    non_empty.fold(generation.items, Summary(0, 0, 0, 0, 0, 0), summarize)
  case summary {
    Summary(total, _, _, succeeded, 0, 0) if succeeded == total ->
      GenerationComplete
    Summary(total, 0, 0, 0, failed, 0) if failed == total -> GenerationFailed
    Summary(total, 0, 0, 0, 0, cancelled) if cancelled == total ->
      GenerationCancelled
    Summary(total, 0, 0, succeeded, failed, cancelled)
      if succeeded + failed + cancelled == total
    -> GenerationPartial
    Summary(total, queued, 0, 0, 0, 0) if queued == total -> GenerationQueued
    Summary(total, _, _, succeeded, _, _) ->
      GenerationRunning(succeeded, positive(total))
  }
}

fn summarize(summary: Summary, item: GenerationItem) -> Summary {
  let Summary(total, queued, active, succeeded, failed, cancelled) = summary
  case item.state {
    Queued(_) ->
      Summary(total + 1, queued + 1, active, succeeded, failed, cancelled)
    Assigned(_, _) ->
      Summary(total + 1, queued, active + 1, succeeded, failed, cancelled)
    Running(_, _, _) ->
      Summary(total + 1, queued, active + 1, succeeded, failed, cancelled)
    Persisting(_, _) ->
      Summary(total + 1, queued, active + 1, succeeded, failed, cancelled)
    Succeeded(_, _) ->
      Summary(total + 1, queued, active, succeeded + 1, failed, cancelled)
    Failed(_, _) ->
      Summary(total + 1, queued, active, succeeded, failed + 1, cancelled)
    Cancelled(_) ->
      Summary(total + 1, queued, active, succeeded, failed, cancelled + 1)
  }
}

fn positive(value_: Int) -> PositiveInt {
  let assert Ok(result) = value.positive_int(value_)
  result
}
