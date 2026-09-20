defmodule CodeMySpecSpex.Story704.Criterion1876Spex do
  @moduledoc """
  Story 704 — Agent administers their session.
  Criterion 1876 — Approved whole-agent tap-out deliberately clears continuous intent.

  Explicit null task identity distinguishes stopping continuous work from
  giving up one task. A real approval must preserve active and completed task
  history and the existing engine, without delivering a new control-message turn.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
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

  spex "Null-task tap-out stops continuous intent, not a task or process" do
    scenario "Human approval leaves the active attempt and completed history untouched" do
      given_ "a continuous durable agent has task history and an available local engine",
             context do
        context = given_a_staffed_checkout(context, "spex_1876")
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)

        {agent, _completed} =
          Fixtures.agent_task_fixture(context.scope, agent,
            status: :completed,
            requirement_name: "spec_file"
          )

        {agent, _active} =
          Fixtures.agent_task_fixture(context.scope, agent,
            status: :active,
            requirement_name: "test_file"
          )

        other_agent = Fixtures.running_agent(context.scope, role: "qa", continuous: true)

        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        {:reply, tasks, _} = ListTasks.execute(%{}, frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (2)"
        assert response_text(tasks) =~ "[active]"
        assert response_text(tasks) =~ "[completed]"

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(agent.id)

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
        {:reply, response, _} = TapOut.execute(%{task_id: nil}, context.agent_frame)
        refute response.isError, response_text(response)
        [_, request_id] = Regex.run(~r/request_id=`([a-f0-9-]+)`/, response_text(response))
        {:ok, Map.put(context, :request_id, request_id)}
      end

      then_ "the pending request has not changed tasks or continuous intent", context do
        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      when_ "the user approves the permission request", context do
        {:ok, view, _} = live(context.conn, "/app/permissions/#{context.request_id}")
        view |> element("[data-test='approve-permission']") |> render_click()
        assert has_element?(view, "[data-test='permission-resolved']")
        {:ok, context}
      end

      then_ "continuous is disabled but no task or process is terminated or given another turn",
            context do
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='false']")
        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        {:ok, other_view, _} = live(context.conn, context.other_conversation_path)
        assert has_element?(other_view, "[data-test='toggle-agent-working'][data-working='true']")
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.agent_id)
        assert HeldProvider.seen() == []
        {:ok, context}
      end
    end
  end
end
