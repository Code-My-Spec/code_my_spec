defmodule CodeMySpecSpex.Story1158.Criterion2467Spex do
  @moduledoc """
  Story 1158 — QA plans and briefs are documents in the database, not files in the docs submodule.
  Criterion 2467 — A plan missing a required part names what is missing.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An absent QA plan document leaves QA setup unmet and explains the missing plan",
    criterion: 2467 do
    scenario "the requirement graph checks a project with no QA plan document" do
      given_ "the project has no QA plan document", context do
        response =
          ToolLibrary.run(
            "read_document",
            %{document_type: "qa_plan"},
            %{current_scope: context.scope, scope: context.scope}
          )

        assert response.isError, "expected the QA plan document to be absent"
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

      then_ "QA setup is unsatisfied and names the missing QA plan", context do
        refute context.requirement_response.isError, response_text(context.requirement_response)
        body = response_text(context.requirement_response)
        assert body =~ "# qa_setup"
        assert body =~ "**Status:** Not satisfied"
        assert body =~ "**Why:**"
        assert body =~ ~r/QA plan|qa_plan/i
        {:ok, context}
      end
    end
  end
end
