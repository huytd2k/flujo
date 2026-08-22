import envoy
import flujo/adapters/runpod_serverless as runpod
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http.{Get, Options, Post}
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
  let port = envoy.get("PORT") |> result.then(int.parse) |> result.unwrap(4000)
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
  use endpoint <- result.try(envoy.get("RUNPOD_ENDPOINT_ID"))
  Ok(runpod.Config(api_key, endpoint))
}

fn handle(
  request: Request(Connection),
  config: Result(runpod.Config, Nil),
) -> Response(ResponseData) {
  case request.method, request.path |> path_segments {
    Options, _ -> respond(204, "")
    Get, ["api", "health"] ->
      respond(
        200,
        json.to_string(
          json.object([
            #("ok", json.bool(True)),
            #("configured", json.bool(result.is_ok(config))),
            #("provider", json.string("runpod-serverless")),
          ]),
        ),
      )
    Post, ["api", "generations"] -> with_body(request, config, runpod.submit)
    Get, ["api", "jobs", job_id] ->
      with_config(config, fn(value) { runpod.status(value, job_id) })
    Post, ["api", "jobs", job_id, "cancel"] ->
      with_config(config, fn(value) { runpod.cancel(value, job_id) })
    _, _ -> respond(404, error_json("not_found"))
  }
}

fn with_body(
  request: Request(Connection),
  config: Result(runpod.Config, Nil),
  operation: fn(runpod.Config, String) -> Result(String, runpod.Error),
) -> Response(ResponseData) {
  case mist.read_body(request, max_body_limit: 10_000_000) {
    Ok(request) ->
      case bit_array.to_string(request.body) {
        Ok(body) -> with_config(config, fn(value) { operation(value, body) })
        Error(_) -> respond(400, error_json("invalid_utf8"))
      }
    Error(_) -> respond(413, error_json("body_too_large"))
  }
}

fn with_config(
  config: Result(runpod.Config, Nil),
  operation: fn(runpod.Config) -> Result(String, runpod.Error),
) -> Response(ResponseData) {
  case config {
    Error(_) -> respond(503, error_json("runpod_not_configured"))
    Ok(value) ->
      case operation(value) {
        Ok(body) -> respond(200, body)
        Error(runpod.Upstream(status, body)) -> respond(status, body)
        Error(runpod.InvalidUrl) ->
          respond(500, error_json("invalid_runpod_url"))
        Error(runpod.Transport) ->
          respond(502, error_json("runpod_unreachable"))
      }
  }
}

fn respond(status: Int, body: String) -> Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_header("access-control-allow-origin", "*")
  |> response.set_header("access-control-allow-headers", "content-type")
  |> response.set_header("access-control-allow-methods", "GET, POST, OPTIONS")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn error_json(code: String) -> String {
  json.object([#("error", json.string(code))]) |> json.to_string
}

fn path_segments(path: String) -> List(String) {
  path
  |> string.split("/")
  |> list.filter(fn(segment) { segment != "" })
}
