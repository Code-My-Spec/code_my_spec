defmodule CodeMySpecSpex.Story1158.Criterion2470Spex do
  @moduledoc """
  Story 1158 — QA plans and briefs are documents in the database, not files in the docs submodule.
  Criterion 2470 — A plan file written after the import changes nothing.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Qa.DocumentImporter
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A post-import plan file cannot replace the QA plan document", criterion: 2470 do
    scenario "QA continues reading the imported document after a stray file is written" do
      given_ "the QA plan file has been imported and deleted", context do
        path = ".code_my_spec/qa/plan.md"

        assert :ok =
                 ExecutionContexts.write_file(context.execution_context, path, imported_plan())

        assert match?({:ok, _}, DocumentImporter.import(context.scope, context.execution_context))
        refute ExecutionContexts.file_exists?(context.execution_context, path)

        {:ok, Map.put(context, :plan_path, path)}
      end

      when_ "someone writes a new plan file under .code_my_spec/qa", context do
        assert :ok =
                 ExecutionContexts.write_file(
                   context.execution_context,
                   context.plan_path,
                   stray_plan()
                 )

        {:ok, context}
      end

      then_ "the QA plan document is unchanged and QA agents still read it", context do
        qa_scope = Fixtures.live_agent_scope(context.scope, label: "Later QA attempt")

        response =
          ToolLibrary.run(
            "read_document",
            %{document_type: "qa_plan"},
            %{current_scope: qa_scope, scope: qa_scope}
          )

        refute response.isError, response_text(response)
        assert response_text(response) =~ "Imported plan marker"
        refute response_text(response) =~ "Stray file marker"
        {:ok, context}
      end
    end
  end

  defp imported_plan do
    """
    # QA Plan

    ## App Overview

    Imported plan marker: exercise authenticated journeys.

    ## Tools Registry

    Use the browser tool to exercise the running application.

    ## Seed Strategy

    Seed a QA account and an example project.
    """
  end

  defp stray_plan do
    String.replace(imported_plan(), "Imported plan marker", "Stray file marker")
  end
end
