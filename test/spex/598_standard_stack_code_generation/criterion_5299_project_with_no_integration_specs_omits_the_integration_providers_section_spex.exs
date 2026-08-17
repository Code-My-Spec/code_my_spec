defmodule CodeMySpecSpex.Story598.Criterion5299Spex do
  @moduledoc """
  Story 598 — Standard stack code generation
  Criterion 5299 — Project with no integration specs omits the Integration Providers section.

  When `.code_my_spec/integrations/` has no spec files, the prompt
  omits the Integration Providers section header.

  Surface: `start_task` MCP tool against `code_generation`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Integration providers come from the integrations directory" do
    scenario "Project with no integration specs omits the Integration Providers section" do
      given_ "the project has no integration specs on disk", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        {:ok, context}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the code_generation task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "code_generation",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the Integration Providers section is absent from the prompt", context do
        # "Integration Providers" also appears in Step 2's instruction
        # heading. Refute the `## ` section-header form so this assertion
        # only catches the conditional providers section.
        refute context.prompt =~ "## Integration Providers",
               "expected the Integration Providers section header to be omitted"

        {:ok, context}
      end
    end
  end
end
