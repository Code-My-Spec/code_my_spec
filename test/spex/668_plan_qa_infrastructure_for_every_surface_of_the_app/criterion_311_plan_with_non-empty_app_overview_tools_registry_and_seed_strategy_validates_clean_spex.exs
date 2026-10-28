defmodule CodeMySpecSpex.Story668.Criterion5482Spex do
  @moduledoc """
  Story 668 — Plan QA infrastructure for every surface of the app
  Criterion 5482 — Plan with non-empty App Overview, Tools Registry,
  and Seed Strategy validates clean.

  Rule (happy path): when the agent writes a plan with all three
  required H2 sections present and non-empty, evaluate_task returns a
  passing response.

  Surface: `evaluate_task` MCP tool against an active qa_setup task,
  with a valid plan written to `.code_my_spec/qa/plan.md` in the
  in-memory environment.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "QA setup evaluate accepts plans with all required sections non-empty", criterion: 311 do
    scenario "Plan with non-empty App Overview, Tools Registry, and Seed Strategy validates clean" do
      given_ :qa_setup_task_started

      given_ "this copy reads the fixture's in-memory files", context do
        {:ok, HarnessHooks.serve_in_memory(context)}
      end

      given_ "a complete plan exists at .code_my_spec/qa/plan.md", context do
        {:ok, _} = CodeMySpec.Qa.Documents.put(context.scope, "qa_plan", nil, valid_plan())

        {:ok, context}
      end

      when_ "the agent calls evaluate_task on the active qa_setup task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the evaluate response signals task completion", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/passed|task completed/i,
               "expected evaluate to surface success for valid plan, got: #{body}"

        refute body =~ ~r/needs work/i,
               "expected evaluate to NOT report needs work for valid plan, got: #{body}"

        {:ok, context}
      end
    end
  end

  defp valid_plan do
    """
    # QA Plan

    ## App Overview

    The app is a Phoenix web application running on port 4000.
    Auth is session-based via phx.gen.auth.

    ## Tools Registry

    - Vibium MCP for browser pipelines
    - curl for JSON API pipelines

    ## Seed Strategy

    Run `mix run priv/repo/qa_seeds.exs` to populate test users and
    projects. Credentials print at the end of the run.
    """
  end
end
