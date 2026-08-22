import gleam/http.{type Method, Delete, Get, Post}
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/result

pub type Config {
  Config(api_key: String)
}

pub type Error {
  InvalidUrl
  InvalidResponse
  Transport
  Upstream(status: Int, body: String)
}

const runpod_url = "https://rest.runpod.io/v1"
const template_id = "7d5q9pntz6"

pub fn provision(config: Config) -> Result(String, Error) {
  let body =
    json.object([
      #("name", json.string("flujo-krea2")),
      #("computeType", json.string("GPU")),
      #("cloudType", json.string("COMMUNITY")),
      #("gpuCount", json.int(1)),
      #("gpuTypeIds", json.array([
        "NVIDIA GeForce RTX 3090", "NVIDIA GeForce RTX 4090",
        "NVIDIA RTX A5000", "NVIDIA RTX A6000",
      ], json.string)),
      #("gpuTypePriority", json.string("availability")),
      #("containerDiskInGb", json.int(50)),
      #("volumeInGb", json.int(20)),
      #("volumeMountPath", json.string("/workspace")),
      #("templateId", json.string(template_id)),
      #("ports", json.array(["8188/http", "22/tcp"], json.string)),
      #("supportPublicIp", json.bool(True)),
    ])
    |> json.to_string
  runpod(config, Post, "/pods", body)
}

pub fn pod(config: Config, pod_id: String) -> Result(String, Error) {
  runpod(config, Get, "/pods/" <> pod_id, "")
}

pub fn terminate(config: Config, pod_id: String) -> Result(String, Error) {
  runpod(config, Delete, "/pods/" <> pod_id, "")
}

pub fn runtime_health(pod_id: String) -> Result(String, Error) {
  comfy(pod_id, Get, "/system_stats", "")
}

pub fn submit(pod_id: String, body: String) -> Result(String, Error) {
  comfy(pod_id, Post, "/prompt", body)
}

pub fn history(pod_id: String, prompt_id: String) -> Result(String, Error) {
  comfy(pod_id, Get, "/history/" <> prompt_id, "")
}

pub fn cancel(pod_id: String) -> Result(String, Error) {
  comfy(pod_id, Post, "/interrupt", "{}")
}

fn runpod(config: Config, method: Method, path: String, body: String) -> Result(String, Error) {
  let Config(api_key) = config
  dispatch(method, runpod_url <> path, body, [#("authorization", "Bearer " <> api_key)])
}

fn comfy(pod_id: String, method: Method, path: String, body: String) -> Result(String, Error) {
  dispatch(method, "https://" <> pod_id <> "-8188.proxy.runpod.net" <> path, body, [])
}

fn dispatch(method: Method, url: String, body: String, headers: List(#(String, String))) -> Result(String, Error) {
  use outgoing <- result.try(request.to(url) |> result.map_error(fn(_) { InvalidUrl }))
  let outgoing =
    headers
    |> list.fold(
      outgoing |> request.set_method(method) |> request.set_header("content-type", "application/json") |> request.set_body(body),
      fn(request_, header) { request.set_header(request_, header.0, header.1) },
    )
  use response <- result.try(
    httpc.configure()
    |> httpc.timeout(30_000)
    |> httpc.dispatch(outgoing)
    |> result.map_error(fn(_) { Transport }),
  )
  case response.status >= 200 && response.status < 300 {
    True -> Ok(response.body)
    False -> Error(Upstream(response.status, response.body))
  }
}
