import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/http.{type Method, Get, Post}
import gleam/http/request
import gleam/httpc
import gleam/json
import gleam/list
import gleam/result
import gleam/string

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

pub type OutputImage {
  OutputImage(filename: String, subfolder: String, kind: String)
}

type RunRecord {
  RunRecord(status: String, images: List(OutputImage))
}

pub fn generation(base_url: String, job_id: String) -> Result(String, Error) {
  use history_body <- result.try(history(base_url, job_id))
  use records <- result.try(
    json.parse(history_body, using: records_decoder())
    |> result.map_error(fn(_) { InvalidResponse }),
  )
  case dict.get(records, job_id) {
    Ok(record) -> Ok(generation_json(job_id, record))
    Error(_) -> {
      use queue_body <- result.try(dispatch(Get, base_url <> "/queue", ""))
      let state = case string.contains(queue_body, job_id) {
        True -> "running"
        False -> "unknown"
      }
      Ok(generation_state_json(job_id, state, "Waiting for runner status", []))
    }
  }
}

fn records_decoder() -> Decoder(Dict(String, RunRecord)) {
  decode.dict(decode.string, record_decoder())
}

fn record_decoder() -> Decoder(RunRecord) {
  use status <- decode.optional_field("status", "", {
    use value <- decode.optional_field("status_str", "", decode.string)
    decode.success(value)
  })
  use outputs <- decode.optional_field(
    "outputs",
    dict.new(),
    decode.dict(decode.string, output_decoder()),
  )
  let images = outputs |> dict.values |> list.flat_map(fn(images) { images })
  decode.success(RunRecord(status, images))
}

fn output_decoder() -> Decoder(List(OutputImage)) {
  use images <- decode.optional_field("images", [], decode.list(image_decoder()))
  decode.success(images)
}

fn image_decoder() -> Decoder(OutputImage) {
  use filename <- decode.field("filename", decode.string)
  use subfolder <- decode.optional_field("subfolder", "", decode.string)
  use kind <- decode.optional_field("type", "output", decode.string)
  decode.success(OutputImage(filename, subfolder, kind))
}

fn generation_json(id: String, record: RunRecord) -> String {
  let state = case record.status, record.images {
    "error", _ -> "failed"
    _, [] -> "failed"
    _, _ -> "succeeded"
  }
  let message = case state {
    "failed" -> "Runner failed this generation"
    _ -> "Generation completed"
  }
  generation_state_json(id, state, message, record.images)
}

fn generation_state_json(
  id: String,
  state: String,
  message: String,
  images: List(OutputImage),
) -> String {
  json.object([
    #("id", json.string(id)),
    #("state", json.string(state)),
    #("message", json.string(message)),
    #("images", json.array(images, of: image_json)),
  ])
  |> json.to_string
}

fn image_json(image: OutputImage) -> json.Json {
  json.object([
    #("filename", json.string(image.filename)),
    #("subfolder", json.string(image.subfolder)),
    #("type", json.string(image.kind)),
  ])
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
