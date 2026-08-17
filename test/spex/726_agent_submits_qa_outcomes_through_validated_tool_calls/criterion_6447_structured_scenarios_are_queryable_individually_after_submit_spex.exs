defmodule CodeMySpecSpex.Story726.Criterion6447Spex do
  @moduledoc """
  Story 726 — Agent submits QA outcomes through validated tool calls
  Criterion 6447 — Structured scenarios are queryable individually
  after submit.

  Demonstrates the structured-scenarios rule: a submit payload's
  scenarios are stored as separate, named records that show up
  individually in `list_qa_attempts`.

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult`
  - `CodeMySpec.McpServers.Qa.Tools.ListQaAttempts`
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.{ListQaAttempts, SubmitQaResult}

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "The submit payload's scenarios field is a structured list" do
    scenario "Structured scenarios are queryable individually after submit" do
      given_ "a started qa_complete task", context do
        {:ok, context}
      end

      when_ "the agent submits with three scenarios (name + status + observation)", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SubmitQaResult.execute(
            %{
              task_id: context.task_id,
              status: "pass",
              scenarios: [
                %{name: "alpha_scenario", status: "pass", observation: "alpha worked"},
                %{name: "beta_scenario", status: "pass", observation: "beta worked"},
                %{name: "gamma_scenario", status: "pass", observation: "gamma worked"}
              ],
              issue_ids: []
            },
            frame
          )

        refute response.isError
        {:ok, context}
      end

      then_ "each scenario is queryable individually by name in the attempt record",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} =
          ListQaAttempts.execute(%{story_id: context.story.id}, frame)

        refute list_response.isError
        text = response_text(list_response)

        assert text =~ "alpha_scenario"
        assert text =~ "beta_scenario"
        assert text =~ "gamma_scenario"

        assert text =~ "alpha worked"
        assert text =~ "beta worked"
        assert text =~ "gamma worked"

        {:ok, context}
      end
    end
  end
end
