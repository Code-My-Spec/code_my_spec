defmodule CodeMySpecSpex.Story1158.Criterion2461Spex do
  @moduledoc """
  Story 1158 — QA plans and briefs are documents in the database, not files in the docs submodule.
  Criterion 2461 — A plan change made on one copy is what QA on another copy reads.

  The two scopes belong to the same project but have distinct working copies
  and filesystems. The only cross-copy action is through document tools.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "QA agents share the project's plan document across working copies", criterion: 2461 do
    scenario "copy B immediately reads the sign-in step added on copy A" do
      given_ "QA agents are on two working copies of the same project", context do
        copy_b_scope = Fixtures.live_agent_scope(context.scope, label: "QA working copy B")

        baseline =
          ToolLibrary.run(
            "write_document",
            %{document_type: "qa_plan", content: baseline_plan()},
            %{current_scope: context.scope, scope: context.scope}
          )

        false = match?({:error, _}, baseline)
        {:ok, Map.put(context, :copy_b_scope, copy_b_scope)}
      end

      when_ "the QA agent on copy A adds a sign-in step to the plan document", context do
        response =
          ToolLibrary.run(
            "write_document",
            %{document_type: "qa_plan", content: plan_with_sign_in_step()},
            %{current_scope: context.scope, scope: context.scope}
          )

        {:ok, Map.put(context, :write_response, response)}
      end

      then_ "copy B reads the updated plan without syncing either checkout", context do
        refute match?({:error, _}, context.write_response), response_text(context.write_response)

        response =
          ToolLibrary.run(
            "read_document",
            %{document_type: "qa_plan"},
            %{current_scope: context.copy_b_scope, scope: context.copy_b_scope}
          )

        refute match?({:error, _}, response), response_text(response)
        assert response_text(response) =~ "Sign in as the QA account before starting a journey."
        {:ok, context}
      end
    end
  end

  defp baseline_plan do
    String.replace(
      plan_with_sign_in_step(),
      "Sign in as the QA account before starting a journey.\n",
      ""
    )
  end

  defp plan_with_sign_in_step do
    """
    # QA Plan

    ## App Overview

    The project has authenticated journeys.
    Sign in as the QA account before starting a journey.

    ## Tools Registry

    Use the browser tool to exercise the running application.

    ## Seed Strategy

    Seed a QA account and an example project before running journeys.
    """
  end
end
