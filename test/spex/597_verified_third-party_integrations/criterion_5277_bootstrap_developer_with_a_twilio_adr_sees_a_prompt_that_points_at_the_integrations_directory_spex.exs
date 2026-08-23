defmodule CodeMySpecSpex.Story597.Criterion5277Spex do
  @moduledoc """
  Story 597 — Verified third-party integrations
  Criterion 5277 — Bootstrap developer with a Twilio ADR sees a prompt that points at the integrations directory.

  Integration specs are derived from technical decisions: a Twilio ADR
  on disk produces a prompt that names the integrations directory,
  instructs writing one spec per service, and surfaces twilio under
  Technical Decisions.

  Surface: `start_task` MCP tool against `qa_integration_plan`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Integration specs are derived from technical decisions" do
    scenario "Bootstrap developer with a Twilio ADR sees a prompt that points at the integrations directory" do
      given_ "a Twilio decision record is on disk", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        Fixtures.with_decision_for_service(context.environment, "twilio")
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

      then_ "the prompt names the integrations directory as the spec destination", context do
        assert context.prompt =~ ".code_my_spec/integrations/",
               "expected the prompt to name the integrations directory"

        {:ok, context}
      end

      and_ "the prompt instructs writing one integration spec per third-party service",
           context do
        assert context.prompt =~ ~r/integration spec/i,
               "expected the prompt to reference integration specs"

        assert context.prompt =~ "qa_integration_plan/workflow.md",
               "expected the prompt to point at the qa_integration_plan playbook (per-service spec procedure lives there)"

        {:ok, context}
      end

      and_ "the prompt surfaces twilio under Technical Decisions", context do
        assert context.prompt =~ "Technical Decisions",
               "expected a Technical Decisions section header"

        assert context.prompt =~ "twilio",
               "expected twilio to be named in the prompt"

        {:ok, context}
      end
    end
  end
end
