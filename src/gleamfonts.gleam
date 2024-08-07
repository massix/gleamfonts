import birl
import gleam/erlang
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleamfonts/github
import gleamfonts/hackto
import gleamfonts/tools
import gleamfonts/unzip
import simplifile

type RuntimeError {
  FromGithubModule(github.GithubError)
  FromUnzipModule(unzip.ZipError)
  FromHacktoModule(hackto.HackneyError)
  FromSimplifileModule(simplifile.FileError)
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
    GenericError(s) -> s
  }

  io.println(string)
}

// FIXME: handle these errors in a better way
fn read_input_int(prompt: String, default: option.Option(Int)) -> Int {
  case erlang.get_line(prompt) {
    Error(_) -> panic as "I/O Error"
    Ok(s) ->
      case int.parse(s |> string.trim) {
        Error(_) -> {
          case default {
            option.Some(x) -> x
            option.None -> panic as "Could not parse input as integer"
          }
        }
        Ok(s) -> s
      }
  }
}

fn choose_release() -> Result(github.GithubRelease, RuntimeError) {
  io.println("Fetching repository's informations")
  use releases <- result.try(
    github.get_main_repository()
    |> result.try(github.list_releases)
    |> result.map_error(fn(e) { FromGithubModule(e) })
    |> result.try(fn(l) {
      case list.length(l) {
        x if x <= 0 -> Error(GenericError("Could not fetch the releases"))
        _ -> Ok(l)
      }
    }),
  )

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
  let read_index =
    read_input_int(" ~ Your choice (default: 0) > ", option.Some(0))

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

  let read_index = read_input_int(" ~ Your choice > ", option.None)
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

      let read_index = read_input_int(" ~ Your choice > ", option.None)
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
      |> result.map_error(fn(e) { FromSimplifileModule(e) })
    }
    False -> Ok(#(False, in))
  }
}

pub fn main() {
  choose_release()
  |> result.try(choose_asset)
  |> result.try(fn(a) {
    io.println("Downloading: " <> a.name)
    github.download_asset(a, in_memory: True)
    |> result.map_error(fn(e) { FromGithubModule(e) })
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
  |> result.map_error(fn(e) { print_error(e) })
}
