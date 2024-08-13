import gleam/dict
import gleam/dynamic
import gleam/erlang
import gleam/json
import gleam/option
import gleam/result
import gleam/string
import simplifile

pub type Key {
  Key(String)
}

pub type Raw {
  Raw(String)
}

pub type Translations =
  dict.Dict(Key, Raw)

/// Loads the translations file for the given locale, returning None if no locale is found
pub fn load_locale(lang l: String) -> option.Option(Translations) {
  let assert Ok(priv) = erlang.priv_directory("gleamfonts")
  use content <- option.then(
    simplifile.read(priv <> "/" <> l <> ".json")
    |> option.from_result,
  )

  let key_decoder = fn(d: dynamic.Dynamic) {
    use k <- result.map(d |> dynamic.string)
    Key(k)
  }

  let raw_decoder = fn(d: dynamic.Dynamic) {
    use raw <- result.map(d |> dynamic.string)
    Raw(raw)
  }

  case json.decode(content, dynamic.dict(key_decoder, raw_decoder)) {
    Ok(k) -> option.Some(k)
    Error(_) -> option.None
  }
}

fn apply_transformations(s: String, t: List(#(String, String))) {
  case t {
    [] -> s
    [#(k, v), ..rest] -> {
      let classic = "{{ " <> k <> " }}"
      let no_spaces = "{{" <> k <> "}}"

      let transformed =
        s |> string.replace(classic, v) |> string.replace(no_spaces, v)
      apply_transformations(transformed, rest)
    }
  }
}

/// Translates a key, uses default as the raw string if a raw string for that key
/// is not found inside the database or if no translation DB has been loaded
pub fn translate(
  using t: option.Option(Translations),
  key key: Key,
  default default: String,
  with_args args: List(#(String, String)),
) -> String {
  case t {
    option.Some(t) ->
      case dict.get(t, key) {
        Ok(Raw(raw)) -> raw
        Error(_) -> default
      }
    option.None -> default
  }
  |> apply_transformations(args)
}
