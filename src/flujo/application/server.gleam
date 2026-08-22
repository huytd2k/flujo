import envoy
import flujo/adapters/runpod_pods as runpod
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http.{Delete, Get, Options, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData}

pub fn main() {
  let config = load_config()
  let port = case envoy.get("PORT") {
    Ok(value) -> int.parse(value) |> result.unwrap(4000)
    Error(_) -> 4000
  }
  let assert Ok(_) =
    fn(request) { handle(request, config) }
    |> mist.new
    |> mist.port(port)
    |> mist.bind("0.0.0.0")
    |> mist.start
  process.sleep_forever()
}

fn load_config() -> Result(runpod.Config, Nil) {
  use api_key <- result.try(envoy.get("RUNPOD_API_KEY"))
  case string.trim(api_key) {
    "" -> Error(Nil)
    api_key -> Ok(runpod.Config(api_key))
  }
}

fn handle(request: Request(Connection), config: Result(runpod.Config, Nil)) -> Response(ResponseData) {
  let config = request_config(request, config)
  case request.method, request.path |> path_segments {
    Options, _ -> respond(204, "")
    Get, ["api", "health"] ->
      respond(200, json.object([
        #("ok", json.bool(True)),
        #("configured", json.bool(result.is_ok(config))),
        #("provider", json.string("runpod-pods")),
      ]) |> json.to_string)
    Post, ["api", "workers"] ->
      with_config(config, runpod.provision, 201)
    Get, ["api", "workers", pod_id] ->
      with_config(config, fn(value) { runpod.pod(value, pod_id) }, 200)
    Get, ["api", "workers", pod_id, "health"] ->
      with_operation(runpod.runtime_health(pod_id), 200)
    Delete, ["api", "workers", pod_id] ->
      with_config(config, fn(value) { runpod.terminate(value, pod_id) }, 200)
    Post, ["api", "workers", pod_id, "generations"] ->
      with_body(request, fn(body) { runpod.submit(pod_id, body) })
    Get, ["api", "workers", pod_id, "jobs", prompt_id] ->
      with_operation(runpod.history(pod_id, prompt_id), 200)
    Post, ["api", "workers", pod_id, "jobs", _, "cancel"] ->
      with_operation(runpod.cancel(pod_id), 200)
    _, _ -> respond(404, error_json("not_found"))
  }
}

fn request_config(
  request: Request(Connection),
  fallback: Result(runpod.Config, Nil),
) -> Result(runpod.Config, Nil) {
  case request.get_header(request, "x-flujo-runpod-key") {
    Ok(api_key) ->
      case string.trim(api_key) {
        "" -> fallback
        api_key -> Ok(runpod.Config(api_key))
      }
    Error(_) -> fallback
  }
}

fn with_body(request: Request(Connection), operation: fn(String) -> Result(String, runpod.Error)) -> Response(ResponseData) {
  case mist.read_body(request, max_body_limit: 10_000_000) {
    Ok(request) ->
      case bit_array.to_string(request.body) {
        Ok(body) -> with_operation(operation(body), 200)
        Error(_) -> respond(400, error_json("invalid_utf8"))
      }
    Error(_) -> respond(413, error_json("body_too_large"))
  }
}

fn with_config(
  config: Result(runpod.Config, Nil),
  operation: fn(runpod.Config) -> Result(String, runpod.Error),
  success_status: Int,
) -> Response(ResponseData) {
  case config {
    Error(_) -> respond(503, error_json("runpod_not_configured"))
    Ok(value) -> with_operation(operation(value), success_status)
  }
}

fn with_operation(operation: Result(String, runpod.Error), success_status: Int) -> Response(ResponseData) {
  case operation {
    Ok("") -> respond(success_status, "{}")
    Ok(body) -> respond(success_status, body)
    Error(runpod.Upstream(status, "")) -> respond(status, error_json("upstream_error"))
    Error(runpod.Upstream(status, body)) -> respond(status, body)
    Error(runpod.InvalidUrl) -> respond(500, error_json("invalid_upstream_url"))
    Error(runpod.InvalidResponse) -> respond(502, error_json("invalid_upstream_response"))
    Error(runpod.Transport) -> respond(502, error_json("upstream_unreachable"))
  }
}

fn respond(status: Int, body: String) -> Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_header("access-control-allow-origin", "*")
  |> response.set_header("access-control-allow-headers", "content-type, x-flujo-runpod-key")
  |> response.set_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn error_json(code: String) -> String {
  json.object([#("error", json.string(code))]) |> json.to_string
}

fn path_segments(path: String) -> List(String) {
  path |> string.split("/") |> list.filter(fn(segment) { segment != "" })
}
