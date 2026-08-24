import flujo/domain/generation.{
  type Generation, type GenerationFailure, type GenerationItem, type RenderedImage,
}
import flujo/domain/non_empty
import flujo/domain/queue.{type GenerationQueue}
import flujo/domain/value.{
  type AssetId, type GenerationId, type GenerationItemId, type Instant,
  type Progress,
}
import gleam/bool
import gleam/list
import gleam/result

pub type State {
  State(generations: List(Generation), queue: GenerationQueue)
}

pub type Message {
  SubmitGeneration(Generation)
  ItemStarted(item: GenerationItemId, at: Instant)
  ItemProgressed(item: GenerationItemId, progress: Progress)
  ItemRendered(item: GenerationItemId, image: RenderedImage)
  AssetPersisted(item: GenerationItemId, asset: AssetId, at: Instant)
  ItemFailed(item: GenerationItemId, failure: GenerationFailure, at: Instant)
  CancelItem(item: GenerationItemId, at: Instant)
}

pub type Effect {
  RunItem(generation: GenerationId, item: GenerationItemId)
  CancelRun(item: GenerationItemId)
  PersistImage(item: GenerationItemId, rendered: RenderedImage)
}

pub type DomainEvent {
  GenerationSubmitted(GenerationId)
  GenerationItemStarted(GenerationItemId)
  GenerationItemSucceeded(GenerationItemId, AssetId)
  GenerationItemFailed(GenerationItemId, GenerationFailure)
}

pub type DomainError {
  DuplicateGeneration
  UnknownItem
  InvalidTransition
  QueueInvariant
}

pub type Transition {
  Transition(state: State, effects: List(Effect), events: List(DomainEvent))
}

pub fn initial() -> State {
  State([], queue.new())
}

pub fn transition(state: State, message: Message) -> Result(Transition, DomainError) {
  case message {
    SubmitGeneration(generation_) -> submit(state, generation_)
    ItemStarted(item, at) -> started(state, item, at)
    ItemProgressed(item, progress) -> progressed(state, item, progress)
    ItemRendered(item, image) -> rendered(state, item, image)
    AssetPersisted(item, asset, at) -> persisted(state, item, asset, at)
    ItemFailed(item, failure, at) -> failed(state, item, failure, at)
    CancelItem(item, at) -> cancel(state, item, at)
  }
}

fn submit(state: State, generation_: Generation) -> Result(Transition, DomainError) {
  use <- bool.guard(
    list.any(state.generations, fn(existing) { existing.id == generation_.id }),
    Error(DuplicateGeneration),
  )
  let was_empty = queue.is_empty(state.queue)
  let ids = generation_.items |> non_empty.to_list |> list.map(fn(item) { item.id })
  use queued <- result.try(
    queue.enqueue_all(state.queue, ids)
    |> result.map_error(fn(_) { QueueInvariant }),
  )
  let next = State([generation_, ..state.generations], queued)
  let effects = case was_empty {
    True -> next_effect(next)
    False -> []
  }
  Ok(Transition(next, effects, [GenerationSubmitted(generation_.id)]))
}

fn started(state: State, item_id: GenerationItemId, at: Instant) -> Result(Transition, DomainError) {
  use <- bool.guard(queue.peek(state.queue) != Ok(item_id), Error(InvalidTransition))
  use generations <- result.try(update_item(state.generations, item_id, fn(item) {
    case item.state {
      generation.Queued(_) ->
        Ok(generation.GenerationItem(
          ..item,
          state: generation.Running(at, generation.ProgressUnknown),
        ))
      _ -> Error(InvalidTransition)
    }
  }))
  Ok(Transition(State(generations, state.queue), [], [GenerationItemStarted(item_id)]))
}

fn progressed(state: State, item_id: GenerationItemId, progress: Progress) -> Result(Transition, DomainError) {
  use generations <- result.try(update_item(state.generations, item_id, fn(item) {
    case item.state {
      generation.Running(at, _) ->
        Ok(generation.GenerationItem(
          ..item,
          state: generation.Running(at, generation.ProgressKnown(progress)),
        ))
      _ -> Error(InvalidTransition)
    }
  }))
  Ok(Transition(State(generations, state.queue), [], []))
}

