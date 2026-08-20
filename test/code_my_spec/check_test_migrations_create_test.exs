defmodule CodeMySpec.CheckTestMigrationsCreateTest do
  @moduledoc """
  A partition database that does not exist is made by the run that wants it.

  The act of creating is not what went wrong on 2026-08-13. What went wrong was
  a background process shelling out to `mix` with an environment that had
  `MIX_ENV` scrubbed, so "create the test database" acted on **dev** and a
  sibling truncate emptied it three times. Nothing is shelled out now:
  `storage_up/1` and `Ecto.Migrator` act on the config this VM is already
  running under, which in `MIX_ENV=test` is this partition's database by
  construction.

  Two things are worth asserting and they are the two decisions in the code —
  whether a reason means "not there" (`missing_database?/1`), and whether this VM
  is allowed to act on the database it names (`creatable/1`). The creating
  itself is exercised live: a fresh partition, `mix test`, and a database with
  every migration applied where there was none.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cms.CheckTestMigrations

  describe "missing_database?/1" do
    test "a Postgres invalid_catalog_name is the database not being there" do
      assert CheckTestMigrations.missing_database?(%Postgrex.Error{
               postgres: %{code: :invalid_catalog_name}
             })
    end

    test "the same thing wrapped in a connection error, which is how a cold pool reports it" do
      assert CheckTestMigrations.missing_database?(%DBConnection.ConnectionError{
               message: ~s|FATAL 3D000 (invalid_catalog_name) database "x" does not exist|
             })
    end

    # The distinction the whole branch turns on. An ownership error under a
    # manual sandbox also stops the query, and answering it by creating a
    # database would be the silent-swallow shape this module has fought twice.
    test "an ownership error is not a missing database" do
      refute CheckTestMigrations.missing_database?(%DBConnection.OwnershipError{
               message: "cannot find ownership process"
             })
    end

    test "an arbitrary term is not a missing database" do
      refute CheckTestMigrations.missing_database?({:error, :closed})
      refute CheckTestMigrations.missing_database?(nil)
    end
  end

  describe "creatable/1" do
    test "a test environment naming its database may create it" do
      assert :ok = CheckTestMigrations.creatable(database: "code_my_spec_testhabc12345")
    end

    # A run that cannot name its own database acts on none — the guard the
    # 2026-08-13 incident needed and did not have.
    test "a repo that cannot name its database creates nothing" do
      assert {:error, message} = CheckTestMigrations.creatable([])
      assert message =~ "cannot name"

      assert {:error, _} = CheckTestMigrations.creatable(database: "")
    end
  end
end
