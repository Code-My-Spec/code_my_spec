defmodule CodeMySpecSpex.Story1080.Criterion1814Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1814 — A settled offer is never settled again.

  The menu is offered on the held task at every turn end, which makes it the
  plainest case: taken once, then settlement runs again at a later turn end.
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

  spex "A claimed offer stays claimed", criterion: 1814 do
    scenario "a coder acts on the menu once, then turn-end settlement runs again later" do
      given_ "a coder holding a task was handed the menu and claimed it", context do
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
        :ok = Fixtures.agent_tool_call(context.scope, %{id: id}, "c1", "list_tasks", %{})
        {:ok, Map.put(context, :coder, id)}
      end

      when_ "turn-end settlement runs again at a later, unrelated turn end", context do
        id = context.coder
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:agent_dispatch, ^id, _ref, "Your turn is done" <> _}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:agent_dispatch, ^id, _ref, "Your turn is done" <> _}, 2_000
        {:ok, context}
      end

      then_ "the claimed offer's settled status is unchanged", context do
        [claimed | _rest] = offers(context, context.coder, %{kind: "menu"}) |> Enum.reverse()

        assert {claimed.status, claimed.attempt} == {"claimed", 1},
               "a settled offer was settled again or miscounted:\n" <> listing(context)

        {:ok, context}
      end
    end
  end
end
