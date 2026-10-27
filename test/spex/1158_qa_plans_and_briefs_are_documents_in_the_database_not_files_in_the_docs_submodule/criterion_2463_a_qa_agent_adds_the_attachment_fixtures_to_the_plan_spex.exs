defmodule CodeMySpecSpex.Story1158.Criterion2463Spex do
  @moduledoc """
  Story 1158 — QA plans and briefs are documents in the database, not files in the docs submodule.
  Criterion 2463 — A QA agent adds the attachment fixtures to the plan.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A QA agent shares attachment fixture instructions through the plan document",
    criterion: 2463 do
    scenario "another QA agent reads the newly added story 1148 fixtures" do
      given_ "the QA plan document lists no attachment fixtures", context do
        reader_scope = Fixtures.live_agent_scope(context.scope, label: "QA plan reader")

        response =
          ToolLibrary.run(
            "write_document",
            %{document_type: "qa_plan", content: plan_without_fixtures()},
            %{current_scope: context.scope, scope: context.scope}
          )

        refute response.isError, response_text(response)
        {:ok, Map.put(context, :reader_scope, reader_scope)}
      end

      when_ "the QA agent adds the story 1148 attachment fixtures with the document tool",
            context do
        response =
          ToolLibrary.run(
            "write_document",
            %{document_type: "qa_plan", content: plan_with_fixtures()},
            %{current_scope: context.scope, scope: context.scope}
          )

        refute response.isError, response_text(response)
        {:ok, context}
      end

      then_ "another QA agent reads the fixtures and how to request them", context do
        response =
          ToolLibrary.run(
            "read_document",
            %{document_type: "qa_plan"},
            %{current_scope: context.reader_scope, scope: context.reader_scope}
          )

        refute response.isError, response_text(response)
        text = response_text(response)
        assert text =~ "attachment_fixtures"
        assert text =~ "roles"
        assert text =~ "main"
        assert text =~ "online"
        assert text =~ "offline"
        assert text =~ "unauthorized_working_copy_id"
        assert text =~ "run_script"
        {:ok, context}
      end
    end
  end

  defp plan_without_fixtures do
    """
    # QA Plan

    ## App Overview

    The project has QA journeys.

    ## Tools Registry

    Use the browser to exercise the running application.

    ## Seed Strategy

    Seed a QA account and an example project.
    """
  end

  defp plan_with_fixtures do
    String.replace(
      plan_without_fixtures(),
      "Use the browser to exercise the running application.",
      """
      Use the browser to exercise the running application.

      #### Fixtures for Main's attachment tools (story 1148)

      Request fixtures with `\"roles\": [\"main\"]` and `\"attachment_fixtures\": true`.
      The reply includes `online` copies with harness commands and readiness URLs,
      an `offline` copy, and an `unauthorized_working_copy_id` from another project.
      Start each online harness in its supplied cwd and wait for ready before use.
      As fixture Main, call `run_script` on the candidate's `/mcp/harness` to use
      `connect_working_copy`, `list_working_copy_attachments`, and `work_in_copy`.
      """
    )
  end
end
