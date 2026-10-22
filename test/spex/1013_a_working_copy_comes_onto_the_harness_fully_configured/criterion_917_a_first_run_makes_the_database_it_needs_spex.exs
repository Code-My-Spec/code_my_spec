defmodule CodeMySpecSpex.Story1013.Criterion917Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 917 — A first run makes the database it needs.

  Driven as product directed on this question: a real, separate OS process
  running the actual command against a scratch checkout, asserting only what
  can be seen from outside -- never a direct call into the module under test.

  `test/test_helper.exs` and the `spex` alias both run
  `mix cms.check_test_migrations` before anything else, which is what
  `provision/0` means by "before the suite starts" -- so running that command
  directly, against a partition nothing has used yet, is the real first-run
  path itself, not a stand-in for it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  spex "A first run makes the database it needs, before the suite starts", criterion: 917 do
    scenario "An exunit run against a never-used partition creates and migrates its database" do
      given_ "a scratch checkout and a partition nothing has used before", context do
        root = Fixtures.scratch_worktree!()
        partition = "cms_spex_#{System.unique_integer([:positive])}"
        database = "code_my_spec_test#{partition}"

        ExUnit.Callbacks.on_exit(fn ->
          Fixtures.run_cmd("psql", [
            "postgres://postgres:postgres@localhost/postgres",
            "-tAc",
            "drop database if exists #{database}"
          ])
        end)

        {:ok,
         context
         |> Map.put(:root, root)
         |> Map.put(:partition, partition)
         |> Map.put(:database, database)}
      end

      when_ "the analyzer's migration check runs there for the first time", context do
        env =
          Fixtures.scratch_worktree_env(MIX_ENV: "test", MIX_TEST_PARTITION: context.partition)

        {output, status} =
          Fixtures.run_cmd_bounded("mix", ["cms.check_test_migrations"], cd: context.root, env: env)

        {:ok, context |> Map.put(:output, output) |> Map.put(:status, status)}
      end

      then_ "the partition database is created and migrated before the suite starts", context do
        assert context.status == 0,
               "the first run against an unused partition did not complete: #{context.output}"

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
