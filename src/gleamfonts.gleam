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
import gleamfonts/translate as t
import gleamfonts/unzip
import simplifile
import sqlight

const version = "1.0.2"

type RuntimeError {
  FromGithubModule(github.GithubError)
  FromUnzipModule(unzip.ZipError)
  FromHacktoModule(hackto.HackneyError)
  FromSimplifileModule(simplifile.FileError)
  FromConnectorModule(connector.ConnectorError)
  GenericError(key: t.Key, default: String)
}

fn print_error(in: RuntimeError, t: option.Option(t.Translations)) -> Nil {
  let string = case in {
    FromGithubModule(e) ->
      t.translate(
        t,
        t.Key("main_error_from_github_module"),
        "Error while communicating with Github: {{ describe }}",
        [#("describe", github.describe_error(e, t))],
      )
    // "Error from Github module: " <> github.describe_error(e)
    FromUnzipModule(unzip.ZipError(s)) ->
      t.translate(
        t,
        t.Key("main_error_from_unzip_module"),
        "Error while extracting the archive: {{ describe }}",
        [#("describe", s)],
      )
    FromHacktoModule(hackto.HackneyError(e)) ->
      t.translate(
        t,
        t.Key("main_error_from_hackto_module"),
        "Error while downloading the archive: {{ describe }}",
        [
          #("describe", case e {
            hackto.Timeout ->
              t.translate(
                t,
                t.Key("hackto_timeout"),
                "timeout during the operation",
                [],
              )
            hackto.Other(_) ->
              t.translate(t, t.Key("hackto_unknown"), "unknown error", [])
          }),
        ],
      )
    FromSimplifileModule(e) ->
      t.translate(
        t,
        t.Key("main_error_from_simplifile_module"),
        "Error while handling the filesystem: {{ describe }}",
        [#("describe", simplifile.describe_error(e))],
      )
    FromConnectorModule(e) ->
      t.translate(
        t,
        t.Key("main_error_from_connector_module"),
        "Error while communicating with the cache: {{ describe }}",
        [
          #("describe", case e {
            connector.Other(r) -> r
            connector.CouldNotConnect(_) ->
              t.translate(
                t,
                t.Key("main_connector_could_not_connect"),
                "could not connect to the cache",
                [],
              )
            connector.CouldNotQuery(sqlight.SqlightError(_, r, _)) -> r
            connector.CouldNotDisconnect(_) ->
              t.translate(
                t,
                t.Key("main_connector_could_not_disconnect"),
                "could not disconnect from the cache",
                [],
              )
            connector.NotConnected ->
              t.translate(
                t,
                t.Key("main_connector_not_connected"),
                "system is not connected to the cache",
                [],
              )
          }),
        ],
      )
    GenericError(key, default) -> t.translate(t, key, default, [])
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
    |> result.map_error(fn(_) {
      GenericError(t.Key("io_error"), "I/O Error while reading input")
    }),
  )

  option.or(option.from_result(int.parse(input)), default)
  |> option.to_result(GenericError(
    t.Key("could_not_parse"),
    "That does not look like a number!",
  ))
}

fn choose_release(
  releases: List(github.GithubRelease),
  t: option.Option(t.Translations),
) -> Result(github.GithubRelease, RuntimeError) {
  io.println(
    t.translate(
      t,
      t.Key("choose_release"),
      "Choose one release from the list below (the releases are sorted from the most recent to the oldest)",
      [],
    ),
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
    t.translate(t, t.Key("cr_prompt"), " ~ Your choice (default: 0) > ", []),
    option.Some(0),
  ))

  let chosen_release = tools.item_at(releases, read_index)

  case chosen_release {
    option.None ->
      Error(GenericError(
        t.Key("release_index_not_found"),
        "Release with that index does not exist",
      ))
    option.Some(r) -> Ok(r)
  }
}

