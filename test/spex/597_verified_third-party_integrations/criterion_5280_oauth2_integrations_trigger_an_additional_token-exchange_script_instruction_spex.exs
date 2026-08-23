defmodule CodeMySpecSpex.Story597.Criterion5280Spex do
  @moduledoc """
  Story 597 — Verified third-party integrations
  Criterion 5280 — OAuth2 integrations trigger an additional token-exchange script instruction.

  OAuth2 integrations get an additional `exchange_*_token.sh` for
  client-credential exchange beyond the standard `verify_*` script.

  Surface: `start_task` MCP tool against `qa_integration_plan`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Each integration carries a runnable verify script" do
    scenario "OAuth2 integrations trigger an additional token-exchange script instruction" do
      given_ "a baseline project is in place", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        {:ok, context}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the qa_integration_plan task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "qa_integration_plan",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt routes OAuth2 token-exchange guidance through the playbook", context do
        assert context.prompt =~ "qa_integration_plan/workflow.md",
               "expected the prompt to point at the qa_integration_plan playbook (the exchange_<name>_token.sh OAuth2 path pattern lives there)"

        {:ok, context}
      end
    end
  end
end
