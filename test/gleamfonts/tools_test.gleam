import gleam/erlang/os
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleamfonts/tools
import simplifile
import startest.{describe, it}
import startest/expect

pub fn tools_tests() {
  describe("tools", [
    iterate_list_suite(),
    first_suite(),
    make_temporary_folder_suite(),
    random_suite(),
    item_at_suite(),
    get_env_suite(),
  ])
}

fn get_env_suite() {
  describe("Environment Variable", [
    it("Should return the variable if it exists", fn() {
      tools.get_env("HOME") |> expect.to_be_some
      Nil
    }),
    it("Should return none if the variable does not exist", fn() {
      // just to be sure
      os.unset_env("DOESNOTEXIST")
      tools.get_env("DOESNOTEXIST") |> expect.to_be_none
    }),
  ])
}

fn item_at_suite() {
  describe("Item at", [
    it("Empty list", fn() { [] |> tools.item_at(5) |> expect.to_be_none }),
    it("Normal list", fn() {
      [1, 2, 3] |> tools.item_at(1) |> expect.to_be_some |> expect.to_equal(2)
    }),
    it("Single element list", fn() {
      [1] |> tools.item_at(0) |> expect.to_be_some |> expect.to_equal(1)
    }),
    it("Last element", fn() {
      [1, 2, 3, 4]
      |> tools.item_at(3)
      |> expect.to_be_some
      |> expect.to_equal(4)
    }),
    it("Out of bounds", fn() {
      [] |> tools.item_at(0) |> expect.to_be_none
      [1, 2] |> tools.item_at(2) |> expect.to_be_none
    }),
  ])
}

fn check_random(list: List(a), max_repeats: Int) -> Bool {
  case max_repeats == 0 {
    True -> False
    False -> {
      let first = tools.random(list)
      let second = tools.random(list)

      case first == second {
        False -> True
        True -> check_random(list, max_repeats - 1)
      }
    }
  }
}

fn first_suite() {
  describe("First element", [
    it("Empty list", fn() { [] |> tools.first |> expect.to_be_none }),
    it("Single element", fn() {
      [1] |> tools.first |> expect.to_be_some |> expect.to_equal(1)
    }),
    it("Many elements", fn() {
      [1, 2, 3, 4] |> tools.first |> expect.to_be_some |> expect.to_equal(1)
    }),
  ])
}

fn random_suite() {
  describe("Random elements", [
    it("Empty list", fn() { [] |> tools.random |> expect.to_be_none }),
    it("Single element", fn() {
      [1] |> tools.random |> expect.to_be_some |> expect.to_equal(1)
    }),
    it("All different", fn() {
      [1, 2, 3, 4, 5] |> check_random(10) |> expect.to_be_true
    }),
    it("All equal", fn() {
      [1, 1, 1, 1, 1] |> check_random(10) |> expect.to_be_false
    }),
  ])
}

fn make_temporary_folder_suite() {
  describe("Make temporary folder", [
    it("With prefix", fn() { make_temporary_folder_gen(with_prefix: True) }),
    it("Without prefix", fn() { make_temporary_folder_gen(with_prefix: False) }),
  ])
}

fn make_temporary_folder_gen(with_prefix p: Bool) {
  os.set_env("TMPDIR", ".")

  let tools.TmpFolder(path) =
    tools.make_temporary_folder(case p {
      True -> option.Some("tmp_test")
      False -> option.None
    })

  path |> string.is_empty |> expect.to_be_false

  let split_path =
    string.split(path, "/")
    |> list.filter(fn(s) { !string.is_empty(s) })

  list.last(split_path)
  |> expect.to_be_ok
  |> string.length
  |> expect.to_equal(36)

  case p {
    True -> list.contains(split_path, "tmp_test") |> expect.to_be_true
    False -> Nil
  }

  simplifile.is_directory(path) |> expect.to_be_ok |> expect.to_be_true
  simplifile.delete(path) |> expect.to_be_ok

  case simplifile.is_directory("./tmp_test") {
    Ok(_) -> {
      let _ = simplifile.delete("./tmp_test")
      Nil
    }
    Error(_) -> Nil
  }
}

fn iterate_list_suite() {
  describe("Iterate over list", [
    it("Should iterate", fn() {
      ["0", "1", "2", "3"]
      |> tools.iterate_list(fn(i, e) {
        let assert Ok(res) = int.parse(e)
        expect.to_equal(res, i)
      })
    }),
  ])
}
