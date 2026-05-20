defmodule CodeMySpecSpex.Story598.Criterion5304Spex do
  @moduledoc """
  Story 598 — Standard stack code generation
  Criterion 5304 — Prompt instructs the agent to rewrite the script from currently-detected state.

  The prompt uses "rewrite" wording and references the currently-detected
  project state — explicitly NOT instructing the agent to append commands
  to an existing script.

  Surface: `start_task` MCP tool against `code_generation`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Retrofit script is rewritten from the currently-detected state" do
    scenario "Prompt instructs the agent to rewrite the script from currently-detected state" do
      given_ "the project has a baseline mix.exs and no existing script", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
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

      then_ "the prompt routes the agent to the script-format playbook (which covers rewrite-from-current-state)",
            context do
        # The "rewrite from currently-detected state" guidance lives in
        # priv/knowledge/cms_generators/script-format.md ("Rewrite, don't
        # append"). The prompt routes the agent to that playbook rather
        # than inlining the guidance.
        assert context.prompt =~ ~r/cms_generators\/(workflow|script-format)\.md/,
               "expected the prompt to reference the cms_generators playbook (workflow.md or script-format.md)"

        {:ok, context}
      end

      and_ "the prompt does not instruct the agent to append commands", context do
        refute context.prompt =~ ~r/append/i,
               "expected no 'append' wording — the playbook covers the rewrite-not-append rule"

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
