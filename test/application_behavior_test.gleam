import application_behavior.{PrintHelp, PrintVersion, WithCache, WithoutCache}
import gleam/list
import startest.{describe, it}
import startest/expect

const all_behaviors = [
  WithCache(True), WithCache(False), PrintVersion, PrintHelp, WithoutCache,
]

pub fn application_behavior_tests() {
  describe("application_behavior", [
    it("default to cache without delete", fn() {
      let args = fn() { [] }
      application_behavior.get_application_behavior(args)
      |> expect.to_equal(WithCache(False))
    }),
    help_flag_suite(),
    version_flag_suite(),
    delete_cache_flag_suite(),
    without_cache_flag_suite(),
  ])
}

fn help_flag_suite() {
  describe("help flag", [
    it("should override everything", fn() {
      all_behaviors
      |> list.map(application_behavior.flag_print_help(_, ["--help"]))
      |> expect.to_equal([PrintHelp, PrintHelp, PrintHelp, PrintHelp, PrintHelp])
    }),
  ])
}

fn version_flag_suite() {
  describe("version flag", [
    it("should override cache and nocache", fn() {
      all_behaviors
      |> list.map(application_behavior.flag_print_version(_, ["--version"]))
      |> expect.to_equal([
        PrintVersion,
        PrintVersion,
        PrintVersion,
        PrintHelp,
        PrintVersion,
      ])
    }),
  ])
}

fn delete_cache_flag_suite() {
  describe("delete cache flag", [
    it("should only work with WithCache", fn() {
      all_behaviors
      |> list.map(application_behavior.flag_delete_cache(_, ["--delete-cache"]))
      |> expect.to_equal([
        WithCache(True),
        WithCache(True),
        PrintVersion,
        PrintHelp,
        WithoutCache,
      ])
    }),
  ])
}

fn without_cache_flag_suite() {
  describe("without cache flag", [
    it("should override all but prints", fn() {
      all_behaviors
      |> list.map(application_behavior.flag_without_cache(_, ["--no-cache"]))
      |> expect.to_equal([
        WithoutCache,
        WithoutCache,
        PrintVersion,
        PrintHelp,
        WithoutCache,
      ])
    }),
  ])
}
