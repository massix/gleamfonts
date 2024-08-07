import birl
import gleam/bytes_builder
import gleam/dynamic.{field, int, list, string}
import gleam/hackney
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri
import gleamfonts/hackto
import gleamfonts/tools
import simplifile

const owner = "ryanoasis"

const repo = "nerd-fonts"

const api_base = "https://api.github.com"

pub type GResult(a) =
  Result(a, GithubError)

/// Represents a GithubRepository for which we have all the
/// needed information.
pub opaque type GithubRepository {
  GithubRepository(
    id: Int,
    releases_url: String,
    html_url: String,
    description: String,
  )
}

pub type GithubRelease {
  GithubRelease(
    id: Int,
    url: uri.Uri,
    tag_name: String,
    name: String,
    published_at: birl.Time,
    assets: List(GithubAsset),
  )
}

pub type GithubError {
  ErrorCannotCreateUri(from_string: String)
  ErrorCannotCreateRequest(for_uri: uri.Uri)
  ErrorCannotSendRequest(
    for_request: request.Request(String),
    hackney_error: hackney.Error,
  )
  ErrorCannotSendBinaryRequest(
    for_request: request.Request(bytes_builder.BytesBuilder),
    hackney_error: hackney.Error,
  )
  ErrorCannotDecodeResponse(body: String)
  ErrorInvalidHttpCode(http_code: Int)
  ErrorInvalidRedirect
  ErrorCannotCreateTempFolder(
    path: String,
    simplifile_error: simplifile.FileError,
  )
  ErrorCannotWriteFile(path: String, simplifile_error: simplifile.FileError)
  ErrorCannotDownloadAsset(
    request: request.Request(bytes_builder.BytesBuilder),
    hackto_error: hackto.HackneyError,
  )
}

pub type GithubAsset {
  GithubAsset(
    url: uri.Uri,
    browser_download_url: uri.Uri,
    name: String,
    label: option.Option(String),
    created_at: birl.Time,
  )
}

/// We can download the asset either in memory or in a file
pub type GithubDownloadedAsset {
  FileAsset(path: String)
  MemoryAsset(asset: BitArray)
}

pub fn is_asset_in_memory(asset in: GithubDownloadedAsset) -> Bool {
  case in {
    FileAsset(_) -> False
    MemoryAsset(_) -> True
  }
}

/// Helper function for debugging the errors
pub fn describe_error(error error: GithubError) -> String {
  let trunc = fn(in: String) -> String {
    case string.length(in) {
      x if x <= 0 -> "Empty body"
      x if x > 80 -> { string.slice(in, 0, 80) } <> "..."
      _ -> in
    }
  }

  case error {
    ErrorCannotCreateUri(s) -> "Cannot create URI from: " <> s
    ErrorCannotCreateRequest(u) ->
      "Cannot create request from: " <> uri.to_string(u)
    ErrorCannotSendRequest(r, _) ->
      "Cannot send request from: " <> { r |> request.to_uri |> uri.to_string }
    ErrorCannotSendBinaryRequest(r, _) ->
      "Cannot send binary request from: "
      <> { r |> request.to_uri |> uri.to_string }
    ErrorCannotDecodeResponse(b) -> "Cannot decode body: " <> trunc(b)
    ErrorInvalidHttpCode(c) ->
      "Invalid HTTP code received: " <> int.to_string(c)
    ErrorInvalidRedirect -> "Status code for redirect, but no location found"
    ErrorCannotCreateTempFolder(s, _) -> "Failed to create folder at: " <> s
    ErrorCannotWriteFile(s, _) -> "Failed to create file at: " <> s
    ErrorCannotDownloadAsset(_, _) -> "Failed to download asset"
  }
}

/// Generic helper to map Error(Nil) to a module error
fn map_nil_error(in: Result(a, Nil), err: GithubError) -> Result(a, GithubError) {
  result.map_error(in, fn(_) { err })
}

/// Wrapper to remap Hackney errors to module errors
fn map_hackney_error(
  in: Result(a, hackney.Error),
  request: request.Request(b),
  f: fn(request.Request(b), hackney.Error) -> GithubError,
) {
  result.map_error(in, fn(he) { f(request, he) })
}

/// Obtains a reference to the Github Repository for nerd-fonts
pub fn get_main_repository() -> GResult(GithubRepository) {
  let path =
    [api_base, "repos", owner, repo]
    |> string.join(with: "/")

  use uri <- result.try(
    uri.parse(path)
    |> map_nil_error(ErrorCannotCreateUri(path)),
  )

  use request <- result.try(
    request.from_uri(uri)
    |> map_nil_error(ErrorCannotCreateRequest(uri))
    |> result.map(fn(r) { request.set_method(r, http.Get) }),
  )

  use response.Response(status_code, _headers, body) <- result.try(
    hackney.send(request)
    |> map_hackney_error(request, ErrorCannotSendRequest),
  )

  let decoder =
    dynamic.decode4(
      GithubRepository,
      field("id", int),
      field("releases_url", string),
      field("html_url", string),
      field("description", string),
    )

  case status_code {
    200 ->
      json.decode(body, decoder)
      |> result.map_error(fn(_) { ErrorCannotDecodeResponse(body) })
    other -> Error(ErrorInvalidHttpCode(other))
  }
}

