import flujo/domain/generation
import flujo/domain/image_size
import flujo/domain/model
import flujo/domain/non_empty
import flujo/domain/queue
import flujo/domain/transition
import flujo/domain/value
import flujo/domain/worker
import gleam/list
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn refined_values_reject_invalid_input_test() {
  value.prompt("   ") |> should.equal(Error(value.EmptyValue))
  value.positive_int(0) |> should.equal(Error(value.NotPositive))
  value.duration(-1) |> should.equal(Error(value.NotPositive))
  value.progress(-0.01) |> should.equal(Error(value.OutOfRange))
  value.progress(1.01) |> should.equal(Error(value.OutOfRange))
  value.progress(1.0) |> should.be_ok
}

pub fn non_empty_and_queue_preserve_invariants_test() {
  non_empty.from_list([]) |> should.be_error
  let assert Ok(id) = value.generation_item_id("item-1")
  let assert Ok(enqueued) = queue.enqueue(queue.new(), id)
  queue.enqueue(enqueued, id) |> should.equal(Error(queue.DuplicateItem))
  queue.to_list(enqueued) |> should.equal([id])
}

pub fn complete_generation_phase_is_derived_test() {
  let #(generation_, _, _, assets) = fixture()
  let assert [asset, ..] = assets
  let complete_items =
    generation_.items
    |> non_empty.map(fn(item) {
      generation.GenerationItem(
        ..item,
        state: generation.Succeeded(asset, value.instant(10)),
      )
    })
  generation.phase(generation.Generation(..generation_, items: complete_items))
  |> should.equal(generation.GenerationComplete)
}

pub fn full_pure_core_lifecycle_test() {
  let #(generation_, model_ref, worker_id, assets) = fixture()
  let assert Ok(idle_duration) = value.duration(1_200_000)
  let state = transition.initial(worker.ShutdownAfterIdle(idle_duration))

  let assert Ok(transition.Transition(state, [transition.ProvisionWorker], _)) =
    transition.transition(state, transition.SubmitGeneration(generation_))
  let assert Ok(transition.Transition(state, [], _)) =
    transition.transition(
      state,
      transition.WorkerProvisioned(worker_id, value.instant(10)),
    )
  let assert Ok(transition.Transition(
    state,
    [transition.LoadModel(_, loaded)],
    _,
  )) =
    transition.transition(
      state,
      transition.WorkerOnline(worker_id, value.instant(20)),
    )
  loaded |> should.equal(model_ref)
  let assert Ok(transition.Transition(
    state,
    [transition.ExecuteItem(_, _, first)],
    _,
  )) =
    transition.transition(
      state,
      transition.ModelLoaded(worker_id, model_ref, value.instant(30)),
    )

  // A stale idle timer is only an observed fact and cannot stop active work.
  let assert Ok(transition.Transition(unchanged, [], [])) =
    transition.transition(
      state,
      transition.IdleDeadlineReached(worker_id, value.instant(9_999_999)),
    )
  unchanged |> should.equal(state)

  let item_ids =
    generation_.items |> non_empty.to_list |> list.map(fn(item) { item.id })
  let assert [first_expected, ..] = item_ids
  first |> should.equal(first_expected)
  let final_state = run_items(state, item_ids, assets, 100)

  let transition.State(generations, worker_state, final_queue, _) = final_state
  queue.is_empty(final_queue) |> should.be_true
  let assert [completed_generation] = generations
  generation.phase(completed_generation)
  |> should.equal(generation.GenerationComplete)
  let assert worker.Ready(_, _, idle_since) = worker_state
  idle_since |> should.equal(value.instant(403))

  let deadline = value.add_duration(idle_since, idle_duration)
  let assert Ok(transition.Transition(stopping, [transition.StopWorker(id)], _)) =
    transition.transition(
      final_state,
      transition.IdleDeadlineReached(worker_id, deadline),
    )
  id |> should.equal(worker_id)
  let assert Ok(transition.Transition(stopped, [], [])) =
    transition.transition(
      stopping,
      transition.WorkerStopped(worker_id, deadline),
    )
  let transition.State(_, final_worker, _, _) = stopped
  final_worker |> should.equal(worker.Sleeping)
}

