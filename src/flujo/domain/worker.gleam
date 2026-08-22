import flujo/domain/model.{type ModelRef}
import flujo/domain/non_empty.{type NonEmpty}
import flujo/domain/value.{
  type Duration, type GenerationItemId, type Instant, type WorkerId,
}
import gleam/option.{type Option, None, Some}

pub type WorkerFailure {
  WorkerFailure(code: String)
}

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
  Draining(worker: WorkerId, model: ModelRef, items: NonEmpty(GenerationItemId))
  Stopping(worker: WorkerId)
  Broken(failure: WorkerFailure)
}

pub type ShutdownPolicy {
  NeverShutdown
  ShutdownAfterIdle(duration: Duration)
}

pub fn idle_deadline(
  worker: WorkerState,
  policy: ShutdownPolicy,
) -> Option(Instant) {
  case worker, policy {
    Ready(_, _, since), ShutdownAfterIdle(duration) ->
      Some(value.add_duration(since, duration))
    Sleeping, _ -> None
    Provisioning(_), _ -> None
    Booting(_, _), _ -> None
    LoadingModel(_, _, _), _ -> None
    Ready(_, _, _), NeverShutdown -> None
    Executing(_, _, _), _ -> None
    Draining(_, _, _), _ -> None
    Stopping(_), _ -> None
    Broken(_), _ -> None
  }
}
