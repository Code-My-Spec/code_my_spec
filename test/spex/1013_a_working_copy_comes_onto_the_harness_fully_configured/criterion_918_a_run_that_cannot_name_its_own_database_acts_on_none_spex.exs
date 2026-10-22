defmodule CodeMySpecSpex.Story1013.Criterion918Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 918 — A run that cannot name its own database acts on none.

  Was driven as a real, separate OS process against a scratch git worktree.
  Main's call (2026-10-22, issue 99c05f98): a full `mix` compile in a fresh
  worktree is too heavy for a spex on this shared machine. Driven in-process
  instead, against `Mix.Tasks.Cms.CheckTestMigrations.creatable/1` -- the
  exact function `provision/0` asks before ever calling `create/1` -- public
  precisely so it can be exercised directly, per its own doc.

  `creatable/1`'s first check is `Mix.env() != :test`. A real subprocess
  reached that by booting under `MIX_ENV=dev`; in this already-booted VM,
  `Mix.env/1` is the same switch the subprocess's own boot made, flipped for
  the one call under test and restored immediately after -- nothing else
  here reads it mid-test. A healthy, reachable `:dev` database would
  short-circuit before ever asking whether it may create one, which is why
  the scenario names a database nothing has created rather than `:dev`'s
  own default.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  spex "A runner that cannot name its own database refuses rather than acting",
    criterion: 918 do
    scenario "A config naming no database is refused, and nothing is created" do
      given_ "a database name nothing has created", context do
        missing_db = "cms_spex_missing_#{System.unique_integer([:positive])}"

        {:ok, Map.put(context, :missing_db, missing_db)}
      end

      when_ "the migration check asks whether it may create that database, outside MIX_ENV=test",
            context do
        config = Fixtures.repo_config_naming(context.missing_db)

        Mix.env(:dev)
        result = Fixtures.check_test_migrations_creatable(config)
        Mix.env(:test)

        {:ok, Map.put(context, :result, result)}
      end

      then_ "it refuses and names what was missing", context do
        assert {:error, message} = context.result

        assert message =~ "refusing to create a database from MIX_ENV=dev",
               "the refusal did not name MIX_ENV as what was missing: #{message}"

        {:ok, context}
      end

      then_ "no database is created, dropped or migrated", context do
        {listing, 0} =
          Fixtures.run_cmd("psql", [
            "postgres://postgres:postgres@localhost/postgres",
            "-tAc",
            "select 1 from pg_database where datname = '#{context.missing_db}'"
          ])

        assert String.trim(listing) == "",
               "the database this run refused to name exists anyway: #{context.missing_db}"

        {:ok, context}
      end
    end
  end
end
