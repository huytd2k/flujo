import flujo/domain/generation.{
  type Generation, type GenerationFailure, type GenerationItem,
  type RenderedImage,
}
import flujo/domain/model.{type ModelRef}
import flujo/domain/non_empty
import flujo/domain/queue.{type GenerationQueue}
import flujo/domain/value.{
  type AssetId, type GenerationId, type GenerationItemId, type Instant,
  type Progress, type WorkerId,
}
import flujo/domain/worker.{type ShutdownPolicy, type WorkerState}
import gleam/bool
import gleam/list
import gleam/option.{None, Some}
import gleam/result

pub type State {
  State(
    generations: List(Generation),
    worker: WorkerState,
    queue: GenerationQueue,
    shutdown_policy: ShutdownPolicy,
  )
}

pub type Message {
  SubmitGeneration(Generation)
  WorkerProvisioned(worker: WorkerId, at: Instant)
  WorkerOnline(worker: WorkerId, at: Instant)
  ModelLoaded(worker: WorkerId, model: ModelRef, at: Instant)
  ItemStarted(item: GenerationItemId, at: Instant)
  ItemProgressed(item: GenerationItemId, progress: Progress)
  ItemRendered(item: GenerationItemId, image: RenderedImage)
  AssetPersisted(item: GenerationItemId, asset: AssetId, at: Instant)
  ItemFailed(item: GenerationItemId, failure: GenerationFailure, at: Instant)
  CancelItem(item: GenerationItemId, at: Instant)
  IdleDeadlineReached(worker: WorkerId, at: Instant)
  WorkerStopped(worker: WorkerId, at: Instant)
}

pub type Effect {
  ProvisionWorker
  LoadModel(worker: WorkerId, model: ModelRef)
  ExecuteItem(
    worker: WorkerId,
    generation: GenerationId,
    item: GenerationItemId,
  )
  CancelExecution(worker: WorkerId, item: GenerationItemId)
  PersistImage(item: GenerationItemId, rendered: RenderedImage)
  StopWorker(worker: WorkerId)
  ScheduleIdleCheck(worker: WorkerId, at: Instant)
}

pub type DomainEvent {
  GenerationSubmitted(GenerationId)
  WorkerProvisionRequested
  WorkerBecameReady(WorkerId)
  GenerationItemStarted(GenerationItemId)
  GenerationItemSucceeded(GenerationItemId, AssetId)
  GenerationItemFailed(GenerationItemId, GenerationFailure)
  WorkerShutdownRequested(WorkerId)
}

pub type DomainError {
  DuplicateGeneration
  UnknownItem
  InvalidTransition
  WorkerMismatch
  ModelMismatch
  QueueInvariant
}

pub type Transition {
  Transition(state: State, effects: List(Effect), events: List(DomainEvent))
}

pub fn initial(policy: ShutdownPolicy) -> State {
  State([], worker.Sleeping, queue.new(), policy)
}

pub fn transition(
  state: State,
  message: Message,
) -> Result(Transition, DomainError) {
  case message {
    SubmitGeneration(generation_) -> submit(state, generation_)
    WorkerProvisioned(id, at) -> provisioned(state, id, at)
    WorkerOnline(id, at) -> online(state, id, at)
    ModelLoaded(id, model_ref, at) -> loaded(state, id, model_ref, at)
    ItemStarted(item, at) -> started(state, item, at)
    ItemProgressed(item, progress) -> progressed(state, item, progress)
    ItemRendered(item, image) -> rendered(state, item, image)
    AssetPersisted(item, asset, at) -> persisted(state, item, asset, at)
    ItemFailed(item, failure, at) -> failed(state, item, failure, at)
    CancelItem(item, at) -> cancel(state, item, at)
    IdleDeadlineReached(id, at) -> idle_reached(state, id, at)
    WorkerStopped(id, _) -> stopped(state, id)
  }
}

