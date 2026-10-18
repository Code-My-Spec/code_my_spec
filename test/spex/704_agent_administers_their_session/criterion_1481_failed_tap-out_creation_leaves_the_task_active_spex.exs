defmodule CodeMySpecSpex.Story704.Criterion3583Spex do
  @moduledoc """
  Story 704 — Agent administers their session.
  Criterion 3583 — A failed tap-out write does not block the task.

  The database refuses the insert for this test user. The tool still receives
  a valid tap-out and an owned active task. Read task state and the real user
  inbox afterward; no test transaction wraps the action to undo its mistakes.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A tap-out that cannot be saved neither blocks work nor reaches the inbox",
    criterion: 1481 do
    scenario "The failed ask leaves its active task and continuous intent unchanged" do
      given_ "the caller owns an active task and its inbox is observable", context do
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        {agent, task} = Fixtures.agent_task_fixture(context.scope, agent)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) =~ task.id
        assert response_text(tasks) =~ "[active]"

        inbox =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, inbox), response_text(inbox)

        {:ok,
         Map.merge(context, %{
           frame: frame,
           task_id: task.id,
           tasks_before: response_text(tasks),
           inbox_before: response_text(inbox),
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      given_ "the database will refuse a tap-out insert for this user", context do
        :ok = Fixtures.refuse_tap_out_inserts(context.scope)
        {:ok, context}
      end

      when_ "the agent asks a valid tap-out linked to its active task", context do
        response =
          ToolLibrary.run(
            "tap_out",
            %{task_id: context.task_id},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the tool reports failure and no tap-out or blocker has been committed", context do
        assert match?({:error, _}, context.response), response_text(context.response)
        refute response_text(context.response) =~ "Tap-out requested"

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        refute response_text(tasks) =~ "[blocked]"

        inbox =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, inbox), response_text(inbox)
        assert response_text(inbox) == context.inbox_before

        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end
    end
  end
end
