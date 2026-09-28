defmodule CodeMySpecSpex.Story704.Criterion3582Spex do
  @moduledoc """
  Story 704 — Agent administers their session.
  Criterion 3582 — Invalid task links create no tap-out request.

  Existing task history is seeded through the fixture bridge. This criterion
  tests validation of that history, not claiming or completing work (the real
  claim-and-tap-out flow is covered by criterion 1875). Outcomes are observed
  through MCP listings and the continuous toggle in the real conversation UI.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  setup context do
    caller = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
    {caller, completed} = Fixtures.agent_task_fixture(context.scope, caller, status: :completed)
    {caller, active} = Fixtures.agent_task_fixture(context.scope, caller)
    other = Fixtures.running_agent(context.scope, role: "qa", continuous: true)
    {other, other_task} = Fixtures.agent_task_fixture(context.scope, other)

    {:ok,
     agent_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: caller.id}},
     other_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: other.id}},
     active_task_id: active.id,
     completed_task_id: completed.id,
     other_task_id: other_task.id,
     caller_path: Fixtures.agent_conversation_path(context.scope, caller),
     other_path: Fixtures.agent_conversation_path(context.scope, other)}
  end

  spex "An unknown tap-out task link has no side effects", criterion: 1480 do
    scenario "an unknown task UUID" do
      given_ "both owners' tasks and the empty permission inbox are observable", context do
        {:reply, caller_tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        {:reply, other_tasks, _} = ListTasks.execute(%{}, context.other_frame)
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.agent_frame)
        refute caller_tasks.isError, response_text(caller_tasks)
        refute other_tasks.isError, response_text(other_tasks)
        refute inbox.isError, response_text(inbox)
        assert response_text(caller_tasks) =~ context.active_task_id
        assert response_text(caller_tasks) =~ context.completed_task_id
        assert response_text(other_tasks) =~ context.other_task_id
        assert String.length(response_text(inbox)) > 0

        {:ok,
         Map.merge(context, %{
           caller_before: response_text(caller_tasks),
           other_before: response_text(other_tasks),
           inbox_before: response_text(inbox)
         })}
      end

      when_ "the caller asks with an unknown task UUID", context do
        {:reply, response, _} =
          TapOut.execute(
            %{
              task_id: "00000000-0000-4000-8000-000000000001"
            },
            context.agent_frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the request is refused without a permission or task mutation", context do
        assert context.response.isError, response_text(context.response)
        {:reply, caller_tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        {:reply, other_tasks, _} = ListTasks.execute(%{}, context.other_frame)
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.agent_frame)
        refute caller_tasks.isError, response_text(caller_tasks)
        refute other_tasks.isError, response_text(other_tasks)
        refute inbox.isError, response_text(inbox)
        assert response_text(caller_tasks) == context.caller_before
        assert response_text(other_tasks) == context.other_before
        assert response_text(inbox) == context.inbox_before
        {:ok, context}
      end

      then_ "both continuous policies remain enabled", context do
        {:ok, caller_view, _} = live(context.conn, context.caller_path)

        assert has_element?(
                 caller_view,
                 "[data-test='toggle-agent-working'][data-working='true']"
               )

        {:ok, other_view, _} = live(context.conn, context.other_path)
        assert has_element?(other_view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end
    end
  end

  spex "A foreign tap-out task link has no side effects" do
    scenario "another agent's active task" do
      given_ "both owners' tasks and the empty permission inbox are observable", context do
        {:reply, caller_tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        {:reply, other_tasks, _} = ListTasks.execute(%{}, context.other_frame)
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.agent_frame)
        refute caller_tasks.isError, response_text(caller_tasks)
        refute other_tasks.isError, response_text(other_tasks)
        refute inbox.isError, response_text(inbox)
        assert response_text(caller_tasks) =~ context.active_task_id
        assert response_text(caller_tasks) =~ context.completed_task_id
        assert response_text(other_tasks) =~ context.other_task_id
        assert String.length(response_text(inbox)) > 0

        {:ok,
         Map.merge(context, %{
           caller_before: response_text(caller_tasks),
           other_before: response_text(other_tasks),
           inbox_before: response_text(inbox)
         })}
      end

      when_ "the caller asks with another agent's active task", context do
        {:reply, response, _} =
          TapOut.execute(
            %{
              task_id: context.other_task_id
            },
            context.agent_frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the request is refused without a permission or task mutation", context do
        assert context.response.isError, response_text(context.response)
        {:reply, caller_tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        {:reply, other_tasks, _} = ListTasks.execute(%{}, context.other_frame)
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.agent_frame)
        refute caller_tasks.isError, response_text(caller_tasks)
        refute other_tasks.isError, response_text(other_tasks)
        refute inbox.isError, response_text(inbox)
        assert response_text(caller_tasks) == context.caller_before
        assert response_text(other_tasks) == context.other_before
        assert response_text(inbox) == context.inbox_before
        {:ok, context}
      end

      then_ "both continuous policies remain enabled", context do
        {:ok, caller_view, _} = live(context.conn, context.caller_path)

        assert has_element?(
                 caller_view,
                 "[data-test='toggle-agent-working'][data-working='true']"
               )

        {:ok, other_view, _} = live(context.conn, context.other_path)
        assert has_element?(other_view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end
    end
  end

  spex "An inactive tap-out task link has no side effects" do
    scenario "the caller's completed task" do
      given_ "both owners' tasks and the empty permission inbox are observable", context do
        {:reply, caller_tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        {:reply, other_tasks, _} = ListTasks.execute(%{}, context.other_frame)
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.agent_frame)
        refute caller_tasks.isError, response_text(caller_tasks)
        refute other_tasks.isError, response_text(other_tasks)
        refute inbox.isError, response_text(inbox)
        assert response_text(caller_tasks) =~ context.active_task_id
        assert response_text(caller_tasks) =~ context.completed_task_id
        assert response_text(other_tasks) =~ context.other_task_id
        assert String.length(response_text(inbox)) > 0

        {:ok,
         Map.merge(context, %{
           caller_before: response_text(caller_tasks),
           other_before: response_text(other_tasks),
           inbox_before: response_text(inbox)
         })}
      end

      when_ "the caller asks with the caller's completed task", context do
        {:reply, response, _} =
          TapOut.execute(
            %{
              task_id: context.completed_task_id
            },
            context.agent_frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the request is refused without a permission or task mutation", context do
        assert context.response.isError, response_text(context.response)
        {:reply, caller_tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        {:reply, other_tasks, _} = ListTasks.execute(%{}, context.other_frame)
        {:reply, inbox, _} = ListNotifications.execute(%{}, context.agent_frame)
        refute caller_tasks.isError, response_text(caller_tasks)
        refute other_tasks.isError, response_text(other_tasks)
        refute inbox.isError, response_text(inbox)
        assert response_text(caller_tasks) == context.caller_before
        assert response_text(other_tasks) == context.other_before
        assert response_text(inbox) == context.inbox_before
        {:ok, context}
      end

      then_ "both continuous policies remain enabled", context do
        {:ok, caller_view, _} = live(context.conn, context.caller_path)

        assert has_element?(
                 caller_view,
                 "[data-test='toggle-agent-working'][data-working='true']"
               )

        {:ok, other_view, _} = live(context.conn, context.other_path)
        assert has_element?(other_view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end
    end
  end
end
