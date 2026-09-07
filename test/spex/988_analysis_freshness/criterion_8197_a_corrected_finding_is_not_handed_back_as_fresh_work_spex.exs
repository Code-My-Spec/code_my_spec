defmodule CodeMySpecSpex.Story988.Criterion8197Spex do
  @moduledoc """
  Story 988 — Analysis Freshness
  Criterion 8197 — A corrected finding is not handed back as fresh work.

  8201 says the finding still blocks. This says the agent must be able to tell
  it is looking at a list that predates its own edit.

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

  spex "A stale list is labelled as one" do
    scenario "the corrected credo finding comes back marked, with instructions" do
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

        refute message =~ "stale",
               "while the run is current the list is current — marking it here " <>
                 "would train the agent to ignore the marker"

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

      then_ "the response marks credo stale and says not to re-fix", context do
        result =
          use_cmd_cassette "clean", record: :none do
            Fixtures.validate_stop(context.scope, @validate_stop_opts)
          end

        assert {:error, message} = result

        assert message =~ "stale",
               """
               Line 61 of a file the agent just corrected, handed back with no
               mark on it, is drill 6 exactly.

               #{message}
               """

        assert message =~ ~r/do not re-?fix/i,
               """
               Naming the state is not enough — the agent needs to know what to
               do with it, which is wait rather than edit. Without that, the
               only reading of a blocked stop is "more work to do".

               #{message}
               """

        {:ok, context}
      end
    end
  end
end
