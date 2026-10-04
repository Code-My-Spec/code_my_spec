defmodule CodeMySpecSpex.Story988.Criterion1679Spex do
  @moduledoc """
  Story 988 — Analysis Freshness
  Criterion 1679 — An analysis run waiting for a slot reads as queued, distinct
  from one that is executing.

  A run is `:running` from the moment it is requested, and the harness runs one
  analyzer at a time machine-wide, so a compiler run sat nineteen minutes behind
  seven others and read as hung (run 54245, bf627680). The harness reports when
  an analyzer actually begins; until it does, the run is queued, and the stop
  hook says which.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An analysis run waiting for a slot reads as queued, distinct from one that is executing",
    criterion: 1679 do
    scenario "the harness has begun spex, and compiler waits behind it" do
      given_ "a harness serving this checkout, asked for compiler and spex", context do
        context = HarnessHooks.ensure_live_harness(context)

        {:ok,
         Map.merge(context, %{
           compiler: Fixtures.start_analysis_run(context.scope, "compiler"),
           spex: Fixtures.start_analysis_run(context.scope, "spex")
         })}
      end

      when_ "the harness reports spex has begun, and the agent stops", context do
        :ok = HarnessHooks.start_analysis(context, context.spex)

        response =
          HarnessHooks.post_hook(context, "stop", %{
            "session_id" => "spex-#{System.unique_integer([:positive])}"
          })

        {:ok, Map.put(context, :said, response["systemMessage"] || response["reason"] || "")}
      end

      then_ "compiler reads as queued, and spex as running", context do
        assert context.said =~ "compiler (queued for a slot)",
               "a run waiting for a slot must say so, or it reads as hung: #{context.said}"

        assert context.said =~ "spex"

        refute context.said =~ "spex (queued",
               "spex has begun; calling it queued is the opposite mistake: #{context.said}"

        {:ok, context}
      end
    end
  end
end
