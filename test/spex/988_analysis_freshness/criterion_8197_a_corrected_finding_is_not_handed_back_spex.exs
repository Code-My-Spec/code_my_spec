defmodule CodeMySpecSpex.Story988.Criterion8197Spex do
  @moduledoc """
  Story 988 — Analysis Freshness
  Criterion 8197 — A corrected finding is not handed back.

  Covers Rule "Persisted problems block a stop only while they describe the
  current working copy."

  8201 asks whether a corrected finding still *blocks*. This asks what the
  agent is actually handed, because that distinction is the whole defect.
  Drill 6's agent was not merely stopped — it was stopped and given four credo
  findings at specific line numbers in code it had already fixed, and it read
  them as work. For "nesting too deep" there is no idempotent second fix, so
  satisfying the list means inventing a *different* refactor of correct code,
  and that edit produces the next stale snapshot for the next stop.

  ## Why this scenario has no second blocker

  The natural way to test a *message* is to keep something else blocking and
  read what arrives alongside it. That cannot be built here, and the reason is
  worth recording.

  Every source fingerprints `:implementation` (`Fingerprint.@source_roles`),
  so correcting one implementation file makes compiler, credo, exunit and spex
  stale in the same instant. A first attempt at this spex held a real compiler
  error as the standing blocker; it stopped blocking too. There is no source
  that survives an implementation edit, so after one there is no message at
  all — the stop simply passes.

  So 8197 holds, but by silence rather than by filtering: nothing is handed
  back because nothing is. The window that opens is filed as an issue; it is
  not asserted here, because `validation.ex` chose it deliberately ("stale
  means silent, not passing") and a spex is the wrong place to overturn a
  decision.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A finding the agent already fixed is absent from what it is handed" do
    scenario "the corrected credo finding is gone from the stop response" do
      given_ "credo recorded a finding and the agent is handed it", context do
        Fixtures.set_analyzer_mode(context.scope, :credo, :block_all)

        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/accounts.ex",
            "defmodule MyApp.Accounts do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        Fixtures.record_problem(context.scope, "credo", %{
          message: "nesting too deep",
          file_path: "lib/my_app/accounts.ex",
          line: 61
        })

        Fixtures.fresh_analysis_runs(context.scope, ["credo"])

        assert {:error, message} = Fixtures.validate_stop(context.scope)

        assert message =~ "nesting too deep",
               "the finding must reach the agent first, or the scenario proves nothing"

        {:ok, context}
      end

      when_ "the agent corrects the file and credo has not run again", context do
        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/accounts.ex",
            "defmodule MyApp.Accounts do\n  # flattened\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "the corrected finding is not named again", context do
        result = Fixtures.validate_stop(context.scope)

        refute match?({:error, msg} when is_binary(msg), result) and
                 elem(result, 1) =~ "nesting too deep",
               """
               This is drill 6 exactly: line 61 of a file the agent just
               corrected, handed back as work to do.

               There is no idempotent second fix for "nesting too deep", so the
               only way to satisfy the list is to refactor correct code
               differently — which produces the next stale snapshot for the next
               stop to hand back. Every turn makes the code worse and the loop
               has no exit.
               """

        {:ok, context}
      end
    end
  end
end
