defmodule Mix.Tasks.Cms.GuardCliMigrate do
  @shortdoc "Refuse to run the Postgres migration set against a SQLite CLI database"

  @moduledoc """
  Answer `mix ecto.migrate` under a CLI environment with what actually migrates it.

      MIX_ENV=dev_cli mix ecto.migrate

  `mix ecto.migrate` runs `priv/repo/migrations` whatever `MIX_ENV` says, because
  that is Ecto's default and nothing points it elsewhere for the CLI
  environments. That directory is the **Postgres** set, and its first statement
  is `CREATE EXTENSION IF NOT EXISTS citext`, so SQLite answers:

      ** (Exqlite.Error) near "EXTENSION": syntax error

  Which reads as a broken migration. It names a statement, a file, and a stack
  descending through `Ecto.Migration.Runner` — every signal says someone wrote
  bad DDL, and none of them says the wrong migration set was pointed at the wrong
  database (02ff6d6b). It is also the second time that shape has cost a
  diagnosis: `61351c19` was a CLI migration carrying Postgres-only SQL, and
  anyone who remembers it will read this as its recurrence.

  ## What migrates the CLI database

  Nothing you run. `CodeMySpecLocalWeb.Migrator` sits in the supervision tree
  between `Repo` and the children that query at init, and runs
  `priv/repo/cli_migrations` on boot. So the answer to "how do I migrate the CLI
  dev database" is "boot it", which is genuinely non-obvious — which is why the
  wrong command gets reached for.

  ## Why refuse rather than redirect

  Running `cli_migrations` from here would do the Migrator's job in a second
  place, and the two would have to be kept saying the same thing. Refusing costs
  one comparison and answers the question the operator actually had.

  ## Keyed on the adapter, not on `MIX_ENV`

  Three environments use SQLite (`dev_cli`, `prod_cli`, `cli_demo`) and a fourth
  with a CLI-shaped name does not: `dev_sprite` sets
  `adapter: Ecto.Adapters.Postgres` back, and its own config calls that line "the
  entire architectural difference". An environment allowlist would refuse it
  wrongly and would miss the next SQLite environment added. The adapter is the
  thing the migration set has to match.

  ## Damage this prevents

  None observed — the failure hits the first statement of the first migration and
  rolls back, verified against a backup at 119 `schema_migrations` rows before and
  after. That is luck rather than design: a Postgres migration that happened to be
  SQLite-compatible would have applied and written a `schema_migrations` row for a
  migration the CLI set does not contain, and the two sets would diverge silently.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  @impl Mix.Task
  def run(_args) do
    refuse_on_sqlite!()
  end

  @doc """
  Raise when `adapter` is SQLite, otherwise pass.

  Takes the adapter rather than reading it, so the test can drive both branches
  without `put_env` on a key every environment reads. Swapping a global in an
  `async: true` file is the shape three real races in this codebase had
  (`07c2c511`, `30e22f47`, `17c4b260`), and a guard is not worth introducing a
  fourth.

  The default reads `Application.get_env/3` with the same fallback
  `CodeMySpec.Repo` compiles in, rather than calling `Repo.__adapter__/0`: this
  runs before `app.start`, deliberately, so a refusal costs no boot — and in a
  CLI environment booting is the very thing that runs the migrations this task
  is refusing to run by hand.
  """
  @spec refuse_on_sqlite!(module()) :: :ok
  def refuse_on_sqlite!(adapter \\ configured_adapter())

  def refuse_on_sqlite!(Ecto.Adapters.SQLite3), do: raise(wrong_set_message())
  def refuse_on_sqlite!(_adapter), do: :ok

  @doc "The repo adapter this environment is configured with."
  @spec configured_adapter() :: module()
  def configured_adapter do
    Application.get_env(:code_my_spec, :adapter, Ecto.Adapters.Postgres)
  end

  defp wrong_set_message do
    """
    `mix ecto.migrate` here would run the Postgres migration set against a SQLite
    database.

    `priv/repo/migrations` is the Postgres set. This environment's repo uses
    #{inspect(Ecto.Adapters.SQLite3)}, whose migrations are `priv/repo/cli_migrations`.

    Nothing here needs running by hand: CodeMySpecLocalWeb.Migrator runs
    `cli_migrations` on boot, before the children that query at init. Start the
    app and it migrates itself.

    Refusing rather than proceeding: the first statement is
    `CREATE EXTENSION IF NOT EXISTS citext`, and SQLite answers
    `near "EXTENSION": syntax error` — which names a statement and a migration
    file, and so reads as broken DDL rather than as the wrong set of migrations.
    """
  end
end
