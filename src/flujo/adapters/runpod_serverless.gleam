import gleam/http.{type Method, Get, Post}
import gleam/http/request
import gleam/httpc
import gleam/result

pub type Config {
  Config(api_key: String, endpoint_id: String)
}

pub type Error {
  InvalidUrl
  Transport
  Upstream(status: Int, body: String)
}

const base_url = "https://api.runpod.ai/v2/"

pub fn submit(config: Config, body: String) -> Result(String, Error) {
  call(config, Post, "/run", body)
}

pub fn status(config: Config, job_id: String) -> Result(String, Error) {
  call(config, Get, "/status/" <> job_id, "")
}

pub fn cancel(config: Config, job_id: String) -> Result(String, Error) {
  call(config, Post, "/cancel/" <> job_id, "{}")
}

fn call(
  config: Config,
  method: Method,
  path: String,
  body: String,
) -> Result(String, Error) {
  let Config(api_key, endpoint_id) = config
  let parsed =
    result.map_error(request.to(base_url <> endpoint_id <> path), fn(_) {
      InvalidUrl
    })
  use outgoing <- result.try(parsed)
  let outgoing =
    outgoing
    |> request.set_method(method)
    |> request.set_header("authorization", "Bearer " <> api_key)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  let dispatched =
    result.map_error(
      httpc.configure()
        |> httpc.timeout(30_000)
        |> httpc.dispatch(outgoing),
      fn(_) { Transport },
    )
  use response <- result.try(dispatched)
  case response.status >= 200 && response.status < 300 {
    True -> Ok(response.body)
    False -> Error(Upstream(response.status, response.body))
  }
}
