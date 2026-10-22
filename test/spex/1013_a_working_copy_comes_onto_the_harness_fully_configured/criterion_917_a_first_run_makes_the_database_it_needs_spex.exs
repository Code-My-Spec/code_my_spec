defmodule CodeMySpecSpex.Story1013.Criterion917Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 917 — A first run makes the database it needs.

  Was driven as a real, separate OS process against a scratch git worktree.
  Main's call (2026-10-22, issue 99c05f98): a full `mix` compile in a fresh
  worktree is too heavy for a spex on this shared machine, and slows every
  other team's run. Driven in-process instead: the same code
  (`Mix.Tasks.Cms.CheckTestMigrations.refuse_if_behind!/0`) runs in this VM,
  with `Fixtures.with_throwaway_database/2` redirecting `CodeMySpec.Repo` to
  a database nothing has used, rather than a real subprocess reaching for
  one via its own environment.

  `test/test_helper.exs` and the `spex` alias both run
  `mix cms.check_test_migrations` before anything else, which is what
  `provision/0` means by "before the suite starts" -- so calling
  `refuse_if_behind!/0` directly against a partition nothing has used is the
  real first-run path itself, not a stand-in for it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  spex "A first run makes the database it needs, before the suite starts", criterion: 917 do
    scenario "A migration check against a never-used database creates and migrates it" do
      given_ "a database name nothing has used before", context do
        database = "code_my_spec_test_spex_#{System.unique_integer([:positive])}"

        {:ok, Map.put(context, :database, database)}
      end

      when_ "the analyzer's migration check runs there for the first time", context do
        output =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            Fixtures.with_throwaway_database(context.database, fn ->
              :ok = Fixtures.check_test_migrations_refuse_if_behind!()
            end)
          end)

        {:ok, Map.put(context, :output, output)}
      end

      then_ "the partition database is created and migrated before the suite starts", context do
        {exists, 0} =
          Fixtures.run_cmd("psql", [
            "postgres://postgres:postgres@localhost/postgres",
            "-tAc",
            "select 1 from pg_database where datname = '#{context.database}'"
          ])

        assert String.trim(exists) == "1",
               "the database this partition names was not created: #{context.database}"

        {applied, 0} =
          Fixtures.run_cmd("psql", [
            "postgres://postgres:postgres@localhost/#{context.database}",
            "-tAc",
            "select count(*) from schema_migrations"
          ])

        refute String.trim(applied) in ["", "0"],
               "the database was created but not migrated -- schema_migrations is empty: " <>
                 inspect(applied)

        {:ok, context}
      end

      then_ "the run creates the database itself, not just reports it missing", context do
        # The pool's own connection retries against a not-yet-created database
        # legitimately log "does not exist" while they happen -- that text is
        # not itself a failure. The one line that proves this run acted,
        # rather than only noticed and reported, is check_test_migrations'
        # own "creating <database>" announcement (missing_database?/1 ->
        # provision/0); its absence would mean the run fell through to
        # report/1 and left the suite to fail downstream instead.
        assert context.output =~ "[check_test_migrations] creating #{context.database}",
               "the run did not announce creating its own database: #{context.output}"

        {:ok, context}
      end
    end
  end
end
