import birl
import gleam/dynamic
import gleam/list
import gleam/option
import gleam/result
import gleam/uri
import gleamfonts/github
import gleamfonts/tools
import sqlight

pub opaque type Connector {
  Disconnected
  Connected(db: sqlight.Connection)
}

pub type ConnectorError {
  CouldNotConnect(underlying: sqlight.Error)
  CouldNotDisconnect(underlying: sqlight.Error)
  CouldNotQuery(underlying: sqlight.Error)
  Other(reason: String)
  NotConnected
}

pub fn new() -> Connector {
  Disconnected
}

pub fn is_connected(in: Connector) -> Bool {
  case in {
    Disconnected -> False
    Connected(_) -> True
  }
}

pub fn get_connection(in: Connector) -> option.Option(sqlight.Connection) {
  case in {
    Disconnected -> option.None
    Connected(db) -> option.Some(db)
  }
}

pub fn connect(
  in: Connector,
  path p: String,
) -> Result(Connector, ConnectorError) {
  case in {
    Disconnected ->
      sqlight.open(p)
      |> result.map(Connected)
      |> result.map_error(CouldNotConnect)
    Connected(db) -> Ok(Connected(db))
  }
}

pub fn disconnect(in: Connector) -> Result(Connector, ConnectorError) {
  case in {
    Disconnected -> Ok(Disconnected)
    Connected(db) ->
      sqlight.close(db)
      |> result.map(fn(_) { Disconnected })
      |> result.map_error(CouldNotDisconnect)
  }
}

fn first_or_error(l: List(a)) -> Result(a, ConnectorError) {
  list.first(l)
  |> result.map_error(fn(_) { Other("No results returned from query") })
}

type DecodableType {
  Repository
  Release
  Asset
}

type Decoder {
  DecodeRepository(
    fn(dynamic.Dynamic) ->
      Result(github.GithubRepository, List(dynamic.DecodeError)),
  )
  DecodeRelease(
    fn(dynamic.Dynamic) ->
      Result(github.GithubRelease, List(dynamic.DecodeError)),
  )
  DecodeAsset(
    fn(dynamic.Dynamic) -> Result(github.GithubAsset, List(dynamic.DecodeError)),
  )
}

fn decode_uri(d: dynamic.Dynamic) -> Result(uri.Uri, List(dynamic.DecodeError)) {
  d
  |> dynamic.string
  |> result.try(fn(s) {
    uri.parse(s)
    |> result.map_error(fn(_) { [dynamic.DecodeError("", "uri", [])] })
  })
}

fn decode_timestamp(
  d: dynamic.Dynamic,
) -> Result(birl.Time, List(dynamic.DecodeError)) {
  dynamic.int(d)
  |> result.map(birl.from_unix)
}

fn decoder_for(in: DecodableType) -> Decoder {
  case in {
    Repository ->
      DecodeRepository(dynamic.decode4(
        github.GithubRepository,
        dynamic.element(0, dynamic.int),
        dynamic.element(1, dynamic.string),
        dynamic.element(2, dynamic.string),
        dynamic.element(3, dynamic.string),
      ))
    Asset ->
      DecodeAsset(dynamic.decode6(
        github.GithubAsset,
        dynamic.element(0, dynamic.int),
        dynamic.element(1, decode_uri),
        dynamic.element(2, decode_uri),
        dynamic.element(3, dynamic.string),
        dynamic.element(4, dynamic.optional(of: dynamic.string)),
        dynamic.element(5, decode_timestamp),
      ))
    Release ->
      DecodeRelease(
        dynamic.decode6(
          github.GithubRelease,
          dynamic.element(0, dynamic.int),
          dynamic.element(1, decode_uri),
          dynamic.element(2, dynamic.string),
          dynamic.element(3, dynamic.string),
          dynamic.element(4, decode_timestamp),
          fn(_) { Ok([]) },
        ),
      )
  }
}

/// Stores a Github Repository into the database, returning the ID of the repository
pub fn store_repository(
  connector in: Connector,
  repo r: github.GithubRepository,
) -> Result(Int, ConnectorError) {
  let query =
    "insert into github_repository(id, releases_url, html_url, description) values (?, ?, ?, ?) returning id"

  case in {
    Disconnected -> Error(NotConnected)
    Connected(db) -> {
      sqlight.query(
        query,
        db,
        [
          sqlight.int(r.id),
          sqlight.text(r.releases_url),
          sqlight.text(r.html_url),
          sqlight.text(r.description),
        ],
        dynamic.element(0, dynamic.int),
      )
      |> result.map_error(CouldNotQuery)
      |> result.try(first_or_error)
    }
  }
}

