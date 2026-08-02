defmodule CodeMySpecSpex.Story988.Criterion8201Spex do
  @moduledoc """
  Story 988 — Analysis Freshness
  Criterion 8201 — A finding fixed since the analyzer ran no longer blocks.

  Covers Rule "Persisted problems block a stop only while they describe the
  current working copy."

  Drill 6. The agent fixed four credo findings and the stop hook handed back the
  same four, at the same line numbers, against code it had already corrected.
  `mix credo --strict` said clean and the ledger agreed — credo exit=1 at 00:40
  and 00:42, exit=0 at 00:45.

  For "nesting too deep" there is no idempotent second fix, so satisfying a
  stale list means inventing a *different* refactor of correct code — and that
  edit produces the next stale snapshot for the next stop. The loop has no exit
  and every turn makes the code worse.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A finding against code that has since changed does not block" do
    scenario "correcting the file releases the stop" do
      given_ "credo recorded a finding against a file and it is blocking", context do
        # block_all so this scenario asks only about freshness. The default,
        # block_changed, also scopes to files touched this turn — a real rule,
        # and a different one.
        Fixtures.set_analyzer_mode(context.scope, :credo, :block_all)

        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/accounts.ex",
            "defmodule MyApp.Accounts do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)
        Fixtures.record_problem(context.scope, "credo")
        Fixtures.fresh_analysis_runs(context.scope, ["credo"])

        assert {:error, _} = Fixtures.validate_stop(context.scope),
               "the finding must actually block first, or the scenario proves nothing"

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

      then_ "the finding no longer blocks the stop", context do
        assert {:ok, _} = Fixtures.validate_stop(context.scope),
               """
               The finding describes bytes that no longer exist. Handing it back
               sends the agent to re-fix correct code, and each such edit produces
               the next stale snapshot — a loop with no exit.
               """

        {:ok, context}
      end
    end
  end
end