fn submit(
  state: State,
  generation_: Generation,
) -> Result(Transition, DomainError) {
  use <- bool.guard(
    list.any(state.generations, fn(g) { g.id == generation_.id }),
    Error(DuplicateGeneration),
  )
  let ids =
    generation_.items |> non_empty.to_list |> list.map(fn(item) { item.id })
  let queued =
    result.map_error(queue.enqueue_all(state.queue, ids), fn(_) {
      QueueInvariant
    })
  use queue_ <- result.try(queued)
  let next =
    State(
      [generation_, ..state.generations],
      state.worker,
      queue_,
      state.shutdown_policy,
    )
  case state.worker {
    worker.Sleeping ->
      Ok(
        Transition(
          State(
            next.generations,
            worker.Provisioning(generation_.created_at),
            queue_,
            next.shutdown_policy,
          ),
          [ProvisionWorker],
          [GenerationSubmitted(generation_.id), WorkerProvisionRequested],
        ),
      )
    worker.Ready(id, loaded_model, _) ->
      schedule_next(next, id, loaded_model, [
        GenerationSubmitted(generation_.id),
      ])
    worker.Provisioning(_) -> accepted(next, generation_.id)
    worker.Booting(_, _) -> accepted(next, generation_.id)
    worker.LoadingModel(_, _, _) -> accepted(next, generation_.id)
    worker.Executing(_, _, _) -> accepted(next, generation_.id)
    worker.Draining(_, _, _) -> accepted(next, generation_.id)
    worker.Stopping(_) -> accepted(next, generation_.id)
    worker.Broken(_) -> accepted(next, generation_.id)
  }
}

fn accepted(state: State, id: GenerationId) -> Result(Transition, DomainError) {
  Ok(Transition(state, [], [GenerationSubmitted(id)]))
}

fn provisioned(
  state: State,
  id: WorkerId,
  at: Instant,
) -> Result(Transition, DomainError) {
  case state.worker {
    worker.Provisioning(_) ->
      Ok(
        Transition(
          State(
            state.generations,
            worker.Booting(id, at),
            state.queue,
            state.shutdown_policy,
          ),
          [],
          [],
        ),
      )
    worker.Sleeping -> Error(InvalidTransition)
    worker.Booting(_, _) -> Error(InvalidTransition)
    worker.LoadingModel(_, _, _) -> Error(InvalidTransition)
    worker.Ready(_, _, _) -> Error(InvalidTransition)
    worker.Executing(_, _, _) -> Error(InvalidTransition)
    worker.Draining(_, _, _) -> Error(InvalidTransition)
    worker.Stopping(_) -> Error(InvalidTransition)
    worker.Broken(_) -> Error(InvalidTransition)
  }
}

fn online(
  state: State,
  id: WorkerId,
  at: Instant,
) -> Result(Transition, DomainError) {
  case state.worker {
    worker.Booting(expected, _) if expected == id -> {
      use model_ref <- result.try(next_model(state))
      Ok(
        Transition(
          State(
            state.generations,
            worker.LoadingModel(id, model_ref, at),
            state.queue,
            state.shutdown_policy,
          ),
          [LoadModel(id, model_ref)],
          [],
        ),
      )
    }
    worker.Booting(_, _) -> Error(WorkerMismatch)
    worker.Sleeping -> Error(InvalidTransition)
    worker.Provisioning(_) -> Error(InvalidTransition)
    worker.LoadingModel(_, _, _) -> Error(InvalidTransition)
    worker.Ready(_, _, _) -> Error(InvalidTransition)
    worker.Executing(_, _, _) -> Error(InvalidTransition)
    worker.Draining(_, _, _) -> Error(InvalidTransition)
    worker.Stopping(_) -> Error(InvalidTransition)
    worker.Broken(_) -> Error(InvalidTransition)
  }
}

fn loaded(
  state: State,
  id: WorkerId,
  model_ref: ModelRef,
  at: Instant,
) -> Result(Transition, DomainError) {
  case state.worker {
    worker.LoadingModel(expected, _, _) if expected != id ->
      Error(WorkerMismatch)
    worker.LoadingModel(_, expected_model, _) if expected_model != model_ref ->
      Error(ModelMismatch)
    worker.LoadingModel(_, _, _) ->
      schedule_next(
        State(
          state.generations,
          worker.Ready(id, model_ref, at),
          state.queue,
          state.shutdown_policy,
        ),
        id,
        model_ref,
        [WorkerBecameReady(id)],
      )
    worker.Sleeping -> Error(InvalidTransition)
    worker.Provisioning(_) -> Error(InvalidTransition)
    worker.Booting(_, _) -> Error(InvalidTransition)
    worker.Ready(_, _, _) -> Error(InvalidTransition)
    worker.Executing(_, _, _) -> Error(InvalidTransition)
    worker.Draining(_, _, _) -> Error(InvalidTransition)
    worker.Stopping(_) -> Error(InvalidTransition)
    worker.Broken(_) -> Error(InvalidTransition)
  }
}

