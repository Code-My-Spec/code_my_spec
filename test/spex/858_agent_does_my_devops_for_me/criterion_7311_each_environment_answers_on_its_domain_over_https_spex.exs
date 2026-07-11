defmodule CodeMySpecSpex.Story858.Criterion7311Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7311 — Each environment answers on its domain over HTTPS.

  Every environment devops_setup stands up must answer on its own
  domain with automatic TLS and a passing health check — no manual
  certificate work anywhere in the plan.

  Surface: `start_task` MCP tool against `devops_setup`.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Each environment answers on its domain over HTTPS" do
    scenario "the setup prompt demands per-domain TLS and health verification" do
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

      then_ "each environment gets its own domain with automatic TLS", context do
        assert context.prompt =~ ~r/TLS|HTTPS|certificate/i,
               "expected TLS in the environment contract"

        refute context.prompt =~ ~r/manual(ly)? .*(certificate|cert\b)/i,
               "expected no manual certificate work in the plan"

        {:ok, context}
      end

      and_ "setup verifies each environment's health check answers", context do
        assert context.prompt =~ ~r|/health|,
               "expected a /health endpoint verification per environment"

        {:ok, context}
      end
    end
  end
end
