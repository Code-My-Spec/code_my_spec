defmodule CodeMySpecSpex.Story1015.Criterion2402Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2402 — Collecting an answer is offered alongside the directive.

  The rule:

  > Every refusal offers collecting an answer to a question the agent asked.

  ## This was a class, and demoting it is the point

  `check_answer` started as the *top* of the tier, ranked above problems, on the
  reasoning that a waiting reply is cheap to collect and may change what the
  right work is. Both of those are true, and it was still wrong.

  A pending question **is** detectable — asking writes a row — so it looked like
  a class. But detectable is necessary for a class, not sufficient: it also has
  to be work in this working copy that the hook can rank against other work. A
  question is neither. Ranked first, one row outranked every real class, and
  `e39b4eba` made that permanent — a question answered anywhere other than
  `QuestionLive` never closes, so a stale row could hold the top of the menu
  forever. This session is in that state right now.

  John: "we should offer answers unconditionally and they will have to
  ultimately be scoped by conversation." The scoping is the real fix for
  `e39b4eba` and is not built here; making it an offer removes the harm in the
  meantime, because an offer costs a line and cannot starve anything.

  ## What this asserts

  That the offer rides a refusal about something else. There is no question
  outstanding in this scenario and the offer is present anyway — which is the
  whole meaning of unconditional, and is why the scenario deliberately does not
  create one. An earlier version of this spec drove `POST /api/questions/ask`
  behind `DeployKeyOrOAuth` to seed a pending question; none of that is needed
  once the answer is that the offer does not depend on the question.

  ## Surface

  `POST /api/hooks/stop`, routed by `x-harness-id`, with an unfinished
  implementation task, the refusal a stop has now that problems never block.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The reply the agent has not read is offered on every refusal", criterion: 899 do
    scenario "an unfinished task is the live class and no question exists at all" do
      given_ :synced_context_component
      given_ :unfinished_implementation_task_started

      when_ "the agent attempts to stop", context do
        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the directive is the unfinished task", context do
        reason = context.response["reason"] || ""

        assert reason =~ "evaluate_task",
               "the offer is additional to the directive, so the directive must " <>
                 "still be there. Got:\n#{reason}"

        {:ok, context}
      end

      then_ "the answer is offered by the tools that collect it, with no question outstanding",
            context do
        reason = context.response["reason"] || ""

        assert reason =~ "check_answer",
               "unconditional means the offer does not depend on a question " <>
                 "existing — which is the point, because a question that exists " <>
                 "and cannot be closed used to hold the top of this menu forever. " <>
                 "It names the tools that collect a reply: John settled e809c0db on " <>
                 "2026-10-05 as option (a), carry both tools, because 'the reply " <>
                 "reaches you' describes a push and an agent whose turn ended before " <>
                 "the answer landed has no way to collect it from that sentence. " <>
                 "The roles that read this now carry `check_answer` and " <>
                 "`list_user_questions`, so the sentence is true of the narrowest " <>
                 "reader rather than the widest. Got:\n#{reason}"

        {:ok, context}
      end

      then_ "the answer offer does not take the directive", context do
        reason = context.response["reason"] || ""
        [next_line | _] = String.split(reason, "\n") |> Enum.filter(&(&1 =~ ~r/\bnext\b/i))

        refute next_line =~ "check_answer",
               "an offer must not become the directive: it is not work in this " <>
                 "working copy and cannot be ranked against work that is. Got:\n#{next_line}"

        {:ok, context}
      end
    end
  end
end
