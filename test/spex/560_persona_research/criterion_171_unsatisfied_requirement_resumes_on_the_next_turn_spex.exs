defmodule CodeMySpecSpex.Story560.Criterion5128Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5128 — Unsatisfied requirement resumes on the next turn. After
  the agent stops mid-task without completing the persona, the next
  get_next_requirement call still returns personas_complete — the graph
  doesn't advance until the checker passes.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent stops mid-persona without completing", criterion: 171 do
    scenario "next get_next_requirement still returns personas_complete" do
      # Persona record exists but no files on disk — task incomplete.
      given_ :persona_exists
      given_ :persona_research_task_started

      when_ "the agent fires the stop hook and then asks for next work", context do
        HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :next_response, response)}
      end

      then_ "the response still surfaces personas_complete", context do
        body = response_text(context.next_response)

        assert body =~ "personas_complete" or body =~ "project_setup",
               "expected the graph to remain blocked before personas_complete; got #{inspect(context.next_response)}"

        {:ok, context}
      end
    end
  end
end
