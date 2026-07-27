defmodule CodeMySpec.AnalysisTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.{Fingerprint, Reconciler, RunsRepository}
  alias CodeMySpec.Files
  alias CodeMySpec.Problems
  alias CodeMySpec.Problems.Problem

  setup do
    %{scope: full_scope_fixture()}
  end

  defp upsert_file!(scope, path, role, fingerprint, extra \\ %{}) do
    {1, _} =
      Files.upsert_files(scope, [
        Map.merge(
          %{
            path: path,
            role: role,
            mtime: DateTime.utc_now(),
            size: 100,
            fingerprint: fingerprint
          },
          extra
        )
      ])

    Files.get_by_path(scope, path)
  end

  describe "Fingerprint" do
    test "changes when a relevant file's content hash changes", %{scope: scope} do
      upsert_file!(scope, "lib/foo.ex", :implementation, "aaa")
      before = Fingerprint.current(scope, "exunit")

      upsert_file!(scope, "lib/foo.ex", :implementation, "bbb")
      assert Fingerprint.current(scope, "exunit") != before
    end

    test "ignores files outside the source's role set", %{scope: scope} do
      upsert_file!(scope, "lib/foo.ex", :implementation, "aaa")
      before = Fingerprint.current(scope, "exunit")

      # bdd_spec feeds spex, not exunit
      upsert_file!(scope, "test/spex/a_spex.ex", :bdd_spec, "zzz")

      assert Fingerprint.current(scope, "exunit") == before
      refute Fingerprint.current(scope, "spex") == Fingerprint.current(scope, "exunit")
    end
  end

  describe "run ledger" do
    test "a completed full run at the current fingerprint reads as fresh", %{scope: scope} do
      upsert_file!(scope, "lib/foo.ex", :implementation, "aaa")

      {:ok, run} =
        RunsRepository.start_run(scope, %{
          source: "exunit",
          kind: :full,
          input_fingerprint: Fingerprint.current(scope, "exunit")
        })

      {:ok, _} = RunsRepository.finish_run(run, :completed, %{exit_status: 0})

      assert CodeMySpec.Analysis.fresh?(scope, "exunit")

      # A content change makes it stale again
      upsert_file!(scope, "lib/foo.ex", :implementation, "bbb")
      refute CodeMySpec.Analysis.fresh?(scope, "exunit")
    end

    test "a failed run is never fresh", %{scope: scope} do
      {:ok, run} =
        RunsRepository.start_run(scope, %{
          source: "exunit",
          kind: :full,
          input_fingerprint: Fingerprint.current(scope, "exunit")
        })

      {:ok, _} = RunsRepository.finish_run(run, :failed, %{})

      refute CodeMySpec.Analysis.fresh?(scope, "exunit")
    end

    test "fail_stranded_runs closes rows left :running", %{scope: scope} do
      {:ok, _run} =
        RunsRepository.start_run(scope, %{source: "exunit", kind: :full})

      assert {:ok, 1} = RunsRepository.fail_stranded_runs()
      assert %{"exunit" => %{status: :failed}} = RunsRepository.latest_full_runs(scope)
    end
  end

  describe "Reconciler" do
    defp problem(path, opts \\ []) do
      %Problem{
        severity: Keyword.get(opts, :severity, :error),
        source: Keyword.get(opts, :source, "exunit"),
        source_type: :test,
        file_path: path,
        message: Keyword.get(opts, :message, "boom"),
        category: "test_failure"
      }
    end

    test "full run replaces the source's problems project-wide", %{scope: scope} do
      Problems.create_problems(scope, [
        %{problem("test/old_test.exs") | project_id: scope.active_project_id}
      ])

      {:ok, run} = RunsRepository.start_run(scope, %{source: "exunit", kind: :full})

      {:ok, finished} =
        Reconciler.reconcile(scope, run, %{
          problems: [problem("test/new_test.exs")],
          output: "1 failure",
          exit_status: 1,
          stats: %{"failures" => 1}
        })

      assert finished.status == :completed
      paths = scope |> Problems.list_project_problems(source: "exunit") |> Enum.map(& &1.file_path)
      assert paths == ["test/new_test.exs"]
    end

    test "a run replaces every problem for its source, not just the files it names",
         %{scope: scope} do
      # A problem from an earlier run, in a file this run does not report on.
      Problems.create_problems(scope, [
        %{problem("test/other_test.exs") | project_id: scope.active_project_id}
      ])

      {:ok, run} =
        RunsRepository.start_run(scope, %{
          source: "exunit",
          kind: :full,
          args: %{"args" => ["test/target_test.exs:12"]}
        })

      {:ok, _} =
        Reconciler.reconcile(scope, run, %{
          problems: [problem("test/target_test.exs")],
          output: "",
          exit_status: 1,
          stats: %{}
        })

      paths =
        scope
        |> Problems.list_project_problems(source: "exunit")
        |> Enum.map(& &1.file_path)
        |> Enum.sort()

      # Every run sweeps the whole project, so its results are the complete
      # picture for that source: the stale problem is gone even though this
      # run never mentioned that file. Scoped clearing is what left problems
      # behind after a fix landed somewhere else.
      assert paths == ["test/target_test.exs"]
    end

    test "stamps component_id on test problems via the file path join", %{scope: scope} do
      component = CodeMySpec.ComponentsFixtures.component_fixture(scope)
      upsert_file!(scope, "test/foo_test.exs", :test, "abc", %{component_id: component.id})

      {:ok, run} = RunsRepository.start_run(scope, %{source: "exunit", kind: :full})

      {:ok, _} =
        Reconciler.reconcile(scope, run, %{
          problems: [problem("test/foo_test.exs")],
          output: "",
          exit_status: 1,
          stats: %{}
        })

      [persisted] = Problems.list_project_problems(scope, source: "exunit")
      assert persisted.component_id == component.id
    end

    test "nil file_path problems are patched, not dropped", %{scope: scope} do
      {:ok, run} = RunsRepository.start_run(scope, %{source: "compiler", kind: :full})

      {:ok, _} =
        Reconciler.reconcile(scope, run, %{
          problems: [problem(nil, source: "compiler", message: "** (CompileError) boom")],
          output: "",
          exit_status: 1,
          stats: %{}
        })

      [persisted] = Problems.list_project_problems(scope, source: "compiler")
      assert persisted.file_path == "unknown"
    end
  end
end
