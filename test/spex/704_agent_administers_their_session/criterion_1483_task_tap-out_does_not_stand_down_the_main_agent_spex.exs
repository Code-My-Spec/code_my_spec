defmodule CodeMySpecSpex.Story704.Criterion3585Spex do
  @moduledoc """
  A main agent's task-scoped tap-out must not stand down project oversight.
  Read cadence policy through its MCP surface before and after the request;
  timer existence and periodic turn admission are separate cadence criteria.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.Cadence
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

  spex "Task-scoped tap-out preserves main-agent oversight policy", criterion: 1483 do
    scenario "A pending decision blocks a task without standing down the main agent" do
      given_ "the continuous main agent owns an active task and has a configured cadence",
             context do
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        {main, task} = Fixtures.agent_task_fixture(context.scope, main)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}
        {:reply, cadence, _} = Cadence.execute(%{seconds: 1200}, frame)
        refute cadence.isError, response_text(cadence)
        assert response_text(cadence) =~ "interval: every 1200s"
        assert response_text(cadence) =~ "woken: yes"

        {:ok,
         Map.merge(context, %{
           frame: frame,
           task_id: task.id,
           cadence_before: response_text(cadence),
           conversation_path: Fixtures.agent_conversation_path(context.scope, main)
         })}
      end

      when_ "the main agent asks to tap out of just its task", context do
        {:reply, response, _} = TapOut.execute(%{task_id: context.task_id}, context.frame)
        refute response.isError, response_text(response)
        [_, request_id] = Regex.run(~r/request_id=`([a-f0-9-]+)`/, response_text(response))
        {:ok, Map.put(context, :request_id, request_id)}
      end

      then_ "cadence policy and continuous intent are unchanged", context do
        {:reply, cadence, _} = Cadence.execute(%{}, context.frame)
        refute cadence.isError, response_text(cadence)
        assert response_text(cadence) == context.cadence_before
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      then_ "only the task is blocked while its human decision is pending", context do
        {:reply, tasks, _} = ListTasks.execute(%{}, context.frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[blocked]"
        {:ok, view, _} = live(context.conn, "/app/permissions/#{context.request_id}")
        assert has_element?(view, "[data-test='approve-permission']")
        refute has_element?(view, "[data-test='permission-resolved']")
        {:ok, context}
      end
    end
  end
end
