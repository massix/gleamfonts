import gleam/bytes_builder
import gleam/dynamic
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option
import gleam/result
import gleam/uri

pub type HackneyRequest {
  HackneyRequest(
    method: http.Method,
    url: String,
    body: bytes_builder.BytesBuilder,
    headers: List(#(String, String)),
    timeout: Int,
  )
}

pub type HackneyResponse {
  HackneyResponse(
    status: Int,
    headers: List(#(String, String)),
    body: option.Option(BitArray),
  )
}

pub type HackneyError {
  HackneyError(HackneyErrorType)
}

pub type HackneyErrorType {
  Timeout
  Other(dynamic.Dynamic)
}

@external(erlang, "hackto_ffi", "send")
fn hackto_send(r: HackneyRequest) -> Result(HackneyResponse, HackneyError)

fn http_request2hackney_request(
  in: request.Request(bytes_builder.BytesBuilder),
  with_timeout timeout: option.Option(Int),
) -> HackneyRequest {
  let host = request.to_uri(in) |> uri.to_string

  HackneyRequest(
    in.method,
    host,
    in.body,
    in.headers,
    option.unwrap(timeout, 5000),
  )
}

fn hackney_response2http_response(
  in: HackneyResponse,
) -> response.Response(BitArray) {
  response.Response(in.status, in.headers, option.unwrap(in.body, <<>>))
}

pub fn send(
  r: request.Request(bytes_builder.BytesBuilder),
  with_timeout timeout: option.Option(Int),
) -> Result(response.Response(BitArray), HackneyError) {
  r
  |> http_request2hackney_request(timeout)
  |> hackto_send
  |> result.map(hackney_response2http_response)
}