pub fn store_release(
  connector in: Connector,
  release r: github.GithubRelease,
) -> Result(Int, ConnectorError) {
  case in {
    Disconnected -> Error(NotConnected)
    Connected(db) -> {
      let release_query =
        "insert into github_release(id, url, tag_name, name, published_at) values (?, ?, ?, ?, ?) on conflict do nothing returning id"

      let asset_query =
        "insert into github_asset(id, url, browser_download_url, name, label, created_at, release_id) values (?, ?, ?, ?, ?, ?, ?) on conflict do nothing returning id"

      // Store the release
      use release_id <- result.try(
        sqlight.query(
          release_query,
          db,
          [
            sqlight.int(r.id),
            sqlight.text(r.url |> uri.to_string),
            sqlight.text(r.tag_name),
            sqlight.text(r.name),
            sqlight.int(r.published_at |> birl.to_unix),
          ],
          dynamic.element(0, dynamic.int),
        )
        |> result.map_error(CouldNotQuery)
        |> result.try(first_or_error),
      )

      // Now store all the assets
      r.assets
      |> list.map(fn(asset) {
        sqlight.query(
          asset_query,
          db,
          [
            sqlight.int(asset.id),
            sqlight.text(asset.url |> uri.to_string),
            sqlight.text(asset.browser_download_url |> uri.to_string),
            sqlight.text(asset.name),
            sqlight.nullable(sqlight.text, asset.label),
            sqlight.int(asset.created_at |> birl.to_unix),
            sqlight.int(release_id),
          ],
          dynamic.element(0, dynamic.int),
        )
        |> result.map_error(CouldNotQuery)
        |> result.try(first_or_error)
      })
      |> result.all
      |> result.map(fn(_) { release_id })
    }
  }
}

/// Retrieves a repository with a given ID
pub fn get_repository(
  connector in: Connector,
  with_id id: Int,
) -> Result(option.Option(github.GithubRepository), ConnectorError) {
  case in {
    Disconnected -> Error(NotConnected)
    Connected(db) -> {
      let query = "select * from github_repository where id = ?"

      let assert DecodeRepository(d) = decoder_for(Repository)
      sqlight.query(query, db, [sqlight.int(id)], d)
      |> result.map_error(CouldNotQuery)
      |> result.map(tools.first)
    }
  }
}

fn fill_assets(
  r: github.GithubRelease,
  db: sqlight.Connection,
) -> Result(github.GithubRelease, ConnectorError) {
  let query = "select * from github_asset where release_id = ?"
  let assert DecodeAsset(d) = decoder_for(Asset)

  use assets <- result.try(
    sqlight.query(query, db, [sqlight.int(r.id)], d)
    |> result.map_error(CouldNotQuery),
  )

  Ok(github.GithubRelease(..r, assets: assets))
}

/// Retrieves a release with a given ID
pub fn get_release(
  connector in: Connector,
  with_id id: Int,
) -> Result(option.Option(github.GithubRelease), ConnectorError) {
  case in {
    Disconnected -> Error(NotConnected)
    Connected(db) -> {
      // Retrieve the release first
      let query = "select * from github_release where id = ?"
      let assert DecodeRelease(d) = decoder_for(Release)

      sqlight.query(query, db, [sqlight.int(id)], d)
      |> result.map_error(CouldNotQuery)
      |> result.map(tools.first)
      |> result.try(fn(mr) {
        case mr {
          option.None -> Ok(option.None)
          option.Some(gr) ->
            case fill_assets(gr, db) {
              Ok(gr) -> Ok(option.Some(gr))
              Error(e) -> Error(e)
            }
        }
      })
    }
  }
}

/// Retrieves all releases
pub fn get_all_releases(
  connector in: Connector,
) -> Result(List(github.GithubRelease), ConnectorError) {
  case in {
    Disconnected -> Error(NotConnected)
    Connected(db) -> {
      let query = "select * from github_release"
      let assert DecodeRelease(d) = decoder_for(Release)

      sqlight.query(query, db, [], d)
      |> result.map_error(CouldNotQuery)
      |> result.try(fn(lr) {
        list.map(lr, fn(r) {
          let query = "select * from github_asset where release_id = ?"
          let assert DecodeAsset(d) = decoder_for(Asset)
          sqlight.query(query, db, [sqlight.int(r.id)], d)
          |> result.map_error(CouldNotQuery)
          |> result.map(fn(assets) { github.GithubRelease(..r, assets: assets) })
        })
        |> result.all
      })
    }
  }
}

/// Retrieves all the repositories
pub fn get_all_repositories(
  connector in: Connector,
) -> Result(List(github.GithubRepository), ConnectorError) {
  case in {
    Disconnected -> Error(NotConnected)
    Connected(db) -> {
      let query = "select * from github_repository"

      let assert DecodeRepository(d) = decoder_for(Repository)
      sqlight.query(query, db, [], d)
      |> result.map_error(CouldNotQuery)
    }
  }
}
