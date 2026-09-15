defmodule CodeMySpec.Analysis.RunnersTest do
  # Sync: `use_cmd_cassette` meck-patches `System.cmd/3` process-globally. This
  # file at `async: true` was the cause of the suite's intermittent `** (EXIT)
  # killed` failures — reproducible in 3.6s by running it beside
  # `validation/blocking_on_recorded_findings_test`.
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
    # Three outcomes that must stay three, not two. A clean build, a build with
    # errors, and a build that failed while saying nothing — the last of which
    # used to be recorded as the first.
    # Keyed on availability, not exit status: `mix compile --return-errors` exits
    # 0 even on a compile error, so a zero exit says nothing at all. The first
    # version of this check keyed on exit status and was inert for exactly the
    # case it was written for.
    test "a build whose diagnostics were never written is not reported as clean" do
      assert {:error, {:compile_diagnostics_unavailable, 0}} =
               Runners.from_raw("compiler", %{
                 "exit_status" => 0,
                 "diagnostics" => [],
                 "diagnostics_available" => false
               }),
             "`:completed` with no problems is how this system says it looked and " <>
               "found nothing — a compiler that could not say why it failed must not " <>
               "borrow that sentence"
    end

    test "a clean build is still clean" do
      assert {:ok, %{problems: []}} =
               Runners.from_raw("compiler", %{
                 "exit_status" => 0,
                 "diagnostics" => [],
                 "diagnostics_available" => true
               })
    end

    # Absent means "an older harness that does not send this", which must keep
    # working rather than being read as unavailable and failing every run.
    test "a payload without the flag is treated as available" do
      assert {:ok, %{problems: []}} =
               Runners.from_raw("compiler", %{"exit_status" => 0, "diagnostics" => []})
    end

    # The restraint that motivated the old behaviour is intact: a failed build
    # that *did* report diagnostics still converts them rather than erroring, so
    # nothing is lost by the stricter path.
    test "a failed build with diagnostics still converts them" do
      raw = %{
        "exit_status" => 1,
        "diagnostics" => [
          %{
            "file" => "lib/a.ex",
            "line" => 1,
            "message" => "undefined function x/0",
            "severity" => "error"
          }
        ]
      }

      assert {:ok, %{problems: [_]}} = Runners.from_raw("compiler", raw)
    end

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

    # The same trap reached through a *zero* exit. The clause above keys on
    # `execution_status: "error"`; this run reports success, so nothing above
    # catches it, and `{:ok, problems: []}` from a suite that executed nothing
    # is byte-identical to a clean sweep of the whole project.
    #
    # Seen in the wild: a 1,502ms `exunit []` against a suite that takes ~165s.
    # It was rejected downstream as `unknown_run`, which is luck rather than a
    # guard — accepted, it would have cleared every recorded exunit Problem and
    # reported every component's tests as passing.
    test "a suite that ran zero tests fails the run rather than reporting them clean" do
      raw = %{
        "exit_status" => 0,
        "execution_status" => "success",
        "output" =>
          "Running ExUnit with seed: 1\n\n\nFinished in 0.00 seconds\n0 tests, 0 failures",
        "stats" => %{"tests" => 0, "failures" => 0},
        "diagnostics" => []
      }

      assert {:error, {:test_suite_did_not_run, 0, _excerpt}} = Runners.from_raw("exunit", raw)
    end

    test "a suite that ran tests and found nothing is still a clean sweep" do
      raw = %{
        "exit_status" => 0,
        "execution_status" => "success",
        "output" => "3793 tests, 0 failures",
        "stats" => %{"tests" => 3793, "failures" => 0},
        "diagnostics" => []
      }

      assert {:ok, %{problems: []}} = Runners.from_raw("exunit", raw)
    end

    # No stats at all is not evidence of a suite that did not run, so it falls
    # through rather than being failed on a guess.
    test "a payload carrying no stats is left alone" do
      raw = %{
        "exit_status" => 0,
        "execution_status" => "success",
        "output" => "",
        "diagnostics" => []
      }

      assert {:ok, %{problems: []}} = Runners.from_raw("exunit", raw)
    end

    # This used to fail the whole run, on the theory that a dependency
    # function undefined at runtime meant its beams moved mid-run — see
    # `CodeMySpec.Analysis.LostBuildTest`'s moduledoc for why that heuristic
    # is gone. Reported now like any other diagnostic.
    test "a dependency function reported as undefined is a real failure, not a lost build" do
      raw = %{
        "exit_status" => 1,
        "execution_status" => "failure",
        "output" => "2 tests, 2 failures",
        "stats" => %{"tests" => 2, "failures" => 2},
        "diagnostics" => [
          %{
            "file" => "test/code_my_spec/notifications/question_request_test.exs",
            "line" => 51,
            "message" =>
              "** (UndefinedFunctionError) function Jason.Decoder.parse/2 is undefined or private"
          }
        ]
      }

      assert {:ok, %{problems: [problem]}} = Runners.from_raw("exunit", raw)
      assert problem.file_path == "test/code_my_spec/notifications/question_request_test.exs"
    end

    test "one of our own undefined functions is still a real failure" do
      raw = %{
        "exit_status" => 1,
        "execution_status" => "failure",
        "output" => "1 test, 1 failure",
        "stats" => %{"tests" => 1, "failures" => 1},
        "diagnostics" => [
          %{
            "file" => "test/code_my_spec/demo_test.exs",
            "line" => 3,
            "message" =>
              "** (UndefinedFunctionError) function CodeMySpec.Demo.missing/1 is undefined or private"
          }
        ]
      }

      assert {:ok, %{problems: [problem]}} = Runners.from_raw("exunit", raw)
      assert problem.file_path == "test/code_my_spec/demo_test.exs"
    end

    test "a spex run that exited nonzero with no failures fails the run" do
      assert {:error, {:spex_suite_did_not_run, 2, ""}} =
               Runners.from_raw("spex", %{"exit_status" => 2, "diagnostics" => []})
    end

    # The excerpt is the whole point of the third element. Without it this
    # failure said `{:spex_suite_did_not_run, code}` and nothing else, so a
    # sweep that died left no account of why anywhere — `harness.log` records
    # only the command, and `Spex.execute` discarded the output. exunit has
    # carried its excerpt since it had the same defect.
    test "a spex suite that did not run carries what mix printed" do
      output = """
      Compiling 1 file (.exs)
      ** (CompileError) test/spex/broken_spex.exs:12: undefined function given_/2
          (elixir 1.19.4) expanding macro
      """

      assert {:error, {:spex_suite_did_not_run, 1, excerpt}} =
               Runners.from_raw("spex", %{
                 "exit_status" => 1,
                 "diagnostics" => [],
                 "output" => output
               })

      assert excerpt =~ "CompileError"
      assert excerpt =~ "broken_spex.exs:12"
    end

    # The first excerpt this helper ever produced in anger was
    # `Mix.Task.run_alias/6 | Mix.CLI.run_task/2 | bin/mix:7` — the last three
    # lines of a mix crash, which are the same boilerplate every time. An
    # excerpt that always says the same thing is not an excerpt.
    test "the exception line wins over the mix boilerplate below it" do
      output = """
      ** (RuntimeError) the thing that actually broke
          (code_my_spec 2.0.0) lib/whatever.ex:12: CodeMySpec.Whatever.go/1
          (mix 1.19.4) lib/mix/task.ex:573: Mix.Task.run_alias/6
          (mix 1.19.4) lib/mix/cli.ex:129: Mix.CLI.run_task/2
          /Users/x/.asdf/installs/elixir/1.19.4-otp-28/bin/mix:7: (file)
      """

      assert {:error, {:spex_suite_did_not_run, 1, excerpt}} =
               Runners.from_raw("spex", %{
                 "exit_status" => 1,
                 "diagnostics" => [],
                 "output" => output
               })

      assert excerpt =~ "the thing that actually broke"
      refute excerpt =~ "Mix.CLI.run_task"
    end

    # Not every failure raises. Without a marker the tail is still the best
    # available answer, so it must not be lost chasing the better one.
    test "falls back to the tail when nothing raised" do
      output = "Compiling 4 files (.ex)\nsome noise\nthe last useful line\n"

      assert {:error, {:spex_suite_did_not_run, 1, excerpt}} =
               Runners.from_raw("spex", %{
                 "exit_status" => 1,
                 "diagnostics" => [],
                 "output" => output
               })

      assert excerpt =~ "the last useful line"
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
