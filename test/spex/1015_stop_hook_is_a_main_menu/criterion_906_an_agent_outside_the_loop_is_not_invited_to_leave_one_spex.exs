defmodule CodeMySpecSpex.Story1015.Criterion2413Spex do
  @moduledoc """
  Story 894 — Stop hook is a main menu
  Criterion 2413 — An agent outside the loop is not invited to leave one.

  The rule:

  > A refusal made while the autonomous loop is running offers leaving it.

  The negative half, and the reason this offer is the one exception to
  unconditional. `ask_question` and `semantic_search` are printed
  every time because what they serve is invisible from here — an unread reply, a
  decision the agent needs, a fact already written down. None of those can be
  detected, so none can be gated.

  `session.continuous` can. And offering `tap_out` outside the loop would be
  worse than noise: it reads as an instruction, the tool would refuse it — its
  whole job is clearing a flag that is not set — and an agent that tried it
  would spend a turn learning that. Three unconditional offers plus one gated on
  a flag is not an inconsistency; it is the difference between what can be known
  and what cannot.

  Paired with 2412 deliberately. On its own, 2412 passes for a response that
  offers `tap_out` always, which is the failure this asserts against.

  ## Surface

  `POST /api/hooks/stop`, routed by `x-harness-id`. Identical to 2412 except
  that continuous mode is never enabled — this session is an ordinary
  interactive one, which is the common case and the one that must stay quiet.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An interactive agent is not told to quit a loop it is not in", criterion: 906 do
    scenario "continuous mode is off and the stop is refused on an unfinished task" do
      given_ :synced_context_component
      # No `start_continuous_mode` here, and that absence is the scenario.
      given_ :unfinished_implementation_task_started

      when_ "the agent attempts to stop", context do
        response = HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is refused, so there are offers to inspect at all", context do
        # The anchor. Without a refusal the refutation below passes against an
        # empty string and proves nothing.
        assert context.response["decision"] == "block",
               "this scenario needs a refusal for the refutation to mean anything. " <>
                 "Got: #{inspect(context.response)}"

        {:ok, context}
      end

      then_ "leaving the loop is not offered", context do
        reason = context.response["reason"] || ""

        # The loop offer, not the tool name: an unfinished task's directive names
        # `tap_out` as one way to block that task, which is not leaving a loop.
        refute reason =~ "asks to leave it",
               "there is no loop to leave, and offering to leave one reads as an " <>
                 "instruction to use a tool that would refuse. Got:\n#{reason}"

        {:ok, context}
      end

      then_ "the unconditional offers are still there", context do
        # Proves the refutation above is about `tap_out` specifically rather
        # than about the offers section being absent.
        reason = context.response["reason"] || ""

        assert reason =~ "ask_question"
        assert reason =~ "semantic_search"

        {:ok, context}
      end
    end
  end
end
