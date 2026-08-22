import flujo/domain/value.{type GenerationItemId}
import gleam/list

pub opaque type GenerationQueue {
  GenerationQueue(List(GenerationItemId))
}

pub type QueueError {
  DuplicateItem
}

pub fn new() -> GenerationQueue {
  GenerationQueue([])
}

pub fn to_list(queue: GenerationQueue) -> List(GenerationItemId) {
  let GenerationQueue(items) = queue
  items
}

pub fn enqueue(
  queue: GenerationQueue,
  item: GenerationItemId,
) -> Result(GenerationQueue, QueueError) {
  let GenerationQueue(items) = queue
  case list.contains(items, item) {
    True -> Error(DuplicateItem)
    False -> Ok(GenerationQueue(list.append(items, [item])))
  }
}

pub fn enqueue_all(
  queue: GenerationQueue,
  items: List(GenerationItemId),
) -> Result(GenerationQueue, QueueError) {
  list.try_fold(items, queue, fn(queue, item) { enqueue(queue, item) })
}

pub fn peek(queue: GenerationQueue) -> Result(GenerationItemId, Nil) {
  let GenerationQueue(items) = queue
  case items {
    [] -> Error(Nil)
    [item, ..] -> Ok(item)
  }
}

pub fn remove(
  queue: GenerationQueue,
  item: GenerationItemId,
) -> GenerationQueue {
  let GenerationQueue(items) = queue
  GenerationQueue(list.filter(items, fn(candidate) { candidate != item }))
}

pub fn is_empty(queue: GenerationQueue) -> Bool {
  let GenerationQueue(items) = queue
  items == []
}