fn schedule_next(
  state: State,
  id: WorkerId,
  loaded_model: ModelRef,
  events: List(DomainEvent),
) -> Result(Transition, DomainError) {
  case queue.peek(state.queue) {
    Error(_) -> {
      let ready = worker.Ready(id, loaded_model, ready_since(state.worker))
      let effects = case worker.idle_deadline(ready, state.shutdown_policy) {
        Some(at) -> [ScheduleIdleCheck(id, at)]
        None -> []
      }
      Ok(Transition(
        State(state.generations, ready, state.queue, state.shutdown_policy),
        effects,
        events,
      ))
    }
    Ok(item_id) -> {
      use #(generation_id, generation_) <- result.try(find_generation_for_item(
        state.generations,
        item_id,
      ))
      let required = generation.spec_model(generation_.spec)
      case required == loaded_model {
        False ->
          Ok(Transition(
            State(
              state.generations,
              worker.LoadingModel(id, required, ready_since(state.worker)),
              state.queue,
              state.shutdown_policy,
            ),
            [LoadModel(id, required)],
            events,
          ))
        True -> {
          use generations <- result.try(
            update_item(state.generations, item_id, fn(item) {
              assigned(item, id, ready_since(state.worker))
            }),
          )
          let executing =
            worker.Executing(id, loaded_model, non_empty.one(item_id))
          Ok(Transition(
            State(generations, executing, state.queue, state.shutdown_policy),
            [ExecuteItem(id, generation_id, item_id)],
            events,
          ))
        }
      }
    }
  }
}

fn started(
  state: State,
  item_id: GenerationItemId,
  at: Instant,
) -> Result(Transition, DomainError) {
  case state.worker {
    worker.Executing(id, _, items) ->
      case non_empty.contains(items, item_id) {
        True -> {
          use generations <- result.try(
            update_item(state.generations, item_id, fn(item) {
              case item.state {
                generation.Assigned(worker_id, _) if worker_id == id ->
                  Ok(
                    generation.GenerationItem(
                      ..item,
                      state: generation.Running(
                        id,
                        at,
                        generation.ProgressUnknown,
                      ),
                    ),
                  )
                _ -> Error(InvalidTransition)
              }
            }),
          )
          Ok(
            Transition(
              State(
                generations,
                state.worker,
                state.queue,
                state.shutdown_policy,
              ),
              [],
              [GenerationItemStarted(item_id)],
            ),
          )
        }
        False -> Error(InvalidTransition)
      }
    _ -> Error(InvalidTransition)
  }
}

fn progressed(
  state: State,
  item_id: GenerationItemId,
  progress: Progress,
) -> Result(Transition, DomainError) {
  use generations <- result.try(
    update_item(state.generations, item_id, fn(item) {
      case item.state {
        generation.Running(id, at, _) ->
          Ok(
            generation.GenerationItem(
              ..item,
              state: generation.Running(
                id,
                at,
                generation.ProgressKnown(progress),
              ),
            ),
          )
        _ -> Error(InvalidTransition)
      }
    }),
  )
  Ok(
    Transition(
      State(generations, state.worker, state.queue, state.shutdown_policy),
      [],
      [],
    ),
  )
}

fn rendered(
  state: State,
  item_id: GenerationItemId,
  image: RenderedImage,
) -> Result(Transition, DomainError) {
  use generations <- result.try(
    update_item(state.generations, item_id, fn(item) {
      case item.state {
        generation.Running(id, _, _) ->
          Ok(
            generation.GenerationItem(
              ..item,
              state: generation.Persisting(id, image),
            ),
          )
        _ -> Error(InvalidTransition)
      }
    }),
  )
  Ok(
    Transition(
      State(generations, state.worker, state.queue, state.shutdown_policy),
      [PersistImage(item_id, image)],
      [],
    ),
  )
}

