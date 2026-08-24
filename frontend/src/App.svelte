<script lang="ts">
  import { onMount } from "svelte";
  import {
    api,
    imageUrl,
    runnerWorkflow,
    type Runner,
    type RunnerInstance,
    type SchemaProperty,
  } from "./api";

  type Phase = "offline" | "idle" | "spinning" | "ready" | "running" | "error";
  type Result = { url: string; prompt: string; inputs: Record<string, unknown> };

  const ratios = [
    { label: "1:1", width: 1024, height: 1024 },
    { label: "4:5", width: 832, height: 1040 },
    { label: "16:9", width: 1024, height: 576 },
    { label: "9:16", width: 576, height: 1024 },
  ];

  let runners: Runner[] = [];
  let selectedRunnerId = "";
  let inputs: Record<string, unknown> = {};
  let instance: RunnerInstance | null = null;
  let phase: Phase = "idle";
  let detail = "Choose a runner and create";
  let runId = "";
  let results: Result[] = [];
  let selected: Result | null = null;
  let settingsOpen = false;
  let runToken = 0;

  $: selectedRunner = runners.find((runner) => runner.id === selectedRunnerId);
  $: properties = Object.entries(selectedRunner?.inputSchema.properties || {});
  $: busy = phase === "spinning" || phase === "running";
  $: canRun = String(inputs.prompt || "").trim().length > 0 && selectedRunnerId !== "" && !busy && phase !== "offline";

  onMount(() => {
    initialize();
    const handleKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key === "Enter" && canRun) run();
    };
    window.addEventListener("keydown", handleKey);
    return () => window.removeEventListener("keydown", handleKey);
  });

  async function initialize(attempt = 0) {
    try {
      const [health, available, active] = await Promise.all([
        api.health(),
        api.runners(),
        api.instances().catch(() => []),
      ]);
      if (!health.configured) {
        phase = "offline";
        detail = "Runner provider is not configured";
        return;
      }
      runners = available;
      if (available[0]) selectRunner(available[0].id);
      const matching = active.find((candidate) => candidate.runnerId === available[0]?.id);
      if (matching) {
        instance = await api.instance(matching.id).catch(() => matching);
        const status = await api.ready(matching.id).catch(() => ({ ready: false }));
        phase = status.ready ? "ready" : "spinning";
        detail = status.ready ? "Runner is ready" : "Runner is starting";
      }
    } catch (error) {
      phase = "offline";
      detail = errorMessage(error);
      if (attempt < 5) {
        await sleep(1_000);
        await initialize(attempt + 1);
      }
    }
  }

  function selectRunner(id: string) {
    selectedRunnerId = id;
    const definition = runners.find((runner) => runner.id === id);
    const next: Record<string, unknown> = {};
    for (const [name, property] of Object.entries(definition?.inputSchema.properties || {})) {
      next[name] = property.default ?? defaultValue(name, property);
    }
    inputs = next;
    instance = null;
    phase = "idle";
    detail = "Runner starts on the first run";
  }

  function defaultValue(name: string, property: SchemaProperty): unknown {
    if (name === "seed") return Math.floor(Math.random() * 2_147_483_647);
    if (name === "width" || name === "height") return 1024;
    if (property.type === "array") return [];
    if (property.type === "boolean") return false;
    return "";
  }

  function updateInput(name: string, value: unknown) {
    inputs = { ...inputs, [name]: value };
  }

  function useRatio(width: number, height: number) {
    inputs = { ...inputs, width, height };
  }

  async function ensureRunner(token: number): Promise<RunnerInstance> {
    let spun = false;
    if (!instance || instance.runnerId !== selectedRunnerId) {
      phase = "spinning";
      spun = true;
      detail = `Spinning ${selectedRunner?.name || "runner"}`;
      try {
        instance = await api.spin(selectedRunnerId);
      } catch (error) {
        const active = await api.instances().catch(() => []);
        const started = active.find((candidate) => candidate.runnerId === selectedRunnerId);
        if (!started) throw error;
        instance = await api.instance(started.id).catch(() => started);
      }
    }
    for (let attempt = 0; attempt < 120; attempt += 1) {
      if (token !== runToken) throw new Error("Run cancelled");
      const status = await api.ready(instance.id).catch(() => ({ ready: false }));
      if (status.ready) {
        instance = await api.instance(instance.id);
        if (spun) {
          detail = `Checking ${selectedRunner?.dependencies.length || 0} dependencies`;
          const report = await api.dependencies(instance.id);
          if (!report.ok) {
            const failed = instance;
            const message = report.errors
              .map((error) => `${error.label}: ${error.message}`)
              .join("\n");
            instance = null;
            await api.stop(failed.id).catch(() => undefined);
            throw new Error(message);
          }
          detail =
            report.warnings.length > 0
              ? report.warnings
                  .map((warning) => `${warning.label}: ${warning.message}`)
                  .join("\n")
              : "Runner is ready · dependencies verified";
        } else {
          detail = "Runner is ready";
        }
        phase = "ready";
        return instance;
      }
      detail = attempt < 3 ? "Starting runner" : "Loading model";
      await sleep(5_000);
    }
    throw new Error("Runner did not become ready within 10 minutes");
  }

  async function run() {
    if (!canRun) return;
    const token = ++runToken;
    const submittedInputs = { ...inputs, prompt: String(inputs.prompt).trim() };
    try {
      const active = await ensureRunner(token);
      phase = "running";
      detail = "Submitting run";
      const response = await api.run(active.id, runnerWorkflow(submittedInputs));
      runId = response.prompt_id;
      for (;;) {
        await sleep(1_500);
        if (token !== runToken) return;
        const history = await api.runStatus(active.id, runId);
        const record = history[runId];
        const images = Object.values(record?.outputs || {}).flatMap((output) => output.images || []);
        if (images.length > 0) {
          const created = images.map((image) => ({
            url: imageUrl(active, image),
            prompt: String(submittedInputs.prompt),
            inputs: submittedInputs,
          }));
          results = [...created, ...results];
          selected = created[0];
          phase = "ready";
          detail = `Run completed · ${created.length} output${created.length === 1 ? "" : "s"}`;
          updateInput("seed", Math.floor(Math.random() * 2_147_483_647));
          return;
        }
        if (record?.status?.status_str === "error") throw new Error("Runner failed this run");
        detail = "Runner is rendering";
      }
    } catch (error) {
      if (token !== runToken) return;
      phase = "error";
      detail = errorMessage(error);
    } finally {
      if (token === runToken) runId = "";
    }
  }

  async function cancelRun() {
    const active = instance;
    const activeRun = runId;
    ++runToken;
    runId = "";
    phase = active ? "ready" : "idle";
    detail = "Run cancelled";
    if (active && activeRun) await api.cancelRun(active.id, activeRun).catch(() => undefined);
  }

  function reuse(result: Result) {
    inputs = { ...result.inputs };
    selected = null;
  }

  const sleep = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds));
  const errorMessage = (error: unknown) => error instanceof Error ? error.message : String(error);
