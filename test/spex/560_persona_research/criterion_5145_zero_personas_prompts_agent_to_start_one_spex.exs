defmodule CodeMySpecSpex.Story560.Criterion5145Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5145 — Zero personas on the project prompts the agent to start
  one. With no personas linked, the checker returns a failure whose
  detail instructs the agent to start a persona research session.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "project has zero personas linked" do
    scenario "evaluate_task feedback directs the agent to start a persona" do
      given_ :persona_research_task_started

      when_ "the agent calls evaluate_task", context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CodeMySpec.McpServers.Tasks.Tools.EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the feedback instructs starting a persona research session", context do
        body = response_text(context.response)

        assert body =~ ~r/Needs work|incomplete|missing|no personas/i,
               "expected failure feedback for zero-personas project"

        assert body =~ ~r/start a persona|no personas/i,
               "expected feedback to direct starting a persona research session"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      o -> inspect(o)
    end)
  end

  defp response_text(other), do: inspect(other)
end
