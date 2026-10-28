defmodule CodeMySpecSpex.Story1158.Criterion2471Spex do
  @moduledoc """
  Story 1158, criterion 2471: a stray QA plan file cannot block QA setup.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Requirements.QaDocumentImporter
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "A bad heading in a stray plan file blocks nothing", criterion: 2471 do
    scenario "QA setup and story QA remain available on both copies" do
      given_ "the QA plan has been imported as a document", context do
        :ok = CodeMySpecSpex.ProjectStateFixtures.delete_qa_document(context.scope, "qa_plan")

        path = ".code_my_spec/qa/plan.md"
        assert :ok = ExecutionContexts.write_file(context.execution_context, path, valid_plan())

        assert match?(
                 {:ok, _},
                 QaDocumentImporter.import(context.scope, context.execution_context)
               )

        refute ExecutionContexts.file_exists?(context.execution_context, path)
        other_scope = Fixtures.live_agent_scope(context.scope, label: "Second QA copy")
        {:ok, Map.merge(context, %{plan_path: path, other_scope: other_scope})}
      end

      when_ "a plan file with a forbidden heading appears on one copy", context do
        assert :ok =
                 ExecutionContexts.write_file(
                   context.execution_context,
                   context.plan_path,
                   bad_plan()
                 )

        {:ok, context}
      end

      then_ "QA setup stays satisfied and the story QA requirement stays available on both copies",
            context do
        for scope <- [context.scope, context.other_scope] do
          frame = %{current_scope: scope, scope: scope}
          plan = ToolLibrary.run("read_document", %{document_type: "qa_plan"}, frame)
          refute match?({:error, _}, plan), response_text(plan)
          refute response_text(plan) =~ "Provisioning agents on a candidate"

          setup =
            ToolLibrary.run(
              "show_requirement",
              %{name: "qa_setup", entity_type: "project", entity_id: scope.active_project_id},
              frame
            )

          refute match?({:error, _}, setup), response_text(setup)
          assert response_text(setup) =~ "**Status:** Satisfied"

          qa =
            ToolLibrary.run(
              "show_requirement",
              %{
                name: "qa_complete",
                entity_type: "story",
                entity_id: to_string(context.story.number)
              },
              frame
            )

          refute match?({:error, _}, qa), response_text(qa)
          refute response_text(qa) =~ "qa_setup is not satisfied"
        end

        {:ok, context}
      end
    end
  end

  defp valid_plan do
    """
    # QA Plan

    ## App Overview

    Run authenticated journeys.

    ## Tools Registry

    Use the browser tool.

    ## Seed Strategy

    Seed a QA account.
    """
  end

  defp bad_plan do
    String.replace(
      valid_plan(),
      "## Seed Strategy",
      "## Provisioning agents on a candidate\n\nBad heading.\n\n## Seed Strategy"
    )
  end
end
