defmodule CodeMySpecSpex.Story704.Criterion3587Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 3587 — Human approves the tap-out and continuous mode clears.

  Covers Rule 5's approval path: after a pending tap_out request is
  approved through the permission flow, `session.continuous` is
  cleared and the next stop hook allows.

  ## Surface

  The session's tap-out is a permission request in the person's inbox; the
  spex approves it on `/app/permissions/:id`, the page that inbox links to.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Human approves the tap-out and continuous mode clears", criterion: 1485 do
    scenario "after approval, continuous is false and next stop hook allows" do
      given_ :synced_context_component
      given_ :context_implementation_task_started

      given_ "continuous mode is enabled and tap_out has been called", context do
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          TapOut.execute(%{session_id: context.session_id}, frame)

        body = TaskResponseHelpers.response_text(response)
        [_, request_id] = Regex.run(~r/request_id=`([^`]+)`/, body)

        {:ok, Map.put(context, :request_id, request_id)}
      end

      when_ "the human approves the pending tap-out request", context do
        {:ok, view, _} = live(context.conn, "/app/permissions/#{context.request_id}")
        view |> element("[data-test='approve-permission']") |> render_click()
        assert has_element?(view, "[data-test='permission-resolved']", "approved")
        {:ok, context}
      end

      then_ "the next stop hook allows the stop (continuous cleared, observed via surface)",
            context do
        # "continuous flag is cleared" is observable through the stop
        # hook: if the flag were still on with actionable work, stop
        # would block with a continuation directive. The empty allow
        # signal is the surface confirmation that continuous cleared.
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
                "compile" =>
                  Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        assert response == %{},
               "expected stop to allow after tap-out approval, got: #{inspect(response)}"

        {:ok, context}
      end
    end
  end

  spex "Ordinary tool permission approval does not become task disposition" do
    scenario "A normal permission is approved while a durable agent holds a task" do
      given_ "an ordinary Read permission is pending and an agent has an active task", context do
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        {agent, _task} = Fixtures.agent_task_fixture(context.scope, agent)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        {:reply, tasks, _} = ListTasks.execute(%{}, frame)
        refute tasks.isError, TaskResponseHelpers.response_text(tasks)

        request_id =
          Fixtures.request_permission(context.scope.user.id,
            tool_name: "Read",
            tool_input: %{"file_path" => "/tmp/permission-compatibility.txt"}
          )

        {:ok,
         Map.merge(context, %{
           frame: frame,
           request_id: request_id,
           tasks_before: TaskResponseHelpers.response_text(tasks),
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      when_ "the user approves the ordinary permission", context do
        {:ok, view, _} = live(context.conn, "/app/permissions/#{context.request_id}")
        assert render(view) =~ "/tmp/permission-compatibility.txt"
        view |> element("[data-test='approve-permission']") |> render_click()
        assert has_element?(view, "[data-test='permission-resolved']", "approved")
        {:ok, context}
      end

      then_ "the saved approval leaves the agent's tasks and continuous policy alone", context do
        {:ok, view, _} = live(context.conn, "/app/permissions/#{context.request_id}")
        assert has_element?(view, "[data-test='permission-resolved']", "approved")
        {:reply, tasks, _} = ListTasks.execute(%{}, context.frame)
        refute tasks.isError, TaskResponseHelpers.response_text(tasks)
        assert TaskResponseHelpers.response_text(tasks) == context.tasks_before
        {:ok, agent_view, _} = live(context.conn, context.conversation_path)
        assert has_element?(agent_view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end
    end
  end
end
