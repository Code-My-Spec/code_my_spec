defmodule CodeMySpecSpex.Story1158.Criterion2472Spex do
  @moduledoc """
  Story 1158, criterion 2472: the journey plan document satisfies its requirement.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A QA agent writes the journey plan as a document", criterion: 2472 do
    scenario "a valid journey plan satisfies the requirement on every copy" do
      given_ "two working copies have no QA journey plan document", context do
        other_scope = Fixtures.live_agent_scope(context.scope, label: "Second QA copy")

        response =
          ToolLibrary.run("read_document", %{document_type: "qa_journey_plan"}, %{
            current_scope: context.scope,
            scope: context.scope
          })

        assert match?({:error, _}, response)
        {:ok, Map.put(context, :other_scope, other_scope)}
      end

      when_ "a QA agent writes a valid journey plan with the document tool", context do
        response =
          ToolLibrary.run(
            "write_document",
            %{document_type: "qa_journey_plan", content: journey_plan()},
            %{current_scope: context.scope, scope: context.scope}
          )

        refute match?({:error, _}, response), response_text(response)
        {:ok, context}
      end

      then_ "both copies have a satisfied journey plan requirement and no journey_plan.md file",
            context do
        for scope <- [context.scope, context.other_scope] do
          frame = %{current_scope: scope, scope: scope}
          plan = ToolLibrary.run("read_document", %{document_type: "qa_journey_plan"}, frame)
          refute match?({:error, _}, plan), response_text(plan)
          assert response_text(plan) =~ "Sign-in journey"

          requirement =
            ToolLibrary.run(
              "show_requirement",
              %{
                name: "qa_journey_plan",
                entity_type: "project",
                entity_id: scope.active_project_id
              },
              frame
            )

          refute match?({:error, _}, requirement), response_text(requirement)
          assert response_text(requirement) =~ "**Status:** Satisfied"
        end

        refute ExecutionContexts.file_exists?(
                 context.execution_context,
                 ".code_my_spec/qa/journey_plan.md"
               )

        {:ok, context}
      end
    end
  end

  defp journey_plan do
    """
    # QA Journey Plan

    ## Journeys

    - Sign-in journey: log in as the seeded QA account and visit the dashboard.

    ## Prerequisites

    - Seed the QA account.
    """
  end
end
