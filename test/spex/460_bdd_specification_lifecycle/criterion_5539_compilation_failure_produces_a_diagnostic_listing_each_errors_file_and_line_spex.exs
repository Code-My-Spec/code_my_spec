defmodule CodeMySpecSpex.Story460.Criterion5539Spex do
  @moduledoc """
  Story 460 — BDD Specification Lifecycle
  Criterion 5539 — Compilation failure produces a diagnostic listing
  each error's file and line.

  When `evaluate_task` runs against a write_bdd_specs task whose story
  has a syntactically broken spec file, the evaluator returns
  "needs work" with feedback that begins with "Compilation failed"
  and names the offending file path and line number.

  Surface: `EvaluateTask` MCP tool. The compile check happens
  in-process via `Code.string_to_quoted/2` against the spec file's
  source — no `mix compile` shellout, no real-project fixture, no
  cassette. Operates entirely on the in-memory environment.
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

  spex "Compile failure → 'Compilation failed' feedback with file:line" do
    scenario "syntactically broken spec → diagnostic surfaces with file and line" do
      given_ :synced_context_component

      given_ "a story with one criterion is linked to the synced component", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Compile-error evaluation story",
            description: "Used for the compile-diagnostic assertion.",
            acceptance_criteria: ["single acceptance criterion text"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ :bdd_task_started

      given_ "a syntactically broken spec file is staged in the env", context do
        [criterion] = context.story.criteria
        spec_path = Fixtures.spec_file_path(context.story, criterion)
        :ok = Environments.write_file(context.environment, spec_path, broken_spec_content())

        {:ok, Map.put(context, :spec_path, spec_path)}
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

      then_ "the response signals needs-work with 'Compilation failed' + file:line",
            context do
        text = response_text(context.evaluate_response)

        assert text =~ ~r/Needs work/i,
               "expected needs-work response, got: #{text}"

        assert text =~ "Compilation failed",
               "expected feedback to include 'Compilation failed', got: #{text}"

        # Diagnostic format: `  <spec_path>:<line>: <message>`
        line_pattern = Regex.compile!(Regex.escape(context.spec_path) <> ~S":\d+:")

        assert text =~ line_pattern,
               "expected diagnostic to include `#{context.spec_path}:<line>:`, got: #{text}"

        {:ok, context}
      end
    end
  end

  # Missing the closing `end` for the `do` block on line 3 — `Code.string_to_quoted/2`
  # rejects this with a `TokenMissingError` whose meta carries `line:`.
  defp broken_spec_content do
    """
    defmodule MyAppSpex.BrokenSpex do
      use MyAppSpex.Case

      spex "broken feature" do
        scenario "missing end" do
          given_ "setup", _context do
            :ok
          end
    end
    """
  end

end
