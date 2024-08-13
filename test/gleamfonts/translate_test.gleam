import gleamfonts/translate
import startest.{describe, it}
import startest/expect

pub fn translate_tests() {
  describe("translate", [
    it("can load a locale file", fn() {
      translate.load_locale("it_IT")
      |> expect.to_be_some

      Nil
    }),
    it("can translate a string", fn() {
      translate.load_locale("it_IT")
      |> translate.translate(
        translate.Key("main_error_from_github_module"),
        "Default string {{describe}}",
        [#("describe", "qualcosa non va")],
      )
      |> expect.to_equal(
        "Errore durante la comunicazione con GitHub: qualcosa non va",
      )
    }),
    it("will return the default string if no key is found", fn() {
      translate.load_locale("it_IT")
      |> translate.translate(
        translate.Key("not existing"),
        "Error while doing something: {{error_desc}}",
        [#("error_desc", "this is the description of the error")],
      )
      |> expect.to_equal(
        "Error while doing something: this is the description of the error",
      )
    }),
    it("will return the default string if no locale is found", fn() {
      translate.load_locale("not_EXISTING")
      |> translate.translate(
        translate.Key("not existing"),
        "Default {{something}} {{ happened }}",
        [#("something", "Hello"), #("happened", "World")],
      )
      |> expect.to_equal("Default Hello World")
    }),
  ])
}
