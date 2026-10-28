defmodule CodeMySpecSpex.Story1158.Criterion2465Spex do
  @moduledoc """
  Story 1158 — QA plans and briefs are documents in the database, not files in the docs submodule.
  Criterion 2465 — A refused change leaves the plan in force.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A rejected QA plan edit preserves the valid document and QA setup", criterion: 2465 do
    scenario "an unknown heading is rejected without changing either copy's QA setup" do
      given_ "the project has a valid QA plan shared by two working copies", context do
        other_scope = Fixtures.live_agent_scope(context.scope, label: "QA plan reader")

        response =
          ToolLibrary.run(
            "write_document",
            %{document_type: "qa_plan", content: valid_plan()},
            %{current_scope: context.scope, scope: context.scope}
          )

        refute match?({:error, _}, response), response_text(response)
        {:ok, Map.put(context, :other_scope, other_scope)}
      end

      when_ "a QA agent submits a plan containing a forbidden heading", context do
        response =
          ToolLibrary.run(
            "write_document",
            %{document_type: "qa_plan", content: invalid_plan()},
            %{current_scope: context.scope, scope: context.scope}
          )

        {:ok, Map.put(context, :write_response, response)}
      end

      then_ "the document tool refuses the edit and names the heading", context do
        assert match?({:error, _}, context.write_response)

        assert String.downcase(response_text(context.write_response)) =~
                 "provisioning agents on a candidate"

        {:ok, context}
      end

      and_ "both copies still read the original plan and show QA setup satisfied", context do
        for scope <- [context.scope, context.other_scope] do
          tool_context = %{current_scope: scope, scope: scope}

          plan = ToolLibrary.run("read_document", %{document_type: "qa_plan"}, tool_context)
          refute match?({:error, _}, plan), response_text(plan)
          assert response_text(plan) =~ "Seed a QA account before testing."
          refute response_text(plan) =~ "Provisioning agents on a candidate"

          requirement =
            ToolLibrary.run(
              "show_requirement",
              %{name: "qa_setup", entity_type: "project", entity_id: scope.active_project_id},
              tool_context
            )

          refute match?({:error, _}, requirement), response_text(requirement)
          assert response_text(requirement) =~ "**Status:** Satisfied"
        end

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

  defp invalid_plan do
    String.replace(
      valid_plan(),
      "## Seed Strategy",
      "## Provisioning agents on a candidate\n\nDo not add this section.\n\n## Seed Strategy"
    )
  end
end
