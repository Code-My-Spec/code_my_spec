defmodule CodeMySpecSpex.Story1080.Criterion1740Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1740 — A work offer ignored twice is offered alongside other work
  the agent could take instead.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.StoryBoundHelpers, only: [issue_accepted: 2]
  import CodeMySpecSpex.IdleAgentHelpers, only: [put_to_work: 1, start_session: 1]
  import CodeMySpecSpex.OfferHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  spex "Work ignored twice comes back with alternatives", criterion: 1740 do
    scenario "a coder ignores the same work two turns running, with other work waiting" do
      given_ "coding work waiting, and an accepted issue on the same story", context do
        context = coding_work_waiting(context)
        {:ok, issue_accepted(context, context.story)}
      end

      given_ "a continuous coder offered the first, mid-turn", context do
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        context = context |> start_session() |> put_to_work()
        id = coder.id
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, Map.put(context, :coder, id)}
      end

      when_ "it ends two turns without taking it, and is offered it a third time", context do
        id = context.coder
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:work_turn_requested, ^id, _ref, _second}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:work_turn_requested, ^id, _ref, third}, 2_000
        {:ok, Map.put(context, :prompt, third)}
      end

      then_ "the third offer names other work it could take instead", context do
        assert context.prompt =~ "Other work you could take instead:", context.prompt
        {:ok, context}
      end
    end
  end
end
