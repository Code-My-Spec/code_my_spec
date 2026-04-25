defmodule CodeMySpecSpex.CodeGeneration.Rule2PromptGroundedInStateSpex do
  @moduledoc """
  Story: Standard stack code generation
  Rule 2 — The prompt is grounded in real project state.

  CodeGeneration's prompt has four conditional sections —
  Technical Decisions, Integration Providers, Existing Generation
  Script, and the per-generator status list — each of which appears
  only when the corresponding state is on disk.

  Two ends of the spectrum:
  - Bare project: no ADRs, no script, no integrations.
  - Fully-populated project: ADRs, integration specs, and an
    existing script all present.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The prompt is grounded in real project state" do
    scenario "Bare project produces a minimal prompt without optional sections" do
      given_ "only a baseline mix.exs exists in the project", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)

        refute Fixtures.script_exists?(context.environment),
               "expected no existing generation script in the bare-project fixture"

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

      then_ "the prompt does not include an Existing Generation Script section",
            context do
        refute context.prompt =~ "Existing Generation Script",
               "expected the existing-script section to be absent"

        {:ok, context}
      end

      and_ "the prompt does not include an Integration Providers section", context do
        # The "Integration Providers" string also appears in Step 2's
        # instruction heading. Refute the section header form (`## `)
        # to scope the assertion correctly.
        refute context.prompt =~ "## Integration Providers",
               "expected the Integration Providers section header to be absent"

        {:ok, context}
      end

      and_ "the Technical Decisions section indicates no decision records were found",
           context do
        assert context.prompt =~ "No decision records found.",
               "expected the no-decisions phrasing when the decisions dir is empty"

        {:ok, context}
      end
    end

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
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
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
        assert context.prompt =~ "Existing Generation Script",
               "expected the Existing Generation Script section to be rendered"

        {:ok, context}
      end

      and_ "the prompt includes the Integration Providers section", context do
        assert context.prompt =~ "## Integration Providers",
               "expected the Integration Providers section header to be rendered"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
