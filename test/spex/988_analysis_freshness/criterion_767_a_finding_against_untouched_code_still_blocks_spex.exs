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

  Since 28d72f8a a finding always blocks, from the latest completed run,
  whatever was edited since — there is no freshness rule left to drop it, so
  the window this used to accept (an unrelated edit silencing every source) is
  closed.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  # See criterion 3059's note: an uncassetted `validate_stop` runs a real
  # `mix compile` and a real recursive `mix spex`, which has nothing to do
  # with the credo finding this criterion is about.
  @validate_stop_opts [
    compile_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
    spex_output_file: Path.expand("test/fixtures/validation/spex_green.jsonl")
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A finding still blocks while the code it describes is unchanged", criterion: 767 do
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
        result =
          use_cmd_cassette "clean", record: :none do
            Fixtures.validate_stop(context.scope, @validate_stop_opts)
          end

        assert {:error, _} = result,
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
