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
        caller_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        other_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.other_frame.assigns,
              :scope,
              context.other_frame.assigns[:current_scope]
            )
          )

        inbox =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, caller_tasks), response_text(caller_tasks)
        assert match?({:ok, _}, other_tasks), response_text(other_tasks)
        assert match?({:ok, _}, inbox), response_text(inbox)
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
        response =
          ToolLibrary.run(
            "tap_out",
            %{
              task_id: "00000000-0000-4000-8000-000000000001"
            },
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the request is refused without a permission or task mutation", context do
        assert match?({:error, _}, context.response), response_text(context.response)

        caller_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        other_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.other_frame.assigns,
              :scope,
              context.other_frame.assigns[:current_scope]
            )
          )

        inbox =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, caller_tasks), response_text(caller_tasks)
        assert match?({:ok, _}, other_tasks), response_text(other_tasks)
        assert match?({:ok, _}, inbox), response_text(inbox)
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
        caller_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        other_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.other_frame.assigns,
              :scope,
              context.other_frame.assigns[:current_scope]
            )
          )

        inbox =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, caller_tasks), response_text(caller_tasks)
        assert match?({:ok, _}, other_tasks), response_text(other_tasks)
        assert match?({:ok, _}, inbox), response_text(inbox)
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
        response =
          ToolLibrary.run(
            "tap_out",
            %{
              task_id: context.other_task_id
            },
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the request is refused without a permission or task mutation", context do
        assert match?({:error, _}, context.response), response_text(context.response)

        caller_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        other_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.other_frame.assigns,
              :scope,
              context.other_frame.assigns[:current_scope]
            )
          )

        inbox =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, caller_tasks), response_text(caller_tasks)
        assert match?({:ok, _}, other_tasks), response_text(other_tasks)
        assert match?({:ok, _}, inbox), response_text(inbox)
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
        caller_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        other_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.other_frame.assigns,
              :scope,
              context.other_frame.assigns[:current_scope]
            )
          )

        inbox =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, caller_tasks), response_text(caller_tasks)
        assert match?({:ok, _}, other_tasks), response_text(other_tasks)
        assert match?({:ok, _}, inbox), response_text(inbox)
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
        response =
          ToolLibrary.run(
            "tap_out",
            %{
              task_id: context.completed_task_id
            },
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the request is refused without a permission or task mutation", context do
        assert match?({:error, _}, context.response), response_text(context.response)

        caller_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        other_tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.other_frame.assigns,
              :scope,
              context.other_frame.assigns[:current_scope]
            )
          )

        inbox =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, caller_tasks), response_text(caller_tasks)
        assert match?({:ok, _}, other_tasks), response_text(other_tasks)
        assert match?({:ok, _}, inbox), response_text(inbox)
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
