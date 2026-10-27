defmodule CodeMySpecSpex.Story1158.Criterion2464Spex do
  @moduledoc """
  Story 1158 — QA plans and briefs are documents in the database, not files in the docs submodule.
  Criterion 2464 — Main reads the QA plan without a checkout.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Main reads the project QA plan with no attached working copy", criterion: 2464 do
    scenario "detached Main receives the plan markdown" do
      given_ "the project has a QA plan document and Main has no checkout", context do
        response =
          ToolLibrary.run(
            "write_document",
            %{document_type: "qa_plan", content: plan()},
            %{current_scope: context.scope, scope: context.scope}
          )

        refute response.isError, response_text(response)

        main_scope = %{context.scope | active_working_copy_id: nil}
        main = Fixtures.running_agent(main_scope, role: "main", execution_mode: :detached)
        assert is_nil(main_scope.active_working_copy_id)
        {:ok, Map.merge(context, %{main_scope: main_scope, main: main})}
      end

      when_ "Main reads the QA plan with the document tool", context do
        response =
          ToolLibrary.run(
            "read_document",
            %{document_type: "qa_plan"},
            %{
              current_scope: context.main_scope,
              scope: context.main_scope,
              agent_id: context.main.id
            }
          )

        {:ok, Map.put(context, :read_response, response)}
      end

      then_ "Main gets the plan markdown without attaching a copy", context do
        refute context.read_response.isError, response_text(context.read_response)
        assert response_text(context.read_response) =~ "Sign in before each QA journey."
        assert is_nil(context.main_scope.active_working_copy_id)
        {:ok, context}
      end
    end
  end

  defp plan do
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
