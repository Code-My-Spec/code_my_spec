defmodule CodeMySpecSpex.Story858.Criterion7306Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7306 — Opting out of prod completes setup UAT-only.

  Prod is default-on but optional: with the project configured to skip
  prod, the devops_setup prompt plans UAT only and the graph never
  demands a prod environment.

  Surface: project configuration (bridge) + `start_task` MCP tool.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Opting out of prod completes setup UAT-only" do
    scenario "with prod opted out, the setup plan is UAT-only" do
      given_ "Sam has set the DevOps level to UAT-only in project configuration", context do
        {:ok, _config} = Fixtures.update_project_configuration(context.scope, %{devops: :uat})
        {:ok, context}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the devops_setup task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "devops_setup",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the plan covers UAT and omits prod", context do
        assert context.prompt =~ ~r/\buat\b/i, "expected the UAT environment in the plan"

        refute context.prompt =~ ~r/deploy .*\bprod(uction)?\b|prod(uction)? environment/i,
               "expected no prod environment demanded after opting out"

        {:ok, context}
      end
    end
  end
end
