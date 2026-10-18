defmodule CodeMySpecSpex.Story1080.Criterion2176Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2176 — A menu offer climbs from the held tasks, to the first in
  detail.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.StoryBoundHelpers, only: [issue_accepted: 2]

  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A menu offer's rungs climb from the held tasks to the first in detail", criterion: 2176 do
    scenario "a coder holds two tasks and ignores the first rung of the menu" do
      given_ "a coder holding two tasks, an accepted issue beside its story work", context do
        context = coder_holding_a_task(context)
        context = issue_accepted(context, context.story)

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "issues_resolved",
              entity_type: "project",
              entity_id: to_string(context.scope.active_project_id)
            },
            agent_frame(context, context.coder)
          )

        refute started.isError, TaskResponseHelpers.response_text(started)
        other_task_id = TaskResponseHelpers.extract_task_id!(started)
        {:ok, Map.put(context, :other_task_id, other_task_id)}
      end

      when_ "its turn ends, and it ignores the first rung of the menu", context do
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.coder)
        :ok = Fixtures.end_turn(context.scope, context.coder)
        id = context.coder
        assert_receive {:agent_dispatch, ^id, _ref, first}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        :ok = Fixtures.end_turn(context.scope, id)
        {:ok, Map.put(context, :first, first)}
      end

      then_ "the first rung lists the held tasks", context do
        assert context.first =~ context.task_id, context.first
        assert context.first =~ context.other_task_id, context.first
        {:ok, context}
      end

      then_ "the next rung gives the detail of the first held task", context do
        id = context.coder
        assert_receive {:agent_dispatch, ^id, _ref, second}, 2_000
        assert second =~ context.task_id, second
        {:ok, context}
      end
    end
  end
end
