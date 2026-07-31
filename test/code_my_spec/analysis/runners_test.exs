defmodule CodeMySpec.Analysis.RunnersTest do
  use CodeMySpecTest.DataCase, async: false
  use ExCliVcr

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.Runners

  setup do
    %{scope: full_scope_fixture() |> Map.put(:cwd, File.cwd!())}
  end

  describe "a tool that never ran" do
    # Regression guard. An analyzer that exits nonzero without reporting a
    # single failure has produced no verdict about the code — but an empty
    # failure list is indistinguishable from a clean sweep by shape alone, and
    # the nonzero exit is the only thing separating them.
    #
    # Reporting `{:ok, problems: []}` was actively harmful: the Reconciler
    # clears a source's Problems wholesale before inserting, so the empty
    # result wiped every real exunit Problem and then finished the run
    # `:completed` at the current fingerprint. `tests_passing` asks for exactly
    # those two things — a fresh completed run and zero problems — so a suite
    # that never executed reported the component's tests as passing.
    test "exunit fails the run instead of reporting a clean sweep", %{scope: scope} do
      use_cmd_cassette "exunit_suite_did_not_run", record: :none do
        assert {:error, {:test_suite_did_not_run, 1, excerpt}} =
                 Runners.run("exunit", scope, [], [])

        # The excerpt carries mix's own explanation through to the run's
        # stats["error"], so a failed run says why rather than just "failed".
        assert excerpt =~ "Could not find a Mix.Project"
      end
    end
  end

  # The conversion half, reached without running anything — which is how a light
  # harness's results arrive. Execution happens on the machine with the disk;
  # the `%Problem{}` schema is here, so this is where diagnostics become
  # Problems. `run/4` goes through the same function, so the two paths cannot
  # disagree about what a diagnostic means.
  describe "from_raw/2" do
    test "a compiler error becomes a blocking Problem" do
      raw = %{
        "exit_status" => 1,
        "diagnostics" => [
          %{
            "file" => "lib/demo/broken.ex",
            "line" => 4,
            "severity" => "error",
            "message" => "** (SyntaxError) unexpected token"
          }
        ]
      }

      assert {:ok, result} = Runners.from_raw("compiler", raw)
      assert [problem] = result.problems
      assert problem.severity == :error
      assert problem.source == "compiler"
      assert problem.file_path == "lib/demo/broken.ex"
      assert result.stats == %{"errors" => 1, "warnings" => 0}
    end

    test "an exunit failure becomes the same Problem a local run would build" do
      raw = %{
        "exit_status" => 1,
        "execution_status" => "failure",
        "output" => "1 test, 1 failure",
        "stats" => %{"failures" => 1},
        "diagnostics" => [
          %{"file" => "test/demo_test.exs", "line" => 9, "message" => "Assertion failed"}
        ]
      }

      assert {:ok, result} = Runners.from_raw("exunit", raw)
      assert [problem] = result.problems
      assert problem.source == "exunit"
      assert problem.source_type == :test
      assert problem.file_path == "test/demo_test.exs"
      assert problem.message == "Assertion failed"

      assert result.output == "1 test, 1 failure",
             "exunit is the one source whose output is the tool's own, not a rendering " <>
               "of the problems — the model reads it back through the analysis API"
    end

    # The distinction the whole design turns on. An empty failure list from a
    # suite that never started would clear every real exunit Problem and finish
    # the run `:completed` at the current fingerprint, which is exactly how
    # `tests_passing` once went green on a project whose tests all failed.
    test "a suite that never started fails the run rather than clearing Problems" do
      raw = %{
        "exit_status" => 1,
        "execution_status" => "error",
        "output" => "** (Mix) Paths given to \"mix test\" did not match any directory",
        "stats" => %{},
        "diagnostics" => []
      }

      assert {:error, {:test_suite_did_not_run, 1, excerpt}} = Runners.from_raw("exunit", raw)
      assert excerpt =~ "did not match"
    end

    test "a spex run that exited nonzero with no failures fails the run" do
      assert {:error, {:spex_suite_did_not_run, 2}} =
               Runners.from_raw("spex", %{"exit_status" => 2, "diagnostics" => []})
    end

    test "a spex failure names the scenario it came from" do
      raw = %{
        "exit_status" => 1,
        "diagnostics" => [
          %{
            "spex" => "Login",
            "scenario" => "a wrong password",
            "file" => "test/spex/login_spex.exs",
            "line" => 12,
            "message" => "expected 401"
          }
        ]
      }

      assert {:ok, result} = Runners.from_raw("spex", raw)
      assert [problem] = result.problems
      assert problem.source == "spex"
      assert problem.message =~ "Login — a wrong password"
      assert problem.message =~ "expected 401"
    end

    # Both of these would otherwise produce a `:completed` run with no problems,
    # which is how this server says "I looked, and it is clean". Neither has
    # looked at anything.
    test "a payload with no diagnostics list refuses to be read as a clean run" do
      assert_raise ArgumentError, ~r/refusing to read it as a clean run/, fn ->
        Runners.from_raw("compiler", %{"exit_status" => 0})
      end
    end

    test "a source this server does not know is an error, not an empty result" do
      assert {:error, {:unreadable_result, "dialyzer"}} =
               Runners.from_raw("dialyzer", %{"exit_status" => 0, "diagnostics" => []})
    end

    test "an exunit payload with no execution_status is refused" do
      assert {:error, {:unreadable_result, "exunit"}} =
               Runners.from_raw("exunit", %{"exit_status" => 0, "diagnostics" => []})
    end
  end
end
