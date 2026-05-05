defmodule CodeMySpecSpex.Story559.Criterion5889Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5889 — When the agent calls `evaluate_task` on a Three
  Amigos task whose story has a linked persona but zero rules, the
  evaluation returns a needs-work response naming "No rules" as the
  failing readiness condition.

  Exercises the readiness gate's `rules > 0` clause via the public
  EvaluateTask MCP surface (manual-validation tasks don't auto-eval
  on the stop hook).

  Depends on:
    - `BddRulesChecker.complete?/2` ✓
    - `AgentTasks.ThreeAmigos.evaluate/2` ✓
    - `:three_amigos_task_started` shared given ✓
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "evaluate fails when story has a persona but no rules" do
    scenario "evaluate_task returns a needs-work response naming the missing rules" do
      given_ :persona_exists
      given_ :three_amigos_task_started

      when_ "the agent calls evaluate_task on the Three Amigos task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the response surfaces the missing-rules readiness failure", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/no rules/i,
               "expected response to name the missing-rules failure, got #{inspect(context.evaluate_response)}"

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
