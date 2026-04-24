defmodule CodeMySpecSpex.Story80.Rule5ValidationGatesOnIndexSpex do
  @moduledoc """
  Story 80 — Architecture Decision Records
  Rule 5 — Validation gates on the decisions index.

  The technical_strategy requirement uses a `:path_exists` check on
  `.code_my_spec/architecture/decisions.md`. After start_task has run,
  the agent is expected to finalize the index file before calling
  evaluate_task. This rule covers both branches through the evaluate
  boundary:

  - Index present → the tool response signals pass.
  - Index missing → the tool response signals needs-work and the
    feedback references the expected path so the agent knows what
    to fix.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Validation gates on the decisions index" do
    scenario "Evaluate passes when the decisions index exists" do
      given_ "the env is reset for this scenario", context do
        Fixtures.reset_setup_env(context.environment)
        {:ok, context}
      end

      given_ :technical_strategy_task_started

      given_ "the decisions index file exists", context do
        Fixtures.with_decisions_index(context.environment)
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

      then_ "the tool response indicates the task passed", context do
        body = response_text(context.response)

        refute body =~ ~r/needs work|incomplete/i,
               "expected a passing response, not a needs-work response"

        assert body =~ ~r/passed|completed|satisfied|valid/i,
               "expected the response to signal that the task passed"

        :ok
      end
    end

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
