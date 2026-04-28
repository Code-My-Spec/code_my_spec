defmodule CodeMySpecSpex.Story668.Criterion5483Spex do
  @moduledoc """
  Story 668 — Plan QA infrastructure for every surface of the app
  Criterion 5483 — Plan missing the Tools Registry section fails
  with a friendly section-name list.

  Rule (failure path): when the agent ships a plan missing a
  required H2 section, evaluate surfaces structured feedback naming
  the missing section in backtick form, plus the qa_plan format
  spec, so the agent can self-correct on the next pass.

  Surface: `evaluate_task` MCP tool against an active qa_setup task,
  with an incomplete plan in the in-memory environment.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "QA setup evaluate names missing required sections" do
    scenario "Plan missing the Tools Registry section fails with a friendly section-name list" do
      given_ :qa_setup_task_started

      given_ "a plan exists with App Overview and Seed Strategy but no Tools Registry", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/qa/plan.md",
            incomplete_plan()
          )

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

      then_ "the evaluate response signals needs-work", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/needs work/i,
               "expected evaluate to surface needs-work for missing section, got: #{body}"

        refute body =~ ~r/passed|task completed/i,
               "expected evaluate to NOT report success for incomplete plan, got: #{body}"

        {:ok, context}
      end

      then_ "the feedback names the missing Tools Registry section in backtick form", context do
        body = response_text(context.evaluate_response)

        assert body =~ "`## Tools Registry`",
               "expected feedback to name `## Tools Registry` in backtick form, got: #{body}"

        {:ok, context}
      end

      then_ "the feedback re-includes the qa_plan format spec for self-correction", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/QA Plan Format/i,
               "expected feedback to include the QA Plan Format spec, got: #{body}"

        {:ok, context}
      end
    end
  end

  defp incomplete_plan do
    """
    # QA Plan

    ## App Overview

    Phoenix web app on port 4000.

    ## Seed Strategy

    Run `mix run priv/repo/qa_seeds.exs`.
    """
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