fn rendered(state: State, item_id: GenerationItemId, image: RenderedImage) -> Result(Transition, DomainError) {
  use generations <- result.try(update_item(state.generations, item_id, fn(item) {
    case item.state {
      generation.Running(_, _) ->
        Ok(generation.GenerationItem(..item, state: generation.Persisting(image)))
      _ -> Error(InvalidTransition)
    }
  }))
  Ok(Transition(
    State(generations, state.queue),
    [PersistImage(item_id, image)],
    [],
  ))
}

fn persisted(state: State, item_id: GenerationItemId, asset: AssetId, at: Instant) -> Result(Transition, DomainError) {
  use generations <- result.try(update_item(state.generations, item_id, fn(item) {
    case item.state {
      generation.Persisting(_) ->
        Ok(generation.GenerationItem(..item, state: generation.Succeeded(asset, at)))
      _ -> Error(InvalidTransition)
    }
  }))
  let next = State(generations, queue.remove(state.queue, item_id))
  Ok(Transition(
    next,
    next_effect(next),
    [GenerationItemSucceeded(item_id, asset)],
  ))
}

fn failed(state: State, item_id: GenerationItemId, failure: GenerationFailure, at: Instant) -> Result(Transition, DomainError) {
  use generations <- result.try(update_item(state.generations, item_id, fn(item) {
    case item.state {
      generation.Queued(_) ->
        Ok(generation.GenerationItem(..item, state: generation.Failed(failure, at)))
      generation.Running(_, _) ->
        Ok(generation.GenerationItem(..item, state: generation.Failed(failure, at)))
      generation.Persisting(_) ->
        Ok(generation.GenerationItem(..item, state: generation.Failed(failure, at)))
      _ -> Error(InvalidTransition)
    }
  }))
  let next = State(generations, queue.remove(state.queue, item_id))
  Ok(Transition(
    next,
    next_effect(next),
    [GenerationItemFailed(item_id, failure)],
  ))
}

fn cancel(state: State, item_id: GenerationItemId, at: Instant) -> Result(Transition, DomainError) {
  use generations <- result.try(update_item(state.generations, item_id, fn(item) {
    case item.state {
      generation.Queued(_) ->
        Ok(generation.GenerationItem(..item, state: generation.Cancelled(at)))
      generation.Running(_, _) ->
        Ok(generation.GenerationItem(..item, state: generation.Cancelled(at)))
      generation.Persisting(_) -> Error(InvalidTransition)
      generation.Succeeded(_, _) -> Error(InvalidTransition)
      generation.Failed(_, _) -> Error(InvalidTransition)
      generation.Cancelled(_) -> Error(InvalidTransition)
    }
  }))
  let was_active = queue.peek(state.queue) == Ok(item_id)
  let next = State(generations, queue.remove(state.queue, item_id))
  let effects = case was_active {
    True -> [CancelRun(item_id), ..next_effect(next)]
    False -> []
  }
  Ok(Transition(next, effects, []))
}

fn next_effect(state: State) -> List(Effect) {
  case queue.peek(state.queue) {
    Error(_) -> []
    Ok(item_id) ->
      case find_generation_for_item(state.generations, item_id) {
        Ok(#(generation_id, _)) -> [RunItem(generation_id, item_id)]
        Error(_) -> []
      }
  }
}

fn find_generation_for_item(
  generations: List(Generation),
  item_id: GenerationItemId,
) -> Result(#(GenerationId, Generation), DomainError) {
  case generations {
    [] -> Error(UnknownItem)
    [generation_, ..rest] ->
      case non_empty.to_list(generation_.items) |> list.any(fn(item) { item.id == item_id }) {
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
          Ok([generation.Generation(..generation_, items: non_empty_items), ..rest])
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
