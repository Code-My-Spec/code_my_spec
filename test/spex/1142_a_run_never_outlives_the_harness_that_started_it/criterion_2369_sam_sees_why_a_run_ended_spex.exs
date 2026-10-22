defmodule CodeMySpecSpex.Story1142.Criterion2369Spex do
  @moduledoc """
  Story 1142 — A run never outlives the harness that started it.
  Criterion 2369 — Sam sees why a run ended.

  A run that died with its harness says so, and stays ended: the harness
  coming back does not start it again on the agent's behalf.
  """

  # The run is held in the harness's queue by occupying the machine's only
  # analyzer slot (`CmsHarness.AnalysisSlots`, one per node).
  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.SlotHolder
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Sam sees why a run ended", criterion: 2369 do
    scenario "the harness went away under Sam's run and came back" do
      given_ "Sam's checkout is served by a live harness", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "the machine's one analyzer slot is taken", context do
        Application.put_env(:code_my_spec, :analysis_slots, 1)
        on_exit(fn -> Application.delete_env(:code_my_spec, :analysis_slots) end)
        _holder = SlotHolder.occupy()

        {:ok, context}
      end

      given_ "Sam's run stopped because its harness went away", context do
        Fixtures.use_recording_transport(context.scope)
        agent = Fixtures.running_agent(context.scope, role: "coding")
        Fixtures.mark_present(agent)

        reply =
          ToolLibrary.run("start_analysis", %{source: "exunit"}, %{
            scope: context.scope,
            current_scope: context.scope,
            agent_id: agent.id
          })

        [_, run_id] = Regex.run(~r/Run (\d+) /, response_text(reply))
        context = HarnessHooks.restart_live_harness(context)

        {:ok, Map.merge(context, %{agent: agent.id, run_id: run_id})}
      end

      when_ "Sam looks at the run", context do
        agent = context.agent

        told =
          receive do
            {:agent_dispatch, ^agent, _ref, message} -> message
          after
            30_000 -> flunk("Sam's agent was never told what became of run #{context.run_id}")
          end

        {:ok, Map.put(context, :told, told)}
      end

      then_ "it says its harness went away", context do
        assert context.told =~ ~r/harness went away/i, context.told
        {:ok, context}
      end

      then_ "and no new run is started on its behalf", context do
        assert context.told =~ ~r/not (being )?run again/i, context.told
        {:ok, context}
      end
    end
  end
end
