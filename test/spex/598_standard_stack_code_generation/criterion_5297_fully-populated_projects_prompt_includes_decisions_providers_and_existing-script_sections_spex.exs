defmodule CodeMySpecSpex.Story598.Criterion5297Spex do
  @moduledoc """
  Story 598 — Standard stack code generation
  Criterion 5297 — Fully-populated project's prompt includes decisions, providers, and existing-script sections.

  With ADRs, integration specs, and an existing script all present,
  the prompt's Technical Decisions, Integration Providers, and
  Existing Generation Script sections are all rendered.

  Surface: `start_task` MCP tool against `code_generation`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The prompt is grounded in real project state" do
    scenario "Fully-populated project's prompt includes decisions, providers, and existing-script sections" do
      given_ "the project has ADRs for elixir, phoenix, and pow-assent-integrations",
             context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)

        Fixtures.with_decisions(context.environment, [
          "elixir",
          "phoenix",
          "pow-assent-integrations"
        ])

        {:ok, context}
      end

      given_ "an existing code_generation.sh records prior generator runs", context do
        Fixtures.with_full_script(context.environment)
        {:ok, context}
      end

      given_ "integration specs exist for github and google", context do
        Fixtures.with_integration_specs(context.environment, ["github", "google"])
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

      then_ "the Technical Decisions section names every recorded ADR", context do
        assert context.prompt =~ "Technical Decisions",
               "expected the Technical Decisions section header"

        for topic <- ["elixir", "phoenix", "pow-assent-integrations"] do
          assert context.prompt =~ "`#{topic}`",
                 "expected ADR `#{topic}` to be listed"
        end

        {:ok, context}
      end

      and_ "the prompt includes the Existing Generation Script section", context do
        assert context.prompt =~ ~r/existing\s+generation\s+script/i,
               "expected the existing-script section to be rendered"

        {:ok, context}
      end

      and_ "the prompt includes the Integration Providers section", context do
        assert context.prompt =~ ~r/##\s+Integration\s+Providers/i,
               "expected the Integration Providers section header to be rendered"

        {:ok, context}
      end
    end
  end
end
