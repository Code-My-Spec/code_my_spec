defmodule CodeMySpecSpex.Story598.Criterion5303Spex do
  @moduledoc """
  Story 598 — Standard stack code generation
  Criterion 5303 — Missing generation script yields needs-work feedback referencing the expected path.

  When `.code_my_spec/tasks/code_generation.sh` is absent, evaluate_task
  returns needs-work and the feedback names the expected path.

  Surface: `evaluate_task` MCP tool against `code_generation`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The generation script is the durable artifact" do
    scenario "Missing generation script yields needs-work feedback referencing the expected path" do
      given_ "the env is reset and a baseline project is in place", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        {:ok, context}
      end

      given_ :code_generation_task_started

      given_ "code_generation.sh does NOT exist", context do
        refute Fixtures.script_exists?(context.environment),
               "expected the generation script to be absent"

        {:ok, context}
      end

      when_ "the agent calls evaluate_task for the code_generation task", context do
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
               "expected a needs-work response when the script is missing"

        {:ok, context}
      end

      and_ "the feedback references the expected code_generation.sh path", context do
        body = response_text(context.response)

        assert body =~ ".code_my_spec/tasks/code_generation.sh",
               "expected the feedback to name the expected script path"

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
