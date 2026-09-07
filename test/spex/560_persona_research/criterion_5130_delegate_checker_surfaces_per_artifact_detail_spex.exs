defmodule CodeMySpecSpex.Story560.Criterion5130Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5130 — Delegate checker surfaces per-artifact detail through the
  hook. When the checker fails for a specific persona, the stop-hook
  feedback names both the persona slug AND the specific missing artifact.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "checker fails with per-persona detail" do
    scenario "hook response names the persona slug AND the artifact gap" do
      given_ :persona_exists
      given_ :persona_research_task_started

      when_ "the agent calls evaluate_task", context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "feedback carries both slug and artifact specifics", context do
        body = response_text(context.response)

        assert body =~ ~r/Needs work|incomplete|missing|invalid/i,
               "expected blocking feedback"

        assert body =~ context.persona_slug,
               "expected feedback to name the persona slug (per-persona detail)"

        assert body =~ ~r/summary\.md|sources\.md/,
               "expected feedback to name a specific artifact (per-artifact detail)"

        {:ok, context}
      end
    end
  end
end
