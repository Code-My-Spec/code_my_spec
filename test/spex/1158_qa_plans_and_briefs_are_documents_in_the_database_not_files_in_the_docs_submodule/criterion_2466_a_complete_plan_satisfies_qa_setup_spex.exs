defmodule CodeMySpecSpex.Story1158.Criterion2466Spex do
  @moduledoc """
  Story 1158 — QA plans and briefs are documents in the database, not files in the docs submodule.
  Criterion 2466 — A complete plan satisfies QA setup.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A valid QA plan document satisfies the project QA setup requirement", criterion: 2466 do
    scenario "the requirement graph checks a complete plan" do
      given_ "the project has a QA plan document passing the qa_plan document spec", context do
        response =
          ToolLibrary.run(
            "write_document",
            %{document_type: "qa_plan", content: valid_plan()},
            %{current_scope: context.scope, scope: context.scope}
          )

        refute match?({:error, _}, response), response_text(response)
        {:ok, context}
      end

      when_ "the requirement graph checks QA setup", context do
        response =
          ToolLibrary.run(
            "show_requirement",
            %{
              name: "qa_setup",
              entity_type: "project",
              entity_id: context.scope.active_project_id
            },
            %{current_scope: context.scope, scope: context.scope}
          )

        {:ok, Map.put(context, :requirement_response, response)}
      end

      then_ "QA setup is satisfied", context do
        refute match?({:error, _}, context.requirement_response),
               response_text(context.requirement_response)

        assert response_text(context.requirement_response) =~ "# qa_setup"
        assert response_text(context.requirement_response) =~ "**Status:** Satisfied"
        {:ok, context}
      end
    end
  end

  defp valid_plan do
    """
    # QA Plan

    ## App Overview

    Sign in before each QA journey.

    ## Tools Registry

    Use the browser tool for application journeys.

    ## Seed Strategy

    Seed a QA account before testing.
    """
  end
end
