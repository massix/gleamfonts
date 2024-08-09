import argv
import birl
import gleam/erlang
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleamfonts/db/connector
import gleamfonts/db/migration
import gleamfonts/github
import gleamfonts/hackto
import gleamfonts/tools
import gleamfonts/unzip
import simplifile
import sqlight

type RuntimeError {
  FromGithubModule(github.GithubError)
  FromUnzipModule(unzip.ZipError)
  FromHacktoModule(hackto.HackneyError)
  FromSimplifileModule(simplifile.FileError)
  FromConnectorModule(connector.ConnectorError)
  GenericError(String)
}

fn print_error(in: RuntimeError) -> Nil {
  let string = case in {
    FromGithubModule(e) ->
      "Error from Github module: " <> github.describe_error(e)
    FromUnzipModule(unzip.ZipError(s)) -> "Error from Unzip module: " <> s
    FromHacktoModule(hackto.HackneyError(e)) ->
      "Error from Hackto module: "
      <> {
        case e {
          hackto.Timeout -> "timeout"
          hackto.Other(_) -> "unknown error"
        }
      }
    FromSimplifileModule(e) ->
      "Error from Simplifile module: " <> simplifile.describe_error(e)
    FromConnectorModule(e) ->
      "Error from connector module: "
      <> case e {
        connector.Other(r) -> r
        connector.CouldNotConnect(_) -> "could not connect to the cache"
        connector.CouldNotQuery(sqlight.SqlightError(_, r, _)) -> r
        connector.CouldNotDisconnect(_) -> "could not disconnect from the cache"
        connector.NotConnected -> "system is not connected to the cache"
      }
    GenericError(s) -> s
  }

  io.println(string)
}

fn read_input_int(
  prompt: String,
  default: option.Option(Int),
) -> Result(Int, RuntimeError) {
  case erlang.get_line(prompt) {
    Error(_) -> Error(GenericError("I/O Error while reading input"))
    Ok(s) ->
      case int.parse(s |> string.trim) {
        Error(_) -> {
          case default {
            option.Some(x) -> Ok(x)
            option.None ->
              Error(GenericError("Could not parse input as integer"))
          }
        }
        Ok(s) -> Ok(s)
      }
  }
}

fn choose_release(
  releases: List(github.GithubRelease),
) -> Result(github.GithubRelease, RuntimeError) {
  io.println(
    "Choose one release from the list below (the releases are sorted from the most recent to the oldest)",
  )

  releases
  |> list.take(10)
  |> tools.iterate_list(fn(index, release) {
    io.println(
      int.to_string(index)
      <> ") "
      <> release.name
      <> " - "
      <> birl.to_http(release.published_at),
    )
  })

  let assert option.Some(_default_release) = tools.item_at(releases, 0)
  use read_index <- result.try(read_input_int(
    " ~ Your choice (default: 0) > ",
    option.Some(0),
  ))

  let chosen_release = tools.item_at(releases, read_index)

  case chosen_release {
    option.None -> Error(GenericError("Release with that index does not exist"))
    option.Some(r) -> Ok(r)
  }
}

fn choose_asset(
  in: github.GithubRelease,
) -> Result(github.GithubAsset, RuntimeError) {
  io.println("\n\n")
  io.println("Choose an asset from the list below")

  in.assets
  |> tools.iterate_list(fn(i, a) {
    io.println(
      int.to_string(i) <> ") " <> a.name <> " - " <> birl.to_http(a.created_at),
    )
  })

  use read_index <- result.try(read_input_int(" ~ Your choice > ", option.None))
  let chosen_asset = tools.item_at(in.assets, read_index)

  case chosen_asset {
    option.None -> Error(GenericError("Asset with that index does not exist"))
    option.Some(a) -> Ok(a)
  }
}

pub opaque type ZipAndAsset {
  ZipAndAsset(
    asset: github.GithubDownloadedAsset,
    zip_content: unzip.ZipContent,
  )
}

fn choose_font(
  in: github.GithubDownloadedAsset,
) -> Result(ZipAndAsset, RuntimeError) {
  let content = unzip.list_asset_content(in)
  case content {
    Ok(r) -> {
      io.println("\n\n")
      io.println(
        "Choose which font to install from the given asset from the list below",
      )
      r
      |> tools.iterate_list(fn(i, zc) {
        case zc {
          unzip.Comment(_) -> Nil
          unzip.File(name, ..) -> io.println(int.to_string(i) <> ") " <> name)
        }
      })

      use read_index <- result.try(read_input_int(
        " ~ Your choice > ",
        option.None,
      ))
      let chosen_file = tools.item_at(r, read_index)
      case chosen_file {
        option.None ->
          Error(GenericError("File with that index does not exist"))
        option.Some(a) -> Ok(ZipAndAsset(in, a))
      }
    }
    Error(e) -> Error(FromUnzipModule(e))
  }
}

fn extract_file(in: ZipAndAsset) -> Result(String, RuntimeError) {
  let assert ZipAndAsset(asset, unzip.File(name, ..)) = in
  let tools.TmpFolder(path) =
    tools.make_temporary_folder(option.Some("gleamfonts"))
  io.println("You chose " <> name)

  let all_files =
    unzip.unzip_asset(asset, [
      unzip.DestinationFolder(path),
      unzip.FilesToExtract([name]),
    ])
  case all_files {
    Ok(ls) -> {
      case list.length(ls) {
        x if x > 1 ->
          Error(GenericError(
            "Too many files extracted (" <> int.to_string(x) <> ")",
          ))
        _ -> {
          let assert option.Some(item) = tools.item_at(ls, 0)
          Ok(item)
        }
      }
    }
    Error(e) -> Error(FromUnzipModule(e))
  }
}