/// Obtains a reference to the latest releases of a specific
/// repository.  The releases are then sorted by publication date
pub fn list_releases(
  for_repository r: GithubRepository,
) -> GResult(List(GithubRelease)) {
  // Drop the "{/id}" from the releases_url string, as returned by GitHub
  let path = { r.releases_url |> string.drop_right(5) } <> "?per_page=500"

  use uri <- result.try(
    uri.parse(path) |> map_nil_error(ErrorCannotCreateUri(path)),
  )

  use request <- result.try(
    request.from_uri(uri)
    |> map_nil_error(ErrorCannotCreateRequest(uri))
    |> result.map(fn(r) { request.set_method(r, http.Get) }),
  )

  use response.Response(status_code, _headers, body) <- result.try(
    hackney.send(request)
    |> map_hackney_error(request, ErrorCannotSendRequest),
  )

  let asset_decoder =
    dynamic.decode5(
      GithubAsset,
      field("url", decode_uri),
      field("browser_download_url", decode_uri),
      field("name", string),
      field("label", dynamic.optional(of: string)),
      field("created_at", decode_timestamp),
    )

  let release_decoder =
    dynamic.decode6(
      GithubRelease,
      field("id", int),
      field("url", decode_uri),
      field("tag_name", string),
      field("name", string),
      field("published_at", decode_timestamp),
      field("assets", list(of: asset_decoder)),
    )

  case status_code {
    200 ->
      json.decode(body, dynamic.list(release_decoder))
      |> result.map(sort_and_filter_releases)
      |> result.map_error(fn(_) { ErrorCannotDecodeResponse(body) })
    other -> Error(ErrorInvalidHttpCode(other))
  }
}

pub fn sort_and_filter_releases(
  releases in: List(GithubRelease),
) -> List(GithubRelease) {
  list.sort(in, fn(a, b) { birl.compare(b.published_at, a.published_at) })
  |> list.map(fn(g) {
    let filtered_assets =
      list.filter(g.assets, fn(asset) { string.ends_with(asset.name, ".zip") })

    GithubRelease(..g, assets: filtered_assets)
  })
}

pub fn decode_uri(
  d: dynamic.Dynamic,
) -> Result(uri.Uri, List(dynamic.DecodeError)) {
  use result <- result.try(d |> string)

  uri.parse(result)
  |> result.map_error(fn(_) {
    [dynamic.DecodeError("url", "Could not parse uri", [])]
  })
}

pub fn decode_timestamp(
  d: dynamic.Dynamic,
) -> Result(birl.Time, List(dynamic.DecodeError)) {
  use result <- result.try(d |> string)

  birl.parse(result)
  |> result.map_error(fn(_) {
    [dynamic.DecodeError("published_at", "Could not parse timestamp", [])]
  })
}

/// Helper function to download the binary asset, following the redirects
fn download(uri: uri.Uri) -> Result(BitArray, GithubError) {
  use request <- result.try(
    request.from_uri(uri)
    |> map_nil_error(ErrorCannotCreateRequest(uri))
    |> result.map(fn(r) { request.set_body(r, bytes_builder.new()) }),
  )

  use r <- result.try(
    hackto.send(request, option.Some(120_000))
    |> result.map_error(fn(orig) { ErrorCannotDownloadAsset(request, orig) }),
  )

  let response.Response(status_code, _headers, body) = r

  case status_code {
    200 -> Ok(body)
    x if x == 301 || x == 302 -> {
      use location_header <- result.try(
        response.get_header(r, "location")
        |> map_nil_error(ErrorInvalidRedirect),
      )

      use new_uri <- result.try(
        uri.parse(location_header)
        |> map_nil_error(ErrorCannotCreateUri(location_header)),
      )

      download(new_uri)
    }
    other -> Error(ErrorInvalidHttpCode(other))
  }
}

/// Downloads an asset. The asset can be kept in memory or stored
/// to a temporary folder.
pub fn download_asset(
  asset in: GithubAsset,
  in_memory mem: Bool,
) -> GResult(GithubDownloadedAsset) {
  use bits <- result.try(download(in.browser_download_url))

  case mem {
    True -> Ok(MemoryAsset(bits))
    False -> {
      let tools.TmpFolder(working_folder) =
        tools.make_temporary_folder(option.Some("gleamfonts"))

      let to = working_folder <> in.name

      use _ <- result.try(
        simplifile.write_bits(to:, bits:)
        |> result.map_error(fn(e) { ErrorCannotWriteFile(to, e) }),
      )

      Ok(FileAsset(to))
    }
  }
}
