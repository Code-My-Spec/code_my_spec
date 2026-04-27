defmodule CodeMySpecSpex.Story80.Criterion5276Spex do
  @moduledoc """
  Story 80 — Architecture Decision Records
  Criterion 5276 — Missing decisions index yields needs-work feedback referencing the expected path.

  When the agent calls evaluate_task without the decisions index in
  place, the tool returns a needs-work response and the feedback names
  the expected `.code_my_spec/architecture/decisions.md` path so the
  agent knows what to fix.

  Surface: `evaluate_task` MCP tool against the `technical_strategy`
  requirement.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Validation gates on the decisions index" do
    scenario "Missing decisions index yields needs-work feedback referencing the expected path" do
      given_ "the env is reset for this scenario", context do
        Fixtures.reset_setup_env(context.environment)
        {:ok, context}
      end

      given_ :technical_strategy_task_started

      given_ "the decisions index file does NOT exist", context do
        refute CodeMySpec.Environments.file_exists?(
                 context.environment,
                 ".code_my_spec/architecture/decisions.md"
               ),
               "expected decisions.md to be absent — start_task does not write the index"

        {:ok, context}
      end

      when_ "the agent calls evaluate_task for the technical_strategy task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the tool response indicates the task needs more work", context do
        body = response_text(context.response)

        assert body =~ ~r/needs work|incomplete|missing|invalid/i,
               "expected a needs-work response when the index is missing"

        {:ok, context}
      end

      and_ "the feedback references the expected decisions.md path", context do
        body = response_text(context.response)

        assert body =~ ".code_my_spec/architecture/decisions.md",
               "expected the feedback to name the expected index path"

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
