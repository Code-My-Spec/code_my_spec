defmodule CodeMySpecSpex.Story80.Criterion5274Spex do
  @moduledoc """
  Story 80 — Architecture Decision Records
  Criterion 5274 — Prompt lays out identify, research, ADR, update index, stop.

  The start_task prompt walks the agent through identifying topics,
  writing ADRs under the decisions directory, updating the decisions
  index, and stopping when the work is complete.

  Surface: `start_task` MCP tool against the `technical_strategy`
  requirement.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Prompt walks the agent through identify, research, ADR, index, stop" do
    scenario "start_task prompt names each workflow step explicitly" do
      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the technical_strategy task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "technical_strategy",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt instructs the agent to identify topics needing decisions", context do
        # Anchor: we really got the technical strategy prompt, not an error
        # or the wrong task's prompt.
        assert context.prompt =~ "Technical Strategy",
               "expected the prompt to be the technical strategy prompt"

        assert context.prompt =~ ~r/priv\/knowledge\/technical_strategy\/workflow\.md/,
               "expected the prompt to reference the technical_strategy workflow playbook " <>
                 "(which covers identifying topics, research, ADR writing, index update)"

        {:ok, context}
      end

      and_ "the prompt instructs the agent to write ADRs under the decisions directory",
           context do
        assert context.prompt =~ ".code_my_spec/architecture/decisions/",
               "expected the decisions directory path to be named as the ADR destination"

        {:ok, context}
      end

      and_ "the prompt instructs the agent to update the decisions index", context do
        assert context.prompt =~ ".code_my_spec/architecture/decisions.md",
               "expected the decisions index path to be named as the update target"

        {:ok, context}
      end

      and_ "the prompt instructs the agent to stop after completing the work", context do
        assert context.prompt =~ ~r/stop/i,
               "expected the prompt to instruct the agent to stop when done"

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
