defmodule CodeMySpecSpex.Story988.Criterion8201Spex do
  @moduledoc """
  Story 988 — Analysis Freshness
  Criterion 8201 — A finding from before the last edit still blocks until the
  rerun lands.

  Problems are an eventually consistent projection. The stop hook blocks on the
  set that is recorded and starts the run that will replace it;
  `reconcile_problems_for_source/4` clears and reinserts a source atomically, so
  the next stop reads the replacement.

  An earlier version of this criterion said the opposite — that a finding
  fixed since the analyzer ran no longer blocks — and the code dropped any
  source whose fingerprint had moved. That read well against drill 6, but every
  source fingerprints `:implementation`, so one edit silenced all four at once
  and nothing could block that stop. The last stop of an unattended run has no
  next stop to catch it.

  It also hid the case that actually strands findings: a failed run leaves the
  previous set untouched, so an analyzer failing every time hands back the same
  list forever. Filtering made that indistinguishable from a run merely
  in flight.

  So the finding still blocks. What changed is that it is labelled — see 8197.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A finding survives the edit that has not been analyzed yet" do
    scenario "correcting the file does not release the stop" do
      given_ "credo recorded a finding against a file and it is blocking", context do
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

      then_ "the finding still blocks, and its source is marked stale", context do
        assert {:error, message} = Fixtures.validate_stop(context.scope),
               """
               Releasing here is how an unattended run ends clean with real
               findings open: every source fingerprints :implementation, so this
               one edit made all four stale and nothing else could block either.
               """

        assert message =~ "stale",
               """
               Blocking is only half of it. The agent has to be able to tell
               this list predates its edit, or it re-fixes correct code — which
               is drill 6.

               #{message}
               """

        {:ok, context}
      end
    end
  end
end
