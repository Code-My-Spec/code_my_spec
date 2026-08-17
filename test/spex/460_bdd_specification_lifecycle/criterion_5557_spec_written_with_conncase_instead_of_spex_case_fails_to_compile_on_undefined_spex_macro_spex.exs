defmodule CodeMySpecSpex.Story460.Criterion5557Spex do
  @moduledoc """
  Story 460 — BDD Specification Lifecycle
  Criterion 5557 — Spec written with `use <App>Web.ConnCase` instead
  of `use <App>Spex.Case` fails to compile on the undefined `spex`
  macro.

  When the agent writes a spec module that opens with
  `use <App>Web.ConnCase` and omits `use <App>Spex.Case`, calling
  the `spex` macro fails — `spex/2` is not in scope. The
  evaluator's compile step surfaces this as a needs-work diagnostic
  with the spec's file path and the offending line.

  Surface: `EvaluateTask` MCP tool.

  Mechanism: `validate_single_spec` AST-scans for `use <App>Spex.Case`.
  If absent, the spec is rejected without ever invoking the compiler —
  `mix compile` doesn't traverse `test/spex/`, so we can't rely on
  compile diagnostics to surface the mistake. The validator catches
  the rule violation with a specific feedback message that names the
  spec path and explains the required `use` line.
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

  spex "Spec using ConnCase (no SpexCase) → compile diagnostic on undefined `spex` macro" do
    scenario "ConnCase-only spec → evaluator surfaces undefined-spex compile error" do
      given_ :synced_liveview_component

      given_ "a story with one criterion is linked to the synced LiveView component", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.liveview_component.module_name,
            title: "ConnCase-instead-of-SpexCase story",
            description: "Used for the SpexCase-omission assertion.",
            acceptance_criteria: ["single acceptance criterion text"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ :bdd_task_started

      given_ "a spec file exists that uses ConnCase and omits SpexCase", context do
        [criterion] = context.story.criteria
        spec_path = Fixtures.spec_file_path(context.story, criterion)

        :ok =
          Environments.write_file(
            context.environment,
            spec_path,
            conncase_only_spec_content()
          )

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

      then_ "the response signals needs-work and names the missing SpexCase requirement",
            context do
        text = response_text(context.evaluate_response)
        [criterion] = context.story.criteria
        spec_path = Fixtures.spec_file_path(context.story, criterion)

        assert text =~ ~r/Needs work/i,
               "expected needs-work response, got: #{text}"

        assert text =~ "<App>Spex.Case",
               "expected feedback to name the required `<App>Spex.Case` template, got: #{text}"

        assert text =~ spec_path,
               "expected feedback to cite the spec path `#{spec_path}`, got: #{text}"

        assert text =~ "Criterion #{criterion.id}",
               "expected feedback to name criterion #{criterion.id}, got: #{text}"

        {:ok, context}
      end
    end
  end

  defp conncase_only_spec_content do
    """
    defmodule MyAppSpex.ConnCaseOnlySpex do
      # The agent forgot `use MyAppSpex.Case` and reached for the
      # familiar Phoenix `ConnCase` instead. The `spex` macro is
      # provided by SexySpex — without `use MyAppSpex.Case` (which
      # `use SexySpex`), `spex/2` is undefined.
      use MyAppWeb.ConnCase

      spex "feature" do
        scenario "happy path" do
          given_ "setup", _context do
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
