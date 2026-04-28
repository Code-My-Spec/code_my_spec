defmodule CodeMySpecSpex.Story460.Criterion5536Spex do
  @moduledoc """
  Story 460 — BDD Specification Lifecycle
  Criterion 5536 — Specs that exist, parse, have scenarios with steps,
  and compile return :valid.

  When `evaluate_task` runs against a write_bdd_specs task whose
  story's spec files all exist (in the env), parse, contain at least
  one scenario with at least one Given/When/Then step, and the
  project compiles (or compilation is skipped because no mix.exs is
  staged), the response signals pass — the task is marked completed.

  Surface: `EvaluateTask` MCP tool. Memory environment with no mix.exs
  → validate_compilation short-circuits to :valid (see
  `WriteBddSpecs.validate_compilation/1`), so this spec exercises
  the file/parse/scenario branches cleanly.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Valid spec set across all criteria → evaluate_task passes" do
    scenario "every criterion has a valid spec file → evaluator returns pass response" do
      given_ :synced_context_component

      given_ "a story with two criteria is linked to the synced component", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Valid spec evaluation story",
            description: "Used for the evaluator-pass assertion.",
            acceptance_criteria: [
              "first acceptance criterion text",
              "second acceptance criterion text"
            ]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ :bdd_task_started

      given_ "valid spec files have been written in the env for every criterion", context do
        for criterion <- context.story.criteria do
          spec_path = Fixtures.spec_file_path(context.story, criterion)
          :ok = Environments.write_file(context.environment, spec_path, valid_spec_content())
        end

        {:ok, context}
      end

      when_ "the agent calls evaluate_task on the active task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the response signals pass for the WriteBddSpecs task", context do
        text = response_text(context.evaluate_response)

        assert text =~ ~r/WriteBddSpecs: Passed/i,
               "expected pass response, got: #{text}"

        refute text =~ ~r/Needs work|Spec file not found|Compilation failed/,
               "pass response should not include failure feedback, got: #{text}"

        {:ok, context}
      end
    end
  end

  defp valid_spec_content do
    """
    defmodule MyAppSpex.ExampleSpex do
      use MyAppSpex.Case

      spex "example feature" do
        scenario "happy path" do
          given_ "setup", _context do
            :ok
          end

          when_ "action", _context do
            :ok
          end

          then_ "assertion", _context do
            assert true
            :ok
          end
        end
      end
    end
    """
  end

end
