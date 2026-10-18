defmodule CodeMySpecSpex.Story1080.Criterion2165Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2165 — Menu, retry and answer offers are accepted by any tool
  call after them — not only a specific one.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A menu offer is accepted by any tool call after it", criterion: 2165 do
    scenario "a coder holding a task is handed the menu, then makes an unrelated tool call" do
      given_ "a coder holding a task was handed the menu", context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        context = HarnessHooks.ensure_live_harness(context)
        Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
        context = context |> start_session() |> put_to_work()
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        context = start_agent_task(context, coder.id, next_task(context, coder.id))
        id = coder.id
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:agent_dispatch, ^id, _ref, "Your turn is done" <> _}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, Map.put(context, :coder, id)}
      end

      when_ "it makes any tool call after the offer was delivered, and its turn ends", context do
        id = context.coder
        :ok = Fixtures.agent_tool_call(context.scope, %{id: id}, "c1", "list_tasks", %{})
        :ok = Fixtures.end_turn(context.scope, id)
        {:ok, context}
      end

      # Newest first: that turn end hands out a fresh menu, so the one the
      # coder was handed is the oldest.
      then_ "the menu offer is accepted and closed", context do
        assert %{status: "claimed"} =
                 context |> offers(context.coder, %{kind: "menu"}) |> List.last(),
               listing(context)

        {:ok, context}
      end
    end
  end
end
