defmodule CodeMySpecSpex.Story80.Criterion5275Spex do
  @moduledoc """
  Story 80 — Architecture Decision Records
  Criterion 5275 — Evaluate passes when the decisions index exists.

  After start_task has run and the agent has finalized
  `.code_my_spec/architecture/decisions.md`, calling evaluate_task
  returns a passing response (path_exists checker satisfied).

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

        {:ok, context}
      end
    end
  end
end
