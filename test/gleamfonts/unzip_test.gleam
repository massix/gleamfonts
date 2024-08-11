import gleam/bit_array
import gleam/list
import gleam/string
import gleamfonts/github
import gleamfonts/unzip
import gluid
import simplifile
import startest.{describe, it}
import startest/expect

pub fn unzip_tests() {
  describe("unzip", [
    list_content_suite(),
    unzip_asset_suite(),
    list_asset_content_errors_suite(),
    unzip_asset_errors_suite(),
  ])
}

fn list_asset_content_errors_suite() {
  describe("List failures", [
    it("Should fail if file does not exist", fn() {
      let error =
        github.FileAsset("non_existing.zip")
        |> unzip.list_asset_content
        |> expect.to_be_error
        |> fn(e: unzip.ZipError) { e.reason }

      error |> expect.to_equal("Error: enoent")
    }),
    it("Should fail if payload is not in zip format", fn() {
      let error =
        github.MemoryAsset(bit_array.from_string("Invalid payload"))
        |> unzip.list_asset_content
        |> expect.to_be_error
        |> fn(e: unzip.ZipError) { e.reason }

      error |> expect.to_equal("Generic ZipError (probably bad payload)")
    }),
  ])
}

fn make_folders() -> #(String, String) {
  let assert Ok(current_directory) = simplifile.current_directory()
  let data_folder = [current_directory, "test_data"] |> string.join(with: "/")
  let assert Ok(result) = simplifile.is_directory(data_folder)
  case result {
    False -> panic as "Could not find test_data folder!"
    _ -> Nil
  }

  let work_folder =
    [current_directory, "test_result", gluid.guidv4()] |> string.join(with: "/")
  case simplifile.create_directory_all(work_folder) {
    Ok(Nil) -> Nil
    Error(simplifile.Eexist) -> Nil
    Error(_) -> panic as "Could not create test_result folder"
  }

  #(data_folder, work_folder)
}

// Helper function which will create and remove the test folder
fn with_work_folder(f: fn(String, String) -> Nil) -> Nil {
  let #(data_folder, work_folder) = make_folders()
  f(data_folder, work_folder)
  let assert Ok(Nil) = simplifile.delete("./test_result")

  Nil
}

fn list_content_suite() {
  let #(data_folder, _) = make_folders()

  describe("List content", [
    it("Can list from files", fn() {
      let file_path = [data_folder, "0xProto.zip"] |> string.join(with: "/")
      let result =
        unzip.list_asset_content(github.FileAsset(file_path))
        |> expect.to_be_ok
        |> list.filter_map(fn(zc) {
          case zc {
            unzip.File(name, ..) -> Ok(name)
            unzip.Comment(..) -> Error(Nil)
          }
        })

      result |> list.all(string.ends_with(_, ".ttf")) |> expect.to_be_true
      result |> expect.list_to_contain("0xProtoNerdFont-Regular.ttf")
    }),
    it("Can list from BitArray", fn() {
      let file_path = [data_folder, "0xProto.zip"] |> string.join(with: "/")
      let assert Ok(bit_content) = simplifile.read_bits(file_path)

      let result =
        unzip.list_asset_content(github.MemoryAsset(bit_content))
        |> expect.to_be_ok
        |> list.filter_map(fn(zc) {
          case zc {
            unzip.File(name, ..) -> Ok(name)
            _ -> Error(Nil)
          }
        })

      result |> list.all(string.ends_with(_, ".ttf")) |> expect.to_be_true
      result |> expect.list_to_contain("0xProtoNerdFontMono-Regular.ttf")
    }),
  ])
}

