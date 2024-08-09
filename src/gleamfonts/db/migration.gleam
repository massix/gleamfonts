import gleam/bit_array
import gleam/dynamic.{bit_array, decode3, element, int, string}
import gleam/list
import gleam/option
import gleam/result
import glesha
import sqlight

/// Keeps track of the FSM for the Migration System.
pub opaque type MigrationState {
  ///First state, we still have to act and init
  Empty

  ///We successfully ran the creation of the table, nothing more
  Inited(db: sqlight.Connection)

  ///We fetched all the migrations from the Database
  RemoteMigrationsFetched(db: sqlight.Connection, remote: List(Migration))

  ///We fetched all the migrations locally
  LocalMigrationsFetched(
    db: sqlight.Connection,
    remote: List(Migration),
    local: List(Migration),
  )

  ///We verified all the migrations, the final list corresponds
  ///to the migrations that we have locally but are not yet
  ///applied to the database
  MigrationsVerified(
    db: sqlight.Connection,
    remote: List(Migration),
    local: List(Migration),
    remaining: List(Migration),
  )

  ///We did everything, no need to continue keeping a reference
  ///on everything!
  AppliedMigrations(List(Migration))
}

///Represents a migration as it is stored in the database
pub opaque type Migration {
  Migration(id: Int, text: String, checksum: BitArray)
}

///Helper function to decode a migration coming from an sqlight query
fn decode_migration() -> fn(dynamic.Dynamic) ->
  Result(Migration, List(dynamic.DecodeError)) {
  decode3(Migration, element(0, int), element(1, string), element(2, bit_array))
}

///Returns an empty migration system
pub fn new() -> MigrationState {
  Empty
}

///Possible errors which may happen during the migration
pub type MigrationError {
  ///Avoid for the system to be inited twice
  ErrorSystemAlreadyInited

  ///Return this error if trying to fetch the migrations while the system
  ///has not been inited
  ErrorSystemNotInited

  ///Return this error if trying to fetch the migrations while being at
  ///a later stage
  ErrorRemoteMigrationsAlreadyFetched

  ///Return this error if trying to invoke a function which needs the
  ///migrations in memory
  ErrorRemoteMigrationsNotFetched

  ///Return this error if trying to fetch the local migrations while
  ///being at a later stage
  ErrorLocalMigrationsAlreadyFetched

  ///Return this error if trying to invoke a function which needs the
  ///local migrations to have been fetched
  ErrorLocalMigrationsNotFetched

  ///Return this error if trying to verify the migrations multiple
  ///times
  ErrorMigrationsAlreadyVerified

  ///Return this error if trying to invoke a function which needs
  ///the migrations to have been verified
  ErrorMigrationsNotVerified

  ///We've already applied the migrstions, there's nothing left to do
  ErrorMigrationsAlreadyApplied

  ///Return this error if there is a difference in the checksum as it
  ///is stored in the database and the one we calculated locally
  ErrorChecksumMismatch(
    migration_id: Int,
    remote_checksum: BitArray,
    local_checksum: BitArray,
  )

  ///Return this error if the database contains more migrations than
  ///the one we have locally
  ErrorTooManyMigrations(local_migrations: Int, remote_migrations: Int)

  ///Failure while applying a migration, applied migrations
  ///will stay in place
  ErrorApplyingMigration(
    id: Int,
    text: String,
    wrapped_error: option.Option(sqlight.Error),
  )

  ///Return this error if the FSM finished doing its job
  ErrorSystemFinished

  ///If we have an error while trying to communicate with the database,
  ///we wrap it into this one
  WrappedSqlightError(wrapped: sqlight.Error)
}

///Initializes the migration systems, creating the table in the DB (if
///it does not exist already) and making sure that the connection is
///active. We return an error if we are unable to init the system.
pub fn init(
  state s: MigrationState,
  db db: sqlight.Connection,
) -> Result(MigrationState, MigrationError) {
  case s {
    Empty -> {
      // Create the migrations table
      sqlight.exec(
        "create table if not exists migrations(id int primary key not null, migration_text text not null, checksum blob not null)",
        db,
      )
      |> result.map(fn(_) { Inited(db) })
      |> result.map_error(WrappedSqlightError)
    }
    _ -> Error(ErrorSystemAlreadyInited)
  }
}

///Fetches all the migrations from the database and store them in memory
pub fn fetch_remote_migrations(
  state s: MigrationState,
) -> Result(MigrationState, MigrationError) {
  case s {
    Empty -> Error(ErrorSystemNotInited)
    Inited(db) -> {
      // Fetch all the migrations
      sqlight.query("select * from migrations", db, [], decode_migration())
      |> result.map(RemoteMigrationsFetched(db, _))
      |> result.map_error(WrappedSqlightError)
    }

    _ -> Error(ErrorRemoteMigrationsAlreadyFetched)
  }
}

///Fetches all local migrations, for now all the migrations are stored in
///the application's code, but in the future we may want to change this
pub fn fetch_local_migrations(
  state s: MigrationState,
  migration_folder _: String,
) -> Result(MigrationState, MigrationError) {
  case s {
    Empty | Inited(_) -> Error(ErrorRemoteMigrationsNotFetched)
    LocalMigrationsFetched(..) | MigrationsVerified(..) ->
      Error(ErrorLocalMigrationsAlreadyFetched)
    RemoteMigrationsFetched(db, remote) ->
      Ok({
        let t = {
          use lm <- list.map(local_migrations)
          let checksum =
            lm.1 |> bit_array.from_string |> glesha.hash(glesha.Sha256)

          Migration(lm.0, lm.1, checksum)
        }

        LocalMigrationsFetched(db, remote, t)
      })
    AppliedMigrations(..) -> Error(ErrorSystemFinished)
  }
}