fn string_trim_lowercase(s: String) -> String {
  s |> string.trim |> string.lowercase
}

// Returns Ok(True, original_file_path) if the file has been replaced, Ok(False, original_file_path) otherwise.
fn replace_file(in: String) -> Result(#(Bool, String), RuntimeError) {
  use line <- result.try(
    erlang.get_line(
      "Do you trust gleamfonts enough to replace your ~/.termux/font.ttf file for you? [y/n] > ",
    )
    |> result.map(string_trim_lowercase)
    |> result.map_error(fn(_) { GenericError("I/O Error") }),
  )

  let positive_answers = ["y", "true", "yes", "ok"]

  case list.contains(positive_answers, line) {
    True -> {
      let home_folder = tools.get_env("HOME") |> option.unwrap("~")

      simplifile.copy_file(in, home_folder <> "/.termux/font.ttf")
      |> result.map(fn(_) { #(True, in) })
      |> result.map_error(FromSimplifileModule)
    }
    False -> Ok(#(False, in))
  }
}

fn with_cache(c: connector.Connector) -> Result(Nil, RuntimeError) {
  use _ <- result.try(
    connector.get_connection(c)
    |> option.map(fn(db) {
      case migration.migrate(db, "") {
        Ok(_) -> Ok(Nil)
        Error(_) -> Error(GenericError("Could not run migrations"))
      }
    })
    |> option.unwrap(Error(GenericError(""))),
  )

  io.println("Cache system ready")

  // Now retrieve the repositories we have in the cache
  use repo <- result.try(
    connector.get_all_repositories(c)
    |> result.map_error(fn(_) {
      GenericError("Failure while retrieving information from the cache")
    })
    |> result.map(tools.first),
  )

  use repo <- result.try(case repo {
    option.None -> {
      io.println("No repositories found in the cache, fetching it from GitHub")
      github.get_main_repository()
      |> result.map_error(FromGithubModule)
      |> result.try(fn(r) {
        io.println("Fetched from GitHub, storing it into the cache")
        connector.store_repository(c, r)
        |> result.map(fn(id) {
          io.println("Stored repository with id: " <> int.to_string(id))
          r
        })
        |> result.map_error(FromConnectorModule)
      })
    }
    option.Some(repo) -> Ok(repo)
  })

  use releases <- result.try(
    connector.get_all_releases(c)
    |> result.map_error(FromConnectorModule)
    |> result.try(fn(l) {
      case list.is_empty(l) {
        False -> Ok(l)
        True -> {
          io.println(
            "No releases found in the cache, fetching them from Github",
          )
          github.list_releases(repo)
          |> result.map(list.take(_, 10))
          |> result.map_error(FromGithubModule)
          |> result.try(fn(l) {
            list.map(l, fn(r) {
              io.println("Fetched release: " <> r.tag_name <> " storing in DB")
              connector.store_release(c, r)
            })
            |> result.all
            |> result.map(fn(_) { l })
            |> result.map_error(FromConnectorModule)
          })
        }
      }
    }),
  )

  choose_release(releases)
  |> result.try(common_path)
}

fn without_cache() -> Result(Nil, RuntimeError) {
  github.get_main_repository()
  |> result.try(github.list_releases)
  |> result.map_error(FromGithubModule)
  |> result.try(choose_release)
  |> result.try(common_path)
}

/// This part here is common for both the without_cache and the with_cache paths
fn common_path(in: github.GithubRelease) -> Result(Nil, RuntimeError) {
  choose_asset(in)
  |> result.try(fn(a) {
    io.println("Downloading: " <> a.name)
    github.download_asset(a, in_memory: True)
    |> result.map_error(FromGithubModule)
  })
  |> result.try(choose_font)
  |> result.try(extract_file)
  |> result.try(replace_file)
  |> result.try(fn(result) {
    let #(result, original_file) = result
    case result {
      False ->
        io.println(
          "No bad feelings, your file is still available at: " <> original_file,
        )
      True -> io.println("Done! Do not forget to run termux-reload-settings")
    }

    Ok(Nil)
  })
}

fn print_usage(program_path: String) -> Nil {
  io.println(
    "usage: " <> program_path <> " [--delete-cache] [--no-cache] [--help]",
  )
  io.println("  if --no-cache is specified, fetch all the data from GitHub")
  io.println("     ignoring the local cache (if any)")
  io.println("  if --delete-cache is specified, remove the old cache first")
  io.println("     and then store everything into the newly created cache")
  io.println("  if both --delete-cache and --no-cache are specified, then")
  io.println("     --delete-cache won't have any effect")
}

pub fn main() {
  let argv = argv.load()

  case list.contains(argv.arguments, "--help") {
    True -> Ok(print_usage(argv.program))
    False ->
      case list.contains(argv.arguments, "--no-cache") {
        False -> {
          let db_file = tools.get_cache_dir() <> "db.sqlite"
          use _ <- result.try(
            simplifile.create_directory_all(tools.get_cache_dir())
            |> result.map_error(fn(e) { print_error(FromSimplifileModule(e)) }),
          )

          case list.contains(argv.arguments, "--delete-cache") {
            True -> {
              let _ = simplifile.delete(db_file)
              Nil
            }
            False -> Nil
          }

          connector.new()
          |> connector.connect(db_file)
          |> result.map_error(FromConnectorModule)
          |> result.try(with_cache)
          |> result.map_error(print_error)
        }
        True ->
          without_cache()
          |> result.map_error(print_error)
      }
  }
}
