import birl
import gleam/dynamic
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import gleam/uri
import gleamfonts/github
import startest.{describe, it}
import startest/expect

// Helper function
fn generate_random_assets(
  quantity counter: Int,
  accumulator acc: List(github.GithubAsset),
) -> List(github.GithubAsset) {
  let download_url_base = "https://download.github.com"
  let font_names = [
    "0xProto", "Lekton", "JetBrains", "Ubuntu", "Recursive", "ZedMono",
    "ComicShanns",
  ]
  let extensions = ["zip", "tar.xz", "tar.gz"]
  let created_at = "2024-01-01" |> birl.parse |> expect.to_be_ok

  case counter {
    0 -> acc
    _ -> {
      let font_name =
        { int.random(list.length(font_names)) + 1 }
        |> list.take(font_names, _)
        |> list.last
        |> expect.to_be_ok

      let font_extension =
        { int.random(list.length(extensions)) + 1 }
        |> list.take(extensions, _)
        |> list.last
        |> expect.to_be_ok

      let font_name = [font_name, font_extension] |> string.join(".")
      let download_url =
        [download_url_base, font_name]
        |> string.join("/")
        |> uri.parse
        |> expect.to_be_ok

      let new_asset =
        github.GithubAsset(
          download_url,
          download_url,
          font_name,
          option.None,
          created_at,
        )

      generate_random_assets(counter - 1, list.append([new_asset], acc))
    }
  }
}

// Helper function, need this to be recursive to make sure we have the adequate
// number of elements in each release
fn sort_and_filter_releases() {
  let uri =
    uri.parse("https://api.github.com/repos/owner/repo/releases?per_page=500")
    |> expect.to_be_ok

  let dates =
    [
      "2024-03-01T00:00:00.9Z", "2024-02-04T00:00:00.9Z",
      "2024-01-04T00:00:00.9Z", "2024-12-12T00:00:00.9Z",
    ]
    |> list.map(fn(date) { birl.parse(date) |> expect.to_be_ok })

  let assets = [
    generate_random_assets(10, []),
    generate_random_assets(10, []),
    generate_random_assets(10, []),
    generate_random_assets(10, []),
  ]

  // Verify that there is at least 1 zip for each release,
  // and less than 10, otherwise relaunch the test.
  let result =
    list.all(assets, fn(a) {
      let zip_count =
        a |> list.count(fn(a) { string.ends_with(a.name, ".zip") })
      zip_count >= 1 && zip_count < 10
    })

  case result {
    False -> sort_and_filter_releases()
    True -> {
      let unsorted_releases =
        list.map2(dates, assets, fn(date, asset) {
          github.GithubRelease(0, uri, "tag_name", "release_name", date, asset)
        })
        |> list.shuffle

      let sorted_releases = github.sort_and_filter_releases(unsorted_releases)
      { unsorted_releases != sorted_releases } |> expect.to_be_true

      let first_release = list.first(sorted_releases) |> expect.to_be_ok
      let last_release = list.last(sorted_releases) |> expect.to_be_ok

      first_release.published_at
      |> birl.to_naive_date_string
      |> expect.to_equal("2024-12-12")

      last_release.published_at
      |> birl.to_naive_date_string
      |> expect.to_equal("2024-01-04")

      list.all(sorted_releases, fn(release) {
        list.all(release.assets, fn(asset) {
          string.ends_with(asset.name, ".zip")
        })
      })
    }
  }
}

pub fn github_tests() {
  describe("github", [
    describe("Describe error", [
      it("Should not truncate the message", fn() {
        github.ErrorCannotCreateUri("something")
        |> github.describe_error
        |> expect.to_equal("Cannot create URI from: something")
      }),
      it("Should truncate the message", fn() {
        github.ErrorCannotDecodeResponse(
          "this string is longer than 80 chars, so it should be truncated by the describe_error function",
        )
        |> github.describe_error
        |> expect.to_equal(
          "Cannot decode body: this string is longer than 80 chars, so it should be truncated by the describe_e...",
        )
      }),
    ]),
    describe("Sort and filter releases", [
      it("Should sort and filter properly", fn() {
        sort_and_filter_releases() |> expect.to_be_true
      }),
    ]),
    describe("Decode dynamics", [
      it("Should decode URI fields", fn() {
        let uri.Uri(host:, scheme:, ..) =
          dynamic.from("https://www.google.com")
          |> github.decode_uri
          |> expect.to_be_ok

        host |> expect.to_be_some |> expect.to_equal("www.google.com")
        scheme |> expect.to_be_some |> expect.to_equal("https")

        let dynamic.DecodeError(field, reason, _) =
          dynamic.from("invalid url")
          |> github.decode_uri
          |> expect.to_be_error
          |> list.first
          |> expect.to_be_ok

        field |> expect.to_equal("url")
        reason |> expect.to_equal("Could not parse uri")
      }),
      it("Should decode Timestamp fields", fn() {
        dynamic.from("2024-08-11 15:00:00.9Z")
        |> github.decode_timestamp
        |> expect.to_be_ok
        |> birl.month
        |> expect.to_equal(birl.Aug)

        let dynamic.DecodeError(field, reason, _) =
          dynamic.from("Invalid date")
          |> github.decode_timestamp
          |> expect.to_be_error
          |> list.first
          |> expect.to_be_ok

        field |> expect.to_equal("published_at")
        reason |> expect.to_equal("Could not parse timestamp")
      }),
    ]),
  ])
}
