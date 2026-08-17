defmodule CodeMySpecSpex.Story668.Criterion5484Spex do
  @moduledoc """
  Story 668 — Plan QA infrastructure for every surface of the app
  Criterion 5484 — Plan with bare H2 headers but empty bodies is
  rejected.

  Rule (failure path): bare H2 presence is not enough — the qa_plan
  doc spec demands non-empty content under each required section.
  Otherwise the agent could ship an outline-only plan that satisfies
  the structural checker but contains no actual guidance.

  Surface: `evaluate_task` MCP tool against an active qa_setup task,
  with an outline-only plan in the in-memory environment.

  NOTE: This spec drives implementation. The current
  `validate_required_sections/2` in `CodeMySpec.Documents` only
  checks `Map.has_key?` — a bare H2 header parses to a key with an
  empty string value, which currently passes. The implementation
  must add an empty-body check (likely a new
  `validate_section_bodies` step alongside `validate_required_sections`
  in `create_dynamic_document/2`).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "QA setup evaluate rejects outline-only plans with empty section bodies" do
    scenario "Plan with bare H2 headers but empty bodies is rejected" do
      given_ :qa_setup_task_started

      given_ "an outline-only plan with all required H2 headers but no bodies exists", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/qa/plan.md",
            outline_only_plan()
          )

        # The checker reads its verdict from the Files projection, so a plan
        # that is never synced is never seen — and "not found" is not the
        # rejection this criterion is about.
        {:ok, _} = Fixtures.notify_file_changed(context.scope, ".code_my_spec/qa/plan.md")

        {:ok, context}
      end

      when_ "the agent calls evaluate_task on the active qa_setup task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the evaluate response signals needs-work for the outline-only plan", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/needs work/i,
               "expected evaluate to surface needs-work for empty section bodies, got: #{body}"

        refute body =~ ~r/passed|task completed/i,
               "expected evaluate to NOT report success for outline-only plan, got: #{body}"

        {:ok, context}
      end
    end
  end

  defp outline_only_plan do
    """
    # QA Plan

    ## App Overview

    ## Tools Registry

    ## Seed Strategy
    """
  end
end