// Helper functions for the checks
fn check_migration_count(
  remote r: List(Migration),
  local l: List(Migration),
) -> Result(Nil, MigrationError) {
  let remote_count = list.length(r)
  let local_count = list.length(l)
  case remote_count > local_count {
    False -> Ok(Nil)
    True -> Error(ErrorTooManyMigrations(local_count, remote_count))
  }
}

fn check_migration_checksums(
  remote r: List(Migration),
  local l: List(Migration),
) -> Result(Nil, MigrationError) {
  list.map2(r, l, fn(rm, lm) {
    case rm.checksum == lm.checksum {
      True -> Ok(Nil)
      False -> Error(ErrorChecksumMismatch(rm.id, rm.checksum, lm.checksum))
    }
  })
  |> result.all
  |> result.map(fn(_) { Nil })
}

pub fn verify_migrations(
  state s: MigrationState,
) -> Result(MigrationState, MigrationError) {
  case s {
    Empty | Inited(..) | RemoteMigrationsFetched(..) ->
      Error(ErrorLocalMigrationsNotFetched)
    MigrationsVerified(..) -> Error(ErrorMigrationsAlreadyVerified)
    LocalMigrationsFetched(db, remote, local) -> {
      result.all([
        check_migration_count(local:, remote:),
        check_migration_checksums(local:, remote:),
      ])
      |> result.map(fn(_) {
        let remote_count = list.length(remote)

        MigrationsVerified(
          db,
          remote:,
          local:,
          remaining: list.drop(local, remote_count),
        )
      })
    }
    AppliedMigrations(..) -> Error(ErrorSystemFinished)
  }
}

pub fn apply_remaining_migrations(
  state s: MigrationState,
) -> Result(MigrationState, MigrationError) {
  case s {
    Empty
    | Inited(..)
    | RemoteMigrationsFetched(..)
    | LocalMigrationsFetched(..) -> Error(ErrorMigrationsNotVerified)
    AppliedMigrations(..) -> Error(ErrorMigrationsAlreadyApplied)
    MigrationsVerified(db, _, _, rest) -> {
      list.map(rest, fn(m) {
        sqlight.exec(m.text, db)
        |> result.try(fn(_) {
          sqlight.query(
            "insert into migrations values (?, ?, ?)",
            db,
            [sqlight.int(m.id), sqlight.text(m.text), sqlight.blob(m.checksum)],
            dynamic.dynamic,
          )
        })
        |> result.map_error(fn(e) {
          ErrorApplyingMigration(m.id, m.text, option.Some(e))
        })
      })
      |> result.all
      |> result.map(fn(_) { AppliedMigrations(rest) })
    }
  }
}

///Convenient method to launch all the steps of the FSM
pub fn migrate(
  db db: sqlight.Connection,
  path path: String,
) -> Result(MigrationState, MigrationError) {
  new()
  |> init(db)
  |> result.try(fetch_remote_migrations)
  |> result.try(fetch_local_migrations(_, path))
  |> result.try(verify_migrations)
  |> result.try(apply_remaining_migrations)
}

///Counts the migrations which are present in the DB. This function *consumes*
///the MigrationState, so it cannot be piped.
pub fn count_remote_migrations(
  state s: MigrationState,
) -> Result(Int, MigrationError) {
  case s {
    Empty | Inited(_) -> Error(ErrorRemoteMigrationsNotFetched)
    RemoteMigrationsFetched(_, l)
    | LocalMigrationsFetched(_, l, _)
    | MigrationsVerified(_, l, ..) -> Ok(list.length(l))
    AppliedMigrations(..) -> Error(ErrorSystemFinished)
  }
}

///Counts the migrations which are present locally. This function *consumes*
///the MigrationState, so it cannot be piped.
pub fn count_local_migrations(
  state s: MigrationState,
) -> Result(Int, MigrationError) {
  case s {
    Empty | Inited(..) | RemoteMigrationsFetched(..) ->
      Error(ErrorLocalMigrationsNotFetched)
    LocalMigrationsFetched(_, _, l) | MigrationsVerified(_, _, l, ..) ->
      Ok(list.length(l))
    AppliedMigrations(..) -> Error(ErrorSystemFinished)
  }
}

///Counts the migrations which we will need to apply in order to pass from
///the desired state to the wished state
pub fn count_remaining_migrations(
  state s: MigrationState,
) -> Result(Int, MigrationError) {
  case s {
    Empty
    | Inited(..)
    | RemoteMigrationsFetched(..)
    | LocalMigrationsFetched(..) -> Error(ErrorMigrationsNotVerified)
    MigrationsVerified(_, _, _, r) -> Ok(list.length(r))
    AppliedMigrations(..) -> Error(ErrorSystemFinished)
  }
}

///This is the list of all the migrations we want to run in the database
///the migrations stored here are tuples of id and text, which will be
///later converted into a Migration type
const local_migrations = [
  #(
    0,
    "
    -- Enable foreign keys check
    pragma foreign_keys=on;

    create table github_repository(
      id int primary key not null,
      releases_url text not null,
      html_url text not null,
      description text not null
    ) strict;

    -- We don't care much about foreign key with github_repository
    -- since we only work with a single repository anyways..
    create table github_release(
      id int primary key not null,
      url text not null,
      tag_name text not null,
      name text not null,
      published_at int
    ) strict;

    create table github_asset(
      id int primary key not null,
      url text,
      browser_download_url text not null,
      name text not null,
      label text,
      created_at int,
      release_id int not null,
      foreign key(release_id) references github_release(id)
    ) strict;
    ",
  ),
]
