defmodule CodeMySpecSpex.CodeGeneration.Rule5ValidationGatesOnScriptSpex do
  @moduledoc """
  Story: Standard stack code generation
  Rule 5 — The generation script is the durable artifact.

  The `code_generation` requirement uses a `:path_exists` check on
  `.code_my_spec/tasks/code_generation.sh`. After start_task runs,
  the agent records every command and writes the script. evaluate_task
  passes when the script exists, regardless of length — even a
  shebang-only "no generators needed" script counts as valid.

  Three branches:
  - Full script with recorded generator commands → pass.
  - Shebang-only script (minimal-project happy path) → pass.
  - Missing script → needs-work feedback names the expected path.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The generation script is the durable artifact" do
    scenario "Non-empty generation script passes evaluation" do
      given_ "the env is reset and a baseline project is in place", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        {:ok, context}
      end

      given_ :code_generation_task_started

      given_ "code_generation.sh records every generator command", context do
        Fixtures.with_full_script(context.environment)

        assert Fixtures.script_exists?(context.environment),
               "expected the full generation script to be written"

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

      then_ "the tool response indicates the task passed", context do
        body = response_text(context.response)

        refute body =~ ~r/needs work|incomplete/i,
               "expected a passing response, not a needs-work response"

        assert body =~ ~r/passed|completed|satisfied|valid/i,
               "expected the response to signal that the task passed"

        {:ok, context}
      end
    end

    scenario "Minimal-project shebang-only script is accepted as valid" do
      given_ "the env is reset and a baseline project is in place", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        {:ok, context}
      end

      given_ :code_generation_task_started

      given_ "code_generation.sh contains only a shebang and a no-generators comment",
             context do
        Fixtures.with_empty_script(context.environment)

        body = Fixtures.read_script(context.environment)
        assert body =~ "#!/bin/bash", "expected the shebang line"
        assert body =~ "No generators needed", "expected the empty-marker comment"

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

      then_ "the tool response indicates the task passed", context do
        body = response_text(context.response)

        refute body =~ ~r/needs work|incomplete/i,
               "expected a passing response, not a needs-work response"

        assert body =~ ~r/passed|completed|satisfied|valid/i,
               "expected the shebang-only script to satisfy the path_exists check"

        {:ok, context}
      end
    end

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