fn choose_asset(
  in: github.GithubRelease,
  t: option.Option(t.Translations),
) -> Result(github.GithubAsset, RuntimeError) {
  io.println("\n\n")
  io.println(
    t.translate(
      t,
      t.Key("choose_asset"),
      "Choose a font family from the list below",
      [],
    ),
  )

  in.assets
  |> tools.iterate_list(fn(i, a) {
    io.println(
      int.to_string(i) <> ") " <> a.name <> " - " <> birl.to_http(a.created_at),
    )
  })

  use read_index <- result.try(read_input_int(
    t.translate(t, t.Key("ca_prompt"), " ~ Your choice > ", []),
    option.None,
  ))
  let chosen_asset = tools.item_at(in.assets, read_index)

  case chosen_asset {
    option.None ->
      Error(GenericError(
        t.Key("asset_index_not_found"),
        "Font family with that index does not exist",
      ))
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
  t: option.Option(t.Translations),
) -> Result(ZipAndAsset, RuntimeError) {
  let content = unzip.list_asset_content(in)
  case content {
    Ok(r) -> {
      case list.length(r) {
        0 ->
          Error(GenericError(
            t.Key("no_installable_font"),
            "No installable fonts found in this package.\nOnly TrueType Fonts and OpenType Fonts are compatible with Termux and some NerdFonts packages (like FontPatcher) contain only incompatible fonts.\nPlease retry!",
          ))
        _ -> {
          io.println("\n\n")
          io.println(
            t.translate(
              t,
              t.Key("choose_font"),
              "Choose which font to install from the list below",
              [],
            ),
          )

          tools.iterate_list(r, fn(i, zc) {
            case zc {
              unzip.Comment(_) -> Nil
              unzip.File(name, ..) ->
                io.println(int.to_string(i) <> ") " <> name)
            }
          })

          use read_index <- result.try(read_input_int(
            t.translate(t, t.Key("ca_prompt"), " ~ Your choice > ", []),
            option.None,
          ))
          let chosen_file = tools.item_at(r, read_index)
          case chosen_file {
            option.None ->
              Error(GenericError(
                t.Key("file_index_not_found"),
                "File with that index does not exist",
              ))
            option.Some(a) -> Ok(ZipAndAsset(in, a))
          }
        }
      }
    }
    Error(e) -> Error(FromUnzipModule(e))
  }
}

fn extract_file(
  in: ZipAndAsset,
  t: option.Option(t.Translations),
) -> Result(String, RuntimeError) {
  let assert ZipAndAsset(asset, unzip.File(name, ..)) = in
  let tools.TmpFolder(path) =
    tools.make_temporary_folder(option.Some("gleamfonts"))
  io.println(
    t.translate(t, t.Key("chosen_font"), "You chose {{ font_name }}", [
      #("font_name", name),
    ]),
  )

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
            t.Key("too_many_files_extracted"),
            "Too many files extracted",
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
fn replace_file(
  in: String,
  t: option.Option(t.Translations),
) -> Result(#(Bool, String), RuntimeError) {
  use line <- result.try(
    erlang.get_line(
      t.translate(
        t,
        t.Key("replace_font_trust"),
        "Do you trust gleamfonts enough to replace your ~/.termux/font.ttf file for you? [y/n] > ",
        [],
      ),
    )
    |> result.map(string_trim_lowercase)
    |> result.map_error(fn(_) { GenericError(t.Key("io_error"), "I/O Error") }),
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

fn with_cache(
  c: connector.Connector,
  t: option.Option(t.Translations),
) -> Result(Nil, RuntimeError) {
  use _ <- result.try(
    connector.get_connection(c)
    |> option.map(fn(db) {
      case migration.migrate(db, "") {
        Ok(_) -> Ok(Nil)
        Error(_) ->
          Error(GenericError(
            t.Key("could_not_run_migrations"),
            "Could not run migrations",
          ))
      }
    })
    |> option.unwrap(
      Error(GenericError(
        t.Key("could_not_retrieve_connection"),
        "Could not communicate with the cache",
      )),
    ),
  )

  // Now retrieve the repositories we have in the cache
  use repo <- result.try(
    connector.get_all_repositories(c)
    |> result.map_error(fn(_) {
      GenericError(
        t.Key("failure_information_cache"),
        "Failure while retrieving information from the cache",
      )
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
    choose_release(releases, t)
    |> result.try(common_path(_, t))

  let disconnect =
    connector.disconnect(c)
    |> result.map(fn(_) { Nil })
    |> result.map_error(FromConnectorModule)

  [ret, disconnect]
  |> result.all
  |> result.map(fn(_) { Nil })
}

fn without_cache(t: option.Option(t.Translations)) -> Result(Nil, RuntimeError) {
  github.get_main_repository()
  |> result.try(github.list_releases)
  |> result.map_error(FromGithubModule)
  |> result.try(choose_release(_, t))
  |> result.try(common_path(_, t))
}

/// This part here is common for both the without_cache and the with_cache paths
fn common_path(
  in: github.GithubRelease,
  t: option.Option(t.Translations),
) -> Result(Nil, RuntimeError) {
  choose_asset(in, t)
  |> result.try(fn(a) {
    io.println(
      t.translate(
        t,
        t.Key("common_path_downloading"),
        "Downloading: {{ font_name }}",
        [#("font_name", a.name)],
      ),
    )
    github.download_asset(a, in_memory: True)
    |> result.map_error(FromGithubModule)
  })
  |> result.try(choose_font(_, t))
  |> result.try(extract_file(_, t))
  |> result.try(replace_file(_, t))
  |> result.try(fn(result) {
    let #(result, original_file) = result
    case result {
      False ->
        io.println(
          t.translate(
            t,
            t.Key("common_path_no_bad_feelings"),
            "No bad feelings, your file is still available at: {{ original_file }}",
            [#("original_file", original_file)],
          ),
        )
      True ->
        io.println(
          t.translate(
            t,
            t.Key("done"),
            "Done! Do not forget to run termux-reload-settings",
            [],
          ),
        )
    }

    Ok(Nil)
  })
}

fn print_usage(t: option.Option(t.Translations)) -> Result(Nil, Nil) {
  io.println(
    t.translate(
      t,
      t.Key("usage_header"),
      "usage: gleamfonts [--delete-cache] [--no-cache] [--help] [--version]",
      [],
    ),
  )
  io.println(
    t.translate(
      t,
      t.Key("usage_nc"),
      "  --no-cache fetch all the data from GitHub, ignoring the cache",
      [],
    ),
  )
  io.println(
    t.translate(
      t,
      t.Key("usage_dc"),
      "  --delete-cache remove the old cache first",
      [],
    ),
  )
  io.println(
    t.translate(
      t,
      t.Key("usage_hp"),
      "  --help print this help page and exit",
      [],
    ),
  )
  io.println(
    t.translate(
      t,
      t.Key("usage_vs"),
      "  --version print version information and exit",
      [],
    ),
  )

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

  let locale =
    tools.get_env("LANG")
    |> option.then(fn(s) {
      string.split(s, ".")
      |> tools.first
    })
    |> option.unwrap("")
    |> t.load_locale

  case behavior {
    application_behavior.PrintHelp -> print_usage(locale)
    application_behavior.PrintVersion -> print_version()
    application_behavior.WithCache(delete) -> {
      let db_file = tools.get_cache_dir() <> "db.sqlite"
      use _ <- result.try(
        simplifile.create_directory_all(tools.get_cache_dir())
        |> result.map_error(fn(e) {
          print_error(FromSimplifileModule(e), locale)
        }),
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
      |> result.try(with_cache(_, locale))
      |> result.map_error(print_error(_, locale))
    }
    application_behavior.WithoutCache ->
      without_cache(locale) |> result.map_error(print_error(_, locale))
  }
}
