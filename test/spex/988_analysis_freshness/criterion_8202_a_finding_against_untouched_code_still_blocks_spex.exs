defmodule CodeMySpecSpex.Story988.Criterion8202Spex do
  @moduledoc """
  Story 988 — Analysis Freshness
  Criterion 8202 — A finding against untouched code still blocks.

  Covers Rule "Persisted problems block a stop only while they describe the
  current working copy."

  The other half of 8201, and the one that keeps that fix honest. 8201 says a
  finding stops blocking once the code it describes has changed. Read alone,
  that is satisfiable by never blocking on anything — so this asks the
  converse: nothing has changed since the analyzer ran, the finding still
  describes the working copy exactly, and it must still block.

  ## The case this deliberately does not assert

  "Untouched" has a second reading: the agent edits a *different* file and
  leaves `accounts.ex` alone. That finding is still true, but it stops
  blocking — freshness is computed per *source* over every file of that
  source's roles (`Analysis.Fingerprint.current/2`), not per file, so any
  implementation edit re-hashes credo's whole input and the source reads
  stale. Verified, not inferred: after an unrelated write the problem is still
  persisted and `Analysis.fresh?(scope, "credo")` is false, so
  `check_blocking_problems/3` drops it.

  That is a real window and it is filed as an issue. It is left out of this
  spex because `validation.ex` chose it on purpose — "stale means silent, not
  passing", on the reasoning that the analyzer is already enqueued and its
  result blocks the next stop. Asserting the opposite here would decide that
  question by fiat and leave a red spex standing on an undecided rule.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A finding still blocks while the code it describes is unchanged" do
    scenario "nothing has changed since the analyzer ran" do
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

        {:ok, context}
      end

      when_ "the agent stops without editing anything", context do
        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      then_ "the finding still blocks the stop", context do
        assert {:error, _} = Fixtures.validate_stop(context.scope),
               """
               Nothing moved. The finding describes exactly the bytes credo
               read, so it is still true and must still block.

               This is what keeps 8201 honest: a freshness rule that also
               releases this one has not made results current, it has stopped
               reporting.
               """

        {:ok, context}
      end
    end
  end
end
