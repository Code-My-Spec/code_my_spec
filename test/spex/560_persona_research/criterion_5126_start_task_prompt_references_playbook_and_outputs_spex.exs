defmodule CodeMySpecSpex.Story560.Criterion5126Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5126 — When the agent opens a persona research task, the returned
  prompt references the knowledge base playbook and names the expected output
  paths.

  DRAFT. Depends on:
    - `personas_complete` node in `project_graph/0`.
    - `CodeMySpec.AgentTasks.PersonaResearch.command/2` producing a prompt
      that references `priv/knowledge/persona_research/` playbook files
      (overview.md, pm_intake.md, primary_research.md) and names the
      output paths under `.code_my_spec/personas/<slug>/`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent opens a persona research task" do
    scenario "prompt references the knowledge playbook and output artifact paths" do
      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for personas_complete", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "personas_complete",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the prompt references the knowledge playbook", context do
        body = response_text(context.response)

        # Anchor: verify we got a real persona research prompt before asserting specifics.
        assert body =~ "Persona Research",
               "expected prompt text to mention persona research"

        assert body =~ "persona_research/",
               "expected prompt to reference the knowledge playbook directory"

        assert body =~ "pm_intake.md",
               "expected prompt to name pm_intake.md as an intake reference"

        {:ok, context}
      end

      then_ "the prompt names the expected output paths", context do
        body = response_text(context.response)

        assert body =~ ".code_my_spec/personas/",
               "expected prompt to name the output directory"

        assert body =~ "summary.md",
               "expected prompt to name summary.md as an output artifact"

        assert body =~ "sources.md",
               "expected prompt to name sources.md as an output artifact"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
