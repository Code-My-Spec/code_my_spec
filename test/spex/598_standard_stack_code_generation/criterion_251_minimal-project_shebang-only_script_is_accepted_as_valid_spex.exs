defmodule CodeMySpecSpex.Story598.Criterion5302Spex do
  @moduledoc """
  Story 598 — Standard stack code generation
  Criterion 5302 — Minimal-project shebang-only script is accepted as valid.

  A `code_generation.sh` containing only a shebang and a "no generators
  needed" comment satisfies the path_exists check — minimal-project
  happy path.

  Surface: `evaluate_task` MCP tool against `code_generation`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The generation script is the durable artifact", criterion: 251 do
    scenario "Minimal-project shebang-only script is accepted as valid" do
      given_ "the env is reset and a baseline project is in place", context do
        Fixtures.reset_setup_env(context.execution_context)
        Fixtures.with_baseline_project(context.execution_context)
        {:ok, context}
      end

      given_ :code_generation_task_started

      given_ "this copy reads the fixture's in-memory files", context do
        {:ok, HarnessHooks.serve_in_memory(context)}
      end

      given_ "code_generation.sh contains only a shebang and a no-generators comment",
             context do
        Fixtures.with_empty_script(context.execution_context)

        body = Fixtures.read_script(context.execution_context)
        assert body =~ "#!/bin/bash", "expected the shebang line"
        assert body =~ "No generators needed", "expected the empty-marker comment"

        {:ok, context}
      end

      when_ "the agent calls evaluate_task for the code_generation task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
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
  end
end
