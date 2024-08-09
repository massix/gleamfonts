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
  case os.get_env(k) {
    Ok(s) -> option.Some(s)
    Error(_) -> option.None
  }
}

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
  case list {
    [] -> option.None
    [f, ..] -> option.Some(f)
  }
}

/// Similar to `each' but the predicate gets the current index
pub fn iterate_list(in l: List(a), predicate p: fn(Int, a) -> Nil) -> Nil {
  iterate_list_acc(l, p, 0)
}

fn iterate_list_acc(l: List(a), p: fn(Int, a) -> Nil, acc: Int) -> Nil {
  case list.is_empty(l) {
    True -> Nil
    False -> {
      let assert Ok(elt) = list.first(l)
      p(acc, elt)
      iterate_list_acc(list.drop(l, 1), p, acc + 1)
    }
  }
}

/// Gets the item at the index i from the list
/// Returns Some(a) if the item is found, None if the index does not exist
pub fn item_at(from list: List(a), index i: Int) -> option.Option(a) {
  case list.drop(list, i) |> list.first {
    Ok(a) -> option.Some(a)
    Error(_) -> option.None
  }
}

pub fn make_temporary_folder(prefix p: option.Option(String)) -> TmpFolder {
  let prefix = case p {
    option.Some(opt) -> opt
    option.None -> ""
  }

  let tmpdir = get_env("TMPDIR") |> option.unwrap("/tmp")

  let path = [tmpdir, prefix, gluid.guidv4(), ""] |> string.join("/")
  case simplifile.create_directory_all(path) {
    Ok(_) -> TmpFolder(path)
    Error(_) -> panic as { "Could not create folder: " <> path }
  }
}
