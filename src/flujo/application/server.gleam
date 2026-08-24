import envoy
import flujo/adapters/comfy as runtime
import flujo/adapters/docker
import flujo/static
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http.{Delete, Get, Options, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree
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

type Provider {
  Docker
}

fn load_config() -> Provider {
  Docker
}

fn handle(
  request: Request(Connection),
  provider: Provider,
) -> Response(ResponseData) {
  let provider = request_config(request, provider)
  case request.method, request.path |> path_segments {
    Options, _ -> respond(204, "")
    Get, ["api", "health"] ->
      respond(
        200,
        json.object([
          #("ok", json.bool(True)),
          #("configured", json.bool(provider_configured(provider))),
          #("provider", json.string(provider_name(provider))),
          #("imageBaseUrl", json.string("")),
        ])
          |> json.to_string,
      )
    Get, ["api", "runners"] -> respond(200, docker.definitions())
    Get, ["api", "runner-instances"] -> docker_instances()
    Post, ["api", "runners", runner_id, "instances"] -> docker_start(runner_id)
    Get, ["api", "runner-instances", instance_id] ->
      get_runner_instance(instance_id)
    Get, ["api", "runner-instances", instance_id, "health"] ->
      runtime_readiness(provider_health(provider, instance_id))
    Get, ["api", "runner-instances", instance_id, "dependencies"] ->
      runner_dependencies(instance_id)
    Get, ["api", "runner-instances", instance_id, "outputs"] ->
      runner_output(request, instance_id)
    Get, ["api", "runner-instances", instance_id, "logs"] ->
      runner_logs(request, instance_id)
    Post, ["api", "runner-instances", instance_id, "runs"] ->
      with_body(request, fn(body) {
        provider_submit(provider, instance_id, body)
      })
    Get, ["api", "runner-instances", instance_id, "runs", run_id] ->
      with_operation(provider_history(provider, instance_id, run_id), 200)
    Post, ["api", "runner-instances", instance_id, "runs", _, "cancel"] ->
      with_operation(provider_cancel(provider, instance_id), 200)
    Delete, ["api", "runner-instances", instance_id] -> docker_stop(instance_id)
    Get, ["api", ..] -> respond(404, error_json("not_found"))
    Get, ["assets", ..asset_path] ->
      serve_file("/app/public/assets/" <> string.join(asset_path, "/"))
    Get, _ -> serve_file("/app/public/index.html")
    _, _ -> respond(404, error_json("not_found"))
  }
}

fn runtime_readiness(
  result: Result(String, runtime.Error),
) -> Response(ResponseData) {
  case result {
    Ok(_) ->
      respond(200, json.object([#("ready", json.bool(True))]) |> json.to_string)
    Error(runtime.Upstream(404, _)) ->
      respond(
        200,
        json.object([#("ready", json.bool(False))]) |> json.to_string,
      )
    Error(runtime.Upstream(502, _)) ->
      respond(
        200,
        json.object([#("ready", json.bool(False))]) |> json.to_string,
      )
    Error(runtime.Upstream(503, _)) ->
      respond(
        200,
        json.object([#("ready", json.bool(False))]) |> json.to_string,
      )
    Error(runtime.Transport) ->
      respond(
        200,
        json.object([#("ready", json.bool(False))]) |> json.to_string,
      )
    Error(error) -> with_operation(Error(error), 200)
  }
}

fn runner_dependencies(id: String) -> Response(ResponseData) {
  case docker.dependencies(id) {
    Ok(report) -> respond(200, report)
    Error(error) -> docker_error(error)
  }
}

type LogMessage {
  PollLogs
}

type LogState {
  LogState(id: String, previous: String, subject: Subject(LogMessage))
}

fn runner_logs(
  request: Request(Connection),
  id: String,
) -> Response(ResponseData) {
  mist.server_sent_events(
    request,
    response.new(200),
    fn(subject) {
      process.send_after(subject, 0, PollLogs)
      LogState(id, "", subject)
    },
    fn(state, message, connection) {
      case message {
        PollLogs -> {
          let next = case docker.logs(state.id) {
            Ok(logs) if logs != state.previous -> {
              let log_event =
                logs
                |> string_tree.from_string
                |> mist.event
                |> mist.event_name("logs")
              let _ = mist.send_event(connection, log_event)

              LogState(..state, previous: logs)
            }
            Ok(_) -> state
            Error(error) -> {
              let error_message = case error {
                docker.DockerUnavailable(message) -> message
                docker.UnknownRunner -> "unknown runner"
              }
              let error_event =
                error_message
                |> string_tree.from_string
                |> mist.event
                |> mist.event_name("error")
              let _ = mist.send_event(connection, error_event)
              state
            }
          }
          process.send_after(next.subject, 1000, PollLogs)
          actor.continue(next)
        }
      }
    },
  )
}

fn runner_output(
  request: Request(Connection),
  id: String,
) -> Response(ResponseData) {
  case docker.port(id) {
    Error(error) -> docker_error(error)
    Ok(port) -> {
      let query = option.unwrap(request.query, "")
      let suffix = case query {
        "" -> ""
        value -> "?" <> value
      }
      case runtime.output("http://127.0.0.1:" <> port <> "/view" <> suffix) {
        Ok(#(status, content_type, body)) ->
          response.new(status)
          |> response.set_header("content-type", content_type)
          |> response.set_header(
            "cache-control",
            "public, max-age=31536000, immutable",
          )
          |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
        Error(message) ->
          respond(
            502,
            json.object([
              #("error", json.string("runner_output_unavailable")),
              #("message", json.string(message)),
            ])
              |> json.to_string,
          )
      }
    }
  }
}

fn serve_file(path: String) -> Response(ResponseData) {
  case static.read(path) {
    Ok(body) ->
      response.new(200)
      |> response.set_header("content-type", content_type(path))
      |> response.set_header(
        "cache-control",
        case string.ends_with(path, "index.html") {
          True -> "no-cache"
          False -> "public, max-age=31536000, immutable"
        },
      )
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
    Error(_) -> respond(404, error_json("asset_not_found"))
  }
}

fn content_type(path: String) -> String {
  case
    string.ends_with(path, ".html"),
    string.ends_with(path, ".css"),
    string.ends_with(path, ".js"),
    string.ends_with(path, ".svg"),
    string.ends_with(path, ".png"),
    string.ends_with(path, ".webp")
  {
    True, _, _, _, _, _ -> "text/html; charset=utf-8"
    _, True, _, _, _, _ -> "text/css; charset=utf-8"
    _, _, True, _, _, _ -> "text/javascript; charset=utf-8"
    _, _, _, True, _, _ -> "image/svg+xml"
    _, _, _, _, True, _ -> "image/png"
    _, _, _, _, _, True -> "image/webp"
    _, _, _, _, _, _ -> "application/octet-stream"
  }
}

fn request_config(
  _request: Request(Connection),
  provider: Provider,
) -> Provider {
  provider
}

fn provider_configured(provider: Provider) -> Bool {
  case provider {
    Docker -> True
  }
}

fn provider_name(provider: Provider) -> String {
  case provider {
    Docker -> "docker-runners"
  }
}

fn get_runner_instance(id: String) -> Response(ResponseData) {
  case docker.port(id) {
    Ok(port) -> respond(200, runner_instance_json(id, port))
    Error(error) -> docker_error(error)
  }
}

fn provider_health(
  _provider: Provider,
  id: String,
) -> Result(String, runtime.Error) {
  use port <- result.try(docker.port(id) |> docker_to_runtime_error)
  runtime.health("http://127.0.0.1:" <> port)
}

fn provider_submit(
  _provider: Provider,
  id: String,
  body: String,
) -> Result(String, runtime.Error) {
  use port <- result.try(docker.port(id) |> docker_to_runtime_error)
  runtime.submit("http://127.0.0.1:" <> port, body)
}

fn provider_history(
  _provider: Provider,
  id: String,
  prompt_id: String,
) -> Result(String, runtime.Error) {
  use port <- result.try(docker.port(id) |> docker_to_runtime_error)
  runtime.generation("http://127.0.0.1:" <> port, prompt_id)
}

fn provider_cancel(
  _provider: Provider,
  id: String,
) -> Result(String, runtime.Error) {
  use port <- result.try(docker.port(id) |> docker_to_runtime_error)
  runtime.cancel("http://127.0.0.1:" <> port)
}

fn with_body(
  request: Request(Connection),
  operation: fn(String) -> Result(String, runtime.Error),
) -> Response(ResponseData) {
  case mist.read_body(request, max_body_limit: 10_000_000) {
    Ok(request) ->
      case bit_array.to_string(request.body) {
        Ok(body) -> with_operation(operation(body), 200)
        Error(_) -> respond(400, error_json("invalid_utf8"))
      }
    Error(_) -> respond(413, error_json("body_too_large"))
  }
}

fn with_operation(
  operation: Result(String, runtime.Error),
  success_status: Int,
) -> Response(ResponseData) {
  case operation {
    Ok("") -> respond(success_status, "{}")
    Ok(body) -> respond(success_status, body)
    Error(runtime.Upstream(status, "")) ->
      respond(status, error_json("upstream_error"))
    Error(runtime.Upstream(status, body)) -> respond(status, body)
    Error(runtime.InvalidUrl) ->
      respond(500, error_json("invalid_upstream_url"))
    Error(runtime.InvalidResponse) ->
      respond(502, error_json("invalid_upstream_response"))
    Error(runtime.Transport) -> respond(502, error_json("upstream_unreachable"))
  }
}

fn docker_start(runner_id: String) -> Response(ResponseData) {
  case docker.start(runner_id) {
    Ok(id) ->
      case docker.port(id) {
        Ok(port) -> respond(201, runner_instance_json(id, port))
        Error(error) -> docker_error(error)
      }
    Error(error) -> docker_error(error)
  }
}

fn docker_instances() -> Response(ResponseData) {
  case docker.instances() {
    Ok(body) -> respond(200, body)
    Error(error) -> docker_error(error)
  }
}

fn docker_stop(id: String) -> Response(ResponseData) {
  case docker.stop(id) {
    Ok(_) -> respond(200, "{}")
    Error(error) -> docker_error(error)
  }
}

fn docker_error(error: docker.Error) -> Response(ResponseData) {
  case error {
    docker.UnknownRunner -> respond(404, error_json("unknown_runner"))
    docker.DockerUnavailable(message) ->
      respond(
        503,
        json.object([
          #("error", json.string("docker_error")),
          #("message", json.string(message)),
        ])
          |> json.to_string,
      )
  }
}

fn docker_to_runtime_error(
  value: Result(String, docker.Error),
) -> Result(String, runtime.Error) {
  result.map_error(value, fn(_) { runtime.Transport })
}

fn runner_instance_json(id: String, port: String) -> String {
  json.object([
    #("id", json.string(id)),
    #("name", json.string("Krea 2 runner")),
    #("desiredStatus", json.string("RUNNING")),
    #("port", json.string(port)),
    #("runnerId", json.string("krea2-svdquant")),
  ])
  |> json.to_string
}

fn respond(status: Int, body: String) -> Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_header("access-control-allow-origin", "*")
  |> response.set_header("access-control-allow-headers", "content-type")
  |> response.set_header(
    "access-control-allow-methods",
    "GET, POST, DELETE, OPTIONS",
  )
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn error_json(code: String) -> String {
  json.object([#("error", json.string(code))]) |> json.to_string
}

fn path_segments(path: String) -> List(String) {
  path |> string.split("/") |> list.filter(fn(segment) { segment != "" })
}
