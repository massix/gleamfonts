import birl
import gleam/list
import gleam/option
import gleam/uri
import gleamfonts/db/connector
import gleamfonts/db/migration
import gleamfonts/github
import gleamfonts/tools
import startest.{describe, it}
import startest/expect

fn with_migrated_db(
  path p: String,
  predicate f: fn(connector.Connector) -> a,
) -> Nil {
  let connector =
    connector.new()
    |> connector.connect(p)
    |> expect.to_be_ok

  let assert option.Some(db) = connector.get_connection(connector)

  migration.migrate(db, "")
  |> expect.to_be_ok

  f(connector)

  connector.disconnect(connector)
  |> expect.to_be_ok

  Nil
}

pub fn connector_tests() {
  describe("connector", [
    describe("connect/disconnect", [
      it("can connect and disconnect", fn() {
        let connector =
          connector.new()
          |> connector.connect(":memory:")
          |> expect.to_be_ok

        connector.is_connected(connector) |> expect.to_be_true()

        connector.disconnect(connector)
        |> expect.to_be_ok
        |> connector.is_connected
        |> expect.to_be_false
      }),
    ]),
    describe("github_repository", [
      it("can store and retrieve repositories", fn() {
        use connector <- with_migrated_db(":memory:")

        connector.store_repository(
          connector,
          github.GithubRepository(
            14,
            "releases_url",
            "html_url",
            "some description",
          ),
        )
        |> expect.to_be_ok
        |> expect.to_equal(14)

        connector.get_repository(connector, 14)
        |> expect.to_be_ok
        |> expect.to_be_some
        |> expect.to_equal(github.GithubRepository(
          14,
          "releases_url",
          "html_url",
          "some description",
        ))

        connector.get_repository(connector, 22)
        |> expect.to_be_ok
        |> expect.to_be_none
      }),
      it("can retrieve all the repositories", fn() {
        use connector <- with_migrated_db(":memory:")

        [1, 2, 3, 4, 5]
        |> list.map(github.GithubRepository(
          _,
          "releases_url",
          "html_url",
          "some_description",
        ))
        |> list.each(connector.store_repository(connector, _))

        let all_repositories =
          connector.get_all_repositories(connector) |> expect.to_be_ok
        all_repositories |> list.length |> expect.to_equal(5)

        all_repositories
        |> list.all(fn(r) { r.releases_url == "releases_url" })
        |> expect.to_be_true

        use idx, elt <- tools.iterate_list(all_repositories)
        expect.to_equal(idx + 1, elt.id)
      }),
    ]),
    describe("github_release", [
      it("can store and retrieve a release", fn() {
        use connector <- with_migrated_db(":memory:")

        github.GithubRelease(
          0,
          uri.parse("https://www.google.com") |> expect.to_be_ok,
          "tag_name",
          "release_name",
          birl.now(),
          [
            github.GithubAsset(
              42,
              uri.parse("https://www.google.com/asset42") |> expect.to_be_ok,
              uri.parse("https://www.google.com/asset42") |> expect.to_be_ok,
              "asset_0",
              option.None,
              birl.now(),
            ),
            github.GithubAsset(
              43,
              uri.parse("https://www.google.com/asset43") |> expect.to_be_ok,
              uri.parse("https://www.google.com/asset43") |> expect.to_be_ok,
              "asset_1",
              option.None,
              birl.now(),
            ),
            github.GithubAsset(
              44,
              uri.parse("https://www.google.com/asset44") |> expect.to_be_ok,
              uri.parse("https://www.google.com/asset44") |> expect.to_be_ok,
              "asset_2",
              option.None,
              birl.now(),
            ),
          ],
        )
        |> connector.store_release(connector, _)
        |> expect.to_be_ok
        |> expect.to_equal(0)

        connector.get_release(connector, 0)
        |> expect.to_be_ok
        |> option.map(fn(r) { r.assets })
        |> expect.to_be_some
        |> list.length
        |> expect.to_equal(3)

        connector.get_release(connector, 32)
        |> expect.to_be_ok
        |> expect.to_be_none

        connector.get_all_releases(connector)
        |> expect.to_be_ok
        |> list.length
        |> expect.to_equal(1)
      }),
    ]),
  ])
}