fn persisted(
  state: State,
  item_id: GenerationItemId,
  asset: AssetId,
  at: Instant,
) -> Result(Transition, DomainError) {
  use generations <- result.try(
    update_item(state.generations, item_id, fn(item) {
      case item.state {
        generation.Persisting(_, _) ->
          Ok(
            generation.GenerationItem(
              ..item,
              state: generation.Succeeded(asset, at),
            ),
          )
        _ -> Error(InvalidTransition)
      }
    }),
  )
  continue_after_item(
    State(
      generations,
      state.worker,
      queue.remove(state.queue, item_id),
      state.shutdown_policy,
    ),
    item_id,
    at,
    [GenerationItemSucceeded(item_id, asset)],
  )
}

fn failed(
  state: State,
  item_id: GenerationItemId,
  failure: GenerationFailure,
  at: Instant,
) -> Result(Transition, DomainError) {
  use generations <- result.try(
    update_item(state.generations, item_id, fn(item) {
      case item.state {
        generation.Assigned(_, _) ->
          Ok(
            generation.GenerationItem(
              ..item,
              state: generation.Failed(failure, at),
            ),
          )
        generation.Running(_, _, _) ->
          Ok(
            generation.GenerationItem(
              ..item,
              state: generation.Failed(failure, at),
            ),
          )
        _ -> Error(InvalidTransition)
      }
    }),
  )
  continue_after_item(
    State(
      generations,
      state.worker,
      queue.remove(state.queue, item_id),
      state.shutdown_policy,
    ),
    item_id,
    at,
    [GenerationItemFailed(item_id, failure)],
  )
}

fn continue_after_item(
  state: State,
  finished: GenerationItemId,
  at: Instant,
  events: List(DomainEvent),
) -> Result(Transition, DomainError) {
  case state.worker {
    worker.Executing(id, model_ref, items) ->
      case non_empty.contains(items, finished) {
        True ->
          schedule_next(
            State(
              state.generations,
              worker.Ready(id, model_ref, at),
              state.queue,
              state.shutdown_policy,
            ),
            id,
            model_ref,
            events,
          )
        False -> Error(InvalidTransition)
      }
    _ -> Error(InvalidTransition)
  }
}

fn cancel(
  state: State,
  item_id: GenerationItemId,
  at: Instant,
) -> Result(Transition, DomainError) {
  use generations <- result.try(
    update_item(state.generations, item_id, fn(item) {
      case item.state {
        generation.Queued(_) ->
          Ok(generation.GenerationItem(..item, state: generation.Cancelled(at)))
        generation.Assigned(_, _) ->
          Ok(generation.GenerationItem(..item, state: generation.Cancelled(at)))
        generation.Running(_, _, _) ->
          Ok(generation.GenerationItem(..item, state: generation.Cancelled(at)))
        generation.Persisting(_, _) -> Error(InvalidTransition)
        generation.Succeeded(_, _) -> Error(InvalidTransition)
        generation.Failed(_, _) -> Error(InvalidTransition)
        generation.Cancelled(_) -> Error(InvalidTransition)
      }
    }),
  )
  let effects = case state.worker {
    worker.Executing(id, _, items) ->
      case non_empty.contains(items, item_id) {
        True -> [CancelExecution(id, item_id)]
        False -> []
      }
    _ -> []
  }
  Ok(
    Transition(
      State(
        generations,
        state.worker,
        queue.remove(state.queue, item_id),
        state.shutdown_policy,
      ),
      effects,
      [],
    ),
  )
}

