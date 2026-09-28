defmodule CodeMySpecSpex.Story1043.Criterion3051Spex do
  @moduledoc """
  Story 1043 — The stop decision reaches the agent running inside our own BEAM.
  Criterion 3051 — A finished turn starts no analysis.

  Rule: Analysis is explicit. A turn ending decides from the problems already
  recorded and enqueues nothing (`.code_my_spec/rules/analysis_is_explicit.md`).

  This criterion used to assert the opposite — that a turn ending re-ran
  whatever was stale. That implicit trigger is what let a failing leg re-request
  itself after every scan and hold the machine's only analyzer slot in a loop
  (`38d87eb5`).

  The premise is still a source whose last run **failed**, created last so
  nothing before the `when_` has reacted to it. Under the old behaviour that is
  exactly what a stop re-ran, so the assertion discriminates: it is red if a
  turn's end starts a run and green only if it starts none.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  @end_turn_opts [
    compile_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
    spex_output_file: Path.expand("test/fixtures/validation/spex_green.jsonl")
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "When the agent ends a turn, no analysis is started", criterion: 1125 do
    scenario "A finished turn starts no analysis" do
      given_ "an agent running under Alloy on a copy the server knows", context do
        Fixtures.deliver_manifest(context.scope)

        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      given_ "and credo's last run failed", context do
        failed = Fixtures.failed_analysis_run(context.scope, "credo")

        {:ok, Map.put(context, :failed_run_id, failed.id)}
      end

      when_ "its turn ends", context do
        :ok =
          use_cmd_cassette "clean", record: :none do
            Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
          end

        {:ok, context}
      end

      then_ "credo's failed run is still the latest, because nothing asked for another",
            context do
        credo = Map.get(Fixtures.analysis_status(context.scope), "credo")

        assert credo && credo.run, """
        credo has no run at all, so the premise did not take hold and this proves
        nothing. The state map says: #{inspect(credo)}
        """

        assert credo.run.id == context.failed_run_id, """
        The turn ended and credo was run again. Analysis is explicit: a turn's end
        decides from the problems already recorded and must not start the runs that
        would produce new ones.

        credo: #{inspect(credo)}
        """

        {:ok, context}
      end
    end
  end
end
