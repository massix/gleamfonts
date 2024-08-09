import gleam/erlang/os
import gleam/list
import gleam/option
import gleam/string
import gluid
import simplifile

pub type TmpFolder {
  TmpFolder(path: String)
}

/// Better version of os.env, returning an option instead of an error
pub fn get_env(key k: String) -> option.Option(String) {
  option.from_result(os.get_env(k))
}

/// Retrieves the path to be used to store the database
pub fn get_cache_dir() -> String {
  let cache_dir =
    get_env("XDG_CACHE_HOME")
    |> option.or(get_env("HOME") |> option.map(fn(p) { p <> "/.cache" }))
    |> option.unwrap("/tmp")
    |> string.append("/gleamfonts/")

  cache_dir
}

/// Gets a random element from the list
pub fn random(from list: List(a)) -> option.Option(a) {
  case list {
    [] -> option.None
    _ -> {
      let assert Ok(a) = list |> list.shuffle |> list.first
      option.Some(a)
    }
  }
}

/// Gets the head of the list
pub fn first(from list: List(a)) -> option.Option(a) {
  option.from_result(list.first(list))
}

/// Similar to `each' but the predicate gets the current index
pub fn iterate_list(in l: List(a), predicate p: fn(Int, a) -> Nil) -> Nil {
  iterate_list_acc(l, p, 0)
}

fn iterate_list_acc(l: List(a), p: fn(Int, a) -> Nil, acc: Int) -> Nil {
  case l {
    [] -> Nil
    [elt, ..rest] -> {
      p(acc, elt)
      iterate_list_acc(rest, p, acc + 1)
    }
  }
}

/// Gets the item at the index i from the list
/// Returns Some(a) if the item is found, None if the index does not exist
pub fn item_at(from list: List(a), index i: Int) -> option.Option(a) {
  list.drop(list, i) |> first
}

// FIXME: Do not panic
/// Creates a temporary folder inside the configured TMPDIR.
pub fn make_temporary_folder(prefix p: option.Option(String)) -> TmpFolder {
  let prefix = option.unwrap(p, "")
  let tmpdir = get_env("TMPDIR") |> option.unwrap("/tmp")
  let path = [tmpdir, prefix, gluid.guidv4(), ""] |> string.join("/")

  case simplifile.create_directory_all(path) {
    Ok(_) -> TmpFolder(path)
    Error(_) -> panic as { "Could not create folder: " <> path }
  }
}
