import gleam/bit_array
import gleam/bytes_builder
import gleam/http/request
import gleam/http/response
import gleam/option
import gleam/result
import gleam/uri
import gleamfonts/hackto
import startest.{describe, it}
import startest/expect

pub fn hackto_tests() {
  describe("hackto", [with_timeout_suite()])
}

// Download a 120MB file....
fn with_timeout_suite() {
  let assert Ok(uri) =
    uri.parse(
      "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.2.1/ZedMono.zip",
    )

  let assert Ok(request) =
    request.from_uri(uri)
    |> result.map(fn(r) { request.set_body(r, bytes_builder.new()) })

  describe("Timeout", [
    it("Should be able to download without timeouts", fn() {
      let assert Ok(response.Response(status, _headers, body)) =
        hackto.send(request, option.Some(120_000))

      status |> expect.to_equal(200)
      body
      |> bit_array.byte_size
      |> fn(x) { x > 264_000_000 }
      |> expect.to_be_true
    }),
    it("Should fail if timeout is too low", fn() {
      hackto.send(request, option.Some(120))
      |> expect.to_be_error
      |> expect.to_equal(hackto.HackneyError(hackto.Timeout))
    }),
  ])
}
