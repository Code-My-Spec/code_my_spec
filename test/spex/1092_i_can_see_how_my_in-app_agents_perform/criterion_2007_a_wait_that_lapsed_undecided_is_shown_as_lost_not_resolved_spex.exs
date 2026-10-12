defmodule CodeMySpecSpex.Story1092.Criterion2007Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2007 -- A wait that lapsed undecided is shown as lost, not
  resolved.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A tap-out nobody ever decided is shown as a lapsed decision, not a resolved one",
    criterion: 2007 do
    scenario "a tap-out that expired with nobody deciding it" do
      given_ "a tap-out aged well past any recovery window, still undecided", context do
        reply = join_working_copy(context, "/tmp/spex-2007", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}
        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2007")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, tapped, _frame} =
          TapOut.execute(%{reason: "this task's own premise never held"}, asking)

        refute tapped.isError, inspect(tapped)
        [_, permission_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(tapped))

        :ok = Fixtures.age_permission(scope, permission_id, 86_400)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "blocked time is shown", context do
        {:ok, index, _html} = live(context.conn, index_path(context))
        html = render_async(index)
        {:ok, Map.put(context, :html, html)}
      end

      then_ "it counts as a lapsed decision", context do
        assert context.html =~ "lapsed",
               "a tap-out that expired undecided is not shown as a lapsed decision"

        {:ok, context}
      end

      then_ "and the time it waited is included", context do
        assert context.html =~ "24h" or context.html =~ "1d",
               "the full day the tap-out waited before lapsing is not reflected in blocked time"

        {:ok, context}
      end
    end
  end
end