fn idle_reached(
  state: State,
  id: WorkerId,
  at: Instant,
) -> Result(Transition, DomainError) {
  case state.worker {
    worker.Ready(expected, _, _) if expected != id -> Error(WorkerMismatch)
    worker.Ready(_, _, _) ->
      case worker.idle_deadline(state.worker, state.shutdown_policy) {
        Some(deadline) ->
          case value.instant_value(at) >= value.instant_value(deadline) {
            True ->
              Ok(
                Transition(
                  State(
                    state.generations,
                    worker.Stopping(id),
                    state.queue,
                    state.shutdown_policy,
                  ),
                  [StopWorker(id)],
                  [WorkerShutdownRequested(id)],
                ),
              )
            False -> Ok(Transition(state, [], []))
          }
        None -> Ok(Transition(state, [], []))
      }
    worker.Sleeping -> Ok(Transition(state, [], []))
    worker.Provisioning(_) -> Ok(Transition(state, [], []))
    worker.Booting(_, _) -> Ok(Transition(state, [], []))
    worker.LoadingModel(_, _, _) -> Ok(Transition(state, [], []))
    worker.Executing(_, _, _) -> Ok(Transition(state, [], []))
    worker.Draining(_, _, _) -> Ok(Transition(state, [], []))
    worker.Stopping(_) -> Ok(Transition(state, [], []))
    worker.Broken(_) -> Ok(Transition(state, [], []))
  }
}

fn stopped(state: State, id: WorkerId) -> Result(Transition, DomainError) {
  case state.worker {
    worker.Stopping(expected) if expected == id ->
      Ok(
        Transition(
          State(
            state.generations,
            worker.Sleeping,
            state.queue,
            state.shutdown_policy,
          ),
          [],
          [],
        ),
      )
    worker.Stopping(_) -> Error(WorkerMismatch)
    _ -> Error(InvalidTransition)
  }
}

fn next_model(state: State) -> Result(ModelRef, DomainError) {
  let next = result.map_error(queue.peek(state.queue), fn(_) { QueueInvariant })
  use id <- result.try(next)
  use #(_, generation_) <- result.try(find_generation_for_item(
    state.generations,
    id,
  ))
  Ok(generation.spec_model(generation_.spec))
}

fn find_generation_for_item(
  generations: List(Generation),
  item_id: GenerationItemId,
) -> Result(#(GenerationId, Generation), DomainError) {
  case generations {
    [] -> Error(UnknownItem)
    [generation_, ..rest] ->
      case
        list.any(non_empty.to_list(generation_.items), fn(item) {
          item.id == item_id
        })
      {
        True -> Ok(#(generation_.id, generation_))
        False -> find_generation_for_item(rest, item_id)
      }
  }
}

fn update_item(
  generations: List(Generation),
  id: GenerationItemId,
  change: fn(GenerationItem) -> Result(GenerationItem, DomainError),
) -> Result(List(Generation), DomainError) {
  case generations {
    [] -> Error(UnknownItem)
    [generation_, ..rest] ->
      case update_items(non_empty.to_list(generation_.items), id, change) {
        Ok(items) -> {
          let assert Ok(non_empty_items) = non_empty.from_list(items)
          Ok([
            generation.Generation(..generation_, items: non_empty_items),
            ..rest
          ])
        }
        Error(UnknownItem) -> {
          use updated <- result.try(update_item(rest, id, change))
          Ok([generation_, ..updated])
        }
        Error(error) -> Error(error)
      }
  }
}

fn update_items(
  items: List(GenerationItem),
  id: GenerationItemId,
  change: fn(GenerationItem) -> Result(GenerationItem, DomainError),
) -> Result(List(GenerationItem), DomainError) {
  case items {
    [] -> Error(UnknownItem)
    [item, ..rest] if item.id == id -> {
      use changed <- result.try(change(item))
      Ok([changed, ..rest])
    }
    [item, ..rest] -> {
      use changed <- result.try(update_items(rest, id, change))
      Ok([item, ..changed])
    }
  }
}

fn assigned(
  item: GenerationItem,
  id: WorkerId,
  at: Instant,
) -> Result(GenerationItem, DomainError) {
  case item.state {
    generation.Queued(_) ->
      Ok(generation.GenerationItem(..item, state: generation.Assigned(id, at)))
    _ -> Error(InvalidTransition)
  }
}

fn ready_since(state: WorkerState) -> Instant {
  case state {
    worker.Ready(_, _, at) -> at
    worker.LoadingModel(_, _, at) -> at
    worker.Executing(_, _, _) -> value.instant(0)
    worker.Sleeping -> value.instant(0)
    worker.Provisioning(at) -> at
    worker.Booting(_, at) -> at
    worker.Draining(_, _, _) -> value.instant(0)
    worker.Stopping(_) -> value.instant(0)
    worker.Broken(_) -> value.instant(0)
  }
}
