defmodule CodeMySpec.GuardCliMigrateTest do
  @moduledoc """
  The guard that stops `mix ecto.migrate` pointing the Postgres migration set at
  a SQLite CLI database.

  `02ff6d6b`: the task runs `priv/repo/migrations` whatever `MIX_ENV` says, so
  under `dev_cli` it reaches `CREATE EXTENSION IF NOT EXISTS citext` and SQLite
  answers `near "EXTENSION": syntax error`. That names a statement, a migration
  file, and a stack through `Ecto.Migration.Runner` — every signal says broken
  DDL, and none says the wrong set was pointed at the wrong database. It is also
  the second time that shape has cost a diagnosis (`61351c19`).

  What is worth asserting is not that it passes on Postgres — that is the state
  every other test already runs in, so a guard that never fires would pass it.
  It is that it fires on SQLite, and that the message carries the thing the
  operator actually needed to know.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Cms.GuardCliMigrate

  describe "refuse_on_sqlite!/1" do
    test "passes on Postgres" do
      assert :ok = GuardCliMigrate.refuse_on_sqlite!(Ecto.Adapters.Postgres)
    end

    # `dev_sprite` sets the adapter back to Postgres under a CLI-shaped env name
    # and its own config calls that line "the entire architectural difference".
    # Keying on MIX_ENV would refuse it wrongly, so the adapter is the key.
    test "passes on any non-SQLite adapter, whatever the environment is called" do
      assert :ok = GuardCliMigrate.refuse_on_sqlite!(Ecto.Adapters.MyXQL)
    end

    test "refuses on SQLite, naming the set that would run and the one that should" do
      %{message: message} =
        assert_raise(RuntimeError, fn ->
          GuardCliMigrate.refuse_on_sqlite!(Ecto.Adapters.SQLite3)
        end)

      assert message =~ "priv/repo/migrations"
      assert message =~ "cli_migrations"

      assert message =~ "Migrator",
             "the operator's real question is how to migrate this database, and " <>
               "the answer is that booting does it — without that the refusal " <>
               "leaves them with no next step"

      assert message =~ ~s(near "EXTENSION"),
             "quoting the error it prevents is what connects this refusal to the " <>
               "one the reader would otherwise have gone looking for"
    end
  end

  describe "configured_adapter/0" do
    test "reads the adapter this environment is configured with" do
      assert GuardCliMigrate.configured_adapter() == CodeMySpec.Repo.__adapter__(),
             "the guard reads the adapter from application config rather than " <>
               "from the repo, so that it can answer before app.start — if the " <>
               "two disagree it is reading the wrong thing"
    end
  end
end
