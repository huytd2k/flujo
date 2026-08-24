import envoy
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type Error {
  DockerUnavailable(String)
  UnknownRunner
}

@external(erlang, "flujo_docker", "run")
fn command(arguments: List(String)) -> Result(String, String)

pub fn definitions() -> String {
  json_values([
    json.object([
      #("id", json.string("krea2-svdquant")),
      #("name", json.string("Krea 2 Turbo SVDQuant")),
      #("image", json.string(image())),
      #(
        "inputSchema",
        json.object([
          #("type", json.string("object")),
          #(
            "required",
            json_values([
              json.string("prompt"),
              json.string("seed"),
              json.string("width"),
              json.string("height"),
            ]),
          ),
          #(
            "properties",
            json.object([
              #("prompt", schema_property("string")),
              #("seed", schema_property("integer")),
              #("width", integer_property()),
              #("height", integer_property()),
              #(
                "modelPath",
                json.object([
                  #("type", json.string("string")),
                  #(
                    "default",
                    json.string(
                      "Krea2-Turbo-SVDQuant-W4A4-rank256-actaware.safetensors",
                    ),
                  ),
                ]),
              ),
              #("loras", loras_property()),
            ]),
          ),
        ]),
      ),
      #("dependencies", dependency_requirements()),
      #("outputSchema", output_schema()),
    ]),
  ])
  |> json.to_string
}

fn json_values(values: List(json.Json)) -> json.Json {
  json.array(values, of: fn(value) { value })
}

fn dependency_requirements() -> json.Json {
  json_values([
    json.object([
      #("id", json.string("gpu")),
      #("label", json.string("NVIDIA GPU")),
      #("kind", json.string("gpu")),
      #("minimum", json.int(1)),
    ]),
    file_requirement(
      "diffusion-model",
      "Krea 2 diffusion model",
      "/opt/ComfyUI/models/diffusion_models/Krea2-Turbo-SVDQuant-W4A4-rank256-actaware.safetensors",
      "43f1982c5a29ad738190b27acaeb288d",
    ),
    file_requirement(
      "text-encoder",
      "Qwen text encoder",
      "/opt/ComfyUI/models/text_encoders/qwen3vl_4b_fp8_scaled.safetensors",
      "e4bb7e5518fec2f8e3fd21a7f30d32fd",
    ),
    file_requirement(
      "vae",
      "Qwen image VAE",
      "/opt/ComfyUI/models/vae/qwen_image_vae.safetensors",
      "5f09a128b4c05c9998b9f218dc137b7b",
    ),
    file_requirement(
      "lora",
      "Default LoRA",
      "/opt/ComfyUI/models/loras/bld_lora.safetensors",
      "5648922235d879abc23a208944c9f3c1",
    ),
  ])
}

fn file_requirement(
  id: String,
  label: String,
  path: String,
  md5: String,
) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("label", json.string(label)),
    #("kind", json.string("file")),
    #("path", json.string(path)),
    #("md5", json.string(md5)),
  ])
}

fn schema_property(kind: String) -> json.Json {
  json.object([#("type", json.string(kind))])
}

fn integer_property() -> json.Json {
  json.object([
    #("type", json.string("integer")),
    #("multipleOf", json.int(16)),
  ])
}

fn loras_property() -> json.Json {
  json.object([
    #("type", json.string("array")),
    #(
      "items",
      json.object([
        #("type", json.string("object")),
        #("required", json_values([json.string("path"), json.string("weight")])),
        #(
          "properties",
          json.object([
            #("path", schema_property("string")),
            #("weight", schema_property("number")),
          ]),
        ),
      ]),
    ),
  ])
}

fn output_schema() -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("required", json_values([json.string("images"), json.string("metadata")])),
    #(
      "properties",
      json.object([
        #("images", schema_property("array")),
        #(
          "metadata",
          json.object([
            #("type", json.string("object")),
            #(
              "properties",
              json.object([
                #("runtimeMs", schema_property("integer")),
                #("seed", schema_property("integer")),
                #("runnerImage", schema_property("string")),
              ]),
            ),
          ]),
        ),
      ]),
    ),
  ])
}

