defmodule CodeMySpecSpex.Story858.Criterion7305Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7305 — Default setup ends with UAT and prod live.

  With the defaults accepted, devops_setup stands up BOTH environments —
  uat.<domain> and <domain> serving the app — before the requirement
  reads satisfied. The task prompt demands both environments and their
  live verification.

  Surface: `start_task` MCP tool against `devops_setup`.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Default setup ends with UAT and prod live" do
    scenario "the default prompt demands both environments live" do
      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the devops_setup task with defaults", context do
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

      then_ "the prompt stands up both UAT and prod", context do
        assert context.prompt =~ ~r/\buat\b/i, "expected the UAT environment in the default plan"
        assert context.prompt =~ ~r/\bprod(uction)?\b/i, "expected the prod environment in the default plan"

        {:ok, context}
      end

      and_ "completion is gated on both environments actually serving", context do
        assert context.prompt =~ ~r/health/i,
               "expected completion to be verified against live health checks"

        {:ok, context}
      end
    end
  end
end
