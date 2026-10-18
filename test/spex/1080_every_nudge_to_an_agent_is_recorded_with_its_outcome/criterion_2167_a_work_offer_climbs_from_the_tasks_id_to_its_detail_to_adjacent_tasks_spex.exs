defmodule CodeMySpecSpex.Story1080.Criterion2167Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2167 — A work offer climbs from the task's id, to its detail, to
  adjacent tasks it could take instead.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers, only: [put_to_work: 1, start_session: 1]
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.StoryBoundHelpers, only: [issue_accepted: 2]

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A work offer's rungs climb from id, to detail, to alternatives", criterion: 2167 do
    scenario "a coder ignores the same offer three turns running" do
      given_ "coding work waiting, an accepted issue on the same story, and a continuous coder",
             context do
        context = coding_work_waiting(context)
        context = issue_accepted(context, context.story)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        context = context |> start_session() |> put_to_work()
        id = coder.id
        assert_receive {:work_turn_requested, ^id, _ref, first}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, Map.merge(context, %{coder: id, first: first})}
      end

      then_ "the first rung names the task by its id", context do
        [offer] = offers(context, context.coder, %{kind: "work"})
        assert context.first =~ offer.subject, context.first
        {:ok, context}
      end

      when_ "it ends the turn without taking it, and is offered again", context do
        id = context.coder
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:work_turn_requested, ^id, _ref, second}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, Map.put(context, :second, second)}
      end

      then_ "the next rung sends the task's detail", context do
        assert context.second =~ "Why it matters:", context.second
        {:ok, context}
      end

      when_ "it ignores that too, and is offered a third time", context do
        id = context.coder
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:work_turn_requested, ^id, _ref, third}, 2_000
        {:ok, Map.put(context, :third, third)}
      end

      then_ "the next rung also names adjacent tasks it could take instead", context do
        assert context.third =~ "Other work you could take instead:", context.third
        {:ok, context}
      end
    end
  end
end