pub fn start(id: String) -> Result(String, Error) {
  case id {
    "krea2-svdquant" -> {
      let base = [
        "run", "--detach", "--rm", "--label", "ai.flujo.runner=krea2-svdquant",
        "--publish", "127.0.0.1::8188",
      ]
      let base = list.append(base, gpu_arguments())
      let args = case envoy.get("FLUJO_MODELS_DIR") {
        Ok(path) if path != "" ->
          list.append(base, ["--volume", path <> ":/opt/ComfyUI/models:ro"])
        _ -> base
      }
      let args = case envoy.get("FLUJO_DIFFUSION_MODELS_DIR") {
        Ok(path) if path != "" ->
          list.append(args, [
            "--volume",
            path <> ":/opt/ComfyUI/models/diffusion_models:ro",
          ])
        _ -> args
      }
      command(list.append(args, [image()]))
      |> map_error
    }
    _ -> Error(UnknownRunner)
  }
}

fn gpu_arguments() -> List(String) {
  case envoy.get("FLUJO_DOCKER_GPU_MODE") {
    Ok("toolkit") -> ["--gpus", "all"]
    _ -> [
      "--env", "CUDA_VISIBLE_DEVICES=0", "--env",
      "LD_LIBRARY_PATH=/usr/local/nvidia/lib64", "--device",
      "/dev/nvidia0:/dev/nvidia0", "--device", "/dev/nvidiactl:/dev/nvidiactl",
      "--device", "/dev/nvidia-uvm:/dev/nvidia-uvm", "--device",
      "/dev/nvidia-uvm-tools:/dev/nvidia-uvm-tools", "--volume",
      "/usr/lib/x86_64-linux-gnu/libcuda.so.610.57.04:/usr/local/nvidia/lib64/libcuda.so.1:ro",
      "--volume",
      "/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.610.57.04:/usr/local/nvidia/lib64/libnvidia-ml.so.1:ro",
      "--volume",
      "/usr/lib/x86_64-linux-gnu/libnvidia-ptxjitcompiler.so.610.57.04:/usr/local/nvidia/lib64/libnvidia-ptxjitcompiler.so.1:ro",
      "--volume",
      "/usr/lib/x86_64-linux-gnu/libnvidia-gpucomp.so.610.57.04:/usr/local/nvidia/lib64/libnvidia-gpucomp.so.610.57.04:ro",
    ]
  }
}

pub fn instances() -> Result(String, Error) {
  command([
    "ps", "--filter", "label=ai.flujo.runner", "--format",
    "{\"id\":\"{{.ID}}\",\"image\":\"{{.Image}}\",\"status\":\"{{.Status}}\",\"runnerId\":\"{{.Label \"ai.flujo.runner\"}}\"}",
  ])
  |> map_error
  |> result_map_lines
}

type DependencyCheck {
  DependencyCheck(
    id: String,
    label: String,
    ok: Bool,
    warning: Bool,
    detail: String,
  )
}

pub fn dependencies(id: String) -> Result(String, Error) {
  let checks = [
    gpu_check(id),
    file_check(
      id,
      "diffusion-model",
      "Krea 2 diffusion model",
      "/opt/ComfyUI/models/diffusion_models/Krea2-Turbo-SVDQuant-W4A4-rank256-actaware.safetensors",
      "43f1982c5a29ad738190b27acaeb288d",
    ),
    file_check(
      id,
      "text-encoder",
      "Qwen text encoder",
      "/opt/ComfyUI/models/text_encoders/qwen3vl_4b_fp8_scaled.safetensors",
      "e4bb7e5518fec2f8e3fd21a7f30d32fd",
    ),
    file_check(
      id,
      "vae",
      "Qwen image VAE",
      "/opt/ComfyUI/models/vae/qwen_image_vae.safetensors",
      "5f09a128b4c05c9998b9f218dc137b7b",
    ),
    file_check(
      id,
      "lora",
      "Default LoRA",
      "/opt/ComfyUI/models/loras/bld_lora.safetensors",
      "5648922235d879abc23a208944c9f3c1",
    ),
  ]
  let errors =
    checks
    |> list.filter(fn(check) {
      let DependencyCheck(_, _, ok, _, _) = check
      !ok
    })
    |> list.map(dependency_issue_json)
  let warnings =
    checks
    |> list.filter(fn(check) {
      let DependencyCheck(_, _, _, warning, _) = check
      warning
    })
    |> list.map(dependency_issue_json)
  Ok(
    json.object([
      #("ok", json.bool(list.is_empty(errors))),
      #("checks", json_values(list.map(checks, dependency_check_json))),
      #("errors", json_values(errors)),
      #("warnings", json_values(warnings)),
    ])
    |> json.to_string,
  )
}

