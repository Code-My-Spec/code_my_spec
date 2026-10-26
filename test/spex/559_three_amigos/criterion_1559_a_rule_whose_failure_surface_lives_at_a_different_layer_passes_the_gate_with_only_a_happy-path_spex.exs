defmodule CodeMySpecSpex.Story559.Criterion167Spex do
  @moduledoc """
  Story 559 — Three Amigos.
  Criterion 167 — A rule with no genuine failure path at this layer passes
  the readiness gate with one happy-path scenario.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "a rule with only a genuine happy path satisfies readiness", criterion: 167 do
    scenario "the agent seals a story without manufacturing a failure scenario" do
      given_ :persona_exists

      given_ "one rule has only its happy-path scenario", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        assigns = Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        statement = "The project title appears on the summary page"

        rule_response =
          ToolLibrary.run(
            "add_rule",
            %{story_number: context.story.number, statement: statement},
            assigns
          )

        refute rule_response.isError

        scenario_response =
          ToolLibrary.run(
            "add_scenario",
            %{
              story_number: context.story.number,
              rule_statement: statement,
              title: "Sam sees the project title",
              kind: "happy_path",
              body: "Given Sam opens the project summary\nWhen the summary loads\nThen the project title is shown"
            },
            assigns
          )

        refute scenario_response.isError
        {:ok, context}
      end

      given_ :three_amigos_task_started

      when_ "the agent evaluates the Three Amigos task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the rule's one scenario is sufficient and the task passes", context do
        refute context.evaluate_response.isError

        assert response_text(context.evaluate_response) =~ ~r/passed|complete/i,
               "expected readiness to accept one happy-path scenario for this rule"

        {:ok, context}
      end
    end
  end
end
