defmodule CodeMySpecSpex.Story1015.Criterion2411Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2411 — Searching what we already know is offered alongside the
  directive.

  The rule:

  > Every refusal offers searching the project's own documentation, because the
  > hook cannot tell when the agent is missing something it already has.

  The second standing offer, and it exists because John remembered a reason
  agents stop that the first pass missed entirely: not that work is outstanding,
  but that the agent is short of information — information the project very
  often already holds. Framework reference, this project's own research and
  decisions, the specs and rules, all searchable, and an agent that does not
  think to look reasons from nothing and produces confident nonsense.

  That failure costs more than anything in the class list. A red test announces
  itself; a fluent wrong answer does not.

  ## Why an offer and not a class

  Same reason `ask_user_question` is one. No query answers "is this agent missing
  something it could look up" — wanting to know is an intention, and the hook
  sees rows. A first pass at this story made needing-input a class and produced
  a Given nothing could evaluate; this would fail the same way for the same
  reason.

  ## Why it is never withdrawn

  `ask_user_question` steps aside while a question is outstanding, because asking twice
  fills a queue with duplicates and that is a real harm. There is no equivalent
  harm in searching twice, and the case for looking is strongest exactly when
  the agent is stuck enough to be stopping. So this one has no exception, which
  is asserted below rather than assumed.

  ## Surface

  `POST /api/hooks/stop`, routed by `x-harness-id`, with an unfinished
  implementation task, the refusal a stop has now that problems never block. The offer rides a
  refusal like everything else in the menu — nothing on the allow path reaches
  the model.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The agent is reminded that the answer may already be written down", criterion: 904 do
    scenario "an unfinished task is the live class and the documentation offer rides along" do
      given_ :synced_context_component
      given_ :unfinished_implementation_task_started

      when_ "the agent attempts to stop", context do
        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the directive is still the unfinished task", context do
        reason = context.response["reason"] || ""

        assert reason =~ "evaluate_task",
               "the offer is additional to the directive, so the directive must " <>
                 "still be there. Got:\n#{reason}"

        {:ok, context}
      end

      then_ "searching the project's documentation is offered", context do
        reason = context.response["reason"] || ""

        assert reason =~ "semantic_search",
               "an agent short of information is a reason to stop that nothing " <>
                 "here can detect, so the remedy is named every time rather than " <>
                 "waiting for a condition that cannot be evaluated. Got:\n#{reason}"

        {:ok, context}
      end
    end
  end
end
