defmodule CodeMySpecSpex.Story1013.Criterion918Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 918 — A run that cannot name its own database acts on none.

  Driven as product directed on this question: a real, separate OS process
  running the actual command, asserting only what can be seen from outside
  (exit status, output, whether a named database exists) -- never `apply/3`
  and never a direct call into `Mix.Tasks.Cms.CheckTestMigrations`.

  `creatable/1`'s first check is `Mix.env() != :test` -- so "an environment
  that does not name MIX_ENV" is reached by actually running outside
  MIX_ENV=test. `:dev`'s own config (`config/dev.exs`) still names a real
  database by default, so the scenario also points `DATABASE_NAME` (the one
  override `:dev` reads) at a name nothing has ever created -- a missing
  database is what sends `cms.check_test_migrations` down `provision/0` into
  `creatable/1` at all; a healthy, reachable `:dev` database each worktree
  already has would short-circuit before ever asking whether it may create
  one.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  spex "A runner that cannot name its own database refuses rather than acting",
    criterion: 918 do
    scenario "A config naming no database is refused, and nothing is created" do
      given_ "a scratch checkout, and a database name nothing has created", context do
        root = Fixtures.scratch_worktree!()
        missing_db = "cms_spex_missing_#{System.unique_integer([:positive])}"

        {:ok,
         context
         |> Map.put(:root, root)
         |> Map.put(:missing_db, missing_db)}
      end

      when_ "the migration check runs there, outside MIX_ENV=test, naming that database",
            context do
        env =
          Fixtures.scratch_worktree_env(
            MIX_ENV: "dev",
            DATABASE_NAME: context.missing_db
          )

        {output, status} =
          Fixtures.run_cmd("mix", ["cms.check_test_migrations"], cd: context.root, env: env)

        {:ok, context |> Map.put(:output, output) |> Map.put(:status, status)}
      end

      then_ "it refuses and names what was missing", context do
        assert context.status == 0,
               "a refusal should print and proceed, not crash the run: #{context.output}"

        assert context.output =~ "refusing to create a database from MIX_ENV=dev",
               "the refusal did not name MIX_ENV as what was missing: #{context.output}"

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