fn run_items(
  state: transition.State,
  ids: List(value.GenerationItemId),
  assets: List(value.AssetId),
  clock: Int,
) -> transition.State {
  case ids, assets {
    [], [] -> state
    [id, ..rest_ids], [asset, ..rest_assets] -> {
      let assert Ok(transition.Transition(state, [], _)) =
        transition.transition(
          state,
          transition.ItemStarted(id, value.instant(clock)),
        )
      let assert Ok(progress) = value.progress(0.5)
      let assert Ok(transition.Transition(state, [], [])) =
        transition.transition(state, transition.ItemProgressed(id, progress))
      let image = generation.RenderedImage("rendered")
      let assert Ok(transition.Transition(
        state,
        [transition.PersistImage(_, _)],
        [],
      )) = transition.transition(state, transition.ItemRendered(id, image))
      let assert Ok(transition.Transition(state, _, _)) =
        transition.transition(
          state,
          transition.AssetPersisted(id, asset, value.instant(clock + 3)),
        )
      run_items(state, rest_ids, rest_assets, clock + 100)
    }
    _, _ -> panic as "fixture mismatch"
  }
}

fn fixture() -> #(
  generation.Generation,
  model.ModelRef,
  value.WorkerId,
  List(value.AssetId),
) {
  let assert Ok(model_id) = value.model_id("flux-dev")
  let model_ref = model.ModelRef(model_id, "1")
  let assert Ok(max_images) = value.positive_int(2)
  let assert Ok(max_batch) = value.positive_int(4)
  let assert Ok(max_loras) = value.positive_int(2)
  let profile =
    model.ModelProfile(
      model_ref,
      "FLUX Dev",
      model.Flux,
      model.TextAndImages(max_images),
      model.SizePolicy(256, 2048, 16, 2_097_152),
      model.BatchPolicy(max_batch),
      model.LoraSupported(max_loras, model.WeightRange(-2.0, 2.0)),
    )
  let assert Ok(prompt) = value.prompt("a glass city in morning light")
  let assert Ok(size) = image_size.new(1024, 1024, profile.size_policy)
  let assert Ok(empty_loras) = generation.lora_stack([], [], profile)
  let assert Ok(steps) = value.positive_int(28)
  let specs =
    non_empty.from_parts(generation.GenerationItemSpec(value.seed(11)), [
      generation.GenerationItemSpec(value.seed(22)),
      generation.GenerationItemSpec(value.seed(33)),
      generation.GenerationItemSpec(value.seed(44)),
    ])
  let assert Ok(spec) =
    generation.spec(
      profile,
      generation.TextToImage(prompt),
      size,
      specs,
      empty_loras,
      model.FluxParams(model.FluxParameters(steps, 3.5)),
    )
  let ids =
    ["item-1", "item-2", "item-3", "item-4"]
    |> list.map(fn(raw) {
      let assert Ok(id) = value.generation_item_id(raw)
      id
    })
  let seeds = non_empty.to_list(specs)
  let items =
    list.map2(ids, seeds, fn(id, item_spec) {
      generation.GenerationItem(
        id,
        item_spec,
        generation.Queued(value.instant(0)),
      )
    })
  let assert Ok(items) = non_empty.from_list(items)
  let assert Ok(generation_id) = value.generation_id("generation-1")
  let assert Ok(worker_id) = value.worker_id("worker-1")
  let assets =
    ["asset-1", "asset-2", "asset-3", "asset-4"]
    |> list.map(fn(raw) {
      let assert Ok(id) = value.asset_id(raw)
      id
    })
  #(
    generation.Generation(generation_id, value.instant(0), spec, items),
    model_ref,
    worker_id,
    assets,
  )
}
