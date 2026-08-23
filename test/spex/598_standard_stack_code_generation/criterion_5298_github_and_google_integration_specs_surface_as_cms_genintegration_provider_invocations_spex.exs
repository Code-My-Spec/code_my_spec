defmodule CodeMySpecSpex.Story598.Criterion5298Spex do
  @moduledoc """
  Story 598 — Standard stack code generation
  Criterion 5298 — github and google integration specs surface as cms_gen.integration_provider invocations.

  Two integration specs in `.code_my_spec/integrations/` surface as
  cms_gen.integration_provider invocations in the prompt — one named
  per provider plus the generator command instruction.

  Surface: `start_task` MCP tool against `code_generation`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Integration providers come from the integrations directory" do
    scenario "github and google integration specs surface as cms_gen.integration_provider invocations" do
      given_ "integration specs exist for github and google", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        Fixtures.with_integration_specs(context.environment, ["github", "google"])
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

      then_ "the prompt names github and google as providers to scaffold", context do
        assert context.prompt =~ "## Integration Providers",
               "expected the Integration Providers section header"

        assert context.prompt =~ "`github`",
               "expected github to be listed as a provider"

        assert context.prompt =~ "`google`",
               "expected google to be listed as a provider"

        {:ok, context}
      end

      and_ "the prompt instructs the agent to run cms_gen.integration_provider for each",
           context do
        assert context.prompt =~ "mix cms_gen.integration_provider",
               "expected the prompt to mention the cms_gen.integration_provider command"

        {:ok, context}
      end
    end
  end
end
