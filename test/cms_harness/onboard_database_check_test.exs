defmodule CmsHarness.OnboardDatabaseCheckTest do
  @moduledoc """
  Onboarding names three databases. Until now it never asked whether any of them
  existed, so "onboarded" and "usable" could come apart with nothing able to tell
  them apart from outside: `--check` answered `onboarded: true` for a copy whose
  three databases had never been created, and the absence surfaced later as
  `undefined_column`, or as a suite that would not start, wearing a different
  failure's costume.

  The rule that onboarding never *creates* a database is untouched and is not
  what these assert. Asking is a different verb, and `TestDatabase.existence/2`
  has one `SELECT` and no DDL to reach for.

  The third state matters as much as the other two. A Postgres nobody can reach
  is the absence of an answer about the databases, not an answer of "none" — and
  reporting it as absence would send an agent to create three databases that are
  already there.
  """
  # Sync: the missing-database cases derive a partition from a temp path and then
  # assert nothing on this machine has that database. That is only true while no
  # other test is creating databases, which nothing does — but the assertion is
  # about the state of the whole server, so it does not belong beside async work.
  use ExUnit.Case, async: false

  alias CmsHarness.TestDatabase
  alias CodeMySpec.Environments

  setup do
    root = CodeMySpec.TempFile.dir("onboard-db-check")
    File.mkdir_p!(Path.join(root, ".claude"))
    on_exit(fn -> File.rm_rf(root) end)

    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    {:ok, _env} = Environments.create(:local, working_dir: root)
    {:ok, root: root}
  end

  # Everything `--check` needs to call this copy configured. The point of these
  # tests is the case where that is true and the copy still cannot run anything.
  defp write_complete_settings!(root) do
    File.write!(
      Path.join([root, ".claude", "settings.local.json"]),
      Jason.encode!(%{
        "env" => %{
          "CMS_HARNESS_ID" => "11111111-2222-3333-4444-555555555555",
          "MIX_TEST_PARTITION" => "honboarddbcheck"
        }
      })
    )
  end

  defp check(root) do
    Mix.Task.reenable("cms.harness.onboard")
    Mix.Task.run("cms.harness.onboard", ["--check", root])
  end

  defp printed do
    Enum.map_join(collect_messages(), "\n", fn {:mix_shell, :info, [line]} -> line end)
  end

  defp collect_messages do
    receive do
      {:mix_shell, :info, _} = message -> [message | collect_messages()]
    after
      0 -> []
    end
  end

  describe "a copy whose settings are complete and whose databases are not" do
    test "is not reported onboarded", %{root: root} do
      write_complete_settings!(root)

      assert %{onboarded: false} = check(root),
             "a working copy with a perfect env block and no databases was " <>
               "reported onboarded. That is the state this check exists to " <>
               "find: nothing it needs is missing from the file, and nothing " <>
               "it needs can run."
    end

    test "names the databases and the commands that make them", %{root: root} do
      write_complete_settings!(root)

      assert %{missing_databases: [_, _, _] = missing} = check(root)

      output = printed()

      for database <- missing do
        assert output =~ database.name
        assert output =~ database.create
        assert output =~ database.migrate
      end
    end

    test "does not tell the reader to re-run onboarding, which would not help",
         %{root: root} do
      write_complete_settings!(root)
      check(root)

      refute printed() =~ "run: mix cms.harness.onboard",
             "the settings are complete, so onboarding has already done its half. " <>
               "Naming it as the remedy sends the reader to re-run a command that " <>
               "succeeded and cannot create a database."
    end

    test "names the directory the commands have to be run from", %{root: root} do
      write_complete_settings!(root)
      check(root)

      assert printed() =~ root,
             "the printed commands carry a partition and no path, so an agent " <>
               "copying them runs them wherever its shell happens to be — and a " <>
               "worktree-isolated one is somewhere else by construction."
    end

    test "creates nothing", %{root: root} do
      write_complete_settings!(root)
      %{missing_databases: missing} = check(root)

      # Asserted before the loop below, which is vacuously true over an empty
      # list — the shape this whole file is about.
      assert length(missing) == 3

      {:ok, present} = TestDatabase.existence(Enum.map(missing, & &1.name))

      assert Enum.all?(present, fn {_name, exists?} -> exists? == false end),
             "asking whether a database exists created one. Onboarding names " <>
               "databases and does not manage them — see `TestDatabase`."
    end
  end

  describe "existence/2" do
    test "tells a database that exists from one that does not" do
      %{database: mine} = Application.get_env(:code_my_spec, CodeMySpec.Repo) |> Map.new()

      {:ok, present} = TestDatabase.existence([mine, "code_my_spec_test_absent_by_construction"])

      assert present[mine] == true
      assert present["code_my_spec_test_absent_by_construction"] == false
    end

    test "an unreachable server is an error, never an answer of absent" do
      assert {:error, reason} = TestDatabase.existence(["anything"], port: 59_999)

      assert reason =~ "nothing answered",
             "a server nobody can reach has to say so. Reported as absence it " <>
               "reads as three databases to create, which may already exist."
    end
  end
end