fn unzip_asset_suite() {
  describe("Unzip file", [
    it("Can unzip from files", fn() {
      use data_folder, work_folder <- with_work_folder()

      let file_path = [data_folder, "0xProto.zip"] |> string.join(with: "/")
      unzip.unzip_asset(github.FileAsset(file_path), [
        unzip.DestinationFolder(work_folder),
      ])
      |> expect.to_be_ok
      |> list.map(fn(elt) {
        string.split(elt, on: "/") |> list.last |> expect.to_be_ok
      })
      |> expect.list_to_contain("0xProtoNerdFont-Regular.ttf")

      simplifile.is_file(work_folder <> "/0xProtoNerdFont-Regular.ttf")
      |> expect.to_be_ok
      |> expect.to_be_true
    }),
    it("Can unzip from BitArray", fn() {
      use data_folder, work_folder <- with_work_folder()

      [data_folder, "0xProto.zip"]
      |> string.join(with: "/")
      |> simplifile.read_bits
      |> expect.to_be_ok
      |> github.MemoryAsset
      |> unzip.unzip_asset([unzip.DestinationFolder(work_folder)])
      |> expect.to_be_ok
      |> list.map(fn(elt) {
        string.split(elt, on: "/") |> list.last |> expect.to_be_ok
      })
      |> expect.list_to_contain("0xProtoNerdFontMono-Regular.ttf")

      simplifile.is_file(work_folder <> "/0xProtoNerdFontMono-Regular.ttf")
      |> expect.to_be_ok
      |> expect.to_be_true
    }),
    it("Can unzip a single file", fn() {
      use data_folder, work_folder <- with_work_folder()

      { data_folder <> "/0xProto.zip" }
      |> simplifile.read_bits
      |> expect.to_be_ok
      |> github.MemoryAsset
      |> unzip.unzip_asset([
        unzip.DestinationFolder(work_folder),
        unzip.FilesToExtract(["README.md"]),
      ])
      |> expect.to_be_ok
      |> list.length
      |> expect.to_equal(1)
    }),
    it("Can unzip no files at all", fn() {
      use data_folder, work_folder <- with_work_folder()

      github.FileAsset(data_folder <> "/0xProto.zip")
      |> unzip.unzip_asset([
        unzip.DestinationFolder(work_folder),
        unzip.FilesToExtract(["NOT_IN_THE_ZIP.md"]),
      ])
      |> expect.to_be_ok
      |> list.is_empty
      |> expect.to_be_true
    }),
  ])
}

fn unzip_asset_errors_suite() {
  describe("Unzip failures", [
    it("Should fail if the file does not exist", fn() {
      github.FileAsset("./does_not_exist.zip")
      |> unzip.unzip_asset([])
      |> expect.to_be_error
      |> expect.to_equal(unzip.ZipError("Error: enoent"))
    }),
    it("Should fail if the target folder does not exist", fn() {
      use data_folder, _work_folder <- with_work_folder()

      github.FileAsset(data_folder <> "/0xProto.zip")
      |> unzip.unzip_asset([unzip.DestinationFolder("./does_not_exist")])
      |> expect.to_be_error
      |> expect.to_equal(unzip.ZipError("Destination folder does not exist"))

      Nil
    }),
    describe("Options", [
      it("Should fail if CWD is specified more than once", fn() {
        use data_folder, work_folder <- with_work_folder()

        github.FileAsset(data_folder <> "/0xProto.zip")
        |> unzip.unzip_asset([
          unzip.DestinationFolder(work_folder),
          unzip.DestinationFolder(work_folder <> "2"),
        ])
        |> expect.to_be_error
        |> expect.to_equal(unzip.ZipError("Too many Cwds"))
      }),
      it("Should fail if FileList is specified more than once", fn() {
        use data_folder, work_folder <- with_work_folder()

        github.FileAsset(data_folder <> "/0xProto.zip")
        |> unzip.unzip_asset([
          unzip.DestinationFolder(work_folder),
          unzip.FilesToExtract([]),
          unzip.FilesToExtract(["README.md"]),
          unzip.FilesToExtract(["0xProtoNerdFont-Regular.ttf"]),
        ])
        |> expect.to_be_error
        |> expect.to_equal(unzip.ZipError("Too many FileLists"))
      }),
    ]),
  ])
}
