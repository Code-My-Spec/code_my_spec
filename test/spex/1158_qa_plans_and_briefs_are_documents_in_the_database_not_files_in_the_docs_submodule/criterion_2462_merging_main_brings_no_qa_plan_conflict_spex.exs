defmodule CodeMySpecSpex.Story1158.Criterion2462Spex do
  @moduledoc """
  Story 1158 — QA plans and briefs are documents in the database.
  Criterion 2462 — Merging main brings no QA plan conflict.

  A real Git merge exercises the working-copy boundary. The plan change goes
  through the document tool while the branches diverge.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "a plan document change cannot conflict with a working copy's merge", criterion: 2462 do
    scenario "main changes after the copy branches" do
      given_ "a working copy branched from main before the QA plan changed", context do
        root = Fixtures.qa_plan_merge_repository()

        response =
          ToolLibrary.run(
            "write_document",
            %{document_type: "qa_plan", content: changed_plan()},
            %{current_scope: context.scope, scope: context.scope}
          )

        refute match?({:error, _}, response), response_text(response)
        Fixtures.qa_plan_merge_advance_main(root)
        {:ok, Map.put(context, :root, root)}
      end

      when_ "the working copy merges main", context do
        merge_output = Fixtures.qa_plan_merge_main(context.root)
        {:ok, Map.put(context, :merge_output, merge_output)}
      end

      then_ "the merge succeeds without a QA plan conflict", context do
        assert context.merge_output =~ "Merge made by"
        state = Fixtures.qa_plan_merge_state(context.root)
        assert state.unmerged == ""
        assert state.status == ""
        assert state.plan_files == ""

        response =
          ToolLibrary.run(
            "read_document",
            %{document_type: "qa_plan"},
            %{current_scope: context.scope, scope: context.scope}
          )

        refute match?({:error, _}, response), response_text(response)
        assert response_text(response) =~ "Sign in before testing."
        {:ok, context}
      end
    end
  end

  defp changed_plan do
    """
    # QA Plan

    ## App Overview

    Sign in before testing.

    ## Tools Registry

    Use a browser to exercise the application.

    ## Seed Strategy

    Seed a QA account.
    """
  end
end
