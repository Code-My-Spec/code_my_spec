defmodule CodeMySpecSpex.Story1002.Criterion3442Spex do
  @moduledoc """
  Story 1002 — Model and system share one analysis run record.
  Criterion 3442 — A CLI-triggered failure blocks the stop hook the same
  way a server-triggered failure would.

  ## The claim, and the only way it can be false

  Criterion 3441 proved the clean half: a CLI-triggered exunit run
  satisfies the server's own staleness check. This is the other half, and
  the one that actually matters for an agent that broke something —  a
  failure has to reach the same Problems ledger the stop hook reads, or
  `mix test` typed by the agent could satisfy staleness while leaving the
  stop hook none the wiser: red locally, waved through on the server.

  It can only be false in one of two places:

    * the ledger — if the CLI's run does not become a `Problem` row, there
      is nothing for the stop hook to find.
    * the gate — if the stop hook reads a different set of Problems than
      the one this run wrote to, or demotes this one because nobody
      attributed it to a session, a real failure stops blocking the
      moment it was found by `mix test` instead of the server's own sweep.

  ## Why this does not run a real suite

  Same reasoning as 3441: the fixture is a bare git checkout rather than a
  mix project, so an actual `mix test` invocation would fail for reasons
  that have nothing to do with this criterion, and would hold one of this
  machine's two analyzer slots for no reason while doing it.

  So the run is recorded through the same path the endpoint uses —
  `Analysis.record_remote_result/2`, the function a harness's reported
  result and a local run both funnel through — with a raw payload
  reporting one failing test, and the assertions are on what the server
  does with that record: persists it as a `Problem`, and blocks the very
  next stop hook call on it, with no session attribution at all — the
  same anonymity a server-triggered run would carry.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.{Fingerprint, RunsRepository}
  alias CodeMySpec.Environments
  alias CodeMySpec.Hooks.{PreToolUse, Stop}
  alias CodeMySpec.Problems
  alias Ecto.Adapters.SQL.Sandbox

  @failing_test_path "test/example_context_test.exs"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent's failing mix test blocks the stop hook through the shared ledger" do
    scenario "a checkout with no recorded exunit problems" do
      given_ "a working copy with no recorded exunit problems", context do
        context = a_promotable_project(context)

        assert [] == Problems.list_project_problems(context.scope, sources: ["exunit"]),
               "the premise failed: this project already carries exunit problems"

        {:ok, context}
      end

      when_ "the agent runs mix test directly via the CLI and a test fails", context do
        # A diagnostic naming a file the Files table has never heard of does not
        # survive the sync every real stop performs: `FileSync` clears any
        # Problem whose file is missing from disk, which would silently erase
        # this one before either assertion below ever ran.
        :ok =
          Environments.write_file(
            context.environment,
            @failing_test_path,
            "defmodule ExampleContextTest do\n  use ExUnit.Case\n  test \"fails\", do: assert(false)\nend\n"
          )

        decision =
          PreToolUse.decide(
            context.scope,
            %{"tool_name" => "Bash", "tool_input" => %{"command" => "mix test"}},
            4004,
            :harness
          )

        command = get_in(decision, ["hookSpecificOutput", "updatedInput", "command"]) || ""

        assert command =~ "/analysis/run",
               """
               `mix test` was left to run as typed. Then a failure it produces never
               reaches the shared ledger at all — the agent's own run and the
               server's are two records, and only one of them would ever see this
               failure. Got: #{inspect(command)}
               """

        {:ok, run} =
          RunsRepository.start_run(context.scope, %{
            source: "exunit",
            kind: :full,
            input_fingerprint: Fingerprint.current(context.scope, "exunit")
          })

        {:ok, _finished} =
          Analysis.record_remote_result(context.scope, %{
            "run_id" => run.id,
            "status" => "ok",
            "result" => %{
              "exit_status" => 1,
              "execution_status" => "failure",
              "output" => "1 test, 1 failure",
              "stats" => %{"tests" => 1, "failures" => 1},
              "diagnostics" => [
                %{
                  "file" => @failing_test_path,
                  "line" => 5,
                  "message" => "assertion failed"
                }
              ]
            }
          })

        # Every other source stays stale otherwise, and the stop hook's own
        # pipeline re-enqueues them the moment it is asked — reporting
        # "analysis running" instead of ever reading the exunit Problem this
        # scenario just wrote. Only exunit's realism is the point here; the
        # other three are backfilled clean so the stop decision actually runs.
        CodeMySpecSpex.Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "spex"])

        {:ok, context}
      end

      then_ "the failure is persisted as a problem through the shared ledger", context do
        problems = Problems.list_project_problems(context.scope, sources: ["exunit"])

        assert Enum.any?(problems, &(&1.file_path == @failing_test_path)),
               """
               The CLI-triggered failure never reached the Problems ledger. Routing
               `mix test` through the analysis service buys nothing if the record it
               writes never becomes a Problem — the stop hook has nothing to read.
               Got: #{inspect(problems)}
               """

        {:ok, context}
      end

      and_ "the next stop hook blocks on it exactly as if the server had triggered the run itself",
           context do
        response = Stop.decide(context.scope, %{})

        assert response["decision"] == "block",
               """
               A CLI-triggered failure did not block the stop hook. The agent's own
               `mix test` and the server's checks are supposed to meet in one
               ledger — if the stop hook lets this through, that ledger is
               decoration. Got: #{inspect(response)}
               """

        assert response["reason"] =~ @failing_test_path,
               "expected the failing test file in the block reason, got:\n#{response["reason"]}"

        {:ok, context}
      end
    end
  end
end
