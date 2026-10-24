defmodule CodeMySpecSpex.Story460.Criterion5531Spex do
  @moduledoc """
  Story 460 — BDD Specification Lifecycle
  Criterion 5531 — Missing spec file is reported with the criterion id
  and expected path.

  When `evaluate_task` runs against a write_bdd_specs task whose story
  has three criteria but only two spec files exist in the env, the
  evaluator returns "needs work" and the feedback names the missing
  criterion's id, description, and expected file path.

  Surface: `EvaluateTask` MCP tool. `:synced_context_component` writes
  the component into the env via the sync UI; `StoryHelpers` drives
  the `CreateStory` and `SetStoryComponent` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Missing spec file → evaluate feedback names the missing criterion", criterion: 94 do
    scenario "two of three criteria have spec files → feedback identifies the third" do
      given_ :synced_context_component

      given_ "a story with three criteria is linked to the synced component", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Missing spec evaluation story",
            description: "Used for the missing-spec assertion.",
            acceptance_criteria: [
              "first acceptance criterion text",
              "second acceptance criterion text",
              "third acceptance criterion text"
            ]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ :bdd_task_started

      given_ "spec files exist for the first two criteria but not the third", context do
        [c1, c2, _c3] = context.story.criteria

        for criterion <- [c1, c2] do
          spec_path = Fixtures.spec_file_path(context.story, criterion)

          :ok =
            ExecutionContexts.write_file(
              context.execution_context,
              spec_path,
              valid_spec_content(criterion.id)
            )
        end

        Fixtures.deliver_manifest(context.scope)
        {:ok, context}
      end

      when_ "the agent calls evaluate_task on the active task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the response signals needs-work and names the missing criterion + path",
            context do
        text = response_text(context.evaluate_response)
        [_c1, _c2, c3] = context.story.criteria

        assert text =~ ~r/Needs work/i,
               "expected needs-work response, got: #{text}"

        assert text =~ "No valid spec names it",
               "expected feedback to say no spec names the criterion, got: #{text}"

        assert text =~ "Criterion #{c3.id}",
               "expected feedback to name criterion #{c3.id}, got: #{text}"

        assert text =~ c3.description,
               "expected feedback to include criterion description, got: #{text}"

        assert text =~ "criterion: #{c3.id}",
               "expected feedback to give the `criterion: #{c3.id}` line to add, got: #{text}"

        {:ok, context}
      end
    end
  end

  defp valid_spec_content(number) do
    """
    defmodule MyAppSpex.ExampleSpex do
      use MyAppSpex.Case

      spex "example feature", criterion: #{number} do
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
