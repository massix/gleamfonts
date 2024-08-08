import gleam/bit_array
import gleam/dynamic
import gleam/list
import gleam/option
import gleam/result
import gleamfonts/db/migration
import glesha
import sqlight
import startest
import startest/expect

fn unsafe_apply_migration(
  connection db: sqlight.Connection,
  query q: String,
) -> Nil {
  // Retrieve how many migrations we have already ran
  let assert Ok(m) =
    sqlight.query(
      "select count(1) from migrations",
      db,
      [],
      dynamic.element(0, dynamic.int),
    )
  let assert Ok(count) = m |> list.first
  let checksum = q |> bit_array.from_string |> glesha.hash(glesha.Sha256)

  let assert Ok(_) =
    sqlight.query(
      "insert into migrations values(?, ?, ?)",
      db,
      [sqlight.int(count), sqlight.text(q), sqlight.blob(checksum)],
      dynamic.dynamic,
    )

  Nil
}

pub fn migration_tests() {
  startest.describe("db/migration", [
    startest.describe("fsm", [
      startest.it("can init the system", fn() {
        use conn <- sqlight.with_connection(":memory:")

        migration.new()
        |> migration.init(conn)
        |> expect.to_be_ok

        Nil
      }),
      startest.it("should fail if initing the system twice", fn() {
        use conn <- sqlight.with_connection(":memory:")

        migration.new()
        |> migration.init(conn)
        |> expect.to_be_ok
        |> migration.init(conn)
        |> expect.to_be_error
        |> expect.to_equal(migration.ErrorSystemAlreadyInited)
      }),
      startest.it("should be able to fetch existing migrations", fn() {
        use conn <- sqlight.with_connection(":memory:")

        // Force the creation of the migration table first
        let state = migration.new() |> migration.init(conn) |> expect.to_be_ok
        unsafe_apply_migration(conn, "create table animals(id int, name text)")

        migration.fetch_remote_migrations(state)
        |> expect.to_be_ok
        |> migration.count_remote_migrations
        |> expect.to_be_ok
        |> expect.to_equal(1)
      }),
      startest.it("should be able to load local migrations", fn() {
        use conn <- sqlight.with_connection(":memory:")

        migration.new()
        |> migration.init(conn)
        |> expect.to_be_ok
        |> migration.fetch_remote_migrations
        |> expect.to_be_ok
        |> migration.fetch_local_migrations("")
        |> expect.to_be_ok
        |> migration.count_local_migrations
        |> expect.to_be_ok
        |> expect.to_equal(1)

        Nil
      }),
      startest.it("should be able to verify the migrations", fn() {
        use conn <- sqlight.with_connection(":memory:")

        let state =
          migration.new()
          |> migration.init(conn)
          |> result.try(migration.fetch_remote_migrations)
          |> result.try(migration.fetch_local_migrations(_, ""))
          |> result.try(migration.verify_migrations)
          |> expect.to_be_ok

        migration.count_remaining_migrations(state)
        |> expect.to_be_ok
        |> expect.to_equal(1)
      }),
      startest.it("should fail if checksums are different", fn() {
        use conn <- sqlight.with_connection(":memory:")

        // Force the creation of the migration table first
        let state = migration.new() |> migration.init(conn) |> expect.to_be_ok

        unsafe_apply_migration(
          connection: conn,
          query: "create table animals(id int)",
        )

        // Now move forward with the state machine, we should have an error
        let assert migration.ErrorChecksumMismatch(id, cs1, cs2) =
          state
          |> migration.fetch_remote_migrations
          |> result.try(migration.fetch_local_migrations(_, ""))
          |> result.try(migration.verify_migrations)
          |> expect.to_be_error

        expect.to_equal(id, 0)
        expect.to_not_equal(cs1, cs2)
      }),
      startest.it("should fail if db contains more migrations than local", fn() {
        use conn <- sqlight.with_connection(":memory:")

        let state = migration.new() |> migration.init(conn) |> expect.to_be_ok
        unsafe_apply_migration(conn, "create table animals(id int)")
        unsafe_apply_migration(conn, "create table dogs(id int, name text)")
        unsafe_apply_migration(
          conn,
          "create table cats(id int, name text, cuteness_level int)",
        )

        state
        |> migration.fetch_remote_migrations
        |> result.try(migration.fetch_local_migrations(_, ""))
        |> result.try(migration.verify_migrations)
        |> expect.to_be_error
        |> expect.to_equal(migration.ErrorTooManyMigrations(1, 3))
      }),
      startest.it("should apply all the migrations", fn() {
        use conn <- sqlight.with_connection(":memory:")

        migration.new()
        |> migration.init(conn)
        |> result.try(migration.fetch_remote_migrations)
        |> result.try(migration.fetch_local_migrations(_, ""))
        |> result.try(migration.verify_migrations)
        |> result.try(migration.apply_remaining_migrations)
        |> expect.to_be_ok

        Nil
      }),
    ]),
    startest.describe("convenient method", [
      startest.it("all ok", fn() {
        use conn <- sqlight.with_connection(":memory:")

        migration.migrate(conn, "")
        |> expect.to_be_ok

        Nil
      }),
      startest.it("error in the middle", fn() {
        use conn <- sqlight.with_connection(":memory:")

        let assert Ok(_) =
          sqlight.exec("create table github_asset(id int)", conn)

        let assert migration.ErrorApplyingMigration(_, _, e) =
          migration.migrate(conn, "")
          |> expect.to_be_error

        let assert option.Some(sqlight.SqlightError(_, reason, _)) = e
        reason |> expect.to_equal("table github_asset already exists")
      }),
    ]),
  ])
}
