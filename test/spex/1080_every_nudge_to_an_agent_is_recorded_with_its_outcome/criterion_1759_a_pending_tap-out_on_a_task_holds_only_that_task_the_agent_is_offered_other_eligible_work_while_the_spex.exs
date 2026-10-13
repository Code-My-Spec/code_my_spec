defmodule CodeMySpecSpex.Story1080.Criterion1759Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1759 — A pending tap-out on a task holds only that task; the agent
  is offered other eligible work while the decision is pending, and a tap-out
  naming no task still holds the agent.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers, only: [coding_work_waiting: 1, agent_frame: 2]
  import CodeMySpecSpex.StoryBoundHelpers, only: [issue_accepted: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A tap-out on a task leaves the agent's other work open", criterion: 1759 do
    scenario "a coder taps out of an accepted bug while story work is eligible" do
      given_ "a continuous coder, mid-turn, resolving an accepted bug beside story work",
             context do
        context = context |> coding_work_waiting() |> issue_accepted() |> a_coder()
        :ok = Fixtures.start_turn(context.scope, context.coder)

        # Project work, so claiming it does not bind the coder to a story
        # (criterion 1752: a bound agent is offered nothing outside its story).
        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "issues_resolved",
              entity_type: "project",
              entity_id: to_string(context.scope.active_project_id)
            },
            context.frame
          )

        refute started.isError, response_text(started)
        {:ok, Map.put(context, :task_id, extract_task_id!(started))}
      end

      when_ "it taps out of that task and ends its turn", context do
        {:reply, tapped, _} =
          TapOut.execute(
            %{task_id: context.task_id, reason: "The bug cannot be reproduced"},
            context.frame
          )

        refute tapped.isError, response_text(tapped)
        :ok = Fixtures.end_turn(context.scope, context.coder, [])
        :ok = Fixtures.settle_graph(context.scope)
        {:ok, context}
      end

      then_ "it is offered other work while the decision is pending", context do
        coder = context.coder
        assert_receive {:work_turn_requested, ^coder, _ref, prompt}, 2_000
        assert prompt =~ "Eligible work is available"
        {:ok, context}
      end
    end
  end

  spex "A tap-out naming no task still holds the agent", criterion: 1759 do
    scenario "a coder asks to stop altogether while work is eligible" do
      given_ "a continuous coder, mid-turn, holding nothing beside eligible work", context do
        context = context |> coding_work_waiting() |> issue_accepted() |> a_coder()
        :ok = Fixtures.start_turn(context.scope, context.coder)
        {:ok, context}
      end

      when_ "it taps out naming no task and ends its turn", context do
        {:reply, tapped, _} =
          TapOut.execute(%{reason: "Nothing here is mine to do"}, context.frame)

        refute tapped.isError, response_text(tapped)
        :ok = Fixtures.end_turn(context.scope, context.coder, [])
        :ok = Fixtures.settle_graph(context.scope)
        {:ok, context}
      end

      then_ "it is offered nothing while the decision is pending", context do
        coder = context.coder
        refute_receive {:work_turn_requested, ^coder, _ref, _prompt}, 1_000
        {:ok, context}
      end
    end
  end

  defp a_coder(context) do
    coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
    Map.merge(context, %{coder: coder.id, frame: agent_frame(context, coder.id)})
  end
end
