defmodule CodeMySpecSpex.Story1158.Criterion2469Spex do
  @moduledoc """
  Story 1158 — QA plans and briefs are documents in the database, not files in the docs submodule.
  Criterion 2469 — The current QA files become documents and are deleted.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Requirements.QaDocumentImporter
  alias CodeMySpec.ToolLibrary

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "The one-time import moves QA files into documents", criterion: 2469 do
    scenario "the plan, journey and brief survive import while source files are removed" do
      given_ "the docs submodule contains the QA plan, journey plan and a story brief", context do
        for {type, number} <- [
              {"qa_plan", nil},
              {"qa_journey_plan", nil},
              {"qa_story_brief", context.story.number}
            ] do
          :ok =
            CodeMySpecSpex.ProjectStateFixtures.delete_qa_document(context.scope, type, number)
        end

        brief_path = ".code_my_spec/qa/#{context.story.number}/brief.md"

        files = [
          {".code_my_spec/qa/plan.md", qa_plan()},
          {".code_my_spec/qa/journey_plan.md", journey_plan()},
          {brief_path, story_brief()}
        ]

        Enum.each(files, fn {path, content} ->
          assert :ok = ExecutionContexts.write_file(context.execution_context, path, content)
        end)

        {:ok, Map.put(context, :source_paths, Enum.map(files, &elem(&1, 0)))}
      end

      when_ "the one-time QA document import runs", context do
        result = QaDocumentImporter.import(context.scope, context.execution_context)
        assert match?({:ok, _}, result), inspect(result)
        {:ok, Map.put(context, :import_report, elem(result, 1))}
      end

      then_ "the plan, journey and brief are documents and the source files are gone",
            context do
        plan = read_document(context.scope, %{document_type: "qa_plan"})
        assert plan =~ "attachment_fixtures"
        assert plan =~ "story 1148"

        journey = read_document(context.scope, %{document_type: "qa_journey_plan"})
        assert journey =~ "Sign-in journey"

        brief =
          read_document(context.scope, %{
            document_type: "qa_story_brief",
            story_number: context.story.number
          })

        assert brief =~ "Check sign-in"

        Enum.each(context.source_paths, fn path ->
          refute ExecutionContexts.file_exists?(context.execution_context, path), path
        end)

        assert context.import_report,
               "the import must return a report for any file it cannot place"

        {:ok, context}
      end
    end
  end

  defp read_document(scope, args) do
    response = ToolLibrary.run("read_document", args, %{current_scope: scope, scope: scope})
    refute match?({:error, _}, response), response_text(response)
    response_text(response)
  end

  defp qa_plan do
    """
    # QA Plan

    ## App Overview

    The project has QA journeys.

    ## Tools Registry

    Use the browser to exercise the running application. Request story 1148
    attachment_fixtures with the supplied run_script commands.

    ## Seed Strategy

    Seed a QA account and an example project.
    """
  end

  defp journey_plan do
    """
    # QA Journey Plan

    ## Journeys

    - Sign-in journey: log in as the seeded QA account.

    ## Prerequisites

    - Seed the QA account.
    """
  end

  defp story_brief do
    """
    # QA Story Brief

    ## Tool

    web

    ## Auth

    Sign in with the seeded QA account.

    ## Seeds

    Use the seeded project.

    ## What to Test

    - Check sign-in.

    ## Result Path

    .code_my_spec/qa/results.md
    """
  end
end
