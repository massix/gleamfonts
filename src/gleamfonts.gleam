import application_behavior
import argv
import birl
import gleam/erlang
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/task
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

const version = "1.0.1"

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

  io.println_error(string)
}

fn read_input_int(
  prompt: String,
  default: option.Option(Int),
) -> Result(Int, RuntimeError) {
  use input <- result.try(
    erlang.get_line(prompt)
    |> result.map(string.trim)
    |> result.map_error(fn(_) { GenericError("I/O Error while reading input") }),
  )

  option.or(option.from_result(int.parse(input)), default)
  |> option.to_result(GenericError("Could not parse input as integer"))
}

fn choose_release(
  releases: List(github.GithubRelease),
) -> Result(github.GithubRelease, RuntimeError) {
  io.println(
    "Choose one release from the list below (the releases are sorted from the most recent to the oldest)",
  )

  releases
  |> list.take(15)
  |> tools.iterate_list(fn(index, release) {
    io.println(
      int.to_string(index)
      <> ") "
      <> release.name
      <> " - "
      <> birl.to_http(release.published_at),
    )
  })

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
      case list.length(r) {
        0 ->
          Error(GenericError(
            "No installable fonts found in this package.\nOnly TrueType Fonts and OpenType Fonts are compatible with Termux and some NerdFonts packages (like FontPatcher) contain only incompatible fonts.\nPlease retry!",
          ))
        _ -> {
          io.println("\n\n")
          io.println(
            "Choose which font to install from the given asset from the list below",
          )

          tools.iterate_list(r, fn(i, zc) {
            case zc {
              unzip.Comment(_) -> Nil
              unzip.File(name, ..) ->
                io.println(int.to_string(i) <> ") " <> name)
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
    |> option.unwrap(Error(GenericError("Could not retrieve a connection"))),
  )

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
      github.get_main_repository()
      |> result.map_error(FromGithubModule)
      |> result.try(fn(r) {
        connector.store_repository(c, r)
        |> result.map(fn(_) { r })
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
          github.list_releases(repo)
          |> result.map(list.take(_, 15))
          |> result.map_error(FromGithubModule)
          |> result.try(fn(l) {
            list.map(l, fn(r) {
              task.async(fn() { connector.store_release(c, r) })
            })
            |> list.map(task.await_forever)
            |> result.all
            |> result.map(fn(_) { l })
            |> result.map_error(FromConnectorModule)
          })
        }
      }
    }),
  )

  let ret =
    choose_release(releases)
    |> result.try(common_path)

  let disconnect =
    connector.disconnect(c)
    |> result.map(fn(_) { Nil })
    |> result.map_error(FromConnectorModule)

  [ret, disconnect]
  |> result.all
  |> result.map(fn(_) { Nil })
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

fn print_usage(program_path: String) -> Result(Nil, Nil) {
  io.println(
    "usage: "
    <> program_path
    <> " [--delete-cache] [--no-cache] [--help] [--version]",
  )
  io.println("  --no-cache fetch all the data from GitHub, ignoring the cache")
  io.println("  --delete-cache remove the old cache first")
  io.println("  --help print this help page and exit")
  io.println("  --version print version information and exit")

  Ok(Nil)
}

fn print_version() -> Result(Nil, Nil) {
  io.println("gleamfonts " <> version)
  Ok(Nil)
}

pub fn main() {
  let argv = argv.load()

  let behavior =
    application_behavior.get_application_behavior(fn() { argv.arguments })

  case behavior {
    application_behavior.PrintHelp -> print_usage(argv.program)
    application_behavior.PrintVersion -> print_version()
    application_behavior.WithCache(delete) -> {
      let db_file = tools.get_cache_dir() <> "db.sqlite"
      use _ <- result.try(
        simplifile.create_directory_all(tools.get_cache_dir())
        |> result.map_error(fn(e) { print_error(FromSimplifileModule(e)) }),
      )
      case delete {
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
    application_behavior.WithoutCache ->
      without_cache() |> result.map_error(print_error)
  }
}
