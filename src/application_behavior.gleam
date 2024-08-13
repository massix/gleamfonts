import gleam/list

// Drives the behavior of the Application depending on the flags
pub type ApplicationBehavior {
  WithCache(delete_cache: Bool)
  WithoutCache
  PrintHelp
  PrintVersion
}

pub fn flag_print_help(
  current_behavior: ApplicationBehavior,
  arguments: List(String),
) -> ApplicationBehavior {
  case list.contains(arguments, "--help") {
    True -> PrintHelp
    False -> current_behavior
  }
}

pub fn flag_print_version(
  current_behavior: ApplicationBehavior,
  arguments: List(String),
) -> ApplicationBehavior {
  case list.contains(arguments, "--version") {
    False -> current_behavior
    True ->
      case current_behavior {
        PrintHelp -> PrintHelp
        _ -> PrintVersion
      }
  }
}

pub fn flag_delete_cache(
  current_behavior: ApplicationBehavior,
  arguments: List(String),
) -> ApplicationBehavior {
  case current_behavior {
    WithCache(_) -> WithCache(list.contains(arguments, "--delete-cache"))
    _ -> current_behavior
  }
}

pub fn flag_without_cache(
  current_behavior: ApplicationBehavior,
  arguments: List(String),
) -> ApplicationBehavior {
  case list.contains(arguments, "--no-cache") {
    False -> current_behavior
    True ->
      case current_behavior {
        WithCache(_) | WithoutCache -> WithoutCache
        _ -> current_behavior
      }
  }
}

pub fn get_application_behavior(
  from: fn() -> List(String),
) -> ApplicationBehavior {
  let arguments = from()

  WithCache(False)
  |> flag_print_help(arguments)
  |> flag_print_version(arguments)
  |> flag_delete_cache(arguments)
  |> flag_without_cache(arguments)
}
