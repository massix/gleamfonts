import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/charlist
import gleam/list
import gleam/result
import gleam/string
import gleamfonts/github
import simplifile

@external(erlang, "zip", "list_dir")
fn erl_unzip_list_dir_file(
  path: charlist.Charlist,
) -> Result(List(FFIZipContent), dynamic.Dynamic)

@external(erlang, "zip", "list_dir")
fn erl_unzip_list_dir_binary(
  binary: BitArray,
) -> Result(List(FFIZipContent), dynamic.Dynamic)

type FFIUnzipOption {
  Cwd(charlist.Charlist)
  FileList(List(charlist.Charlist))
}

pub type ZipUnzipOption {
  DestinationFolder(String)
  FilesToExtract(List(String))
}

fn to_ffi_unzip_option(in: ZipUnzipOption) -> FFIUnzipOption {
  case in {
    DestinationFolder(s) -> Cwd(s |> charlist.from_string)
    FilesToExtract(l) ->
      FileList(l |> list.map(fn(s) { s |> charlist.from_string }))
  }
}

@external(erlang, "zip", "unzip")
fn erl_unzip_unzip_file(
  path: charlist.Charlist,
  options: List(FFIUnzipOption),
) -> Result(List(charlist.Charlist), dynamic.Dynamic)

@external(erlang, "zip", "unzip")
fn erl_unzip_unzip_binary(
  binary: BitArray,
  options: List(FFIUnzipOption),
) -> Result(List(charlist.Charlist), dynamic.Dynamic)

pub type ZipContent {
  Comment(comment: String)
  File(
    name: String,
    info: ZipFileInfo,
    comment: String,
    offset: Int,
    comp_size: Int,
  )
}

pub type ZipFileInfo {
  FileInfo(size: Int)
}

type FFIZipContent {
  ZipComment(comment: charlist.Charlist)
  ZipFile(
    name: charlist.Charlist,
    info: ZipFileInfo,
    comment: charlist.Charlist,
    offset: Int,
    comp_size: Int,
  )
}

pub type ZipError {
  ZipError(reason: String)
}

fn dynamic_to_zip_error(in: dynamic.Dynamic) -> ZipError {
  case atom.from_dynamic(in) {
    Ok(result) -> {
      ZipError(["Error", result |> atom.to_string] |> string.join(": "))
    }
    Error(_) -> ZipError("Generic ZipError (probably bad payload)")
  }
}

fn ffi_list_dir_result_to_gleam(
  in: Result(List(FFIZipContent), dynamic.Dynamic),
) -> Result(List(ZipContent), ZipError) {
  let ffi_type_to_gleam = fn(in: FFIZipContent) -> ZipContent {
    case in {
      ZipComment(comment) -> Comment(comment |> charlist.to_string)
      ZipFile(name, info, comment, offset, comp_size) ->
        File(
          name |> charlist.to_string,
          info,
          comment |> charlist.to_string,
          offset,
          comp_size,
        )
    }
  }

  in
  |> result.map(fn(l) { list.map(l, ffi_type_to_gleam) })
  |> result.map_error(dynamic_to_zip_error)
}

fn ffi_unzip_result_to_gleam(
  in: Result(List(charlist.Charlist), dynamic.Dynamic),
) -> Result(List(String), ZipError) {
  let map_list = fn(list: List(charlist.Charlist)) -> List(String) {
    list.map(list, fn(c) { c |> charlist.to_string })
  }

  in
  |> result.map(map_list)
  |> result.map_error(dynamic_to_zip_error)
}

pub fn list_asset_content(
  asset in: github.GithubDownloadedAsset,
) -> Result(List(ZipContent), ZipError) {
  case in {
    github.FileAsset(p) ->
      erl_unzip_list_dir_file(p |> charlist.from_string)
      |> ffi_list_dir_result_to_gleam
    github.MemoryAsset(b) ->
      erl_unzip_list_dir_binary(b)
      |> ffi_list_dir_result_to_gleam
  }
}

pub fn unzip_asset(
  asset in: github.GithubDownloadedAsset,
  options options: List(ZipUnzipOption),
) -> Result(List(String), ZipError) {
  let options = list.map(options, to_ffi_unzip_option)

  // Helper function to unzip
  let do_unzip = fn() -> Result(List(String), ZipError) {
    case in {
      github.FileAsset(p) ->
        erl_unzip_unzip_file(p |> charlist.from_string, options)
        |> ffi_unzip_result_to_gleam
      github.MemoryAsset(b) ->
        erl_unzip_unzip_binary(b, options)
        |> ffi_unzip_result_to_gleam
    }
  }

  // This function returns an error if an option has been defined more than once (even with different parameters)
  let check_options = fn() -> Result(Nil, ZipError) {
    let total_cwd =
      list.count(options, fn(opt) {
        case opt {
          Cwd(_) -> True
          _ -> False
        }
      })

    let total_file_list =
      list.count(options, fn(opt) {
        case opt {
          FileList(_) -> True
          _ -> False
        }
      })

    case total_cwd {
      x if x > 1 -> Error(ZipError("Too many Cwds"))
      _ ->
        case total_file_list {
          x if x > 1 -> Error(ZipError("Too many FileLists"))
          _ -> Ok(Nil)
        }
    }
  }

  // This function returns an error if the destination folder does not exist.
  let check_destination_folder = fn() -> Result(Nil, ZipError) {
    // Fail if the destination folder does not exist
    let result =
      options
      |> list.filter_map(fn(opt) {
        case opt {
          Cwd(s) -> Ok(s)
          _ -> Error(Nil)
        }
      })
      |> list.first

    case result {
      Ok(cwd) ->
        case simplifile.is_directory(cwd |> charlist.to_string) {
          // We can move forward if *and only if* we have a True value here
          Ok(True) -> Ok(Nil)
          _ -> Error(ZipError("Destination folder does not exist"))
        }

      _ -> Ok(Nil)
    }
  }

  use _ <- result.try(check_options())
  use _ <- result.try(check_destination_folder())

  do_unzip()
}
