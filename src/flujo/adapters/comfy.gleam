import gleam/http.{type Method, Get, Post}
import gleam/http/request
import gleam/httpc
import gleam/result

pub type Error {
  InvalidUrl
  InvalidResponse
  Transport
  Upstream(status: Int, body: String)
}

pub fn health(base_url: String) -> Result(String, Error) {
  dispatch(Get, base_url <> "/system_stats", "")
}

pub fn submit(base_url: String, body: String) -> Result(String, Error) {
  dispatch(Post, base_url <> "/prompt", body)
}

pub fn history(base_url: String, job_id: String) -> Result(String, Error) {
  dispatch(Get, base_url <> "/history/" <> job_id, "")
}

pub fn cancel(base_url: String) -> Result(String, Error) {
  dispatch(Post, base_url <> "/interrupt", "{}")
}

@external(erlang, "flujo_http", "get_binary")
fn get_binary(url: String) -> Result(#(Int, String, BitArray), String)

pub fn output(url: String) -> Result(#(Int, String, BitArray), String) {
  get_binary(url)
}

fn dispatch(
  method: Method,
  url: String,
  body: String,
) -> Result(String, Error) {
  use outgoing <- result.try(
    request.to(url) |> result.map_error(fn(_) { InvalidUrl }),
  )
  use response <- result.try(
    outgoing
    |> request.set_method(method)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
    |> httpc.send
    |> result.map_error(fn(_) { Transport }),
  )
  case response.status >= 200 && response.status < 300 {
    True -> Ok(response.body)
    False -> Error(Upstream(response.status, response.body))
  }
}