fn gpu_check(id: String) -> DependencyCheck {
  case
    command([
      "exec",
      id,
      "/opt/venv/bin/python",
      "-c",
      "import torch; print(torch.cuda.device_count())",
    ])
  {
    Ok(output) ->
      case int.parse(string.trim(output)) {
        Ok(count) ->
          case count >= 1 {
            True ->
              DependencyCheck(
                "gpu",
                "NVIDIA GPU",
                True,
                False,
                int.to_string(count) <> " GPU(s) available",
              )
            False ->
              DependencyCheck(
                "gpu",
                "NVIDIA GPU",
                False,
                False,
                "At least 1 GPU is required; found 0",
              )
          }
        Error(_) ->
          DependencyCheck(
            "gpu",
            "NVIDIA GPU",
            False,
            False,
            "GPU check returned an invalid count: " <> string.trim(output),
          )
      }
    Error(error) -> DependencyCheck("gpu", "NVIDIA GPU", False, False, error)
  }
}

fn file_check(
  instance_id: String,
  dependency_id: String,
  label: String,
  path: String,
  expected_md5: String,
) -> DependencyCheck {
  case command(["exec", instance_id, "md5sum", path]) {
    Ok(output) ->
      case string.split(output, " ") |> list.first {
        Ok(actual_md5) if actual_md5 == expected_md5 ->
          DependencyCheck(dependency_id, label, True, False, "MD5 verified")
        Ok(actual_md5) ->
          DependencyCheck(
            dependency_id,
            label,
            True,
            True,
            "MD5 mismatch: expected " <> expected_md5 <> ", got " <> actual_md5,
          )
        Error(_) ->
          DependencyCheck(
            dependency_id,
            label,
            False,
            False,
            "md5sum returned no digest for " <> path,
          )
      }
    Error(error) -> DependencyCheck(dependency_id, label, False, False, error)
  }
}

fn dependency_issue_json(check: DependencyCheck) -> json.Json {
  let DependencyCheck(id, label, _, _, detail) = check
  json.object([
    #("id", json.string(id)),
    #("label", json.string(label)),
    #("message", json.string(detail)),
  ])
}

fn dependency_check_json(check: DependencyCheck) -> json.Json {
  let DependencyCheck(id, label, ok, warning, detail) = check
  let status = case ok, warning {
    False, _ -> "error"
    True, True -> "warning"
    True, False -> "ok"
  }
  json.object([
    #("id", json.string(id)),
    #("label", json.string(label)),
    #("status", json.string(status)),
    #("detail", json.string(detail)),
  ])
}

pub fn logs(id: String) -> Result(String, Error) {
  command(["logs", "--tail", "100", id]) |> map_error
}

pub fn stop(id: String) -> Result(String, Error) {
  command(["rm", "--force", id]) |> map_error
}

pub fn port(id: String) -> Result(String, Error) {
  command(["port", id, "8188/tcp"])
  |> map_error
  |> result.map(fn(value) {
    value |> string.split(":") |> list.last |> result.unwrap("")
  })
}

fn image() -> String {
  envoy.get("FLUJO_RUNNER_IMAGE") |> result.unwrap("flujo-comfy:cu130")
}

fn map_error(value: Result(String, String)) -> Result(String, Error) {
  result.map_error(value, DockerUnavailable)
}

fn result_map_lines(value: Result(String, Error)) -> Result(String, Error) {
  result.map(value, fn(output) {
    let entries = output |> string.split("\n") |> list.filter(fn(x) { x != "" })
    "[" <> string.join(entries, ",") <> "]"
  })
}
