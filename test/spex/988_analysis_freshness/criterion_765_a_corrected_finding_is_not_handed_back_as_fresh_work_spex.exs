defmodule CodeMySpecSpex.Story988.Criterion8197Spex do
  @moduledoc """
  Story 988 — Analysis Freshness
  Criterion 8197 — A corrected finding is not handed back as fresh work.

  8201 says the finding still blocks. This says the agent must be able to tell
  it is looking at a list that predates its own edit.

  28d72f8a: it is told by the run that recorded the list — its commit and how
  long ago it finished — on every finding, always. There is no "stale" label:
  whether a run saw the current code is the promote gate's question, and the
  label changed what an agent did without changing what was true. This
  criterion's wording ("not handed back as fresh work") should be retired or
  reworded to "a finding names the run that recorded it".

  That distinction is the whole of drill 6. The agent was stopped and handed
  four credo findings at specific line numbers in code it had already fixed,
  with nothing marking them provisional, so it read them as work. For "nesting
  too deep" there is no idempotent second fix — satisfying the list means
  refactoring correct code differently, and that edit invalidates the next run
  in turn.

  Blocking was never the problem. Blocking silently was.
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

  spex "A finding names the run that recorded it", criterion: 765 do
    scenario "the corrected credo finding comes back labelled with its run" do
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

        result =
          use_cmd_cassette "clean", record: :none do
            Fixtures.validate_stop(context.scope, @validate_stop_opts)
          end

        assert {:error, message} = result
        assert message =~ "nesting too deep"

        assert message =~ ~r/from the run[^\n]*finished \d+s ago/,
               "every finding is labelled with the run that recorded it: #{message}"

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

      then_ "the response still names the run, and says nothing about staleness", context do
        result =
          use_cmd_cassette "clean", record: :none do
            Fixtures.validate_stop(context.scope, @validate_stop_opts)
          end

        assert {:error, message} = result

        assert message =~ ~r/from the run[^\n]*finished \d+s ago/,
               """
               Line 61 of a file the agent just corrected has to say which run
               found it, so the agent can tell it predates the edit.

               #{message}
               """

        refute message =~ "stale",
               "no stale label: the run's age and commit are the facts (28d72f8a)"

        {:ok, context}
      end
    end
  end
end
