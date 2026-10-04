defmodule CodeMySpecSpex.Story1080.Criterion1677Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1677 — A settled offer is never settled again, and a new offer
  after a claim starts again at attempt one.

  The menu is offered on the held task at every turn end, which makes it the
  plainest case: taken once, then not taken. The attempt counts the tries since
  the agent last took it, so a claim resets it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  spex "Settled stays settled; a claim resets the attempt", criterion: 1677 do
    scenario "a coder acts on the menu once, then does not" do
      given_ "a coder holding a task was handed the menu and has started its next turn",
             context do
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

      when_ "it acts on that menu, and then ends a turn without acting on the next", context do
        id = context.coder
        :ok = Fixtures.agent_tool_call(context.scope, %{id: id}, "c1", "list_tasks", %{})
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:agent_dispatch, ^id, _ref, "Your turn is done" <> _}, 2_000

        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:agent_dispatch, ^id, _ref, "Your turn is done" <> _}, 2_000
        {:ok, context}
      end

      then_ "the first is still claimed, the second ignored, and the attempts restart after the claim",
            context do
        # Newest first.
        assert [third, second, first] = offers(context, context.coder, %{kind: "menu"}),
               listing(context)

        assert {first.status, first.attempt} == {"claimed", 1},
               "the claimed menu offer was settled again or miscounted:\n" <> listing(context)

        assert {second.status, second.attempt} == {"ignored", 1},
               "the offer after a claim should start again at attempt 1:\n" <> listing(context)

        assert {third.status, third.attempt} == {"open", 2}, listing(context)
        {:ok, context}
      end
    end
  end
end
