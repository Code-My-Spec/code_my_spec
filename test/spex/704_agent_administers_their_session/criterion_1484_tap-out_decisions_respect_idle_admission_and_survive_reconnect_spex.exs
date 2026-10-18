defmodule CodeMySpecSpex.Story704.Criterion3586Spex do
  @moduledoc """
  Story 704 — Agent administers their session.
  Criterion 3586 — Rejected whole-agent tap-out preserves continuous intent.

  Explicit null task identity distinguishes stopping continuous work from
  giving up one task. A real rejection must preserve active and completed task
  history and the existing engine, without delivering a new control-message turn.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A tap-out decision does not queue a turn beside busy work", criterion: 1484 do
    scenario "Human rejection leaves the active attempt and completed history untouched" do
      given_ "a continuous durable agent has task history and an available local engine",
             context do
        context = given_a_staffed_checkout(context, "spex_3586_busy")
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)

        {agent, _completed} =
          Fixtures.agent_task_fixture(context.scope, agent,
            status: :completed,
            requirement_name: "spec_file"
          )

        {agent, _active} =
          Fixtures.agent_task_fixture(context.scope, agent,
            status: :active,
            requirement_name: "implementation_file"
          )

        other_agent = Fixtures.running_agent(context.scope, role: "qa", continuous: true)

        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (2)"
        assert response_text(tasks) =~ "[active]"
        assert response_text(tasks) =~ "[completed]"

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        assert {:ok, %{busy?: false}} = Machine.status(agent.id)

        assert {:ok, :started} =
                 Machine.send_message(
                   agent.id,
                   "user-turn-3586",
                   "Finish this user-requested turn"
                 )

        _ = HeldProvider.await_request()
        assert {:ok, %{busy?: true}} = Machine.status(agent.id)

        {:ok,
         Map.merge(context, %{
           other_conversation_path: Fixtures.agent_conversation_path(context.scope, other_agent),
           agent_id: agent.id,
           agent_frame: frame,
           tasks_before: response_text(tasks),
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      when_ "the agent explicitly requests whole-agent tap-out with task_id null", context do
        response =
          ToolLibrary.run(
            "tap_out",
            %{task_id: nil},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, response), response_text(response)
        [_, request_id] = Regex.run(~r/request_id=`([a-f0-9-]+)`/, response_text(response))
        {:ok, Map.put(context, :request_id, request_id)}
      end

      then_ "the pending request has not changed tasks or continuous intent", context do
        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      when_ "the user denies the permission request", context do
        {:ok, view, _} = live(context.conn, "/app/permissions/#{context.request_id}")
        assert has_element?(view, "[data-test='deny-permission']")

        view
        |> element("#permission-#{context.request_id}-confirm-deny [data-role='confirm-confirm']")
        |> render_click()

        assert has_element?(view, "[data-test='permission-resolved']")
        {:ok, context}
      end

      then_ "continuous stays enabled and the busy turn gets no queued decision message",
            context do
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        {:ok, other_view, _} = live(context.conn, context.other_conversation_path)
        assert has_element?(other_view, "[data-test='toggle-agent-working'][data-working='true']")
        assert {:ok, %{busy?: true}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 1
        {:ok, context}
      end
    end
  end

  spex "A saved tap-out decision survives explicit engine restart" do
    scenario "Human rejection leaves the active attempt and completed history untouched" do
      given_ "a continuous durable agent has task history and an available local engine",
             context do
        context = given_a_staffed_checkout(context, "spex_3586_disconnected")
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)

        {agent, _completed} =
          Fixtures.agent_task_fixture(context.scope, agent,
            status: :completed,
            requirement_name: "spec_file"
          )

        {agent, _active} =
          Fixtures.agent_task_fixture(context.scope, agent,
            status: :active,
            requirement_name: "implementation_file"
          )

        other_agent = Fixtures.running_agent(context.scope, role: "qa", continuous: true)

        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (2)"
        assert response_text(tasks) =~ "[active]"
        assert response_text(tasks) =~ "[completed]"

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        assert {:ok, %{busy?: false}} = Machine.status(agent.id)

        {:ok,
         Map.merge(context, %{
           other_conversation_path: Fixtures.agent_conversation_path(context.scope, other_agent),
           base_url: base_url,
           agent_id: agent.id,
           agent_frame: frame,
           tasks_before: response_text(tasks),
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      when_ "the agent explicitly requests whole-agent tap-out with task_id null", context do
        response =
          ToolLibrary.run(
            "tap_out",
            %{task_id: nil},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, response), response_text(response)
        [_, request_id] = Regex.run(~r/request_id=`([a-f0-9-]+)`/, response_text(response))
        assert :ok = Machine.stop_agent(context.agent_id)
        assert {:error, :not_running} = Machine.status(context.agent_id)
        {:ok, Map.put(context, :request_id, request_id)}
      end

      then_ "the pending request has not changed tasks or continuous intent", context do
        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      when_ "the user denies the permission request", context do
        {:ok, view, _} = live(context.conn, "/app/permissions/#{context.request_id}")
        assert has_element?(view, "[data-test='deny-permission']")

        view
        |> element("#permission-#{context.request_id}-confirm-deny [data-role='confirm-confirm']")
        |> render_click()

        assert has_element?(view, "[data-test='permission-resolved']")
        {:ok, context}
      end

      then_ "the saved decision does not restart the disconnected agent",
            context do
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        {:ok, other_view, _} = live(context.conn, context.other_conversation_path)
        assert has_element?(other_view, "[data-test='toggle-agent-working'][data-working='true']")
        assert {:error, :not_running} = Machine.status(context.agent_id)
        assert HeldProvider.seen() == []
        {:ok, context}
      end

      when_ "the operator explicitly starts the same durable agent", context do
        assert {:ok, _} =
                 Machine.start_agent(context.agent_id, context.copy, base_url: context.base_url)

        {:ok, context}
      end

      then_ "the rejected decision and task history survive without a replayed turn", context do
        {:ok, view, _} = live(context.conn, "/app/permissions/#{context.request_id}")
        assert has_element?(view, "[data-test='permission-resolved']", "denied")

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        assert {:ok, %{busy?: false}} = Machine.status(context.agent_id)
        assert HeldProvider.seen() == []
        {:ok, context}
      end
    end
  end
end