</script>

<svelte:head>
  <title>Flujo — Runner studio</title>
  <meta name="description" content="Spin a model runner and turn prompts into images." />
</svelte:head>

<div class="app-shell">
  <aside class="sidebar">
    <div class="wordmark"><span class="mark"></span><span>flujo</span></div>
    <button class="new-button" onclick={() => { selected = null; updateInput("prompt", ""); }}>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14" /></svg>
      New run
    </button>
    <div class="side-section">
      <p class="side-label">This session</p>
      {#if results.length === 0}
        <p class="empty-history">Completed runs will appear here.</p>
      {:else}
        <div class="history-grid">
          {#each results as result}
            <button class:active={selected?.url === result.url} onclick={() => selected = result} aria-label="Open run output">
              <img src={result.url} alt="" />
            </button>
          {/each}
        </div>
      {/if}
    </div>
    <div class="runtime-card">
      <div class="status-line"><span class:phase-error={phase === "error"} class:phase-busy={busy}></span>{phase}</div>
      <strong>{selectedRunner?.name || "No runner"}</strong>
      <small>{detail}</small>
    </div>
  </aside>

  <main>
    <header>
      <div><p class="kicker">Runner studio</p><h1>Turn an idea into an image.</h1></div>
      <label class="runner-select">
        <span>Runner</span>
        <select value={selectedRunnerId} disabled={busy} onchange={(event) => selectRunner(event.currentTarget.value)}>
          {#each runners as runner}<option value={runner.id}>{runner.name}</option>{/each}
        </select>
      </label>
    </header>

    <section class="workspace" aria-live="polite">
      {#if selected}
        <div class="result-stage">
          <img src={selected.url} alt={selected.prompt} />
          <div class="image-actions"><button onclick={() => reuse(selected!)}><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 4v6h6M20 20v-6h-6M5.5 15a7 7 0 0 0 12 2M18.5 9a7 7 0 0 0-12-2" /></svg>Reuse settings</button></div>
          <div class="result-meta"><span>{selected.prompt}</span><span>Seed {String(selected.inputs.seed)}</span></div>
        </div>
      {:else if busy}
        <div class="loading-stage"><div class="orb"><span></span></div><p>{phase === "spinning" ? "Spinning your runner" : "Creating your image"}</p><small>{detail}</small><button onclick={cancelRun}>Cancel</button></div>
      {:else}
        <div class="blank-stage"><div class="spark-mark"><span></span><span></span><span></span></div><h2>Ready when you are.</h2><p>The selected runner exposes its inputs. Add a prompt, tune the run, and create.</p></div>
      {/if}
    </section>

    <section class="composer">
      <label for="prompt">Prompt</label>
      <textarea id="prompt" value={String(inputs.prompt || "")} oninput={(event) => updateInput("prompt", event.currentTarget.value)} placeholder="A quiet coastal motel at blue hour, cinematic light, shot on 35mm…" rows="3"></textarea>
      <div class="composer-toolbar">
        <div class="controls">
          <div class="ratio-control">
            {#each ratios as ratio}
              <button class:active={Number(inputs.width) === ratio.width && Number(inputs.height) === ratio.height} onclick={() => useRatio(ratio.width, ratio.height)}>{ratio.label}</button>
            {/each}
          </div>
          <button class:open={settingsOpen} class="control-button" onclick={() => settingsOpen = !settingsOpen}><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h10M18 7h2M4 17h2M10 17h10M14 4v6M6 14v6" /></svg>Inputs</button>
        </div>
        {#if busy}
          <button class="cancel-button" onclick={cancelRun}>Cancel run</button>
        {:else}
          <button class="generate-button" disabled={!canRun} onclick={run}>Run <span>⌘↵</span></button>
        {/if}
      </div>

      {#if settingsOpen}
        <div class="advanced-panel">
          {#each properties.filter(([name]) => name !== "prompt") as [name, property]}
            <label class:wide-input={property.type === "array"}>
              <span>{property.title || name}</span>
              {#if property.type === "number" || property.type === "integer"}
                <input type="number" value={Number(inputs[name] || 0)} min={property.minimum} max={property.maximum} step={property.multipleOf || "any"} oninput={(event) => updateInput(name, Number(event.currentTarget.value))} />
              {:else if property.type === "boolean"}
                <input type="checkbox" checked={Boolean(inputs[name])} onchange={(event) => updateInput(name, event.currentTarget.checked)} />
              {:else if property.type === "array"}
                <textarea class="json-input" value={JSON.stringify(inputs[name] || [])} oninput={(event) => { try { updateInput(name, JSON.parse(event.currentTarget.value)); } catch { /* keep last valid schema value */ } }}></textarea>
              {:else}
                <input value={String(inputs[name] || "")} oninput={(event) => updateInput(name, event.currentTarget.value)} />
              {/if}
            </label>
          {/each}
        </div>
      {/if}
    </section>
  </main>
</div>
