defmodule CodeMySpecSpex.Story598.Criterion5296Spex do
  @moduledoc """
  Story 598 — Standard stack code generation
  Criterion 5296 — Bare project produces a minimal prompt without optional sections.

  With only a baseline mix.exs (no ADRs, no script, no integrations),
  the prompt omits the Existing Generation Script and Integration
  Providers sections, and the Technical Decisions section indicates no
  decision records were found.

  Surface: `start_task` MCP tool against `code_generation`.
  """

  use CodeMySpecSpex.Case
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

      then_ "the prompt does not include an Existing Generation Script section",
            context do
        refute context.prompt =~ ~r/existing\s+generation\s+script/i,
               "expected the existing-script section to be absent"

        {:ok, context}
      end

      and_ "the prompt does not include an Integration Providers section", context do
        # The "Integration Providers" string also appears in Step 2's
        # instruction heading. Refute the section header form (`## `)
        # to scope the assertion correctly.
        refute context.prompt =~ ~r/##\s+Integration\s+Providers/i,
               "expected the Integration Providers section header to be absent"

        {:ok, context}
      end

      and_ "the Technical Decisions section indicates no decision records were found",
           context do
        assert context.prompt =~ ~r/no (ADRs|decision records|decisions) found/i,
               "expected the no-decisions phrasing when the decisions dir is empty"

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
